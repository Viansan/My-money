import SwiftUI
import SwiftData

/// 新增或完整编辑单条资产表单页
/// - 简化为「按金额」与「证券 / 基金」两档，系统自动识别场内现价或场外净值
/// - 输入代码停顿 0.45 秒自动识别名称与价格，无需用户先选市场再点按钮
/// - 仅在极少数重码（如 000001 或 LOF）时弹出双候选轻点切换
struct HoldingFormSheet: View {
    private enum EntryKind: String, CaseIterable, Identifiable {
        case manualAmount = "按金额"
        case quoteTracked = "证券 / 基金"
        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(PortfolioRefreshStore.self) private var refreshStore

    @Query(sort: \AssetCategory.sortOrder) private var categories: [AssetCategory]
    @Query(sort: \AssetAccount.sortOrder) private var accounts: [AssetAccount]
    @Query(sort: \AssetHolding.sortOrder) private var allHoldings: [AssetHolding]

    let existingHolding: AssetHolding?
    var preselectedCategory: AssetCategory? = nil
    var preselectedAccount: AssetAccount? = nil
    var preselectedPool: AssetPool = .investable

    @State private var entryKind: EntryKind = .manualAmount
    /// 系统自动识别出的真实底层模式（.exchangeSecurity 或 .otcFund）
    @State private var resolvedQuoteMode: ValuationMode = .exchangeSecurity

    @State private var code: String = ""
    @State private var name: String = ""
    @State private var userEditedName: Bool = false
    @State private var sharesText: String = ""
    @State private var latestPriceText: String = "1"
    @State private var manualAmountText: String = ""
    @State private var priceDateText: String = ""

    @State private var selectedCategoryID: UUID?
    @State private var selectedAccountID: UUID?

    @State private var trackCost: Bool = false
    @State private var costEntryStyle: CostEntryStyle = .totalPrincipal
    @State private var costInputText: String = ""
    @State private var note: String = ""

    @State private var isLookingUpQuote: Bool = false
    @State private var lookupCandidates: [QuoteResult] = []
    @State private var lookupStatusText: String?
    @State private var lookupIsError: Bool = false
    @State private var debounceLookupTask: Task<Void, Never>?
    @State private var lastResolvedCode: String = ""
    @State private var hasLoadedInitial: Bool = false

    @State private var showingNewCategorySheet = false
    @State private var showingNewAccountSheet = false
    @State private var showingDeleteConfirm = false

    private enum Field: Hashable {
        case code
        case name
        case shares
        case latestPrice
        case manualAmount
        case costInput
        case note
    }

    @FocusState private var focusedField: Field?

    private var isEditing: Bool { existingHolding != nil }

    private var effectiveValuationMode: ValuationMode {
        entryKind == .manualAmount ? .manualAmount : resolvedQuoteMode
    }

    private var parsedShares: Double {
        max(Formatters.parseDouble(sharesText) ?? 0, 0)
    }

    private var parsedPrice: Double {
        max(Formatters.parseDouble(latestPriceText) ?? 0, 0)
    }

    private var parsedManualAmount: Double {
        max(Formatters.parseDouble(manualAmountText) ?? 0, 0)
    }

    private var previewMarketValue: Double {
        entryKind == .quoteTracked ? (parsedShares * parsedPrice) : parsedManualAmount
    }

