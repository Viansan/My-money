import Foundation
import CoreFoundation

/// 单只标的行情查询结果（自带识别出的准确计价模式，无需用户区分场内/场外）
struct QuoteResult: Sendable, Identifiable, Equatable {
    var id: String { "\(mode.rawValue)-\(code)" }
    let code: String
    let name: String
    let price: Double
    let dateText: String
    let source: String
    let mode: ValuationMode
    /// 是否为纯场内 ETF（腾讯第 61 字段为 "ETF"，用于自动消除 ETF 场内现价与参考净值的重复干扰）
    let isPureETF: Bool
}

/// 去重查询键（同一代码在同一计价模式下仅请求一次网络）
struct QuoteLookupKey: Hashable, Sendable {
    let mode: ValuationMode
    let normalizedCode: String
}

/// 行情拉取错误定义
enum QuoteError: LocalizedError, Sendable {
    case emptyCode
    case unsupportedMode
    case networkFailure(String)
    case invalidResponse(String)
    case zeroOrMissingPrice(String)

    var errorDescription: String? {
        switch self {
        case .emptyCode:
            return "请输入证券或基金代码"
        case .unsupportedMode:
            return "该计价方式无需联网拉取行情"
        case .networkFailure(let detail):
            return "网络请求失败：\(detail)"
        case .invalidResponse(let code):
            return "未找到代码「\(code)」的行情，请核对代码或手动填单价"
        case .zeroOrMissingPrice(let code):
            return "代码「\(code)」暂无有效价格，请稍后重试或手动填单价"
        }
    }
}

