import Foundation
import SwiftUI

/// 盈亏汇总（仅统计填写了成本本金的持仓，避免无成本记录的现金被误算为纯利润）
struct PnLSummary {
    let trackedCount: Int
    let trackedPrincipal: Double
    let trackedMarketValue: Double

    var hasTrackedHoldings: Bool {
        trackedCount > 0
    }

    var profitLoss: Double {
        trackedMarketValue - trackedPrincipal
    }

    var profitLossRate: Double? {
        guard trackedPrincipal > 0 else { return nil }
        return profitLoss / trackedPrincipal
    }

    static func compute(from holdings: [AssetHolding]) -> PnLSummary {
        var count = 0
        var principal = 0.0
        var market = 0.0
        for item in holdings {
            if let cost = item.totalCost {
                count += 1
                principal += cost
                market += item.marketValue
            }
        }
        return PnLSummary(
            trackedCount: count,
            trackedPrincipal: principal,
            trackedMarketValue: market
        )
    }
}

/// 环形图与分类卡片展示切片
struct AllocationSlice: Identifiable {
    let id: UUID
    let name: String
    let iconName: String
    let color: Color
    let pool: AssetPool
    let amount: Double
    /// 在所属资金池内的实际占比（0 ~ 100）
    let poolRatioPercent: Double
    /// 占全部总净值的比例（0 ~ 100）
    let netWorthRatioPercent: Double
    /// 选填目标占比（0 ~ 100，nil 表示未设目标）
    let targetRatioPercent: Double?
    let holdingCount: Int
    let pnl: PnLSummary

    /// 实际占比与选填目标占比的绝对百分点偏差（如 +2.4 代表超配 2.4 个百分点）
    var deviationPoints: Double? {
        guard let target = targetRatioPercent else { return nil }
        return poolRatioPercent - target
    }
}

/// 账户分布切片（用于多平台资金盘点与对账）
struct AccountSlice: Identifiable {
    let id: UUID
    let name: String
    let subtitle: String
    let iconName: String
    let color: Color
    let totalAmount: Double
    let investableAmount: Double
    let fixedAmount: Double
    let netWorthRatioPercent: Double
    let holdingCount: Int
}

/// 全局资产组合聚合快照（纯计算层，将「投资资产」与「固定/底仓资产」完全隔离计算）
struct PortfolioSnapshot {
    let totalNetWorth: Double
    let investableTotal: Double
    let fixedTotal: Double

    let overallPnL: PnLSummary
    let investablePnL: PnLSummary
    let fixedPnL: PnLSummary

    let investableSlices: [AllocationSlice]
    let fixedSlices: [AllocationSlice]
    let accountSlices: [AccountSlice]

    /// 若至少有一个投资类别填写了目标占比，返回已设目标占比之和（方便参考是否合计 100%）
    let configuredTargetSum: Double?
    let latestQuoteUpdatedAt: Date?

    var investableShareOfNetWorth: Double {
        guard totalNetWorth > 0 else { return 0 }
        return (investableTotal / totalNetWorth) * 100.0
    }

    var fixedShareOfNetWorth: Double {
        guard totalNetWorth > 0 else { return 0 }
        return (fixedTotal / totalNetWorth) * 100.0
    }

