import Foundation
import Observation
import SwiftData

/// 全局偏好设置与行情刷新状态管理（使用 iOS 17 `@Observable`）
@MainActor
@Observable
final class PortfolioRefreshStore {
    private enum Keys {
        static let hideAmounts = "MyMoney.pref.hideAmounts"
        static let pnlColorScheme = "MyMoney.pref.pnlColorScheme"
        static let themeMode = "MyMoney.pref.themeMode"
        static let lastNetworkRefresh = "MyMoney.pref.lastNetworkRefresh"
    }

    var isRefreshing: Bool = false
    var statusBannerText: String?
    var errorMessages: [String] = []

    var hideAmounts: Bool {
        didSet { UserDefaults.standard.set(hideAmounts, forKey: Keys.hideAmounts) }
    }

    var pnlColorScheme: PnLColorScheme {
        didSet { UserDefaults.standard.set(pnlColorScheme.rawValue, forKey: Keys.pnlColorScheme) }
    }

    var themeMode: AppThemeMode {
        didSet { UserDefaults.standard.set(themeMode.rawValue, forKey: Keys.themeMode) }
    }

    var lastNetworkRefresh: Date? {
        didSet { UserDefaults.standard.set(lastNetworkRefresh, forKey: Keys.lastNetworkRefresh) }
    }

    private let priceService = PriceService()

    init() {
        let defaults = UserDefaults.standard
        self.hideAmounts = defaults.bool(forKey: Keys.hideAmounts)
        if let rawPnL = defaults.string(forKey: Keys.pnlColorScheme),
           let parsedPnL = PnLColorScheme(rawValue: rawPnL) {
            self.pnlColorScheme = parsedPnL
        } else {
            self.pnlColorScheme = .redUpGreenDown
        }

        if let rawTheme = defaults.string(forKey: Keys.themeMode),
           let parsedTheme = AppThemeMode(rawValue: rawTheme) {
            self.themeMode = parsedTheme
        } else {
            self.themeMode = .system
        }

        self.lastNetworkRefresh = defaults.object(forKey: Keys.lastNetworkRefresh) as? Date
    }

    /// 并发刷新全部联网证券与场外基金持仓
    func refreshAllQuotes(holdings: [AssetHolding], in context: ModelContext) async {
        guard !isRefreshing else { return }

        let refreshable = holdings.filter { $0.supportsQuoteRefresh }
        guard !refreshable.isEmpty else {
            statusBannerText = "当前没有需要联网更新单价的证券或基金"
            errorMessages = []
            return
        }

        isRefreshing = true
        errorMessages = []
        statusBannerText = nil
        defer { isRefreshing = false }

        let keys = refreshable.map {
            QuoteLookupKey(
                mode: $0.valuationMode,
                normalizedCode: $0.code.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        let batchOutcome = await priceService.fetchBatchQuotes(keys: keys)

        var updatedCount = 0
        var failures: [String] = []
        let now = Date.now

        for holding in refreshable {
            let key = QuoteLookupKey(
                mode: holding.valuationMode,
                normalizedCode: holding.code.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            guard let result = batchOutcome[key] else { continue }

            switch result {
            case .success(let quote):
                holding.latestPrice = quote.price
                if !quote.dateText.isEmpty {
                    holding.priceDateText = quote.dateText
                }
                if holding.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    holding.name = quote.name
                }
                holding.lastUpdated = now
                updatedCount += 1

            case .failure(let error):
                let message = "\(holding.name)(\(holding.code))：\(error.localizedDescription)"
                if !failures.contains(message) {
                    failures.append(message)
                }
            }
        }

        try? context.save()
        if updatedCount > 0 {
            lastNetworkRefresh = now
        }

        errorMessages = failures
        if failures.isEmpty {
            statusBannerText = "已更新 \(updatedCount) 项行情净值"
        } else {
            statusBannerText = "成功 \(updatedCount) 项，失败 \(failures.count) 项"
        }
    }

    /// 单独查询某个代码（用于新增/编辑页一键识别名称与现价）
    func lookupSingleQuote(code: String, mode: ValuationMode) async throws -> QuoteResult {
        try await priceService.fetchQuote(code: code, mode: mode)
    }

    /// 刷新单条持仓价格
    func refreshSingleHolding(_ holding: AssetHolding, in context: ModelContext) async throws {
        let quote = try await priceService.fetchQuote(code: holding.code, mode: holding.valuationMode)
        holding.latestPrice = quote.price
        if !quote.dateText.isEmpty {
            holding.priceDateText = quote.dateText
        }
        if holding.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            holding.name = quote.name
        }
        holding.lastUpdated = .now
        try? context.save()
        lastNetworkRefresh = .now
    }
}