/// 异步行情与净值服务
/// - 系统自动判断场内证券 / 场外基金：用户输入代码即可直出结果，仅在真实重码（如 000001 / LOF）时列出双候选
/// - 场内证券：腾讯财经实时行情接口（GB18030 解码 + 集合竞价 0 价自动回退昨收保护）
/// - 场外基金：腾讯场外净值 + 东财移动端净值 + F10 历史净值三级自动兜底（兼容债基与美股 QDII）
struct PriceService: Sendable {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
    }

    // MARK: - 公开查询入口

    /// 智能识别代码：自动判断是场内现价还是场外净值
    /// - 95% 以上代码直接返回 1 条精准匹配结果；
    /// - 仅在极少数真实重码（如 000001 平安银行/华夏成长，或 161125 LOF 场内/场外双渠道）时返回 2 条供用户轻点切换。
    func lookupSmartCandidates(rawCode: String) async throws -> [QuoteResult] {
        let cleaned = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw QuoteError.emptyCode
        }

        let lower = cleaned.lowercased()

        // 1. 显式基金前缀 jj
        if lower.hasPrefix("jj") {
            let fund = try await fetchOTCFundQuote(rawCode: cleaned)
            return [fund]
        }

        // 2. 显式交易所前缀、美股全字母、或 5 位港股代码 -> 100% 场内证券
        if lower.hasPrefix("sh") || lower.hasPrefix("sz") || lower.hasPrefix("bj")
            || lower.hasPrefix("hk") || (lower.hasPrefix("us") && cleaned.count > 2)
            || cleaned.allSatisfy({ $0.isLetter })
            || (cleaned.count == 5 && cleaned.allSatisfy({ $0.isNumber })) {
            let sec = try await fetchExchangeSecurityQuote(rawCode: cleaned)
            return [sec]
        }

        // 3. 6 位数字代码：并行探测场内现价与场外净值（完美兼容 519xxx 沪市场外基金、51/56/58/159 ETF、LOF 及普通 A 股/公募）
        async let exchangeTask: Result<QuoteResult, Error> = {
            do { return .success(try await self.fetchExchangeSecurityQuote(rawCode: cleaned)) }
            catch { return .failure(error) }
        }()

        async let otcTask: Result<QuoteResult, Error> = {
            do { return .success(try await self.fetchOTCFundQuote(rawCode: cleaned)) }
            catch { return .failure(error) }
        }()

        let exchangeOutcome = await exchangeTask
        let otcOutcome = await otcTask

        switch (exchangeOutcome, otcOutcome) {
        case (.success(let ex), .success(let otc)):
            // 纯场内 ETF（如 515800、563020、159915）天然只有场内持仓形态，直接返回场内现价，不打扰用户二选一
            if ex.isPureETF {
                return [ex]
            }
            // 真正存在场内/场外双义的标的（如 000001 或 161125/501018 LOF），返回双候选
            return [ex, otc]

        case (.success(let ex), .failure):
            return [ex]

        case (.failure, .success(let otc)):
            return [otc]

        case (.failure(let err1), .failure(let err2)):
            if case QuoteError.networkFailure = err1 {
                throw err1
            }
            if case QuoteError.networkFailure = err2 {
                throw err2
            }
            throw QuoteError.invalidResponse(cleaned)
        }
    }

    /// 按已知计价模式查询单只标的（用于批量刷新已有持仓）
    func fetchQuote(code: String, mode: ValuationMode) async throws -> QuoteResult {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw QuoteError.emptyCode
        }

        switch mode {
        case .manualAmount:
            throw QuoteError.unsupportedMode
        case .exchangeSecurity:
            return try await fetchExchangeSecurityQuote(rawCode: trimmed)
        case .otcFund:
            return try await fetchOTCFundQuote(rawCode: trimmed)
        }
    }

    /// 并发批量拉取多只持仓行情（使用 TaskGroup，自动按代码去重）
    func fetchBatchQuotes(keys: [QuoteLookupKey]) async -> [QuoteLookupKey: Result<QuoteResult, Error>] {
        let uniqueKeys = Array(Set(keys))
        guard !uniqueKeys.isEmpty else { return [:] }

        return await withTaskGroup(of: (QuoteLookupKey, Result<QuoteResult, Error>).self) { group in
            for key in uniqueKeys {
                group.addTask {
                    do {
                        let quote = try await self.fetchQuote(code: key.normalizedCode, mode: key.mode)
                        return (key, .success(quote))
                    } catch {
                        return (key, .failure(error))
                    }
                }
            }

            var results: [QuoteLookupKey: Result<QuoteResult, Error>] = [:]
            for await (key, outcome) in group {
                results[key] = outcome
            }
            return results
        }
    }

    // MARK: - 1. 场内证券行情（腾讯财经）

    private func fetchExchangeSecurityQuote(rawCode: String) async throws -> QuoteResult {
        let symbol = Self.resolveTencentExchangeSymbol(rawCode)
        guard let url = URL(string: "https://qt.gtimg.cn/q=\(symbol)") else {
            throw QuoteError.invalidResponse(rawCode)
        }

        let data = try await performGET(url: url)
        guard let decoded = Self.decodeGB18030(data),
              let payload = Self.extractQuotedPayload(from: decoded) else {
            throw QuoteError.invalidResponse(rawCode)
        }

        let fields = payload.components(separatedBy: "~")
        guard fields.count > 5 else {
            throw QuoteError.invalidResponse(rawCode)
        }

        let name = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw QuoteError.invalidResponse(rawCode)
        }

        let currentPrice = Double(fields[3]) ?? 0
        let previousClose = Double(fields[4]) ?? 0
        // 早盘 9:15 前集合竞价或临时停牌时现价可能为 0.000，自动回退读取昨收价保护市值不归零
        let effectivePrice = currentPrice > 0 ? currentPrice : previousClose
        guard effectivePrice > 0 else {
            throw QuoteError.zeroOrMissingPrice(rawCode)
        }

        let rawTimestamp = fields.count > 30 ? fields[30] : ""
        let formattedDate = Self.formatTencentTimestamp(rawTimestamp)
        let kindField = fields.count > 61 ? fields[61].trimmingCharacters(in: .whitespacesAndNewlines).uppercased() : ""
        let isPureETF = (kindField == "ETF")

        return QuoteResult(
            code: rawCode,
            name: name,
            price: effectivePrice,
            dateText: formattedDate,
            source: "场内现价",
            mode: .exchangeSecurity,
            isPureETF: isPureETF
        )
    }

    /// 根据输入代码自动推断市场前缀（兼容 sh / sz / bj / hk / us）
    static func resolveTencentExchangeSymbol(_ input: String) -> String {
        let cleaned = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = cleaned.lowercased()

        if lower.hasPrefix("sh") || lower.hasPrefix("sz") || lower.hasPrefix("bj") || lower.hasPrefix("hk") {
            return lower
        }
        if lower.hasPrefix("us") && cleaned.count > 2 {
            let ticker = cleaned.dropFirst(2).uppercased()
            return "us\(ticker)"
        }

        // 全字母默认按美股代码处理（如 SPY、QQQ、AAPL）
        if cleaned.allSatisfy({ $0.isLetter }) {
            return "us\(cleaned.uppercased())"
        }

        // 5 位数字默认按港股处理（如 00700）
        if cleaned.count == 5 && cleaned.allSatisfy({ $0.isNumber }) {
            return "hk\(cleaned)"
        }

        // 沪深京 6 位证券/ETF代码判断
        if let first = cleaned.first {
            switch first {
            case "5", "6", "9":
                return "sh\(cleaned)"
            case "0", "1", "2", "3":
                return "sz\(cleaned)"
            case "4", "8":
                return "bj\(cleaned)"
            default:
                break
            }
        }
        return "sh\(cleaned)"
    }

    // MARK: - 2. 场外基金官方单位净值（三级容错，杜绝失真盘中估值）

    private func fetchOTCFundQuote(rawCode: String) async throws -> QuoteResult {
        let code = rawCode.lowercased().hasPrefix("jj") ? String(rawCode.dropFirst(2)) : rawCode

        // 第一级：腾讯场外基金净值接口（速度快、覆盖公募/债基/QDII，直接返回名称 + 最新官方单位净值 + 净值日期）
        if let quote = try? await fetchOTCViaTencent(code: code) {
            return quote
        }

        // 第二级：东方财富移动端基金详情接口（UTF-8 JSON，含简称与官方 DWJZ）
        if let quote = try? await fetchOTCViaEastmoneyMobile(code: code) {
            return quote
        }

        // 第三级：东方财富 F10 历史净值接口（取最新一期官方 DWJZ）
        return try await fetchOTCViaEastmoneyLSJZ(code: code)
    }

    private func fetchOTCViaTencent(code: String) async throws -> QuoteResult {
        guard let url = URL(string: "https://qt.gtimg.cn/q=jj\(code)") else {
            throw QuoteError.invalidResponse(code)
        }
        let data = try await performGET(url: url)
        guard let decoded = Self.decodeGB18030(data),
              let payload = Self.extractQuotedPayload(from: decoded) else {
            throw QuoteError.invalidResponse(code)
        }

        // 格式示例: 050025~博时标普500ETF联接A~0.0000~0.0000~~5.0216~5.0806~-3.5180~2026-11-20~
        let fields = payload.components(separatedBy: "~")
        guard fields.count > 8 else {
            throw QuoteError.invalidResponse(code)
        }

        let name = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let officialNAV = Double(fields[5]) ?? 0
        let navDate = Self.formatShortDate(fields[8])

        guard !name.isEmpty, officialNAV > 0 else {
            throw QuoteError.zeroOrMissingPrice(code)
        }

        return QuoteResult(
            code: code,
            name: name,
            price: officialNAV,
            dateText: navDate,
            source: "场外净值",
            mode: .otcFund,
            isPureETF: false
        )
    }

    private func fetchOTCViaEastmoneyMobile(code: String) async throws -> QuoteResult {
        var components = URLComponents(string: "https://fundmobapi.eastmoney.com/FundMNewApi/FundMNBasicInformation")
        components?.queryItems = [
            URLQueryItem(name: "FCODE", value: code),
            URLQueryItem(name: "deviceid", value: "MyMoneyApp"),
            URLQueryItem(name: "plat", value: "Iphone"),
            URLQueryItem(name: "product", value: "EFund"),
            URLQueryItem(name: "version", value: "6.5.0")
        ]
        guard let url = components?.url else {
            throw QuoteError.invalidResponse(code)
        }

        let data = try await performGET(url: url)
        let decoded = try JSONDecoder().decode(EastmoneyMobileResponse.self, from: data)
        guard let info = decoded.Datas,
              let name = info.SHORTNAME, !name.isEmpty,
              let navString = info.DWJZ, let nav = Double(navString), nav > 0 else {
            throw QuoteError.invalidResponse(code)
        }

        return QuoteResult(
            code: code,
            name: name,
            price: nav,
            dateText: Self.formatShortDate(info.FSRQ ?? ""),
            source: "场外净值",
            mode: .otcFund,
            isPureETF: false
        )
    }

    private func fetchOTCViaEastmoneyLSJZ(code: String) async throws -> QuoteResult {
        var components = URLComponents(string: "https://api.fund.eastmoney.com/f10/lsjz")
        components?.queryItems = [
            URLQueryItem(name: "fundCode", value: code),
            URLQueryItem(name: "pageIndex", value: "1"),
            URLQueryItem(name: "pageSize", value: "1")
        ]
        guard let url = components?.url else {
            throw QuoteError.invalidResponse(code)
        }

        let data = try await performGET(
            url: url,
            headers: [
                "Referer": "https://fundf10.eastmoney.com/",
                "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15"
            ]
        )
        let decoded = try JSONDecoder().decode(EastmoneyLSJZResponse.self, from: data)
        guard let item = decoded.Data?.LSJZList.first,
              let nav = Double(item.DWJZ), nav > 0 else {
            throw QuoteError.invalidResponse(code)
        }

        return QuoteResult(
            code: code,
            name: "基金 \(code)",
            price: nav,
            dateText: Self.formatShortDate(item.FSRQ),
            source: "场外净值",
            mode: .otcFund,
            isPureETF: false
        )
    }

    // MARK: - 网络与编码工具

    private func performGET(url: URL, headers: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw QuoteError.networkFailure("HTTP \(http.statusCode)")
            }
            return data
        } catch let error as QuoteError {
            throw error
        } catch {
            throw QuoteError.networkFailure(error.localizedDescription)
        }
    }

    /// 使用 GB_18030_2000 解码腾讯财经返回文本，兼容简体/繁体中文证券简称
    static func decodeGB18030(_ data: Data) -> String? {
        let cfEncoding = CFStringEncodings.GB_18030_2000
        let nsEncoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cfEncoding.rawValue))
        let gbkEncoding = String.Encoding(rawValue: nsEncoding)
        if let text = String(data: data, encoding: gbkEncoding) {
            return text
        }
        return String(data: data, encoding: .utf8)
    }

    /// 提取双引号内的行情正文
    private static func extractQuotedPayload(from raw: String) -> String? {
        guard let firstQuote = raw.firstIndex(of: "\""),
              let lastQuote = raw.lastIndex(of: "\""),
              firstQuote < lastQuote else {
            return nil
        }
        let content = raw[raw.index(after: firstQuote)..<lastQuote]
        return content.isEmpty ? nil : String(content)
    }

    /// 统一规范场内时间戳为简洁的 "MM-dd HH:mm"（兼容 A 股 14 位数字、港股斜杠、美股连字符）
    private static func formatTencentTimestamp(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 12 && trimmed.allSatisfy({ $0.isNumber }) {
            let month = trimmed.dropFirst(4).prefix(2)
            let day = trimmed.dropFirst(6).prefix(2)
            let hour = trimmed.dropFirst(8).prefix(2)
            let minute = trimmed.dropFirst(10).prefix(2)
            return "\(month)-\(day) \(hour):\(minute)"
        }
        let normalized = trimmed.replacingOccurrences(of: "/", with: "-")
        // 格式如 "2026-11-23 16:00:01" -> "11-23 16:00"
        if normalized.count >= 16, normalized.dropFirst(4).hasPrefix("-") {
            return String(normalized.dropFirst(5).prefix(11))
        }
        return formatShortDate(normalized)
    }

    /// 统一规范日期为 "MM-dd"（如 "2026-11-20" -> "11-20"）
    private static func formatShortDate(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        if trimmed.count >= 10, trimmed.dropFirst(4).hasPrefix("-") {
            return String(trimmed.dropFirst(5).prefix(5))
        }
        return trimmed
    }
}

// MARK: - 内部 JSON 响应模型

private struct EastmoneyMobileResponse: Decodable, Sendable {
    struct FundInfo: Decodable, Sendable {
        let FCODE: String?
        let SHORTNAME: String?
        let DWJZ: String?
        let FSRQ: String?
    }
    let Datas: FundInfo?
}

private struct EastmoneyLSJZResponse: Decodable, Sendable {
    struct DataContainer: Decodable, Sendable {
        let LSJZList: [Item]
    }
    struct Item: Decodable, Sendable {
        let FSRQ: String
        let DWJZ: String
    }
    let Data: DataContainer?
}
