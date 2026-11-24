import Foundation
import Observation
import SwiftData

/// 底部 Tab 路由标识
enum AppTab: Int, Hashable {
    case overview = 0
    case holdings = 1
    case management = 2
}

/// 从总览点击切片下钻到资产页的精准筛选条件
struct HoldingsDrilldownFilter: Equatable {
    enum Kind: Equatable {
        case category(UUID?)
        case account(UUID?)
    }
    let kind: Kind
    let label: String
}

/// 全局状态、行情刷新、跨页下钻、统一 Toast 与撤销删除协调器（iOS 17 `@Observable`）
@MainActor
@Observable
final class PortfolioRefreshStore {
    private enum Keys {
        static let hideAmounts = "MyMoney.pref.hideAmounts"
        static let pnlColorScheme = "MyMoney.pref.pnlColorScheme"
        static let themeMode = "MyMoney.pref.themeMode"
        static let lastNetworkRefresh = "MyMoney.pref.lastNetworkRefresh"
    }

    // MARK: - 导航与下钻状态
    var selectedTab: AppTab = .overview
    var holdingsGroupMode: HoldingsGroupMode = .byCategory
    var holdingsPoolFilter: PoolFilterOption = .all
    var activeDrilldown: HoldingsDrilldownFilter?

    // MARK: - 行情刷新状态
    var isRefreshing: Bool = false

    // MARK: - 统一非阻塞 Toast 与撤销栈
    var currentToast: AppToast?
    private var toastActionHandler: (() -> Void)?
    private var toastDismissTask: Task<Void, Never>?
    private var lastDeletedHolding: BackupPayload.HoldingDTO?

    // MARK: - 持久化用户偏好
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
    /// 自动刷新静默冷却间隔（5 分钟内重复回到前台不再重复打扰网络）
    private let autoRefreshStaleInterval: TimeInterval = 300

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

    // MARK: - 统一 Toast 反馈（不打断用户当前操作）

