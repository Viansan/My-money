import Foundation
import SwiftData

/// 数据初始化、示例演示数据与 JSON 导入导出服务
enum DataBackupService {
    private static let initialSeedFlagKey = "MyMoney.hasSeededBaseDictionaries.v1"

    /// 首次启动时注入通用默认分类与账户字典（不强制任何投资配比，0 持仓干净开局）
    @MainActor
    static func ensureBaseDictionariesIfNeeded(in context: ModelContext) {
        guard !UserDefaults.standard.bool(forKey: initialSeedFlagKey) else { return }

        let existingCategories = (try? context.fetchCount(FetchDescriptor<AssetCategory>())) ?? 0
        let existingAccounts = (try? context.fetchCount(FetchDescriptor<AssetAccount>())) ?? 0

        if existingCategories == 0 && existingAccounts == 0 {
            insertDefaultDictionaries(in: context)
            try? context.save()
        }

        UserDefaults.standard.set(true, forKey: initialSeedFlagKey)
    }

    @MainActor
    @discardableResult
    static func insertDefaultDictionaries(in context: ModelContext) -> (categories: [AssetCategory], accounts: [AssetAccount]) {
        let defaultCategories: [AssetCategory] = [
            // 投资资产池（默认不填死目标比例，用户可按需选填）
            AssetCategory(name: "境内权益", pool: .investable, colorToken: .blue, iconName: "chart.line.uptrend.xyaxis", targetRatio: nil, sortOrder: 0),
            AssetCategory(name: "海外指数", pool: .investable, colorToken: .indigo, iconName: "globe.americas.fill", targetRatio: nil, sortOrder: 1),
            AssetCategory(name: "债券固收", pool: .investable, colorToken: .teal, iconName: "shield.lefthalf.filled", targetRatio: nil, sortOrder: 2),
            AssetCategory(name: "流动现金", pool: .investable, colorToken: .green, iconName: "banknote.fill", targetRatio: nil, sortOrder: 3),
            // 固定资产池（独立于投资占比之外）
            AssetCategory(name: "大额定期", pool: .fixed, colorToken: .amber, iconName: "lock.doc.fill", targetRatio: nil, sortOrder: 4),
            AssetCategory(name: "房产/不动产", pool: .fixed, colorToken: .slate, iconName: "house.fill", targetRatio: nil, sortOrder: 5)
        ]

        let defaultAccounts: [AssetAccount] = [
            AssetAccount(name: "证券账户", subtitle: "场内股票与 ETF", colorToken: .blue, iconName: "chart.bar.xaxis", sortOrder: 0),
            AssetAccount(name: "基金理财账户", subtitle: "场外公募与活期理财", colorToken: .teal, iconName: "iphone.gen3", sortOrder: 1),
            AssetAccount(name: "银行储蓄账户", subtitle: "存款与大额定期", colorToken: .amber, iconName: "building.columns.fill", sortOrder: 2)
        ]

        for category in defaultCategories {
            context.insert(category)
        }
        for account in defaultAccounts {
            context.insert(account)
        }
        return (defaultCategories, defaultAccounts)
    }

