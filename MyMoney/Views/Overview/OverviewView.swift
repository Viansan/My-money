import SwiftUI
import SwiftData

/// Tab 1：资产总览页
/// - 紧致成熟的信息架构：小标题导航栏 + 双核心表面（净值总览 + 图表与结构一体化容器），消除大块留白与零散卡片堆叠感
/// - 设定参考比例后，同步呈现「目标 % + 目标金额（元）」与「偏离金额（超/差 ¥X）+ 偏离百分点」双维度数字
struct OverviewView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PortfolioRefreshStore.self) private var refreshStore

    @Query(sort: \AssetHolding.sortOrder) private var holdings: [AssetHolding]
    @Query(sort: \AssetCategory.sortOrder) private var categories: [AssetCategory]
    @Query(sort: \AssetAccount.sortOrder) private var accounts: [AssetAccount]

    @State private var selectedLens: OverviewLens = .investable
    @State private var showingAddHolding = false

    private var snapshot: PortfolioSnapshot {
        PortfolioSnapshot.build(holdings: holdings, categories: categories, accounts: accounts)
    }

    private var availableLenses: [OverviewLens] {
        var lenses: [OverviewLens] = []
        if snapshot.hasInvestableHoldings || snapshot.configuredTargetSum != nil {
            lenses.append(.investable)
        }
        if snapshot.hasFixedHoldings {
            lenses.append(.fixed)
        }
        if !snapshot.accountSlices.isEmpty {
            lenses.append(.accounts)
        }
        return lenses.isEmpty ? [.investable] : lenses
    }

    private var addSheetDefaultPool: AssetPool {
        selectedLens == .fixed ? .fixed : .investable
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if holdings.isEmpty {
                        emptyWelcomeCard
                            .padding(.top, 20)
                    } else {
                        heroNetWorthCard

                        unifiedAllocationSurface
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 28)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("我的资产")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable {
                if snapshot.hasRefreshableHoldings {
                    await refreshStore.refreshAllQuotes(holdings: holdings, in: modelContext, silent: false)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !holdings.isEmpty {
                        Button {
                            Haptics.selection()
                            refreshStore.hideAmounts.toggle()
                        } label: {
                            Image(systemName: refreshStore.hideAmounts ? "eye.slash" : "eye")
                                .font(.subheadline)
                        }
                        .accessibilityLabel(refreshStore.hideAmounts ? "显示金额" : "隐藏金额")
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 14) {
                        if snapshot.hasRefreshableHoldings {
                            Button {
                                Task {
                                    await refreshStore.refreshAllQuotes(holdings: holdings, in: modelContext, silent: false)
                                }
                            } label: {
                                if refreshStore.isRefreshing {
                                    ProgressView()
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                            }
                            .disabled(refreshStore.isRefreshing)
                            .accessibilityLabel("刷新行情")
                        }

                        Button {
                            Haptics.lightImpact()
                            showingAddHolding = true
                        } label: {
                            Image(systemName: "plus")
                                .fontWeight(.semibold)
                        }
                        .accessibilityLabel("新增资产")
                    }
                }
            }
            .sheet(isPresented: $showingAddHolding) {
                HoldingFormSheet(existingHolding: nil, preselectedPool: addSheetDefaultPool)
            }
            .onAppear(perform: reconcileSelectedLens)
            .onChange(of: availableLenses) { _, _ in
                reconcileSelectedLens()
            }
        }
    }

    private func reconcileSelectedLens() {
        if !availableLenses.contains(selectedLens), let first = availableLenses.first {
            selectedLens = first
        }
    }

    // MARK: - 表面 1：紧致总净值与双池一体化头卡

    private var heroNetWorthCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center) {
                    Text(snapshot.hasBothPools ? "全部总净值" : (snapshot.hasFixedHoldings ? "固定资产总额" : "总资产"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    Spacer()

                    if let updated = refreshStore.lastNetworkRefresh ?? snapshot.latestQuoteUpdatedAt {
                        Text(Formatters.shortDateTime(updated))
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Formatters.currency(snapshot.totalNetWorth, hidden: refreshStore.hideAmounts))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.68)

                    Spacer(minLength: 4)

                    if snapshot.overallPnL.hasTrackedHoldings {
                        let delta = snapshot.overallPnL.profitLoss
                        HStack(spacing: 3) {
                            Text(Formatters.signedCurrency(delta, hidden: refreshStore.hideAmounts))
                            if !snapshot.hasBothPools, let rate = snapshot.overallPnL.profitLossRate {
                                Text(Formatters.signedRate(rate, hidden: refreshStore.hideAmounts))
                            }
                        }
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(refreshStore.pnlColorScheme.color(for: delta))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            refreshStore.pnlColorScheme.color(for: delta).opacity(0.12),
                            in: Capsule()
                        )
                    }
                }

                if snapshot.hasBothPools {
                    GeometryReader { geo in
                        let totalWidth = max(geo.size.width, 1)
                        let invRatio = min(max(snapshot.investableTotal / max(snapshot.totalNetWorth, 1), 0), 1)
                        HStack(spacing: 2) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(CategoryColorToken.blue.color)
                                .frame(width: max(totalWidth * invRatio - 1, 4))
                            RoundedRectangle(cornerRadius: 2)
                                .fill(CategoryColorToken.amber.color.opacity(0.85))
                        }
                    }
                    .frame(height: 4)
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            if snapshot.hasBothPools {
                Divider()
                    .padding(.horizontal, 14)

                HStack(spacing: 0) {
                    poolStripColumn(
                        title: "投资资产",
                        roleHint: "占比分母",
                        badgeColor: CategoryColorToken.blue.color,
                        amount: snapshot.investableTotal,
                        sharePercent: snapshot.investableShareOfNetWorth,
                        pnl: snapshot.investablePnL,
                        isSelected: selectedLens == .investable
                    ) {
                        Haptics.selection()
                        withAnimation(.snappy) { selectedLens = .investable }
                    }

                    Divider()
                        .frame(height: 36)

                    poolStripColumn(
                        title: "固定资产",
                        roleHint: "不计入投资占比",
                        badgeColor: CategoryColorToken.amber.color,
                        amount: snapshot.fixedTotal,
                        sharePercent: snapshot.fixedShareOfNetWorth,
                        pnl: snapshot.fixedPnL,
                        isSelected: selectedLens == .fixed
                    ) {
                        Haptics.selection()
                        withAnimation(.snappy) { selectedLens = .fixed }
                    }
                }
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func poolStripColumn(
        title: String,
        roleHint: String,
        badgeColor: Color,
        amount: Double,
        sharePercent: Double,
        pnl: PnLSummary,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(badgeColor)
                        .frame(width: 6, height: 6)
                    Text(title)
                        .font(.caption.weight(isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                    Spacer()
                    Text(Formatters.percentPoints(sharePercent, digits: 0))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Formatters.currency(amount, hidden: refreshStore.hideAmounts, compact: amount >= 100_000))
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)

                    Spacer(minLength: 2)

                    if pnl.hasTrackedHoldings {
                        let delta = pnl.profitLoss
                        Text(Formatters.signedCurrency(delta, hidden: refreshStore.hideAmounts))
                            .font(.system(size: 10.5, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(refreshStore.pnlColorScheme.color(for: delta))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    } else {
                        Text(roleHint)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? badgeColor.opacity(0.06) : Color.clear)
            .overlay(alignment: .bottom) {
                if isSelected {
                    Rectangle()
                        .fill(badgeColor)
                        .frame(height: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 表面 2：图表 + 分组明细一体化容器（消除多卡堆叠留白）

    private var unifiedAllocationSurface: some View {
        VStack(spacing: 0) {
            AllocationChartSection(
                selectedLens: $selectedLens,
                availableLenses: availableLenses,
                snapshot: snapshot,
                hideAmounts: refreshStore.hideAmounts
            )

            Divider()

            // 内嵌列表表头
            HStack {
                Text(breakdownTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                if let trailing = breakdownTrailingNote {
                    Text(trailing.text)
                        .font(.caption2.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(trailing.isWarning ? Color.orange : Color.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(.tertiarySystemGroupedBackground).opacity(0.45))

            Divider()

            // 无缝分组明细行
            breakdownRows
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var breakdownTitle: String {
        switch selectedLens {
        case .investable: return "投资结构"
        case .fixed: return "固定资产明细"
        case .accounts: return "账户资金分布"
        }
    }

    private var breakdownTrailingNote: (text: String, isWarning: Bool)? {
        switch selectedLens {
        case .investable:
            if let targetSum = snapshot.configuredTargetSum {
                return ("参考目标合计 \(Formatters.percentPoints(targetSum, digits: 0))", abs(targetSum - 100) >= 0.1)
            }
            return ("共 \(snapshot.investableSlices.count) 类", false)
        case .fixed:
            return ("占总净值 \(Formatters.percentPoints(snapshot.fixedShareOfNetWorth))", false)
        case .accounts:
            return ("共 \(snapshot.accountSlices.count) 个账户", false)
        }
    }

    @ViewBuilder
    private var breakdownRows: some View {
        switch selectedLens {
        case .investable:
            VStack(spacing: 0) {
                ForEach(Array(snapshot.investableSlices.enumerated()), id: \.element.id) { index, slice in
                    allocationSliceRow(slice: slice, showTargetIfPresent: true)
                    if index < snapshot.investableSlices.count - 1 {
                        Divider().padding(.leading, 50)
                    }
                }
            }

        case .fixed:
            VStack(spacing: 0) {
                ForEach(Array(snapshot.fixedSlices.enumerated()), id: \.element.id) { index, slice in
                    allocationSliceRow(slice: slice, showTargetIfPresent: false)
                    if index < snapshot.fixedSlices.count - 1 {
                        Divider().padding(.leading, 50)
                    }
                }
            }

        case .accounts:
            VStack(spacing: 0) {
                ForEach(Array(snapshot.accountSlices.enumerated()), id: \.element.id) { index, acc in
                    accountSliceRow(acc)
                    if index < snapshot.accountSlices.count - 1 {
                        Divider().padding(.leading, 50)
                    }
                }
            }
        }
    }

    /// 单行分类明细：设了参考比例时同时展示「目标 % + 目标金额」与「超/差 ¥金额 + 偏离 %」
    private func allocationSliceRow(slice: AllocationSlice, showTargetIfPresent: Bool) -> some View {
        Button {
            refreshStore.drillDownToCategory(id: slice.categoryID, name: slice.name, pool: slice.pool)
        } label: {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(slice.color.opacity(0.15))
                        .frame(width: 28, height: 28)
                    Image(systemName: slice.iconName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(slice.color)
                }

                VStack(alignment: .leading, spacing: 5) {
                    // 第一行：类别名 + 实际金额 & 实际占比
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(slice.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text("\(slice.holdingCount)项")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)

                        Spacer(minLength: 4)

                        Text(Formatters.currency(slice.amount, hidden: refreshStore.hideAmounts, compact: slice.amount >= 1_000_000))
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(Formatters.percentPoints(slice.poolRatioPercent))
                            .font(.caption.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    // 第二行：设定参考后，完整给出百分比 + 具体金额双维度信息
                    if showTargetIfPresent, let targetPct = slice.targetRatioPercent, let devPts = slice.deviationPoints {
                        HStack(spacing: 6) {
                            if let targetAmt = slice.targetAmount, !refreshStore.hideAmounts {
                                Text("目标 \(Formatters.percentPoints(targetPct, digits: 0)) (\(Formatters.wholeCurrency(targetAmt)))")
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("目标 \(Formatters.percentPoints(targetPct, digits: 0))")
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 4)

                            targetDeviationBadge(devPoints: devPts, devAmount: slice.deviationAmount)
                        }
                        .font(.caption2)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    } else if slice.pool == .fixed {
                        HStack {
                            Text("占总净值 \(Formatters.percentPoints(slice.netWorthRatioPercent))")
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Spacer()
                            if slice.pnl.hasTrackedHoldings {
                                let delta = slice.pnl.profitLoss
                                Text("盈亏 \(Formatters.signedCurrency(delta, hidden: refreshStore.hideAmounts))")
                                    .font(.caption2)
                                    .monospacedDigit()
                                    .foregroundStyle(refreshStore.pnlColorScheme.color(for: delta))
                            }
                        }
                    } else if slice.pnl.hasTrackedHoldings {
                        let delta = slice.pnl.profitLoss
                        HStack(spacing: 4) {
                            Text("盈亏 \(Formatters.signedCurrency(delta, hidden: refreshStore.hideAmounts))")
                            if let rate = slice.pnl.profitLossRate {
                                Text("(\(Formatters.signedRate(rate, hidden: refreshStore.hideAmounts)))")
                            }
                        }
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(refreshStore.pnlColorScheme.color(for: delta))
                    }

                    // 第三行：紧致进度条 + 目标刻度
                    GeometryReader { geo in
                        let width = max(geo.size.width, 1)
                        let actualFraction = min(max(slice.poolRatioPercent / 100.0, 0), 1)
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color(.tertiarySystemFill))
                                .frame(height: 4)

                            if actualFraction > 0 {
                                Capsule()
                                    .fill(slice.color)
                                    .frame(width: max(width * actualFraction, 3), height: 4)
                            }

                            if showTargetIfPresent, let target = slice.targetRatioPercent, target > 0, target <= 100 {
                                let markerX = min(max(width * (target / 100.0), 1), width - 2)
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(Color.primary.opacity(0.65))
                                    .frame(width: 2, height: 8)
                                    .offset(x: markerX - 1)
                            }
                        }
                    }
                    .frame(height: 8)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.quaternary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 参考目标偏差：同时展示具体差额（超 ¥4,600 / 差 ¥2,500）与百分偏差（+2.3% / -1.8%）
    @ViewBuilder
    private func targetDeviationBadge(devPoints: Double, devAmount: Double?) -> some View {
        let isSignificant = abs(devPoints) >= 5.0
        let tint: Color = isSignificant ? .orange : .secondary

        if abs(devPoints) < 0.2 {
            Text("已达标")
                .fontWeight(.medium)
                .foregroundStyle(.green)
        } else if let devAmount, !refreshStore.hideAmounts {
            let verb = devAmount >= 0 ? "超" : "差"
            Text("\(verb) \(Formatters.wholeCurrency(abs(devAmount))) (\(Formatters.signedPercentPoints(devPoints)))")
                .fontWeight(isSignificant ? .semibold : .medium)
                .foregroundStyle(tint)
        } else {
            let verb = devPoints >= 0 ? "偏高" : "偏低"
            Text("\(verb) \(Formatters.signedPercentPoints(devPoints))")
                .fontWeight(isSignificant ? .semibold : .medium)
                .foregroundStyle(tint)
        }
    }

    private func accountSliceRow(_ acc: AccountSlice) -> some View {
        Button {
            refreshStore.drillDownToAccount(id: acc.accountID, name: acc.name)
        } label: {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(acc.color.opacity(0.15))
                        .frame(width: 28, height: 28)
                    Image(systemName: acc.iconName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(acc.color)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(acc.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text("\(acc.holdingCount)项")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)

                        Spacer(minLength: 4)

                        Text(Formatters.currency(acc.totalAmount, hidden: refreshStore.hideAmounts, compact: acc.totalAmount >= 1_000_000))
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(.primary)

                        Text(Formatters.percentPoints(acc.netWorthRatioPercent))
                            .font(.caption.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    if acc.investableAmount > 0 && acc.fixedAmount > 0 {
                        Text("投资 \(Formatters.wholeCurrency(acc.investableAmount, hidden: refreshStore.hideAmounts)) · 固定 \(Formatters.wholeCurrency(acc.fixedAmount, hidden: refreshStore.hideAmounts))")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    } else if !acc.subtitle.isEmpty {
                        Text(acc.subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    GeometryReader { geo in
                        let width = max(geo.size.width, 1)
                        let fraction = min(max(acc.netWorthRatioPercent / 100.0, 0), 1)
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color(.tertiarySystemFill))
                                .frame(height: 4)
                            if fraction > 0 {
                                Capsule()
                                    .fill(acc.color)
                                    .frame(width: max(width * fraction, 3), height: 4)
                            }
                        }
                    }
                    .frame(height: 4)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.quaternary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 极简空状态引导

    private var emptyWelcomeCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.pie.fill")
                .font(.system(size: 42))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 4)

            VStack(spacing: 6) {
                Text("记下你的第一笔资产")
                    .font(.headline)
                Text("按类别看配置，按账户好对账。\n大额存单、房产等固定资产可独立核算，不稀释投资比例。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }

            VStack(spacing: 8) {
                Button {
                    Haptics.lightImpact()
                    showingAddHolding = true
                } label: {
                    Label("新增第一笔资产", systemImage: "plus.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    do {
                        try DataBackupService.loadSampleShowcase(in: modelContext)
                        Haptics.success()
                        refreshStore.showToast(
                            style: .success,
                            message: "已载入示例（可在「管理」页一键清空）",
                            autoDismissSeconds: 3.0
                        )
                    } catch {
                        refreshStore.showToast(style: .warning, message: "载入失败：\(error.localizedDescription)")
                    }
                } label: {
                    Text("先载入演示数据看看效果")
                        .font(.footnote.weight(.medium))
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
