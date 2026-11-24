import SwiftUI
import SwiftData

/// Tab 1：资产总览页（极简方案 B）
/// - 聚焦「总净值 + 投资/固定资产结构」，彻底去除冗余图表与重复账户入口（看账户直达 Tab 2）
/// - 全部数值、进度条、双池滑块与按压状态均采用统一 Motion 物理曲线，克制跟手、零抖动
struct OverviewView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(PortfolioRefreshStore.self) private var refreshStore

    @Query(sort: \AssetHolding.sortOrder) private var holdings: [AssetHolding]
    @Query(sort: \AssetCategory.sortOrder) private var categories: [AssetCategory]
    @Query(sort: \AssetAccount.sortOrder) private var accounts: [AssetAccount]

    @State private var activePool: AssetPool = .investable
    @State private var showingAddHolding = false
    @Namespace private var poolIndicatorNS

    private var snapshot: PortfolioSnapshot {
        PortfolioSnapshot.build(holdings: holdings, categories: categories, accounts: accounts)
    }

    private var displayedSlices: [AllocationSlice] {
        activePool == .fixed ? snapshot.fixedSlices : snapshot.investableSlices
    }

    var body: some View {
        @Bindable var bindableStore = refreshStore

        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if holdings.isEmpty {
                        emptyWelcomeCard
                            .padding(.top, 20)
                            .transition(.opacity)
                    } else {
                        heroNetWorthCard

                        structureCard
                    }
                }
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 32)
                .animation(Motion.standard(reduceMotion: reduceMotion), value: holdings.isEmpty)
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
                        PrivacyToggleButton(hideAmounts: $bindableStore.hideAmounts)
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        if snapshot.hasRefreshableHoldings {
                            RefreshToolbarButton(isRefreshing: refreshStore.isRefreshing) {
                                Task {
                                    await refreshStore.refreshAllQuotes(holdings: holdings, in: modelContext, silent: false)
                                }
                            }
                        }

                        Button {
                            Haptics.lightImpact()
                            showingAddHolding = true
                        } label: {
                            Image(systemName: "plus")
                                .fontWeight(.semibold)
                                .frame(width: 24, height: 24)
                        }
                        .accessibilityLabel("新增资产")
                    }
                }
            }
            .sheet(isPresented: $showingAddHolding) {
                HoldingFormSheet(existingHolding: nil, preselectedPool: activePool)
            }
            .onAppear(perform: reconcileActivePool)
            .onChange(of: snapshot.hasInvestableHoldings) { _, _ in reconcileActivePool() }
            .onChange(of: snapshot.hasFixedHoldings) { _, _ in reconcileActivePool() }
        }
    }

    private func reconcileActivePool() {
        if activePool == .fixed && !snapshot.hasFixedHoldings {
            activePool = .investable
        } else if activePool == .investable && !snapshot.hasInvestableHoldings && snapshot.hasFixedHoldings && snapshot.configuredTargetSum == nil {
            activePool = .fixed
        }
    }

    // MARK: - 表面 1：净值总览与双池滑动切换卡

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
                        .contentTransition(.numericText(value: snapshot.totalNetWorth))
                        .animation(Motion.numeric(reduceMotion: reduceMotion), value: snapshot.totalNetWorth)

                    Spacer(minLength: 4)

                    if snapshot.overallPnL.hasTrackedHoldings {
                        let delta = snapshot.overallPnL.profitLoss
                        HStack(spacing: 3) {
                            Text(Formatters.signedCurrency(delta, hidden: refreshStore.hideAmounts))
                                .contentTransition(.numericText(value: delta))
                            if !snapshot.hasBothPools, let rate = snapshot.overallPnL.profitLossRate {
                                Text(Formatters.signedRate(rate, hidden: refreshStore.hideAmounts))
                                    .contentTransition(.numericText(value: rate))
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
                        .animation(Motion.numeric(reduceMotion: reduceMotion), value: delta)
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
                        .animation(Motion.standard(reduceMotion: reduceMotion), value: invRatio)
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
                        pool: .investable,
                        title: "投资资产",
                        roleHint: "占比分母",
                        badgeColor: CategoryColorToken.blue.color,
                        amount: snapshot.investableTotal,
                        sharePercent: snapshot.investableShareOfNetWorth,
                        pnl: snapshot.investablePnL
                    )

                    Divider()
                        .frame(height: 36)

                    poolStripColumn(
                        pool: .fixed,
                        title: "固定资产",
                        roleHint: "不计入投资占比",
                        badgeColor: CategoryColorToken.amber.color,
                        amount: snapshot.fixedTotal,
                        sharePercent: snapshot.fixedShareOfNetWorth,
                        pnl: snapshot.fixedPnL
                    )
                }
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func poolStripColumn(
        pool: AssetPool,
        title: String,
        roleHint: String,
        badgeColor: Color,
        amount: Double,
        sharePercent: Double,
        pnl: PnLSummary
    ) -> some View {
        let isSelected = (activePool == pool)

        return Button {
            guard activePool != pool else { return }
            Haptics.selection()
            withAnimation(Motion.standard(reduceMotion: reduceMotion)) {
                activePool = pool
            }
        } label: {
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
                        .contentTransition(.numericText(value: sharePercent))
                }

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Formatters.currency(amount, hidden: refreshStore.hideAmounts, compact: amount >= 100_000))
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                        .contentTransition(.numericText(value: amount))

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
                        .matchedGeometryEffect(id: "poolIndicator", in: poolIndicatorNS)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(TactilePressButtonStyle(pressedScale: 0.99, pressedOpacity: 0.88))
    }

    // MARK: - 表面 2：纯净资产结构列表（投资结构 / 固定资产明细）

    private var structureCard: some View {
        VStack(spacing: 0) {
            HStack {
                Text(activePool == .fixed ? "固定资产明细" : "投资结构")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                if activePool == .investable, let targetSum = snapshot.configuredTargetSum {
                    Text("目标合计 \(Formatters.percentPoints(targetSum, digits: 0))")
                        .font(.caption2.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(abs(targetSum - 100) >= 0.1 ? Color.orange : Color.secondary)
                } else if activePool == .fixed {
                    Text("占总净值 \(Formatters.percentPoints(snapshot.fixedShareOfNetWorth))")
                        .font(.caption2.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    Text("共 \(displayedSlices.count) 类")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(.tertiarySystemGroupedBackground).opacity(0.45))

            Divider()

            VStack(spacing: 0) {
                ForEach(Array(displayedSlices.enumerated()), id: \.element.id) { index, slice in
                    allocationSliceRow(slice: slice, showTargetIfPresent: activePool == .investable)
                    if index < displayedSlices.count - 1 {
                        Divider().padding(.leading, 50)
                    }
                }
            }
            .id(activePool)
            .transition(.opacity)
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .animation(Motion.standard(reduceMotion: reduceMotion), value: activePool)
    }

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

                VStack(alignment: .leading, spacing: 4) {
                    // 第一行：类别名 + 唯一主角金额
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
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
                            .contentTransition(.numericText(value: slice.amount))
                            .animation(Motion.numeric(reduceMotion: reduceMotion), value: slice.amount)
                    }

                    // 第二行：占比与目标对比（无重复信息）
                    if showTargetIfPresent, let targetPct = slice.targetRatioPercent, let devPts = slice.deviationPoints {
                        HStack(spacing: 6) {
                            HStack(spacing: 3) {
                                Text(Formatters.percentPoints(slice.poolRatioPercent))
                                    .fontWeight(.medium)
                                    .foregroundStyle(.secondary)
                                    .contentTransition(.numericText(value: slice.poolRatioPercent))
                                Text("/ \(Formatters.percentPoints(targetPct, digits: 0))")
                                    .foregroundStyle(.tertiary)
                                if let targetAmt = slice.targetAmount, !refreshStore.hideAmounts {
                                    Text("· 目标 \(Formatters.wholeCurrency(targetAmt))")
                                        .foregroundStyle(.tertiary)
                                }
                            }

                            Spacer(minLength: 4)

                            targetGapLabel(devPoints: devPts, devAmount: slice.deviationAmount)
                        }
                        .font(.caption2)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    } else if slice.pool == .fixed {
                        HStack {
                            Text("占总净值 \(Formatters.percentPoints(slice.netWorthRatioPercent))")
                                .foregroundStyle(.secondary)
                            Spacer()
                            if slice.pnl.hasTrackedHoldings {
                                let delta = slice.pnl.profitLoss
                                Text("盈亏 \(Formatters.signedCurrency(delta, hidden: refreshStore.hideAmounts))")
                                    .foregroundStyle(refreshStore.pnlColorScheme.color(for: delta))
                            }
                        }
                        .font(.caption2)
                        .monospacedDigit()
                    } else {
                        HStack {
                            Text("占比 \(Formatters.percentPoints(slice.poolRatioPercent))")
                                .foregroundStyle(.secondary)
                            Spacer()
                            if slice.pnl.hasTrackedHoldings {
                                let delta = slice.pnl.profitLoss
                                Text("盈亏 \(Formatters.signedCurrency(delta, hidden: refreshStore.hideAmounts))")
                                    .foregroundStyle(refreshStore.pnlColorScheme.color(for: delta))
                            }
                        }
                        .font(.caption2)
                        .monospacedDigit()
                    }

                    // 第三行：紧致进度条 + 目标刻度线（数值更新时顺滑过渡）
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
                                    .fill(Color.primary.opacity(0.6))
                                    .frame(width: 2, height: 8)
                                    .offset(x: markerX - 1)
                            }
                        }
                        .animation(Motion.standard(reduceMotion: reduceMotion), value: actualFraction)
                    }
                    .frame(height: 8)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.quaternary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(TactilePressButtonStyle(pressedScale: 0.992, pressedOpacity: 0.88))
    }

    @ViewBuilder
    private func targetGapLabel(devPoints: Double, devAmount: Double?) -> some View {
        if abs(devPoints) < 0.2 {
            Text("已达标")
                .fontWeight(.medium)
                .foregroundStyle(.green)
        } else if let devAmount, !refreshStore.hideAmounts {
            if devAmount > 0 {
                Text("超 \(Formatters.wholeCurrency(devAmount))")
                    .fontWeight(.medium)
                    .foregroundStyle(Color.orange)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Color.orange.opacity(0.11), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .contentTransition(.numericText(value: devAmount))
            } else {
                Text("差 \(Formatters.wholeCurrency(abs(devAmount)))")
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: abs(devAmount)))
            }
        } else {
            Text(devPoints > 0 ? "高 \(Formatters.percentPoints(devPoints))" : "低 \(Formatters.percentPoints(abs(devPoints)))")
                .fontWeight(.medium)
                .foregroundStyle(devPoints > 0 ? Color.orange : Color.secondary)
        }
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
                Text("按账户好对账，按类别看配置。\n定存、房产等固定资产独立核算，不稀释投资占比。")
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
                .buttonStyle(TactilePressButtonStyle(pressedScale: 0.96))
                .foregroundStyle(Color.accentColor)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