    /// 一键载入演示数据（展示「100 万固定资产」与「20 万投资组合」如何完美解耦）
    @MainActor
    static func loadSampleShowcase(in context: ModelContext) throws {
        var categories = (try? context.fetch(FetchDescriptor<AssetCategory>())) ?? []
        var accounts = (try? context.fetch(FetchDescriptor<AssetAccount>())) ?? []

        if categories.isEmpty && accounts.isEmpty {
            let inserted = insertDefaultDictionaries(in: context)
            categories = inserted.categories
            accounts = inserted.accounts
        }

        func findOrCreateCategory(name: String, pool: AssetPool, color: CategoryColorToken, icon: String, target: Double?, order: Int) -> AssetCategory {
            if let match = categories.first(where: { $0.name == name && $0.pool == pool }) {
                if match.targetRatio == nil {
                    match.targetRatio = target
                }
                return match
            }
            let created = AssetCategory(name: name, pool: pool, colorToken: color, iconName: icon, targetRatio: target, sortOrder: order)
            context.insert(created)
            categories.append(created)
            return created
        }

        func findOrCreateAccount(name: String, subtitle: String, color: CategoryColorToken, icon: String, order: Int) -> AssetAccount {
            if let match = accounts.first(where: { $0.name == name }) {
                return match
            }
            let created = AssetAccount(name: name, subtitle: subtitle, colorToken: color, iconName: icon, sortOrder: order)
            context.insert(created)
            accounts.append(created)
            return created
        }

        let catEquity = findOrCreateCategory(name: "境内权益", pool: .investable, color: .blue, icon: "chart.line.uptrend.xyaxis", target: 40, order: 0)
        let catGlobal = findOrCreateCategory(name: "海外指数", pool: .investable, color: .indigo, icon: "globe.americas.fill", target: 30, order: 1)
        let catBond = findOrCreateCategory(name: "债券固收", pool: .investable, color: .teal, icon: "shield.lefthalf.filled", target: 20, order: 2)
        let catCash = findOrCreateCategory(name: "流动现金", pool: .investable, color: .green, icon: "banknote.fill", target: 10, order: 3)
        let catReserve = findOrCreateCategory(name: "大额定期", pool: .fixed, color: .amber, icon: "lock.doc.fill", target: nil, order: 4)

        let accBroker = findOrCreateAccount(name: "证券账户", subtitle: "场内股票与 ETF", color: .blue, icon: "chart.bar.xaxis", order: 0)
        let accFund = findOrCreateAccount(name: "基金理财账户", subtitle: "场外公募与活期理财", color: .teal, icon: "iphone.gen3", order: 1)
        let accBank = findOrCreateAccount(name: "银行储蓄账户", subtitle: "存款与大额定期", color: .amber, icon: "building.columns.fill", order: 2)

        let sampleHoldings: [AssetHolding] = [
            AssetHolding(
                name: "中证800ETF汇添富",
                valuationMode: .exchangeSecurity,
                code: "515800",
                shares: 48000,
                latestPrice: 1.091,
                totalCost: 49500,
                priceDateText: "示例行情",
                note: "下拉可刷新实时现价",
                sortOrder: 0,
                category: catEquity,
                account: accBroker
            ),
            AssetHolding(
                name: "红利低波ETF易方达",
                valuationMode: .exchangeSecurity,
                code: "563020",
                shares: 25000,
                latestPrice: 1.227,
                totalCost: 29000,
                priceDateText: "示例行情",
                sortOrder: 1,
                category: catEquity,
                account: accBroker
            ),
            AssetHolding(
                name: "博时标普500ETF联接A",
                valuationMode: .otcFund,
                code: "050025",
                shares: 12000,
                latestPrice: 5.0216,
                totalCost: 54000,
                priceDateText: "示例净值",
                note: "QDII 场外基金",
                sortOrder: 2,
                category: catGlobal,
                account: accFund
            ),
            AssetHolding(
                name: "广发7-10年国开债A",
                valuationMode: .otcFund,
                code: "003376",
                shares: 28000,
                latestPrice: 1.3965,
                totalCost: 38200,
                priceDateText: "示例净值",
                sortOrder: 3,
                category: catBond,
                account: accFund
            ),
            AssetHolding(
                name: "活期理财备用金",
                valuationMode: .manualAmount,
                manualAmount: 20000,
                totalCost: nil,
                note: "随时可用流动资金",
                sortOrder: 4,
                category: catCash,
                account: accFund
            ),
            AssetHolding(
                name: "三年期大额存单",
                valuationMode: .manualAmount,
                manualAmount: 1000000,
                totalCost: nil,
                note: "归属固定资产，到期自动还本付息",
                sortOrder: 5,
                annualRate: 2.35,
                startDate: Calendar.current.date(byAdding: .year, value: -1, to: .now),
                maturityDate: Calendar.current.date(byAdding: .year, value: 2, to: .now),
                category: catReserve,
                account: accBank
            )
        ]

        for item in sampleHoldings {
            context.insert(item)
        }
        try context.save()
    }

    // MARK: - JSON 备份导出与恢复

