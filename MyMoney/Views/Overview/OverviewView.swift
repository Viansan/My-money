import SwiftUI
import SwiftData

/// Tab 1：资产总览页
/// 核心职责：清晰展示全部总净值、隔离展示「投资资产池」与「固定/底仓资产」，并呈现分类实际占比（及选填目标对比）与账户分布
struct OverviewView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PortfolioRefreshStore.self) private var refreshStore

    @Query(sort: \AssetHolding.sortOrder) private var holdings: [AssetHolding]
    @Query(sort: \AssetCategory.sortOrder) private var categories: [AssetCategory]
    @Query(sort: \AssetAccount.sortOrder) private var accounts: [AssetAccount]

    @State private var selectedLens: OverviewLens = .investable
    @State private var showingAddHolding = false
    @State private var demoLoadError: String?

    private var snapshot: PortfolioSnapshot {
        PortfolioSnapshot.build(holdings: holdings, categories: categories, accounts: accounts)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    heroNetWorthCard

                    if let statusText = refreshStore.statusBannerText {
                        refreshStatusBanner(text: statusText)
                    }

                    if holdings.isEmpty {
                        emptyWelcomeCard
                    } else {
                        AllocationChartSection(
                            selectedLens: $selectedLens,
                            snapshot: snapshot,
                            hideAmounts: refreshStore.hideAmounts
                        )

                        breakdownSection
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("总览")
            .navigationBarTitleDisplayMode(.large)
            .refreshable {
                await refreshStore.refreshAllQuotes(holdings: holdings, in: modelContext)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 14) {
                        Button {
                            Task {
                                await refreshStore.refreshAllQuotes(holdings: holdings, in: modelContext)
                            }
                        } label: {
                            if refreshStore.isRefreshing {
                                ProgressView()
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .disabled(refreshStore.isRefreshing)
                        .accessibilityLabel("刷新全部行情")

                        Button {
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
                HoldingFormSheet(existingHolding: nil)
            }
            .alert("载入示例失败", isPresented: Binding(
                get: { demoLoadError != nil },
                set: { if !$0 { demoLoadError = nil } }
            )) {
                Button("好", role: .cancel) { demoLoadError = nil }
            } message: {
                Text(demoLoadError ?? "")
            }
        }
    }

    // MARK: - 顶部总净值与双资金池隔离主卡片

    private var heroNetWorthCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center) {
                HStack(spacing: 6) {
                    Text("全部总净值")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)

                    Button {
                        refreshStore.hideAmounts.toggle()
                    } label: {
                        Image(systemName: refreshStore.hideAmounts ? "eye.slash" : "eye")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
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
                    Text(Formatters.signedCurrency(delta, hidden: refreshStore.hideAmounts))
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

            // 宏观双池比例条（直观展示投资池 vs 固定/底仓的体量隔离）
            if snapshot.totalNetWorth > 0 {
                GeometryReader { geo in
                    let totalWidth = max(geo.size.width, 1)
                    let invRatio = min(max(snapshot.investableTotal / snapshot.totalNetWorth, 0), 1)
                    HStack(spacing: 3) {
                        if invRatio > 0 {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(CategoryColorToken.blue.color)
                                .frame(width: max(totalWidth * invRatio - 1.5, 4))
                        }
                        if invRatio < 1 {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(CategoryColorToken.amber.color.opacity(0.85))
                        }
                    }
                }
                .frame(height: 6)
            }

            // 投资资产池 vs 固定/底仓资产 双栏拆解
            HStack(spacing: 10) {
                poolSummaryTile(
                    title: "投资资产池",
                    badgeColor: CategoryColorToken.blue.color,
                    amount: snapshot.investableTotal,
                    sharePercent: snapshot.investableShareOfNetWorth,
                    pnl: snapshot.investablePnL,
                    isSelected: selectedLens == .investable
                ) {
                    withAnimation(.snappy) { selectedLens = .investable }
                }

                poolSummaryTile(
                    title: "固定/底仓",
                    badgeColor: CategoryColorToken.amber.color,
                    amount: snapshot.fixedTotal,
                    sharePercent: snapshot.fixedShareOfNetWorth,
                    pnl: snapshot.fixedPnL,
                    isSelected: selectedLens == .fixed
                ) {
                    withAnimation(.snappy) { selectedLens = .fixed }
                }
            }
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func poolSummaryTile(
        title: String,
        badgeColor: Color,
        amount: Double,
        sharePercent: Double,
        pnl: PnLSummary,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(badgeColor)
                        .frame(width: 7, height: 7)
                    Text(title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(Formatters.percentPoints(sharePercent, digits: 0))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }

                Text(Formatters.currency(amount, hidden: refreshStore.hideAmounts, compact: amount >= 1_000_000))
                    .font(.system(.callout, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                if pnl.hasTrackedHoldings {
                    let delta = pnl.profitLoss
                    HStack(spacing: 4) {
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
                    Text("独立核算")
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
                    .strokeBorder(isSelected ? badgeColor.opacity(0.55) : .clear, lineWidth: 1.2)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 刷新状态与错误提示条

    private func refreshStatusBanner(text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: refreshStore.errorMessages.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(refreshStore.errorMessages.isEmpty ? .green : .orange)
                Text(text)
                    .font(.footnote.weight(.medium))
                Spacer()
                Button {
                    refreshStore.statusBannerText = nil
                    refreshStore.errorMessages = []
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if !refreshStore.errorMessages.isEmpty {
                ForEach(refreshStore.errorMessages, id: \.self) { err in
                    Text("• \(err)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - 空状态引导卡片

    private var emptyWelcomeCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.pie.fill")
                .font(.system(size: 40))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 8)

            VStack(spacing: 6) {
                Text("开始记录你的第一笔资产")
                    .font(.headline)
                Text("支持按「资产类别 + 存放账户」双维度管理，并将固定大额底仓与日常投资组合自动隔离核算。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 10) {
                Button {
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
                    } catch {
                        demoLoadError = error.localizedDescription
                    }
                } label: {
                    Text("载入演示数据体验效果（可随时一键清空）")
                        .font(.footnote.weight(.medium))
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: - 下方分类 / 账户占比明细列表

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
                        Text("已设目标合计 \(Formatters.percentPoints(targetSum, digits: 0))")
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
                    Text("固定与底仓明细")
                        .font(.headline)
                    Spacer()
                    Text("占总净值 \(Formatters.percentPoints(snapshot.fixedShareOfNetWorth))")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)

                if snapshot.fixedSlices.allSatisfy({ $0.holdingCount == 0 }) {
                    Text("暂无归属「固定/底仓」类别的资产。可在「管理 -> 资产类别」中将大额存单、房产等设为固定/底仓，避免影响投资组合比例。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else {
                    VStack(spacing: 10) {
                        ForEach(snapshot.fixedSlices) { slice in
                            allocationSliceCard(slice: slice, showTargetIfPresent: false)
                        }
                    }
                }
            }

        case .accounts:
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("各账户资金分布")
                        .font(.headline)
                    Spacer()
                    Text("共 \(snapshot.accountSlices.filter { $0.holdingCount > 0 }.count) 个活跃账户")
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
                        Text("\(slice.holdingCount)项")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if showTargetIfPresent, let target = slice.targetRatioPercent, let dev = slice.deviationPoints {
                        HStack(spacing: 6) {
                            Text("目标 \(Formatters.percentPoints(target))")
                                .foregroundStyle(.secondary)
                            Text("偏差 \(Formatters.signedPercentPoints(dev))")
                                .foregroundStyle(abs(dev) >= 5.0 ? Color.orange : Color.secondary)
                        }
                        .font(.caption)
                        .monospacedDigit()
                    } else if slice.pool == .fixed {
                        Text("占全部总净值 \(Formatters.percentPoints(slice.netWorthRatioPercent))")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    } else if slice.pnl.hasTrackedHoldings {
                        let delta = slice.pnl.profitLoss
                        Text("持仓盈亏 \(Formatters.signedCurrency(delta, hidden: refreshStore.hideAmounts))")
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

                    Text(Formatters.percentPoints(slice.poolRatioPercent))
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            // 进度条（若设置了选填目标比例，则额外渲染目标刻度线）
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

    private func accountSliceCard(_ acc: AccountSlice) -> some View {
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

                    Text(Formatters.percentPoints(acc.netWorthRatioPercent))
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
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
}
