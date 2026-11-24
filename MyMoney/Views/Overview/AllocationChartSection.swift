import SwiftUI
import Charts

/// 总览页分析视角枚举
enum OverviewLens: String, CaseIterable, Identifiable {
    case investable = "投资配置"
    case fixed = "固定/底仓"
    case accounts = "账户分布"

    var id: String { rawValue }
}

/// 环形图通用切片模型
struct RingChartItem: Identifiable {
    let id: UUID
    let name: String
    let amount: Double
    let color: Color
}

/// 基于 Swift Charts `SectorMark` 的原生环形图卡片
struct AllocationChartSection: View {
    @Binding var selectedLens: OverviewLens
    let snapshot: PortfolioSnapshot
    let hideAmounts: Bool

    private var chartItems: [RingChartItem] {
        switch selectedLens {
        case .investable:
            return snapshot.investableSlices
                .filter { $0.amount > 0 && $0.amount.isFinite }
                .map { RingChartItem(id: $0.id, name: $0.name, amount: $0.amount, color: $0.color) }
        case .fixed:
            return snapshot.fixedSlices
                .filter { $0.amount > 0 && $0.amount.isFinite }
                .map { RingChartItem(id: $0.id, name: $0.name, amount: $0.amount, color: $0.color) }
        case .accounts:
            return snapshot.accountSlices
                .filter { $0.totalAmount > 0 && $0.totalAmount.isFinite }
                .map { RingChartItem(id: $0.id, name: $0.name, amount: $0.totalAmount, color: $0.color) }
        }
    }

    private var centerTitle: String {
        switch selectedLens {
        case .investable: return "投资池总额"
        case .fixed: return "固定/底仓"
        case .accounts: return "全部总净值"
        }
    }

    private var centerAmount: Double {
        switch selectedLens {
        case .investable: return snapshot.investableTotal
        case .fixed: return snapshot.fixedTotal
        case .accounts: return snapshot.totalNetWorth
        }
    }

    private var lensCaption: String {
        switch selectedLens {
        case .investable:
            return "分母仅含「投资资产」，固定/底仓资产已隔离，不稀释配置比例"
        case .fixed:
            return "独立核算的大额底仓、定期存款或不动产，仅计入全部总净值"
        case .accounts:
            return "按真实存放渠道汇总全部资金，金额与对应平台账面保持一致"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("分析视角", selection: $selectedLens) {
                ForEach(OverviewLens.allCases) { lens in
                    Text(lens.rawValue).tag(lens)
                }
            }
            .pickerStyle(.segmented)

            if chartItems.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: selectedLens == .fixed ? "shield.slash" : "chart.pie")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("当前视角下暂无资产记录")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 190)
            } else {
                ZStack {
                    Chart(chartItems) { item in
                        SectorMark(
                            angle: .value("金额", item.amount),
                            innerRadius: .ratio(0.64),
                            angularInset: 1.8
                        )
                        .cornerRadius(5)
                        .foregroundStyle(item.color)
                    }
                    .chartLegend(.hidden)
                    .frame(height: 215)

                    VStack(spacing: 4) {
                        Text(centerTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(Formatters.currency(centerAmount, hidden: hideAmounts, compact: true))
                            .font(.system(.title3, design: .rounded, weight: .bold))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .padding(.horizontal, 28)
                }
            }

            Text(lensCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
