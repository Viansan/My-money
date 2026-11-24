import SwiftUI
import Charts

/// 总览页分析视角枚举
enum OverviewLens: String, CaseIterable, Identifiable {
    case investable = "投资资产"
    case fixed = "固定资产"
    case accounts = "账户分布"

    var id: String { rawValue }
}

/// 环形图通用切片模型
struct RingChartItem: Identifiable {
    let id: UUID
    let name: String
    let amount: Double
    let percent: Double
    let color: Color
}

/// 基于 Swift Charts `SectorMark` 的可交互环形图卡片
/// - 只显示此刻有数据的视角，不展示无意义的空 Tab
/// - 轻点环上任意色块即可高亮并展示该项金额与占比；再点一次（或点圆心）即可收回恢复总览
struct AllocationChartSection: View {
    @Binding var selectedLens: OverviewLens
    let availableLenses: [OverviewLens]
    let snapshot: PortfolioSnapshot
    let hideAmounts: Bool

    @State private var chartAngleSelection: Double?
    @State private var selectedItemID: UUID?

    private var chartItems: [RingChartItem] {
        switch selectedLens {
        case .investable:
            return snapshot.investableSlices
                .filter { $0.amount > 0 && $0.amount.isFinite }
                .map {
                    RingChartItem(
                        id: $0.id,
                        name: $0.name,
                        amount: $0.amount,
                        percent: $0.poolRatioPercent,
                        color: $0.color
                    )
                }
        case .fixed:
            return snapshot.fixedSlices
                .filter { $0.amount > 0 && $0.amount.isFinite }
                .map {
                    RingChartItem(
                        id: $0.id,
                        name: $0.name,
                        amount: $0.amount,
                        percent: $0.poolRatioPercent,
                        color: $0.color
                    )
                }
        case .accounts:
            return snapshot.accountSlices
                .filter { $0.totalAmount > 0 && $0.totalAmount.isFinite }
                .map {
                    RingChartItem(
                        id: $0.id,
                        name: $0.name,
                        amount: $0.totalAmount,
                        percent: $0.netWorthRatioPercent,
                        color: $0.color
                    )
                }
        }
    }

    private var selectedItem: RingChartItem? {
        guard let id = selectedItemID else { return nil }
        return chartItems.first(where: { $0.id == id })
    }

    private var centerTitle: String {
        if let selectedItem {
            return selectedItem.name
        }
        switch selectedLens {
        case .investable: return "投资资产"
        case .fixed: return "固定资产"
        case .accounts: return "全部总净值"
        }
    }

    private var centerAmount: Double {
        if let selectedItem {
            return selectedItem.amount
        }
        switch selectedLens {
        case .investable: return snapshot.investableTotal
        case .fixed: return snapshot.fixedTotal
        case .accounts: return snapshot.totalNetWorth
        }
    }

    private var centerSubtitle: String? {
        if let selectedItem {
            return Formatters.percentPoints(selectedItem.percent)
        }
        if selectedLens == .investable && snapshot.hasFixedHoldings {
            return "不含固定资产"
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if availableLenses.count > 1 {
                Picker("分析视角", selection: $selectedLens) {
                    ForEach(availableLenses) { lens in
                        Text(lens.rawValue).tag(lens)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: selectedLens) { _, _ in
                    Haptics.selection()
                    selectedItemID = nil
                    chartAngleSelection = nil
                }
            }

            if chartItems.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "chart.pie")
                        .font(.system(size: 30))
                        .foregroundStyle(.tertiary)
                    Text("当前视角暂无金额")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 180)
            } else {
                ZStack {
                    Chart(chartItems) { item in
                        let isSelected = (selectedItemID == item.id)
                        let isDimmed = (selectedItemID != nil && !isSelected)
                        SectorMark(
                            angle: .value("金额", item.amount),
                            innerRadius: .ratio(0.64),
                            outerRadius: .ratio(isSelected ? 1.0 : 0.94),
                            angularInset: 1.8
                        )
                        .cornerRadius(5)
                        .foregroundStyle(item.color)
                        .opacity(isDimmed ? 0.32 : 1.0)
                    }
                    .chartLegend(.hidden)
                    .chartAngleSelection(value: $chartAngleSelection)
                    .onChange(of: chartAngleSelection) { _, newAngle in
                        guard let newAngle else { return }
                        handleAngleTap(newAngle)
                    }
                    .frame(height: 216)

                    // 圆心信息（点击圆心可取消选中恢复总计）
                    Button {
                        if selectedItemID != nil {
                            Haptics.selection()
                            withAnimation(.snappy) {
                                selectedItemID = nil
                                chartAngleSelection = nil
                            }
                        }
                    } label: {
                        VStack(spacing: 3) {
                            Text(centerTitle)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)

                            Text(Formatters.currency(centerAmount, hidden: hideAmounts, compact: true))
                                .font(.system(.title3, design: .rounded, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)

                            if let sub = centerSubtitle {
                                Text(sub)
                                    .font(.caption2.weight(.medium))
                                    .monospacedDigit()
                                    .foregroundStyle(selectedItem?.color ?? .secondary)
                            }
                        }
                        .frame(maxWidth: 120)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func handleAngleTap(_ angle: Double) {
        var cumulative = 0.0
        var matched: UUID?
        for item in chartItems {
            cumulative += item.amount
            if angle <= cumulative {
                matched = item.id
                break
            }
        }
        guard let matched else { return }
        Haptics.selection()
        withAnimation(.snappy(duration: 0.2)) {
            // 再按同一色块即可收回取消高亮
            if selectedItemID == matched {
                selectedItemID = nil
            } else {
                selectedItemID = matched
            }
        }
        chartAngleSelection = nil
    }
}
