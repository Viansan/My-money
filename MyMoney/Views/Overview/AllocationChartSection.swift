import SwiftUI

/// 总览页分析视角枚举
enum OverviewLens: String, CaseIterable, Identifiable {
    case investable = "投资资产"
    case fixed = "固定资产"
    case accounts = "账户分布"

    var id: String { rawValue }
}

/// 构成条切片模型
struct CompositionBarItem: Identifiable {
    let id: UUID
    let name: String
    let amount: Double
    let percent: Double
    let deviationAmount: Double?
    let color: Color
}

/// 高信息密度的比例构成条（类似 iPhone 储存空间构成条）
/// - 彻底避免小屏圆环内数字重叠的问题，将视觉高度从 185pt 压缩至 ~48pt，让首屏完整露出下方明细
/// - 轻点条上任意色块高亮对应分类并联动高亮下方列表行，再点一次或点 × 收回
struct AllocationChartSection: View {
    @Binding var selectedLens: OverviewLens
    @Binding var highlightedSliceID: UUID?
    let availableLenses: [OverviewLens]
    let snapshot: PortfolioSnapshot
    let hideAmounts: Bool

    private var items: [CompositionBarItem] {
        switch selectedLens {
        case .investable:
            return snapshot.investableSlices
                .filter { $0.amount > 0 && $0.amount.isFinite }
                .map {
                    CompositionBarItem(
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
                    CompositionBarItem(
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
                    CompositionBarItem(
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

    private var totalAmount: Double {
        items.reduce(0.0) { $0 + $1.amount }
    }

    private var selectedItem: CompositionBarItem? {
        guard let id = highlightedSliceID else { return nil }
        return items.first(where: { $0.id == id })
    }

    /// 按金额降序取前 3 项用于紧凑色点图例，其余合并为「其他」保持单行不拥挤
    private var legendEntries: [(id: UUID?, name: String, percent: Double, color: Color)] {
        let sorted = items.sorted { $0.amount > $1.amount }
        if sorted.count <= 4 {
            return sorted.map { ($0.id, $0.name, $0.percent, $0.color) }
        }
        let topThree = sorted.prefix(3)
        let restPercent = sorted.dropFirst(3).reduce(0.0) { $0 + $1.percent }
        var result: [(id: UUID?, name: String, percent: Double, color: Color)] = topThree.map {
            ($0.id, $0.name, $0.percent, $0.color)
        }
        if restPercent >= 0.1 {
            result.append((nil, "其余", restPercent, Color(.systemGray3)))
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if availableLenses.count > 1 {
                Picker("分析视角", selection: $selectedLens) {
                    ForEach(availableLenses) { lens in
                        Text(lens.rawValue).tag(lens)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: selectedLens) { _, _ in
                    Haptics.selection()
                    highlightedSliceID = nil
                }
            }

            if items.isEmpty || totalAmount <= 0 {
                HStack {
                    Image(systemName: "chart.bar.xaxis")
                        .foregroundStyle(.tertiary)
                    Text("当前视角暂无金额")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            } else {
                // 1. 满宽比例构成条（与下方列表顺序一一对应，可点击任意色块）
                GeometryReader { geo in
                    let gap: CGFloat = 2
                    let count = items.count
                    let usableWidth = max(geo.size.width - gap * CGFloat(max(count - 1, 0)), 1)
                    let minSegWidth: CGFloat = 5

                    // 计算每段像素宽，确保极小占比（如 0.4%）依然可见可点且总宽严格贴合
                    let rawWidths: [CGFloat] = items.map { item in
                        max(usableWidth * CGFloat(item.amount / totalAmount), minSegWidth)
                    }
                    let rawSum = max(rawWidths.reduce(0, +), 1)
                    let scale = usableWidth / rawSum

                    HStack(spacing: gap) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                            let segWidth = rawWidths[idx] * scale
                            let isSelected = (highlightedSliceID == item.id)
                            let isDimmed = (highlightedSliceID != nil && !isSelected)

                            ZStack {
                                Color.clear
                                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                                    .fill(item.color)
                                    .frame(height: isSelected ? 14 : 11)
                                    .opacity(isDimmed ? 0.28 : 1.0)
                            }
                            .frame(width: max(segWidth, 3), height: 22)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                toggleSelection(item.id)
                            }
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .center)
                }
                .frame(height: 22)

                // 2. 动态信息条：选中色块时显示精准数字读数；未选中时显示紧凑色点图例
                if let selected = selectedItem {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(selected.color)
                            .frame(width: 7, height: 7)

                        Text(selected.name)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text("\(Formatters.wholeCurrency(selected.amount, hidden: hideAmounts)) · \(Formatters.percentPoints(selected.percent))")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Spacer(minLength: 4)

                        if let devAmt = selected.deviationAmount, !hideAmounts, abs(devAmt) >= 50 {
                            Text("\(devAmt >= 0 ? "超" : "差") \(Formatters.wholeCurrency(abs(devAmt)))")
                                .font(.caption2.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(devAmt >= 0 ? Color.orange : Color.secondary)
                        }

                        Button {
                            Haptics.selection()
                            withAnimation(.snappy) { highlightedSliceID = nil }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(selected.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                } else {
                    HStack(spacing: 10) {
                        ForEach(Array(legendEntries.enumerated()), id: \.offset) { _, entry in
                            Button {
                                if let id = entry.id {
                                    toggleSelection(id)
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(entry.color)
                                        .frame(width: 6, height: 6)
                                    Text(entry.name)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Text(Formatters.percentPoints(entry.percent, digits: 0))
                                        .monospacedDigit()
                                        .foregroundStyle(.tertiary)
                                }
                                .font(.caption2)
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func toggleSelection(_ id: UUID) {
        Haptics.selection()
        withAnimation(.snappy(duration: 0.2)) {
            if highlightedSliceID == id {
                highlightedSliceID = nil
            } else {
                highlightedSliceID = id
            }
        }
    }
}
