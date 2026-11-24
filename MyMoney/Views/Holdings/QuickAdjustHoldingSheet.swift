import SwiftUI
import SwiftData

/// 轻点持仓弹出的快捷调数抽屉
/// - 实时预览「原值 -> 新值（变化量）」，防止多打一个零
/// - 支持一键快捷步进胶囊与现价本金估算，常用调数 2 秒搞定
/// - 未改内容随手下拉即关，改过内容防误滑丢失
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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

    private var parsedDeltaNumber: Double {
        max(Formatters.parseDouble(deltaNumberText) ?? 0, 0)
    }

    private var previewSharesOrAmount: Double {
        switch adjustStyle {
        case .replaceTotal:
            return max(Formatters.parseDouble(primaryNumberText) ?? 0, 0)
        case .deltaChange:
            let base = usesShares ? holding.shares : holding.manualAmount
            let result = deltaDirection == .add ? (base + parsedDeltaNumber) : (base - parsedDeltaNumber)
            return max(result, 0)
        }
    }

    private var previewUnitPrice: Double {
        max(Formatters.parseDouble(unitPriceText) ?? holding.latestPrice, 0)
    }

    private var previewMarketValue: Double {
        usesShares ? (previewSharesOrAmount * previewUnitPrice) : previewSharesOrAmount
    }

    private var valueChangeDelta: Double {
        previewMarketValue - holding.marketValue
    }

    private var previewTotalCost: Double? {
        guard trackCost else { return nil }
        if adjustStyle == .deltaChange {
            if let deltaCost = Formatters.parseDouble(deltaPrincipalText), deltaCost > 0 {
                let baseCost = holding.totalCost ?? 0
                let updated = deltaDirection == .add ? (baseCost + deltaCost) : (baseCost - deltaCost)
                return max(updated, 0)
            }
            return holding.totalCost
        }
        guard let raw = Formatters.parseDouble(costInputText), raw >= 0 else {
            return holding.totalCost
        }
        if usesShares && costEntryStyle == .unitCostPrice {
            return previewSharesOrAmount * raw
        }
        return raw
    }

    private var hasChanges: Bool {
        let baseQuantity = usesShares ? holding.shares : holding.manualAmount
        if abs(previewSharesOrAmount - baseQuantity) > 0.0001 { return true }
        if usesShares && abs(previewUnitPrice - holding.latestPrice) > 0.00001 { return true }
        switch (holding.totalCost, previewTotalCost) {
        case (nil, nil):
            return false
        case (let old?, let new?):
            return abs(old - new) > 0.01
        default:
            return true
        }
    }

    private var isFixedAsset: Bool {
        holding.effectivePool == .fixed
    }

    private var hasFixedDepositMeta: Bool {
        isFixedAsset && (holding.annualRate != nil || holding.maturityDate != nil)
    }

    private var previewDepositInterestText: String? {
        guard isFixedAsset, let rate = holding.annualRate, rate > 0, previewMarketValue > 0 else {
            return nil
        }
        let annual = previewMarketValue * (rate / 100.0)
        if let start = holding.startDate, let mat = holding.maturityDate, mat > start {
            let cal = Calendar.current
            let days = cal.dateComponents([.day], from: cal.startOfDay(for: start), to: cal.startOfDay(for: mat)).day ?? 0
            if days > 0 {
                let total = annual * (Double(days) / 365.0)
                return "预计到期息 +\(Formatters.wholeCurrency(total))"
            }
        }
        return "预计年息 \(Formatters.wholeCurrency(annual))"
    }

    private var quickStepPresets: [(label: String, amount: Double)] {
        if usesShares {
            return [("100份", 100), ("500份", 500), ("1000份", 1000)]
        } else if isFixedAsset {
            return [("1万", 10_000), ("5万", 50_000), ("10万", 100_000)]
        } else {
            return [("1千", 1000), ("5千", 5000), ("1万", 10000)]
        }
    }

    private var estimatedDeltaPrincipal: Double? {
        guard adjustStyle == .deltaChange, usesShares, parsedDeltaNumber > 0, previewUnitPrice > 0 else {
            return nil
        }
        return parsedDeltaNumber * previewUnitPrice
    }

    var body: some View {
        NavigationStack {
            Form {
                // 实时估值与变化量预览
                Section {
                    HStack(alignment: .center) {
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

                            if hasFixedDepositMeta {
                                HStack(spacing: 4) {
                                    if let rate = holding.annualRate, rate > 0 {
                                        Text("年化 \(Formatters.annualRate(rate))")
                                    }
                                    if let mat = holding.maturityDate {
                                        Text("\(holding.annualRate != nil ? "· " : "")\(Formatters.dateYMD(mat)) 到期")
                                    }
                                }
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(holding.isMaturitySoonOrPast ? Color.orange : Color.secondary)
                            }
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 4) {
                            Text(Formatters.currency(previewMarketValue))
                                .font(.system(.title3, design: .rounded, weight: .bold))
                                .monospacedDigit()
                                .contentTransition(.numericText(value: previewMarketValue))
                                .animation(Motion.numeric(reduceMotion: reduceMotion), value: previewMarketValue)

                            if abs(valueChangeDelta) >= 0.01 {
                                Text("变动 \(Formatters.signedCurrency(valueChangeDelta))")
                                    .font(.caption.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(Color.accentColor)
                                    .contentTransition(.numericText(value: valueChangeDelta))
                                    .transition(.opacity)
                            } else if let interestText = previewDepositInterestText {
                                Text(interestText)
                                    .font(.caption.weight(.medium))
                                    .monospacedDigit()
                                    .foregroundStyle(CategoryColorToken.amber.color)
                                    .transition(.opacity)
                            } else if let cost = previewTotalCost {
                                let pnl = previewMarketValue - cost
                                Text("盈亏 \(Formatters.signedCurrency(pnl))")
                                    .font(.caption.weight(.medium))
                                    .monospacedDigit()
                                    .foregroundStyle(refreshStore.pnlColorScheme.color(for: pnl))
                                    .contentTransition(.numericText(value: pnl))
                                    .transition(.opacity)
                            }
                        }
                        .animation(Motion.micro(reduceMotion: reduceMotion), value: abs(valueChangeDelta) >= 0.01)
                    }
                }

                // 核心数量 / 金额调整
                Section {
                    Picker("修改方式", selection: $adjustStyle.animation(Motion.standard(reduceMotion: reduceMotion))) {
                        ForEach(AdjustStyle.allCases) { style in
                            Text(style.rawValue).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: adjustStyle) { _, _ in
                        Haptics.selection()
                    }

                    if adjustStyle == .replaceTotal {
                        HStack {
                            Text(usesShares ? "最新持有份额" : (isFixedAsset ? "最新本金 / 金额（元）" : "最新总金额（元）"))
                            Spacer()
                            TextField("0", text: $primaryNumberText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                                .focused($focusedField, equals: .primaryNumber)
                        }
                    } else {
                        Picker("变动方向", selection: $deltaDirection.animation(Motion.micro(reduceMotion: reduceMotion))) {
                            ForEach(DeltaDirection.allCases) { dir in
                                Text(dir.rawValue).tag(dir)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: deltaDirection) { _, _ in
                            Haptics.selection()
                        }

                        HStack {
                            Text(usesShares ? "本次变动份额" : "本次变动金额")
                            Spacer()
                            TextField(usesShares ? "输入份数" : "输入金额", text: $deltaNumberText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                                .focused($focusedField, equals: .deltaNumber)
                        }

                        // 一键步进胶囊（常用加仓/入账直接点）
                        HStack(spacing: 8) {
                            ForEach(quickStepPresets, id: \.label) { preset in
                                Button {
                                    Haptics.selection()
                                    let current = parsedDeltaNumber
                                    withAnimation(Motion.numeric(reduceMotion: reduceMotion)) {
                                        deltaNumberText = Formatters.editableDecimal(current + preset.amount, maxDecimals: 2)
                                    }
                                } label: {
                                    Text("\(deltaDirection == .add ? "+" : "-")\(preset.label)")
                                        .font(.caption.weight(.medium))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Color(.tertiarySystemFill), in: Capsule())
                                }
                                .buttonStyle(TactilePressButtonStyle(pressedScale: 0.93))
                            }

                            Spacer()

                            if parsedDeltaNumber > 0 {
                                Button("清零") {
                                    Haptics.selection()
                                    withAnimation(Motion.micro(reduceMotion: reduceMotion)) {
                                        deltaNumberText = ""
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .buttonStyle(TactilePressButtonStyle(pressedScale: 0.92))
                                .transition(.opacity)
                            }
                        }
                        .animation(Motion.micro(reduceMotion: reduceMotion), value: parsedDeltaNumber > 0)

                        HStack {
                            Text(usesShares ? "调整后总份额" : "调整后总金额")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(usesShares ? Formatters.shares(previewSharesOrAmount) : Formatters.currency(previewSharesOrAmount))
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                                .contentTransition(.numericText(value: previewSharesOrAmount))
                                .animation(Motion.numeric(reduceMotion: reduceMotion), value: previewSharesOrAmount)
                        }
                    }

                    if usesShares {
                        HStack(spacing: 10) {
                            Text(holding.valuationMode.priceFieldLabel)
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
                                    ZStack {
                                        if isFetchingQuote {
                                            ProgressView()
                                                .controlSize(.small)
                                                .transition(.opacity)
                                        } else {
                                            Label("拉现价", systemImage: "arrow.clockwise")
                                                .labelStyle(.titleAndIcon)
                                                .font(.caption.weight(.semibold))
                                                .transition(.opacity)
                                        }
                                    }
                                    .frame(minWidth: 62, minHeight: 18)
                                    .animation(Motion.micro(reduceMotion: reduceMotion), value: isFetchingQuote)
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
                                .transition(.opacity)
                        }
                    }
                } header: {
                    Text(usesShares ? "份额与单价" : (isFixedAsset ? "本金 / 当前金额" : "当前金额"))
                }

                // 选填成本调整（固定资产若未记录成本则不打扰）
                if !isFixedAsset || holding.totalCost != nil {
                    Section {
                        Toggle("记录投入成本（算盈亏）", isOn: $trackCost.animation(Motion.standard(reduceMotion: reduceMotion)))

                        if trackCost {
                            if adjustStyle == .deltaChange {
                                HStack {
                                    Text("同步\(deltaDirection == .add ? "增加" : "减少")本金")
                                    Spacer()
                                    TextField("不填保持原成本", text: $deltaPrincipalText)
                                        .keyboardType(.decimalPad)
                                        .multilineTextAlignment(.trailing)
                                        .monospacedDigit()
                                        .focused($focusedField, equals: .deltaPrincipal)
                                }

                                if let est = estimatedDeltaPrincipal {
                                    Button {
                                        Haptics.selection()
                                        deltaPrincipalText = Formatters.editableDecimal(est, maxDecimals: 2)
                                    } label: {
                                        Label("按当前单价自动填入 \(Formatters.currency(est))", systemImage: "wand.and.stars")
                                            .font(.caption.weight(.medium))
                                    }
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
                                        Haptics.selection()
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
                }

                Section {
                    Button {
                        Haptics.lightImpact()
                        onRequestFullEdit()
                        dismiss()
                    } label: {
                        Label(
                            isFixedAsset ? "修改利率、到期日、名称或备注..." : "修改名称、分类、账户或备注...",
                            systemImage: "slider.horizontal.3"
                        )
                        .font(.subheadline)
                    }
                }
            }
            .navigationTitle("快速调数")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(hasChanges)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        saveChanges()
                    }
                    .fontWeight(.semibold)
                    .disabled(!hasChanges)
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
            costInputText = Formatters.editableDecimal(currentVal / shares, maxDecimals: 4)
        case .totalPrincipal:
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
            Haptics.success()
        } catch {
            Haptics.warning()
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
        Haptics.success()
        refreshStore.showToast(style: .success, message: "已更新「\(holding.name)」", autoDismissSeconds: 2.0)
        dismiss()
    }
}
