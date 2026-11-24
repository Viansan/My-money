import SwiftUI
import SwiftData

/// 轻点持仓弹出的快捷调数抽屉
/// 支持「直接改总量」与「加减变动量（自动避免 iOS 数字键盘无负号痛点）」，并可一键更新单价或切换完整编辑
struct QuickAdjustHoldingSheet: View {
    private enum AdjustStyle: String, CaseIterable, Identifiable {
        case replaceTotal = "直接改总量"
        case deltaChange = "加减变动"
        var id: String { rawValue }
    }

    private enum DeltaDirection: String, CaseIterable, Identifiable {
        case add = "+ 增加"
        case subtract = "- 减少"
        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(PortfolioRefreshStore.self) private var refreshStore

    let holding: AssetHolding
    let onRequestFullEdit: () -> Void

    @State private var adjustStyle: AdjustStyle = .replaceTotal
    @State private var deltaDirection: DeltaDirection = .add

    @State private var primaryNumberText: String = ""
    @State private var deltaNumberText: String = ""
    @State private var unitPriceText: String = ""

    @State private var trackCost: Bool = false
    @State private var costEntryStyle: CostEntryStyle = .totalPrincipal
    @State private var costInputText: String = ""
    @State private var deltaPrincipalText: String = ""

    @State private var isFetchingQuote: Bool = false
    @State private var quoteErrorMessage: String?

    private enum Field: Hashable {
        case primaryNumber
        case deltaNumber
        case unitPrice
        case deltaPrincipal
        case costInput
    }

    @FocusState private var focusedField: Field?

    private var usesShares: Bool {
        holding.valuationMode.usesSharesAndPrice
    }

    private var previewSharesOrAmount: Double {
        switch adjustStyle {
        case .replaceTotal:
            return max(Formatters.parseDouble(primaryNumberText) ?? 0, 0)
        case .deltaChange:
            let base = usesShares ? holding.shares : holding.manualAmount
            let delta = max(Formatters.parseDouble(deltaNumberText) ?? 0, 0)
            let result = deltaDirection == .add ? (base + delta) : (base - delta)
            return max(result, 0)
        }
    }

    private var previewUnitPrice: Double {
        max(Formatters.parseDouble(unitPriceText) ?? holding.latestPrice, 0)
    }

    private var previewMarketValue: Double {
        if usesShares {
            return previewSharesOrAmount * previewUnitPrice
        } else {
            return previewSharesOrAmount
        }
    }

    private var previewTotalCost: Double? {
        guard trackCost else { return nil }
        if adjustStyle == .deltaChange, let deltaCost = Formatters.parseDouble(deltaPrincipalText), deltaCost > 0 {
            let baseCost = holding.totalCost ?? 0
            let updated = deltaDirection == .add ? (baseCost + deltaCost) : (baseCost - deltaCost)
            return max(updated, 0)
        }
        guard let raw = Formatters.parseDouble(costInputText), raw >= 0 else {
            return holding.totalCost
        }
        if usesShares && costEntryStyle == .unitCostPrice {
            return previewSharesOrAmount * raw
        }
        return raw
    }