    func showToast(
        style: AppToast.Style,
        message: String,
        details: [String] = [],
        actionTitle: String? = nil,
        autoDismissSeconds: TimeInterval? = 2.6,
        action: (() -> Void)? = nil
    ) {
        toastDismissTask?.cancel()
        toastActionHandler = action

        let toast = AppToast(
            style: style,
            message: message,
            details: details,
            actionTitle: actionTitle,
            autoDismissSeconds: autoDismissSeconds
        )
        currentToast = toast

        if let delay = autoDismissSeconds {
            let toastID = toast.id
            toastDismissTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self, self.currentToast?.id == toastID else { return }
                self.dismissToast()
            }
        }
    }

    func triggerToastAction() {
        let handler = toastActionHandler
        dismissToast()
        handler?()
    }

    func dismissToast() {
        toastDismissTask?.cancel()
        toastDismissTask = nil
        toastActionHandler = nil
        currentToast = nil
    }

    // MARK: - 跨页下钻（「总览」卡片点一下直达「资产」对应分组）

    func drillDownToCategory(id: UUID?, name: String, pool: AssetPool) {
        Haptics.selection()
        holdingsGroupMode = .byCategory
        holdingsPoolFilter = (pool == .fixed) ? .fixed : .investable
        activeDrilldown = HoldingsDrilldownFilter(kind: .category(id), label: name)
        selectedTab = .holdings
    }

    func drillDownToAccount(id: UUID?, name: String) {
        Haptics.selection()
        holdingsGroupMode = .byAccount
        holdingsPoolFilter = .all
        activeDrilldown = HoldingsDrilldownFilter(kind: .account(id), label: name)
        selectedTab = .holdings
    }

    func clearDrilldown() {
        Haptics.selection()
        activeDrilldown = nil
        holdingsPoolFilter = .all
    }

    // MARK: - 安全删除 + 5 秒一键撤销

    func deleteHoldingWithUndo(_ holding: AssetHolding, in context: ModelContext) {
        let dto = BackupPayload.HoldingDTO(
            id: holding.id,
            name: holding.name,
            valuationModeRaw: holding.valuationModeRaw,
            code: holding.code,
            shares: holding.shares,
            latestPrice: holding.latestPrice,
            manualAmount: holding.manualAmount,
            totalCost: holding.totalCost,
            priceDateText: holding.priceDateText,
            lastUpdated: holding.lastUpdated,
            note: holding.note,
            sortOrder: holding.sortOrder,
            fallbackPoolRaw: holding.fallbackPoolRaw,
            categoryID: holding.category?.id,
            accountID: holding.account?.id
        )
        let deletedName = holding.name
        lastDeletedHolding = dto

        context.delete(holding)
        try? context.save()
        Haptics.warning()

        showToast(
            style: .info,
            message: "已删除「\(deletedName)」",
            actionTitle: "撤销",
            autoDismissSeconds: 5.0
        ) { [weak self] in
            self?.undoLastDeletedHolding(in: context)
        }
    }

    private func undoLastDeletedHolding(in context: ModelContext) {
        guard let dto = lastDeletedHolding else { return }
        lastDeletedHolding = nil

        let allCategories = (try? context.fetch(FetchDescriptor<AssetCategory>())) ?? []
        let allAccounts = (try? context.fetch(FetchDescriptor<AssetAccount>())) ?? []

        let restored = AssetHolding(
            id: dto.id,
            name: dto.name,
            valuationMode: ValuationMode(rawValue: dto.valuationModeRaw) ?? .manualAmount,
            code: dto.code,
            shares: dto.shares,
            latestPrice: dto.latestPrice,
            manualAmount: dto.manualAmount,
            totalCost: dto.totalCost,
            priceDateText: dto.priceDateText,
            lastUpdated: dto.lastUpdated,
            note: dto.note,
            sortOrder: dto.sortOrder,
            fallbackPool: AssetPool(rawValue: dto.fallbackPoolRaw) ?? .investable,
            category: dto.categoryID.flatMap { id in allCategories.first(where: { $0.id == id }) },
            account: dto.accountID.flatMap { id in allAccounts.first(where: { $0.id == id }) }
        )

        context.insert(restored)
        try? context.save()
        Haptics.success()
        showToast(style: .success, message: "已恢复「\(dto.name)」", autoDismissSeconds: 2.0)
    }

    // MARK: - 行情自动刷新与查询

    /// App 启动或回到前台时，若行情超过 5 分钟未更新，后台静默替用户拉新（不打断不弹窗）
    func autoRefreshIfStale(holdings: [AssetHolding], in context: ModelContext) async {
        let refreshable = holdings.filter { $0.supportsQuoteRefresh }
        guard !refreshable.isEmpty, !isRefreshing else { return }

        if let last = lastNetworkRefresh, Date.now.timeIntervalSince(last) < autoRefreshStaleInterval {
            return
        }
        await refreshAllQuotes(holdings: holdings, in: context, silent: true)
    }

    /// 并发刷新全部联网证券与场外基金持仓
    func refreshAllQuotes(holdings: [AssetHolding], in context: ModelContext, silent: Bool = false) async {
        guard !isRefreshing else { return }

        let refreshable = holdings.filter { $0.supportsQuoteRefresh }
        guard !refreshable.isEmpty else { return }

        isRefreshing = true
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
                let message = "\(holding.name)（\(holding.code)）：\(error.localizedDescription)"
                if !failures.contains(message) {
                    failures.append(message)
                }
            }
        }

        try? context.save()
        if updatedCount > 0 {
            lastNetworkRefresh = now
        }

        if failures.isEmpty {
            if !silent {
                Haptics.success()
                showToast(style: .success, message: "已更新 \(updatedCount) 项行情净值", autoDismissSeconds: 2.2)
            }
        } else {
            if !silent {
                Haptics.warning()
                showToast(
                    style: .warning,
                    message: updatedCount > 0
                        ? "更新成功 \(updatedCount) 项，失败 \(failures.count) 项"
                        : "行情更新失败（\(failures.count) 项）",
                    details: failures,
                    actionTitle: "重试",
                    autoDismissSeconds: nil
                ) { [weak self] in
                    Task {
                        await self?.refreshAllQuotes(holdings: holdings, in: context, silent: false)
                    }
                }
            }
        }
    }

    /// 智能识别代码（自动分辨场内现价或场外净值）
    func lookupSmartCandidates(code: String) async throws -> [QuoteResult] {
        try await priceService.lookupSmartCandidates(rawCode: code)
    }

    /// 按已知模式查单只标的
    func lookupSingleQuote(code: String, mode: ValuationMode) async throws -> QuoteResult {
        try await priceService.fetchQuote(code: code, mode: mode)
    }

    /// 刷新单条持仓价格（供资产列表右滑快捷刷新）
    func refreshSingleHolding(_ holding: AssetHolding, in context: ModelContext) async {
        guard holding.supportsQuoteRefresh else { return }
        do {
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
            Haptics.success()
            showToast(
                style: .success,
                message: "\(holding.name) 已更新为 ¥\(Formatters.unitPrice(quote.price))",
                autoDismissSeconds: 2.2
            )
        } catch {
            Haptics.warning()
            showToast(
                style: .warning,
                message: "\(holding.name) 刷新失败",
                details: [error.localizedDescription],
                autoDismissSeconds: 4.0
            )
        }
    }
}
