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
    let deviationAmount: Double?
    let color: Color
}

/// 嵌入式可交互环形图模块（与下方明细行融为同一视觉表面，消除模块割裂感）
/// - 轻点环上色块即可高亮并在圆心显示该项金额、占比与目标差额；再点一次或点圆心即收回
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
                        deviationAmount: $0.deviationAmount,
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
                        deviationAmount: nil,
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
                        deviationAmount: nil,
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
            let pct = Formatters.percentPoints(selectedItem.percent)
            if let devAmt = selectedItem.deviationAmount, !hideAmounts, abs(devAmt) >= 50 {
                let tag = devAmt > 0 ? "超" : "差"
                return "\(pct) · \(tag)\(Formatters.wholeCurrency(abs(devAmt)))"
            }
            return pct
        }
        if selectedLens == .investable && snapshot.hasFixedHoldings {
            return "不含固定资产"
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 10) {
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
                VStack(spacing: 6) {
                    Image(systemName: "chart.pie")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("当前视角暂无金额")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 140)
            } else {
                ZStack {
                    Chart(chartItems) { item in
                        let isSelected = (selectedItemID == item.id)
                        let isDimmed = (selectedItemID != nil && !isSelected)
                        SectorMark(
                            angle: .value("金额", item.amount),
                            innerRadius: .ratio(0.67),
                            outerRadius: .ratio(isSelected ? 1.0 : 0.94),
                            angularInset: 1.5
                        )
                        .cornerRadius(4)
                        .foregroundStyle(item.color)
                        .opacity(isDimmed ? 0.30 : 1.0)
                    }
                    .chartLegend(.hidden)
                    .chartAngleSelection(value: $chartAngleSelection)
                    .onChange(of: chartAngleSelection) { _, newAngle in
                        guard let newAngle else { return }
                        handleAngleTap(newAngle)
                    }
                    .frame(height: 164)

                    Button {
                        if selectedItemID != nil {
                            Haptics.selection()
                            withAnimation(.snappy) {
                                selectedItemID = nil
                                chartAngleSelection = nil
                            }
                        }
                    } label: {
                        VStack(spacing: 2) {
                            Text(centerTitle)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)

                            Text(Formatters.currency(centerAmount, hidden: hideAmounts, compact: true))
                                .font(.system(.headline, design: .rounded, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)

                            if let sub = centerSubtitle {
                                Text(sub)
                                    .font(.system(size: 10.5, weight: .medium))
                                    .monospacedDigit()
                                    .foregroundStyle(selectedItem?.color ?? .secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                        }
                        .frame(maxWidth: 108)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
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
            if selectedItemID == matched {
                selectedItemID = nil
            } else {
                selectedItemID = matched
            }
        }
        chartAngleSelection = nil
    }
}
