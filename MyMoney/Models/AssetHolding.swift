import Foundation
import SwiftData

/// 具体资产持仓记录
/// 同时支持「直接输入金额」与「代码 + 份额 × 单价」两种估值方式，并支持选填成本计算盈亏
@Model
final class AssetHolding {
    var id: UUID
    var name: String
    var valuationModeRaw: String
    var code: String
    var shares: Double
    var latestPrice: Double
    var manualAmount: Double
    /// 选填投入总本金（nil 表示不追踪该笔资产的成本与盈亏）
    var totalCost: Double?
    /// 行情或净值日期描述（如 "2026-11-20" 或 "11-24 15:00"）
    var priceDateText: String
    var lastUpdated: Date
    var note: String
    var sortOrder: Int
    /// 当所属分类被删除变为未分类时，保留其原先的资金池归属（避免固定资产意外混入投资池）
    var fallbackPoolRaw: String

    var category: AssetCategory?
    var account: AssetAccount?

    init(
        id: UUID = UUID(),
        name: String,
        valuationMode: ValuationMode = .manualAmount,
        code: String = "",
        shares: Double = 0,
        latestPrice: Double = 1.0,
        manualAmount: Double = 0,
        totalCost: Double? = nil,
        priceDateText: String = "",
        lastUpdated: Date = .now,
        note: String = "",
        sortOrder: Int = 0,
        fallbackPool: AssetPool = .investable,
        category: AssetCategory? = nil,
        account: AssetAccount? = nil
    ) {
        self.id = id
        self.name = name
        self.valuationModeRaw = valuationMode.rawValue
        self.code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        self.shares = shares
        self.latestPrice = latestPrice
        self.manualAmount = manualAmount
        self.totalCost = totalCost
        self.priceDateText = priceDateText
        self.lastUpdated = lastUpdated
        self.note = note
        self.sortOrder = sortOrder
        self.fallbackPoolRaw = (category?.pool ?? fallbackPool).rawValue
        self.category = category
        self.account = account
    }

    var valuationMode: ValuationMode {
        get { ValuationMode(rawValue: valuationModeRaw) ?? .manualAmount }
        set { valuationModeRaw = newValue.rawValue }
    }

    /// 实际生效的资金池归属（优先跟随所属类别）
    var effectivePool: AssetPool {
        if let category {
            return category.pool
        }
        return AssetPool(rawValue: fallbackPoolRaw) ?? .investable
    }

    /// 当前总市值
    var marketValue: Double {
        let raw: Double
        switch valuationMode {
        case .manualAmount:
            raw = manualAmount
        case .exchangeSecurity, .otcFund:
            raw = shares * latestPrice
        }
        return raw.isFinite ? raw : 0
    }

    /// 是否支持联网自动拉取单价
    var supportsQuoteRefresh: Bool {
        valuationMode.usesSharesAndPrice && !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 折算成本均价（仅份额类且已填成本时有效）
    var unitCost: Double? {
        guard valuationMode.usesSharesAndPrice, shares > 0, let cost = totalCost else {
            return nil
        }
        return cost / shares
    }

    /// 累计持仓盈亏金额
    var profitLoss: Double? {
        guard let cost = totalCost else { return nil }
        return marketValue - cost
    }

    /// 累计持仓收益率（如 0.085 代表 +8.5%）
    var profitLossRate: Double? {
        guard let cost = totalCost, cost > 0 else { return nil }
        return (marketValue - cost) / cost
    }

    /// 安全切换分类并同步资金池兜底标记
    func assignCategory(_ newCategory: AssetCategory?) {
        self.category = newCategory
        if let newCategory {
            self.fallbackPoolRaw = newCategory.poolRaw
        }
    }
}