    private var computedTotalCost: Double? {
        guard trackCost, let val = Formatters.parseDouble(costInputText), val >= 0 else {
            return nil
        }
        if entryKind == .quoteTracked && costEntryStyle == .unitCostPrice {
            return parsedShares * val
        }
        return val
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasUnsavedChanges: Bool {
        if let item = existingHolding {
            return item.name != name.trimmingCharacters(in: .whitespacesAndNewlines)
                || item.valuationMode != effectiveValuationMode
                || item.code != (entryKind == .quoteTracked ? code.trimmingCharacters(in: .whitespacesAndNewlines) : "")
                || abs(item.shares - (entryKind == .quoteTracked ? parsedShares : 0)) > 0.001
                || abs(item.manualAmount - (entryKind == .manualAmount ? parsedManualAmount : 0)) > 0.01
                || item.category?.id != selectedCategoryID
                || item.account?.id != selectedAccountID
                || item.note != note.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return !name.isEmpty || !code.isEmpty || !sharesText.isEmpty || !manualAmountText.isEmpty || !note.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                // 1. 计价方式与智能代码识别
                Section {
                    Picker("记录方式", selection: $entryKind.animation(Motion.standard(reduceMotion: reduceMotion))) {
                        ForEach(EntryKind.allCases) { kind in
                            Text(kind.rawValue).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: entryKind) { _, _ in
                        Haptics.selection()
                    }

                    if entryKind == .quoteTracked {
                        HStack(spacing: 8) {
                            TextField("输入代码自动识别（515800、050025、SPY）", text: $code)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                                .focused($focusedField, equals: .code)
                                .onChange(of: code) { _, newValue in
                                    scheduleAutoLookupIfAppropriate(for: newValue)
                                }

                            ZStack {
                                if isLookingUpQuote {
                                    ProgressView()
                                        .controlSize(.small)
                                        .transition(.opacity)
                                } else if !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Button {
                                        Task { await performSmartLookup(rawCode: code, force: true) }
                                    } label: {
                                        Image(systemName: "arrow.clockwise.circle.fill")
                                            .font(.title3)
                                            .foregroundStyle(Color.accentColor)
                                    }
                                    .buttonStyle(TactilePressButtonStyle(pressedScale: 0.90))
                                    .accessibilityLabel("重新识别行情")
                                    .transition(.opacity)
                                }
                            }
                            .frame(width: 24, height: 24)
                            .animation(Motion.micro(reduceMotion: reduceMotion), value: isLookingUpQuote)
                        }

                        // 仅在极少数真实重码（如 000001 / LOF）时显示 1 键切换候选
                        if lookupCandidates.count > 1 {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("检测到同名场内与场外标的，点选你实际持有的渠道：")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                ForEach(lookupCandidates) { candidate in
                                    let isSelected = (candidate.mode == resolvedQuoteMode)
                                    Button {
                                        Haptics.selection()
                                        withAnimation(Motion.micro(reduceMotion: reduceMotion)) {
                                            applyCandidate(candidate, overwriteName: true)
                                        }
                                    } label: {
                                        HStack {
                                            Text(candidate.mode.title)
                                                .font(.caption2.weight(.semibold))
                                                .foregroundStyle(isSelected ? .white : Color.accentColor)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(
                                                    isSelected ? Color.accentColor : Color.accentColor.opacity(0.14),
                                                    in: RoundedRectangle(cornerRadius: 4)
                                                )
                                            Text(candidate.name)
                                                .font(.caption.weight(.medium))
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                            Spacer()
                                            Text("¥\(Formatters.unitPrice(candidate.price))")
                                                .font(.caption.weight(.semibold))
                                                .monospacedDigit()
                                                .foregroundStyle(.primary)
                                        }
                                        .padding(8)
                                        .background(
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .fill(isSelected ? Color.accentColor.opacity(0.1) : Color(.tertiarySystemFill))
                                        )
                                    }
                                    .buttonStyle(TactilePressButtonStyle(pressedScale: 0.985))
                                }
                            }
                            .padding(.vertical, 2)
                            .transition(.opacity)
                        } else if let lookupStatusText {
                            HStack(spacing: 6) {
                                Image(systemName: lookupIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(lookupIsError ? .orange : .green)
                                    .contentTransition(.symbolEffect(.replace))
                                Text(lookupStatusText)
                                    .font(.caption)
                                    .foregroundStyle(lookupIsError ? .orange : .secondary)
                            }
                            .transition(.opacity)
                        }
                    }

                    TextField(entryKind == .manualAmount ? "资产名称（必填，如：活期存款、三年期存单）" : "名称（输入代码后自动填充，也可自定）", text: $name)
                        .focused($focusedField, equals: .name)
                        .onChange(of: name) { _, newValue in
                            if focusedField == .name {
                                userEditedName = !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            }
                        }
                } header: {
                    Text("基本信息")
                }

                // 2. 当前价值
                Section {
                    if entryKind == .quoteTracked {
                        HStack {
                            Text("持有份额 / 股数")
                            Spacer()
                            TextField("0", text: $sharesText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                                .focused($focusedField, equals: .shares)
                        }

                        HStack {
                            Text(resolvedQuoteMode.priceFieldLabel)
                            Spacer()
                            TextField("1.0000", text: $latestPriceText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                                .focused($focusedField, equals: .latestPrice)
                        }

                        HStack {
                            Text("折算当前市值")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(Formatters.currency(previewMarketValue))
                                .font(.callout.weight(.semibold))
                                .monospacedDigit()
                                .contentTransition(.numericText(value: previewMarketValue))
                                .animation(Motion.numeric(reduceMotion: reduceMotion), value: previewMarketValue)
                        }
                    } else {
                        HStack {
                            Text("当前金额（元）")
                            Spacer()
                            TextField("0.00", text: $manualAmountText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                                .focused($focusedField, equals: .manualAmount)
                        }
                    }
                } header: {
                    Text("当前价值")
                }

                // 3. 归属分类与存放账户
                Section {
                    Picker("资产类别", selection: $selectedCategoryID) {
                        Text("未分类").tag(UUID?.none)
                        ForEach(categories) { cat in
                            Text("[\(cat.pool == .investable ? "投资" : "固定")] \(cat.name)")
                                .tag(Optional(cat.id))
                        }
                    }

                    Button {
                        showingNewCategorySheet = true
                    } label: {
                        Label("新建资产类别...", systemImage: "plus.circle")
                            .font(.footnote)
                    }

                    Picker("存放账户", selection: $selectedAccountID) {
                        Text("未指定账户").tag(UUID?.none)
                        ForEach(accounts) { acc in
                            Text(acc.name).tag(Optional(acc.id))
                        }
                    }

                    Button {
                        showingNewAccountSheet = true
                    } label: {
                        Label("新建存放账户...", systemImage: "plus.circle")
                            .font(.footnote)
                    }
                } header: {
                    Text("归属维度")
                } footer: {
                    if let selectedCat = categories.first(where: { $0.id == selectedCategoryID }) {
                        Text(selectedCat.pool == .fixed
                             ? "归属「固定资产」，计入总净值，不稀释投资占比。"
                             : "归属「投资资产」，计入投资组合结构占比。")
                    }
                }

                // 4. 选填成本与备注
                Section {
                    Toggle("记录成本（展示盈亏与收益率）", isOn: $trackCost.animation(Motion.standard(reduceMotion: reduceMotion)))

                    if trackCost {
                        if entryKind == .quoteTracked {
                            Picker("成本口径", selection: $costEntryStyle.animation(Motion.micro(reduceMotion: reduceMotion))) {
                                ForEach(CostEntryStyle.allCases) { style in
                                    Text(style.title).tag(style)
                                }
                            }
                            .pickerStyle(.segmented)
                            .onChange(of: costEntryStyle) { _, newStyle in
                                Haptics.selection()
                                convertCostStyle(to: newStyle)
                            }
                        }

                        HStack {
                            Text(entryKind == .quoteTracked && costEntryStyle == .unitCostPrice ? "持仓成本单价" : "累计投入本金（元）")
                            Spacer()
                            TextField("0.00", text: $costInputText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                                .focused($focusedField, equals: .costInput)
                        }

                        if let totalCost = computedTotalCost {
                            let pnl = previewMarketValue - totalCost
                            HStack {
                                Text("预计累计盈亏")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(Formatters.signedCurrency(pnl))
                                    .font(.subheadline.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(refreshStore.pnlColorScheme.color(for: pnl))
                                    .contentTransition(.numericText(value: pnl))
                                    .animation(Motion.numeric(reduceMotion: reduceMotion), value: pnl)
                            }
                        }
                    }

                    TextField("备注（选填，如定存到期日等）", text: $note)
                        .focused($focusedField, equals: .note)
                } header: {
                    Text("选填信息")
                }

                if isEditing {
                    Section {
                        Button(role: .destructive) {
                            Haptics.lightImpact()
                            showingDeleteConfirm = true
                        } label: {
                            HStack {
                                Spacer()
                                Text("删除该笔资产")
                                Spacer()
                            }
                        }
                    }
                }
            }
            .navigationTitle(isEditing ? "编辑资产" : "新增资产")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(hasUnsavedChanges)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { saveHolding() }
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { focusedField = nil }
                }
            }
            .onAppear(perform: loadInitialDataIfNeeded)
            .onDisappear {
                debounceLookupTask?.cancel()
            }
            .sheet(isPresented: $showingNewCategorySheet) {
                CategoryEditorSheet(existingCategory: nil, defaultPool: preselectedPool) { created in
                    selectedCategoryID = created.id
                }
            }
            .sheet(isPresented: $showingNewAccountSheet) {
                AccountEditorSheet(existingAccount: nil) { created in
                    selectedAccountID = created.id
                }
            }
            .confirmationDialog("确认删除「\(existingHolding?.name ?? "")」？", isPresented: $showingDeleteConfirm, titleVisibility: .visible) {
                Button("删除（5 秒内可撤销）", role: .destructive) {
                    if let existingHolding {
                        refreshStore.deleteHoldingWithUndo(existingHolding, in: modelContext)
                    }
                    dismiss()
                }
                Button("取消", role: .cancel) {}
            }
        }
    }

    // MARK: - 初始化与自动识别逻辑

    private func loadInitialDataIfNeeded() {
        guard !hasLoadedInitial else { return }
        hasLoadedInitial = true

        if let item = existingHolding {
            entryKind = item.valuationMode.usesSharesAndPrice ? .quoteTracked : .manualAmount
            resolvedQuoteMode = item.valuationMode.usesSharesAndPrice ? item.valuationMode : .exchangeSecurity
            code = item.code
            lastResolvedCode = item.code
            name = item.name
            userEditedName = !item.name.isEmpty
            sharesText = item.shares > 0 ? Formatters.editableDecimal(item.shares, maxDecimals: 2) : ""
            latestPriceText = Formatters.editableDecimal(item.latestPrice, maxDecimals: 4)
            manualAmountText = item.manualAmount > 0 ? Formatters.editableDecimal(item.manualAmount, maxDecimals: 2) : ""
            priceDateText = item.priceDateText
            selectedCategoryID = item.category?.id
            selectedAccountID = item.account?.id
            note = item.note

            if let cost = item.totalCost {
                trackCost = true
                costEntryStyle = .totalPrincipal
                costInputText = Formatters.editableDecimal(cost, maxDecimals: 2)
            }
        } else {
            if let preCat = preselectedCategory {
                selectedCategoryID = preCat.id
            } else if let poolMatch = categories.first(where: { $0.pool == preselectedPool }) {
                selectedCategoryID = poolMatch.id
            } else {
                selectedCategoryID = categories.first?.id
            }
            selectedAccountID = (preselectedAccount ?? accounts.first)?.id
        }
    }

    /// 输入代码停顿 0.45 秒自动识别（仅在形态完整时触发，不打扰用户输入过程）
    private func scheduleAutoLookupIfAppropriate(for raw: String) {
        debounceLookupTask?.cancel()
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            lookupCandidates = []
            lookupStatusText = nil
            return
        }
        guard cleaned != lastResolvedCode else { return }

        let isCompletePattern: Bool = {
            if cleaned.allSatisfy({ $0.isNumber }) {
                return cleaned.count == 5 || cleaned.count == 6
            }
            if cleaned.allSatisfy({ $0.isLetter }) {
                return cleaned.count >= 2 && cleaned.count <= 5
            }
            let lower = cleaned.lowercased()
            if lower.hasPrefix("sh") || lower.hasPrefix("sz") || lower.hasPrefix("bj") || lower.hasPrefix("jj") {
                return cleaned.count == 8
            }
            if lower.hasPrefix("hk") {
                return cleaned.count == 7
            }
            if lower.hasPrefix("us") {
                return cleaned.count >= 4
            }
            return false
        }()

        guard isCompletePattern else { return }

        debounceLookupTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            await performSmartLookup(rawCode: cleaned, force: false)
        }
    }

    private func performSmartLookup(rawCode: String, force: Bool) async {
        let cleaned = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        if !force && cleaned == lastResolvedCode { return }

        isLookingUpQuote = true
        lookupStatusText = nil
        lookupIsError = false
        defer { isLookingUpQuote = false }

        do {
            let candidates = try await refreshStore.lookupSmartCandidates(code: cleaned)
            guard !Task.isCancelled else { return }
            lastResolvedCode = cleaned
            withAnimation(Motion.standard(reduceMotion: reduceMotion)) {
                lookupCandidates = candidates
                if let primary = candidates.first {
                    applyCandidate(primary, overwriteName: !userEditedName || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if !candidates.isEmpty {
                Haptics.success()
            }
        } catch {
            guard !Task.isCancelled else { return }
            withAnimation(Motion.standard(reduceMotion: reduceMotion)) {
                lookupCandidates = []
                lookupStatusText = error.localizedDescription
                lookupIsError = true
            }
            Haptics.warning()
        }
    }

    private func applyCandidate(_ candidate: QuoteResult, overwriteName: Bool) {
        resolvedQuoteMode = candidate.mode
        if overwriteName {
            name = candidate.name
            userEditedName = false
        }
        latestPriceText = Formatters.editableDecimal(candidate.price, maxDecimals: 4)
        priceDateText = candidate.dateText

        let dateSuffix = candidate.dateText.isEmpty ? "" : " · \(candidate.dateText)"
        lookupStatusText = "已自动识别为\(candidate.mode.title)：¥\(Formatters.unitPrice(candidate.price))\(dateSuffix)"
        lookupIsError = false
    }

    private func convertCostStyle(to newStyle: CostEntryStyle) {
        guard let val = Formatters.parseDouble(costInputText), parsedShares > 0 else { return }
        switch newStyle {
        case .unitCostPrice:
            costInputText = Formatters.editableDecimal(val / parsedShares, maxDecimals: 4)
        case .totalPrincipal:
            costInputText = Formatters.editableDecimal(val * parsedShares, maxDecimals: 2)
        }
    }

    private func saveHolding() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        let chosenCategory = categories.first(where: { $0.id == selectedCategoryID })
        let chosenAccount = accounts.first(where: { $0.id == selectedAccountID })
        let cleanedCode = entryKind == .quoteTracked ? code.trimmingCharacters(in: .whitespacesAndNewlines) : ""

        if let target = existingHolding {
            target.name = trimmedName
            target.valuationMode = effectiveValuationMode
            target.code = cleanedCode
            target.shares = entryKind == .quoteTracked ? parsedShares : 0
            target.latestPrice = entryKind == .quoteTracked ? parsedPrice : 1.0
            target.manualAmount = entryKind == .manualAmount ? parsedManualAmount : 0
            target.totalCost = computedTotalCost
            target.priceDateText = entryKind == .quoteTracked ? priceDateText : ""
            target.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
            target.assignCategory(chosenCategory)
            target.account = chosenAccount
            target.lastUpdated = .now
        } else {
            let nextOrder = (allHoldings.map(\.sortOrder).max() ?? -1) + 1
            let created = AssetHolding(
                name: trimmedName,
                valuationMode: effectiveValuationMode,
                code: cleanedCode,
                shares: entryKind == .quoteTracked ? parsedShares : 0,
                latestPrice: entryKind == .quoteTracked ? parsedPrice : 1.0,
                manualAmount: entryKind == .manualAmount ? parsedManualAmount : 0,
                totalCost: computedTotalCost,
                priceDateText: entryKind == .quoteTracked ? priceDateText : "",
                lastUpdated: .now,
                note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                sortOrder: nextOrder,
                fallbackPool: chosenCategory?.pool ?? preselectedPool,
                category: chosenCategory,
                account: chosenAccount
            )
            modelContext.insert(created)
        }

        try? modelContext.save()
        Haptics.success()
        refreshStore.showToast(
            style: .success,
            message: isEditing ? "已保存「\(trimmedName)」" : "已新增「\(trimmedName)」",
            autoDismissSeconds: 2.0
        )
        dismiss()
    }
}
