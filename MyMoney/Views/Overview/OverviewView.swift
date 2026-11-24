import SwiftUI
import SwiftData

/// Tab 1：资产总览页
/// - 0 持仓时呈现极简欢迎引导，不堆砌无意义的 ¥0.00 卡片
/// - 同时存在「投资资产」与「固定资产」时清晰双池隔离，仅存其一时自动收起多余模块
/// - 轻点下方任意分类/账户卡片，直接下钻至「资产」页对应明细
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

    /// 仅展示此刻有意义的视角（此刻没用的，就不出现）
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
                VStack(spacing: 16) {
                    if holdings.isEmpty {
                        emptyWelcomeCard
                            .padding(.top, 24)
                    } else {
                        heroNetWorthCard

                        AllocationChartSection(
                            selectedLens: $selectedLens,
                            availableLenses: availableLenses,
                            snapshot: snapshot,
                            hideAmounts: refreshStore.hideAmounts
                        )

                        breakdownSection
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 36)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("总览")
            .navigationBarTitleDisplayMode(.large)
            .refreshable {
                if snapshot.hasRefreshableHoldings {
                    await refreshStore.refreshAllQuotes(holdings: holdings, in: modelContext, silent: false)
                }
            }
            .toolbar {
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

    // MARK: - 顶部总净值与双资金池隔离主卡片

    private var heroNetWorthCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                HStack(spacing: 6) {
                    Text(snapshot.hasBothPools ? "全部总净值" : (snapshot.hasFixedHoldings ? "固定资产总额" : "总资产"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)

                    Button {
                        Haptics.selection()
                        refreshStore.hideAmounts.toggle()
                    } label: {
                        Image(systemName: refreshStore.hideAmounts ? "eye.slash" : "eye")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(refreshStore.hideAmounts ? "显示金额" : "隐藏金额")
                }

                Spacer()

                if let updated = refreshStore.lastNetworkRefresh ?? snapshot.latestQuoteUpdatedAt {
                    Text("更新于 \(Formatters.shortDateTime(updated))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(Formatters.currency(snapshot.totalNetWorth, hidden: refreshStore.hideAmounts))
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)

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
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        refreshStore.pnlColorScheme.color(for: delta).opacity(0.12),
                        in: Capsule()
                    )
                }
            }

            // 仅当同时存在投资资产与固定资产时，展示双池隔离条与并排拆解（不给单池用户增加多余噪点）
            if snapshot.hasBothPools {
                GeometryReader { geo in
                    let totalWidth = max(geo.size.width, 1)
                    let invRatio = min(max(snapshot.investableTotal / max(snapshot.totalNetWorth, 1), 0), 1)
                    HStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(CategoryColorToken.blue.color)
                            .frame(width: max(totalWidth * invRatio - 1.5, 4))
                        RoundedRectangle(cornerRadius: 3)
                            .fill(CategoryColorToken.amber.color.opacity(0.85))
                    }
                }
                .frame(height: 6)

                HStack(spacing: 10) {
                    poolSummaryTile(
                        title: "投资资产",
                        roleHint: "下方占比分母",
                        badgeColor: CategoryColorToken.blue.color,
                        amount: snapshot.investableTotal,
                        sharePercent: snapshot.investableShareOfNetWorth,
                        pnl: snapshot.investablePnL,
                        isSelected: selectedLens == .investable
                    ) {
                        Haptics.selection()
                        withAnimation(.snappy) { selectedLens = .investable }
                    }

                    poolSummaryTile(
                        title: "固定资产",
                        roleHint: "不参与投资占比",
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
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func poolSummaryTile(
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
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(badgeColor)
                        .frame(width: 7, height: 7)
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(Formatters.percentPoints(sharePercent, digits: 0))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                Text(Formatters.currency(amount, hidden: refreshStore.hideAmounts, compact: amount >= 1_000_000))
                    .font(.system(.callout, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                if pnl.hasTrackedHoldings {
                    let delta = pnl.profitLoss
                    HStack(spacing: 3) {
                        Text(Formatters.signedCurrency(delta, hidden: refreshStore.hideAmounts))
                        if let rate = pnl.profitLossRate {
                            Text("(\(Formatters.signedRate(rate, hidden: refreshStore.hideAmounts)))")
                        }
                    }
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(refreshStore.pnlColorScheme.color(for: delta))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                } else {
                    Text(roleHint)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.tertiarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? badgeColor.opacity(0.6) : .clear, lineWidth: 1.3)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 极简空状态引导

    private var emptyWelcomeCard: some View {
        VStack(spacing: 18) {
            Image(systemName: "chart.pie.fill")
                .font(.system(size: 46))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 8)

            VStack(spacing: 6) {
                Text("记下你的第一笔资产")
                    .font(.title3.weight(.bold))
                Text("按类别看配置，按账户好对账。\n大额存单、房产等固定资产可独立核算，不稀释投资比例。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }

            VStack(spacing: 10) {
                Button {
                    Haptics.lightImpact()
                    showingAddHolding = true
                } label: {
                    Label("新增第一笔资产", systemImage: "plus.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
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
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: - 下方分类 / 账户占比明细（轻点卡片直达对应资产列表）

    @ViewBuilder
    private var breakdownSection: some View {
        switch selectedLens {
        case .investable:
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("投资资产结构")
                        .font(.headline)
                    Spacer()
                    if let targetSum = snapshot.configuredTargetSum {
                        Text("目标合计 \(Formatters.percentPoints(targetSum, digits: 0))")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(abs(targetSum - 100) < 0.1 ? Color.secondary : Color.orange)
                    }
                }
                .padding(.horizontal, 4)

                VStack(spacing: 10) {
                    ForEach(snapshot.investableSlices) { slice in
                        allocationSliceCard(slice: slice, showTargetIfPresent: true)
                    }
                }
            }

        case .fixed:
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("固定资产明细")
                        .font(.headline)
                    Spacer()
                    Text("占总净值 \(Formatters.percentPoints(snapshot.fixedShareOfNetWorth))")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)

                VStack(spacing: 10) {
                    ForEach(snapshot.fixedSlices) { slice in
                        allocationSliceCard(slice: slice, showTargetIfPresent: false)
                    }
                }
            }

        case .accounts:
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("各账户资金分布")
                        .font(.headline)
                    Spacer()
                    Text("共 \(snapshot.accountSlices.count) 个账户")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)

                VStack(spacing: 10) {
                    ForEach(snapshot.accountSlices) { acc in
                        accountSliceCard(acc)
                    }
                }
            }
        }
    }

    private func allocationSliceCard(slice: AllocationSlice, showTargetIfPresent: Bool) -> some View {
        Button {
            refreshStore.drillDownToCategory(id: slice.categoryID, name: slice.name, pool: slice.pool)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(slice.color.opacity(0.15))
                            .frame(width: 34, height: 34)
                        Image(systemName: slice.iconName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(slice.color)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(slice.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("\(slice.holdingCount)项")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        if showTargetIfPresent, let target = slice.targetRatioPercent, let dev = slice.deviationPoints {
                            HStack(spacing: 6) {
                                Text("目标 \(Formatters.percentPoints(target, digits: 0))")
                                    .foregroundStyle(.secondary)
                                Text(deviationLabel(dev))
                                    .foregroundStyle(abs(dev) >= 5.0 ? Color.orange : Color.secondary)
                            }
                            .font(.caption)
                            .monospacedDigit()
                        } else if slice.pool == .fixed {
                            Text("占总净值 \(Formatters.percentPoints(slice.netWorthRatioPercent))")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        } else if slice.pnl.hasTrackedHoldings {
                            let delta = slice.pnl.profitLoss
                            Text("盈亏 \(Formatters.signedCurrency(delta, hidden: refreshStore.hideAmounts))")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(refreshStore.pnlColorScheme.color(for: delta))
                        }
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Formatters.currency(slice.amount, hidden: refreshStore.hideAmounts))
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(.primary)

                        Text(Formatters.percentPoints(slice.poolRatioPercent))
                            .font(.caption.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.quaternary)
                }

                // 进度条（若设置了目标比例，额外绘制目标刻度线）
                GeometryReader { geo in
                    let width = max(geo.size.width, 1)
                    let actualFraction = min(max(slice.poolRatioPercent / 100.0, 0), 1)
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color(.tertiarySystemFill))
                            .frame(height: 6)

                        if actualFraction > 0 {
                            Capsule()
                                .fill(slice.color)
                                .frame(width: max(width * actualFraction, 4), height: 6)
                        }

                        if showTargetIfPresent, let target = slice.targetRatioPercent, target > 0, target <= 100 {
                            let markerX = min(max(width * (target / 100.0), 1), width - 2)
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Color.primary.opacity(0.65))
                                .frame(width: 2, height: 11)
                                .offset(x: markerX - 1)
                        }
                    }
                }
                .frame(height: 11)
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func deviationLabel(_ dev: Double) -> String {
        if abs(dev) < 0.2 {
            return "贴合目标"
        }
        return dev > 0 ? "偏高 \(Formatters.signedPercentPoints(dev))" : "偏低 \(Formatters.signedPercentPoints(dev))"
    }

    private func accountSliceCard(_ acc: AccountSlice) -> some View {
        Button {
            refreshStore.drillDownToAccount(id: acc.accountID, name: acc.name)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(acc.color.opacity(0.15))
                            .frame(width: 34, height: 34)
                        Image(systemName: acc.iconName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(acc.color)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(acc.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("\(acc.holdingCount)项")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        if acc.investableAmount > 0 && acc.fixedAmount > 0 {
                            Text("投资 \(Formatters.currency(acc.investableAmount, hidden: refreshStore.hideAmounts, compact: true)) · 固定 \(Formatters.currency(acc.fixedAmount, hidden: refreshStore.hideAmounts, compact: true))")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        } else if !acc.subtitle.isEmpty {
                            Text(acc.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Formatters.currency(acc.totalAmount, hidden: refreshStore.hideAmounts))
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(.primary)

                        Text(Formatters.percentPoints(acc.netWorthRatioPercent))
                            .font(.caption.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.quaternary)
                }

                GeometryReader { geo in
                    let width = max(geo.size.width, 1)
                    let fraction = min(max(acc.netWorthRatioPercent / 100.0, 0), 1)
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color(.tertiarySystemFill))
                            .frame(height: 6)
                        if fraction > 0 {
                            Capsule()
                                .fill(acc.color)
                                .frame(width: max(width * fraction, 4), height: 6)
                        }
                    }
                }
                .frame(height: 6)
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
