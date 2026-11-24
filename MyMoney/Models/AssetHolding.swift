import Foundation
import SwiftData

/// 具体资产持仓记录
/// - 投资资产：支持「按金额」与「代码 + 份额 × 单价」计价，选填成本算盈亏
/// - 固定资产：支持选填「年化利率」「起息日」「到期日」，自动核算预计利息、到期倒计时与存期进度
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
    /// 行情或净值日期描述（如 "11-24 15:00" 或 "11-20"）
    var priceDateText: String
    var lastUpdated: Date
    var note: String
    var sortOrder: Int
    /// 当所属分类被删除变为未分类时，保留其原先的资金池归属（避免固定资产意外混入投资池）
    var fallbackPoolRaw: String

    // MARK: - 固定资产 / 存单专属选填维度（可选字段，SwiftData 自动轻量迁移，完全兼容旧数据）

    /// 年化利率（百分比数值，如 2.45 代表 2.45%）
    var annualRate: Double?
    /// 起息日（选填，用于计算存期进度与到期预计总利息）
    var startDate: Date?
    /// 到期日（选填，用于到期倒计时与临期提醒）
    var maturityDate: Date?

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
        annualRate: Double? = nil,
        startDate: Date? = nil,
        maturityDate: Date? = nil,
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
        self.annualRate = annualRate
        self.startDate = startDate
        self.maturityDate = maturityDate
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

    /// 当前总市值 / 存单本金
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

    // MARK: - 固定资产 / 存单自动核算指标

    /// 距离到期剩余自然日（正数为剩余天数，0 为今日到期，负数为已过期天数）
    var daysUntilMaturity: Int? {
        guard let maturityDate else { return nil }
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let target = cal.startOfDay(for: maturityDate)
        return cal.dateComponents([.day], from: today, to: target).day
    }

    /// 存期已过进度（0.0 ~ 1.0，需同时有起息日与到期日）
    var termProgress: Double? {
        guard let startDate, let maturityDate, maturityDate > startDate else { return nil }
        let total = maturityDate.timeIntervalSince(startDate)
        let elapsed = Date.now.timeIntervalSince(startDate)
        return min(max(elapsed / total, 0.0), 1.0)
    }

    /// 预计年利息（本金 × 年化利率）
    var estimatedAnnualInterest: Double? {
        guard let annualRate, annualRate > 0, marketValue > 0 else { return nil }
        return marketValue * (annualRate / 100.0)
    }

    /// 预计到期总利息（单利估算：有起息日和到期日时按实际天数/365 折算）
    var estimatedMaturityInterest: Double? {
        guard let annualInterest = estimatedAnnualInterest,
              let startDate, let maturityDate, maturityDate > startDate else {
            return nil
        }
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: startDate), to: cal.startOfDay(for: maturityDate)).day ?? 0
        guard days > 0 else { return nil }
        return annualInterest * (Double(days) / 365.0)
    }

    /// 是否临近到期（30 天以内或已到期）
    var isMaturitySoonOrPast: Bool {
        guard let days = daysUntilMaturity else { return false }
        return days <= 30
    }

    /// 安全切换分类并同步资金池兜底标记
    func assignCategory(_ newCategory: AssetCategory?) {
        self.category = newCategory
        if let newCategory {
            self.fallbackPoolRaw = newCategory.poolRaw
        }
    }
}