    var body: some View {
        NavigationStack {
            Form {
                // 实时估值预览头
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(holding.name)
                                .font(.headline)
                            HStack(spacing: 6) {
                                if let catName = holding.category?.name {
                                    Text(catName)
                                }
                                if let accName = holding.account?.name {
                                    Text("· \(accName)")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 4) {
                            Text(Formatters.currency(previewMarketValue))
                                .font(.system(.title3, design: .rounded, weight: .bold))
                                .monospacedDigit()

                            if let cost = previewTotalCost {
                                let pnl = previewMarketValue - cost
                                Text("盈亏 \(Formatters.signedCurrency(pnl))")
                                    .font(.caption.weight(.medium))
                                    .monospacedDigit()
                                    .foregroundStyle(refreshStore.pnlColorScheme.color(for: pnl))
                            }
                        }
                    }
                }

                // 核心数量 / 金额调整
                Section {
                    Picker("修改方式", selection: $adjustStyle) {
                        ForEach(AdjustStyle.allCases) { style in
                            Text(style.rawValue).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)

                    if adjustStyle == .replaceTotal {
                        HStack {
                            Text(usesShares ? "最新持有份额" : "最新总金额（元）")
                            Spacer()
                            TextField("0", text: $primaryNumberText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                                .focused($focusedField, equals: .primaryNumber)
                        }
                    } else {
                        Picker("变动方向", selection: $deltaDirection) {
                            ForEach(DeltaDirection.allCases) { dir in
                                Text(dir.rawValue).tag(dir)
                            }
                        }
                        .pickerStyle(.segmented)

                        HStack {
                            Text(usesShares ? "本次变动份额" : "本次变动金额")
                            Spacer()
                            TextField(usesShares ? "输入变动份数" : "输入变动金额", text: $deltaNumberText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                                .focused($focusedField, equals: .deltaNumber)
                        }

                        HStack {
                            Text(usesShares ? "调整后总份额" : "调整后总金额")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(usesShares ? Formatters.shares(previewSharesOrAmount) : Formatters.currency(previewSharesOrAmount))
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                        }
                    }

                    if usesShares {
                        HStack(spacing: 10) {
                            Text("最新单价/净值")
                            Spacer()
                            TextField("单价", text: $unitPriceText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                                .focused($focusedField, equals: .unitPrice)

                            if holding.supportsQuoteRefresh {
                                Button {
                                    Task { await fetchLatestQuote() }
                                } label: {
                                    if isFetchingQuote {
                                        ProgressView()
                                    } else {
                                        Label("拉现价", systemImage: "arrow.clockwise")
                                            .labelStyle(.titleAndIcon)
                                            .font(.caption.weight(.semibold))
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(isFetchingQuote)
                            }
                        }

                        if let quoteErrorMessage {
                            Text(quoteErrorMessage)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                } header: {
                    Text(usesShares ? "份额与单价" : "当前金额")
                }

                // 选填成本调整
                Section {
                    Toggle("记录投入成本（计算盈亏）", isOn: $trackCost)

                    if trackCost {
                        if adjustStyle == .deltaChange {
                            HStack {
                                Text("同步\(deltaDirection == .add ? "增加" : "减少")本金（选填）")
                                Spacer()
                                TextField("不填则保持原成本", text: $deltaPrincipalText)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .monospacedDigit()
                                    .focused($focusedField, equals: .deltaPrincipal)
                            }
                        } else {
                            if usesShares {
                                Picker("成本口径", selection: $costEntryStyle) {
                                    ForEach(CostEntryStyle.allCases) { item in
                                        Text(item.title).tag(item)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .onChange(of: costEntryStyle) { _, newStyle in
                                    syncCostInputField(for: newStyle)
                                }
                            }

                            HStack {
                                Text(usesShares && costEntryStyle == .unitCostPrice ? "持仓成本单价" : "累计投入本金（元）")
                                Spacer()
                                TextField("0", text: $costInputText)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .monospacedDigit()
                                    .focused($focusedField, equals: .costInput)
                            }
                        }
                    }
                } header: {
                    Text("成本与盈亏（选填）")
                }

                Section {
                    Button {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            onRequestFullEdit()
                        }
                    } label: {
                        Label("打开完整编辑（修改名称、分类、账户或备注）", systemImage: "slider.horizontal.3")
                            .font(.subheadline)
                    }
                }
            }
            .navigationTitle("快速调整")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        saveChanges()
                    }
                    .fontWeight(.semibold)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { focusedField = nil }
                }
            }
            .onAppear(perform: populateInitialValues)
        }
        .presentationDetents([.medium, .large])
    }

    private func populateInitialValues() {
        if usesShares {
            primaryNumberText = Formatters.editableDecimal(holding.shares, maxDecimals: 2)
            unitPriceText = Formatters.editableDecimal(holding.latestPrice, maxDecimals: 4)
        } else {
            primaryNumberText = Formatters.editableDecimal(holding.manualAmount, maxDecimals: 2)
        }

        if let cost = holding.totalCost {
            trackCost = true
            costEntryStyle = .totalPrincipal
            costInputText = Formatters.editableDecimal(cost, maxDecimals: 2)
        } else {
            trackCost = false
            costInputText = ""
        }
    }

    private func syncCostInputField(for style: CostEntryStyle) {
        guard let currentVal = Formatters.parseDouble(costInputText) else { return }
        let shares = max(previewSharesOrAmount, 0)
        guard shares > 0 else { return }

        switch style {
        case .unitCostPrice:
            // 从总本金转为成本单价
            costInputText = Formatters.editableDecimal(currentVal / shares, maxDecimals: 4)
        case .totalPrincipal:
            // 从成本单价转为总本金
            costInputText = Formatters.editableDecimal(currentVal * shares, maxDecimals: 2)
        }
    }

    private func fetchLatestQuote() async {
        isFetchingQuote = true
        quoteErrorMessage = nil
        defer { isFetchingQuote = false }

        do {
            let quote = try await refreshStore.lookupSingleQuote(code: holding.code, mode: holding.valuationMode)
            unitPriceText = Formatters.editableDecimal(quote.price, maxDecimals: 4)
            holding.priceDateText = quote.dateText
        } catch {
            quoteErrorMessage = error.localizedDescription
        }
    }

    private func saveChanges() {
        if usesShares {
            holding.shares = previewSharesOrAmount
            holding.latestPrice = previewUnitPrice
        } else {
            holding.manualAmount = previewSharesOrAmount
        }
        holding.totalCost = previewTotalCost
        holding.lastUpdated = .now

        try? modelContext.save()
        dismiss()
    }
}