    static func build(
        holdings: [AssetHolding],
        categories: [AssetCategory],
        accounts: [AssetAccount]
    ) -> PortfolioSnapshot {
        let investableHoldings = holdings.filter { $0.effectivePool == .investable }
        let fixedHoldings = holdings.filter { $0.effectivePool == .fixed }

        let investableSum = investableHoldings.reduce(0.0) { $0 + $1.marketValue }
        let fixedSum = fixedHoldings.reduce(0.0) { $0 + $1.marketValue }
        let netWorth = investableSum + fixedSum

        // 1. 构建投资资产分类切片（分母严格为 investableSum，完全不受固定资产金额影响）
        let sortedCategories = categories.sorted {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return $0.createdAt < $1.createdAt
        }

        let investableCategories = sortedCategories.filter { $0.pool == .investable }
        var investSlices: [AllocationSlice] = investableCategories.map { cat in
            let catHoldings = investableHoldings.filter { $0.category?.id == cat.id }
            let amount = catHoldings.reduce(0.0) { $0 + $1.marketValue }
            let poolPct = investableSum > 0 ? (amount / investableSum) * 100.0 : 0
            let totalPct = netWorth > 0 ? (amount / netWorth) * 100.0 : 0
            return AllocationSlice(
                id: cat.id,
                name: cat.name,
                iconName: cat.iconName,
                color: cat.tintColor,
                pool: .investable,
                amount: amount,
                poolRatioPercent: poolPct,
                netWorthRatioPercent: totalPct,
                targetRatioPercent: cat.targetRatio,
                holdingCount: catHoldings.count,
                pnl: PnLSummary.compute(from: catHoldings)
            )
        }

        // 未分类的投资资产兜底切片
        let uncategorizedInvestable = investableHoldings.filter { $0.category == nil }
        if !uncategorizedInvestable.isEmpty {
            let amount = uncategorizedInvestable.reduce(0.0) { $0 + $1.marketValue }
            investSlices.append(
                AllocationSlice(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID(),
                    name: "未分类（投资）",
                    iconName: "questionmark.folder.fill",
                    color: CategoryColorToken.slate.color,
                    pool: .investable,
                    amount: amount,
                    poolRatioPercent: investableSum > 0 ? (amount / investableSum) * 100.0 : 0,
                    netWorthRatioPercent: netWorth > 0 ? (amount / netWorth) * 100.0 : 0,
                    targetRatioPercent: nil,
                    holdingCount: uncategorizedInvestable.count,
                    pnl: PnLSummary.compute(from: uncategorizedInvestable)
                )
            )
        }

        // 2. 构建固定/底仓资产切片
        let fixedCategories = sortedCategories.filter { $0.pool == .fixed }
        var fixSlices: [AllocationSlice] = fixedCategories.map { cat in
            let catHoldings = fixedHoldings.filter { $0.category?.id == cat.id }
            let amount = catHoldings.reduce(0.0) { $0 + $1.marketValue }
            let poolPct = fixedSum > 0 ? (amount / fixedSum) * 100.0 : 0
            let totalPct = netWorth > 0 ? (amount / netWorth) * 100.0 : 0
            return AllocationSlice(
                id: cat.id,
                name: cat.name,
                iconName: cat.iconName,
                color: cat.tintColor,
                pool: .fixed,
                amount: amount,
                poolRatioPercent: poolPct,
                netWorthRatioPercent: totalPct,
                targetRatioPercent: nil,
                holdingCount: catHoldings.count,
                pnl: PnLSummary.compute(from: catHoldings)
            )
        }

        let uncategorizedFixed = fixedHoldings.filter { $0.category == nil }
        if !uncategorizedFixed.isEmpty {
            let amount = uncategorizedFixed.reduce(0.0) { $0 + $1.marketValue }
            fixSlices.append(
                AllocationSlice(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000002") ?? UUID(),
                    name: "未分类（固定）",
                    iconName: "archivebox.fill",
                    color: CategoryColorToken.slate.color,
                    pool: .fixed,
                    amount: amount,
                    poolRatioPercent: fixedSum > 0 ? (amount / fixedSum) * 100.0 : 0,
                    netWorthRatioPercent: netWorth > 0 ? (amount / netWorth) * 100.0 : 0,
                    targetRatioPercent: nil,
                    holdingCount: uncategorizedFixed.count,
                    pnl: PnLSummary.compute(from: uncategorizedFixed)
                )
            )
        }

        // 3. 构建按账户汇总切片（同一账户下合并展示投资+固定总额，与真实银行/券商 App 账面一致）
        let sortedAccounts = accounts.sorted {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return $0.createdAt < $1.createdAt
        }

        var accSlices: [AccountSlice] = sortedAccounts.map { acc in
            let accHoldings = holdings.filter { $0.account?.id == acc.id }
            let invAmt = accHoldings.filter { $0.effectivePool == .investable }.reduce(0.0) { $0 + $1.marketValue }
            let fixAmt = accHoldings.filter { $0.effectivePool == .fixed }.reduce(0.0) { $0 + $1.marketValue }
            let total = invAmt + fixAmt
            return AccountSlice(
                id: acc.id,
                name: acc.name,
                subtitle: acc.subtitle,
                iconName: acc.iconName,
                color: acc.tintColor,
                totalAmount: total,
                investableAmount: invAmt,
                fixedAmount: fixAmt,
                netWorthRatioPercent: netWorth > 0 ? (total / netWorth) * 100.0 : 0,
                holdingCount: accHoldings.count
            )
        }

        let unassignedHoldings = holdings.filter { $0.account == nil }
        if !unassignedHoldings.isEmpty {
            let invAmt = unassignedHoldings.filter { $0.effectivePool == .investable }.reduce(0.0) { $0 + $1.marketValue }
            let fixAmt = unassignedHoldings.filter { $0.effectivePool == .fixed }.reduce(0.0) { $0 + $1.marketValue }
            let total = invAmt + fixAmt
            accSlices.append(
                AccountSlice(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000003") ?? UUID(),
                    name: "未指定账户",
                    subtitle: "",
                    iconName: "tray.fill",
                    color: CategoryColorToken.slate.color,
                    totalAmount: total,
                    investableAmount: invAmt,
                    fixedAmount: fixAmt,
                    netWorthRatioPercent: netWorth > 0 ? (total / netWorth) * 100.0 : 0,
                    holdingCount: unassignedHoldings.count
                )
            )
        }

        // 4. 统计已填写的可选目标比例总和
        let targets = investableCategories.compactMap(\.targetRatio)
        let targetSum: Double? = targets.isEmpty ? nil : targets.reduce(0.0, +)

        let latestTime = holdings.map(\.lastUpdated).max()

        return PortfolioSnapshot(
            totalNetWorth: netWorth,
            investableTotal: investableSum,
            fixedTotal: fixedSum,
            overallPnL: PnLSummary.compute(from: holdings),
            investablePnL: PnLSummary.compute(from: investableHoldings),
            fixedPnL: PnLSummary.compute(from: fixedHoldings),
            investableSlices: investSlices,
            fixedSlices: fixSlices,
            accountSlices: accSlices,
            configuredTargetSum: targetSum,
            latestQuoteUpdatedAt: latestTime
        )
    }
}