    static func makeBackupPayload(
        categories: [AssetCategory],
        accounts: [AssetAccount],
        holdings: [AssetHolding]
    ) -> BackupPayload {
        let categoryDTOs = categories
            .sorted { $0.sortOrder < $1.sortOrder }
            .map { cat in
                BackupPayload.CategoryDTO(
                    id: cat.id,
                    name: cat.name,
                    poolRaw: cat.poolRaw,
                    colorTokenRaw: cat.colorTokenRaw,
                    iconName: cat.iconName,
                    targetRatio: cat.targetRatio,
                    sortOrder: cat.sortOrder,
                    createdAt: cat.createdAt
                )
            }

        let accountDTOs = accounts
            .sorted { $0.sortOrder < $1.sortOrder }
            .map { acc in
                BackupPayload.AccountDTO(
                    id: acc.id,
                    name: acc.name,
                    subtitle: acc.subtitle,
                    colorTokenRaw: acc.colorTokenRaw,
                    iconName: acc.iconName,
                    sortOrder: acc.sortOrder,
                    createdAt: acc.createdAt
                )
            }

        let holdingDTOs = holdings
            .sorted { $0.sortOrder < $1.sortOrder }
            .map { h in
                BackupPayload.HoldingDTO(
                    id: h.id,
                    name: h.name,
                    valuationModeRaw: h.valuationModeRaw,
                    code: h.code,
                    shares: h.shares,
                    latestPrice: h.latestPrice,
                    manualAmount: h.manualAmount,
                    totalCost: h.totalCost,
                    priceDateText: h.priceDateText,
                    lastUpdated: h.lastUpdated,
                    note: h.note,
                    sortOrder: h.sortOrder,
                    fallbackPoolRaw: h.fallbackPoolRaw,
                    annualRate: h.annualRate,
                    startDate: h.startDate,
                    maturityDate: h.maturityDate,
                    categoryID: h.category?.id,
                    accountID: h.account?.id
                )
            }

        return BackupPayload(
            schemaVersion: 1,
            exportedAt: .now,
            categories: categoryDTOs,
            accounts: accountDTOs,
            holdings: holdingDTOs
        )
    }

    /// 预解析 JSON 备份，在弹出覆盖确认前提前校验格式并向用户展示备份内容摘要
    static func parseBackup(from data: Data) throws -> BackupPayload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BackupPayload.self, from: data)
    }

    /// 从 JSON 数据全量恢复（先清空旧记录再按原 UUID 重建关联关系）
    @MainActor
    static func restoreBackup(from data: Data, into context: ModelContext) throws -> (categories: Int, accounts: Int, holdings: Int) {
        let payload = try parseBackup(from: data)
        return try restoreBackup(payload: payload, into: context)
    }

    /// 从已校验的 BackupPayload 全量恢复
    @MainActor
    static func restoreBackup(payload: BackupPayload, into context: ModelContext) throws -> (categories: Int, accounts: Int, holdings: Int) {
        // 清空现有数据
        let oldHoldings = try context.fetch(FetchDescriptor<AssetHolding>())
        for item in oldHoldings { context.delete(item) }

        let oldCategories = try context.fetch(FetchDescriptor<AssetCategory>())
        for item in oldCategories { context.delete(item) }

        let oldAccounts = try context.fetch(FetchDescriptor<AssetAccount>())
        for item in oldAccounts { context.delete(item) }

        try context.save()

        // 重建分类字典映射
        var categoryMap: [UUID: AssetCategory] = [:]
        for dto in payload.categories {
            let cat = AssetCategory(
                id: dto.id,
                name: dto.name,
                pool: AssetPool(rawValue: dto.poolRaw) ?? .investable,
                colorToken: CategoryColorToken(rawValue: dto.colorTokenRaw) ?? .blue,
                iconName: dto.iconName,
                targetRatio: dto.targetRatio,
                sortOrder: dto.sortOrder,
                createdAt: dto.createdAt
            )
            context.insert(cat)
            categoryMap[dto.id] = cat
        }

        // 重建账户字典映射
        var accountMap: [UUID: AssetAccount] = [:]
        for dto in payload.accounts {
            let acc = AssetAccount(
                id: dto.id,
                name: dto.name,
                subtitle: dto.subtitle,
                colorToken: CategoryColorToken(rawValue: dto.colorTokenRaw) ?? .indigo,
                iconName: dto.iconName,
                sortOrder: dto.sortOrder,
                createdAt: dto.createdAt
            )
            context.insert(acc)
            accountMap[dto.id] = acc
        }

        // 重建持仓并恢复关联
        for dto in payload.holdings {
            let linkedCategory = dto.categoryID.flatMap { categoryMap[$0] }
            let linkedAccount = dto.accountID.flatMap { accountMap[$0] }
            let holding = AssetHolding(
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
                annualRate: dto.annualRate,
                startDate: dto.startDate,
                maturityDate: dto.maturityDate,
                category: linkedCategory,
                account: linkedAccount
            )
            context.insert(holding)
        }

        try context.save()
        UserDefaults.standard.set(true, forKey: initialSeedFlagKey)
        return (payload.categories.count, payload.accounts.count, payload.holdings.count)
    }

    /// 清空全部持仓记录（保留自定义分类与账户结构）
    @MainActor
    static func clearAllHoldings(in context: ModelContext) throws {
        let allHoldings = try context.fetch(FetchDescriptor<AssetHolding>())
        for item in allHoldings {
            context.delete(item)
        }
        try context.save()
    }
}
