import SwiftUI
import SwiftData

/// 新增或完整编辑单条资产表单页
/// 支持代码自动识别名称与单价、页内直接新建分类/账户、选填成本等完整 CRUD 能力
struct HoldingFormSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(PortfolioRefreshStore.self) private var refreshStore

    @Query(sort: \AssetCategory.sortOrder) private var categories: [AssetCategory]
    @Query(sort: \AssetAccount.sortOrder) private var accounts: [AssetAccount]
    @Query(sort: \AssetHolding.sortOrder) private var allHoldings: [AssetHolding]

    let existingHolding: AssetHolding?
    var preselectedCategory: AssetCategory? = nil
    var preselectedAccount: AssetAccount? = nil

    @State private var valuationMode: ValuationMode = .manualAmount
    @State private var code: String = ""
    @State private var name: String = ""
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
    @State private var lookupFeedback: String?
    @State private var lookupIsError: Bool = false

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
        valuationMode.usesSharesAndPrice ? (parsedShares * parsedPrice) : parsedManualAmount
    }

    private var computedTotalCost: Double? {
        guard trackCost, let val = Formatters.parseDouble(costInputText), val >= 0 else {
            return nil
        }
        if valuationMode.usesSharesAndPrice && costEntryStyle == .unitCostPrice {
            return parsedShares * val
        }
        return val
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                // 1. 计价模式与行情自动识别
                Section {
                    Picker("计价方式", selection: $valuationMode) {
                        ForEach(ValuationMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    if valuationMode.usesSharesAndPrice {
                        HStack(spacing: 8) {
                            TextField(valuationMode.codePlaceholder, text: $code)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                                .focused($focusedField, equals: .code)

                            Button {
                                Task { await lookupQuoteAndFill() }
                            } label: {
                                if isLookingUpQuote {
                                    ProgressView()
                                } else {
                                    Text("自动识别")
                                        .font(.caption.weight(.semibold))
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLookingUpQuote)
                        }

                        if let lookupFeedback {
                            Text(lookupFeedback)
                                .font(.caption)
                                .foregroundStyle(lookupIsError ? .orange : .secondary)
                        }
                    }

                    TextField("资产名称（如：中证800ETF、三年期存单）", text: $name)
                        .focused($focusedField, equals: .name)
                } header: {
                    Text("基本信息")
                }

                // 2. 金额或份额明细
                Section {
                    if valuationMode.usesSharesAndPrice {
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
                            Text(valuationMode == .otcFund ? "最新单位净值" : "最新单价（元）")
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

                // 3. 归属分类与存放账户（支持不跳出页面直接新建）
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
                    Text("分类与账户归属")
                } footer: {
                    if let selectedCat = categories.first(where: { $0.id == selectedCategoryID }) {
                        Text(selectedCat.pool == .fixed
                             ? "当前所选类别归属「固定/底仓」，计入全部总净值，不会稀释日常投资组合的配置占比。"
                             : "当前所选类别归属「投资资产」，参与投资组合结构占比计算。")
                    }
                }

                // 4. 选填成本与备注
                Section {
                    Toggle("记录成本以展示盈亏（选填）", isOn: $trackCost)

                    if trackCost {
                        if valuationMode.usesSharesAndPrice {
                            Picker("成本录入方式", selection: $costEntryStyle) {
                                ForEach(CostEntryStyle.allCases) { style in
                                    Text(style.title).tag(style)
                                }
                            }
                            .pickerStyle(.segmented)
                            .onChange(of: costEntryStyle) { _, newStyle in
                                convertCostStyle(to: newStyle)
                            }
                        }

                        HStack {
                            Text(valuationMode.usesSharesAndPrice && costEntryStyle == .unitCostPrice ? "持仓成本单价" : "累计投入本金（元）")
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
                            }
                        }
                    }

                    TextField("备注（选填，如定存到期日、限购说明等）", text: $note)
                        .focused($focusedField, equals: .note)
                } header: {
                    Text("选填信息")
                }

                if isEditing {
                    Section {
                        Button(role: .destructive) {
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
            .onAppear(perform: loadInitialData)
            .sheet(isPresented: $showingNewCategorySheet) {
                CategoryEditorSheet(existingCategory: nil) { created in
                    selectedCategoryID = created.id
                }
            }
            .sheet(isPresented: $showingNewAccountSheet) {
                AccountEditorSheet(existingAccount: nil) { created in
                    selectedAccountID = created.id
                }
            }
            .confirmationDialog("确认删除该笔资产？", isPresented: $showingDeleteConfirm, titleVisibility: .visible) {
                Button("删除资产", role: .destructive) {
                    if let existingHolding {
                        modelContext.delete(existingHolding)
                        try? modelContext.save()
                    }
                    dismiss()
                }
                Button("取消", role: .cancel) {}
            }
        }
    }

    private func loadInitialData() {
        if let item = existingHolding {
            valuationMode = item.valuationMode
            code = item.code
            name = item.name
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
            selectedCategoryID = (preselectedCategory ?? categories.first)?.id
            selectedAccountID = (preselectedAccount ?? accounts.first)?.id
        }
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

    private func lookupQuoteAndFill() async {
        isLookingUpQuote = true
        lookupFeedback = nil
        lookupIsError = false
        defer { isLookingUpQuote = false }

        do {
            let quote = try await refreshStore.lookupSingleQuote(code: code, mode: valuationMode)
            name = quote.name
            latestPriceText = Formatters.editableDecimal(quote.price, maxDecimals: 4)
            priceDateText = quote.dateText
            let dateInfo = quote.dateText.isEmpty ? "" : "（\(quote.dateText)）"
            lookupFeedback = "已获取：\(quote.name)，单价 \(Formatters.unitPrice(quote.price))\(dateInfo)"
            lookupIsError = false
        } catch {
            lookupFeedback = error.localizedDescription
            lookupIsError = true
        }
    }

    private func saveHolding() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        let chosenCategory = categories.first(where: { $0.id == selectedCategoryID })
        let chosenAccount = accounts.first(where: { $0.id == selectedAccountID })
        let cleanedCode = valuationMode.usesSharesAndPrice ? code.trimmingCharacters(in: .whitespacesAndNewlines) : ""

        if let target = existingHolding {
            target.name = trimmedName
            target.valuationMode = valuationMode
            target.code = cleanedCode
            target.shares = valuationMode.usesSharesAndPrice ? parsedShares : 0
            target.latestPrice = valuationMode.usesSharesAndPrice ? parsedPrice : 1.0
            target.manualAmount = valuationMode.usesSharesAndPrice ? 0 : parsedManualAmount
            target.totalCost = computedTotalCost
            target.priceDateText = valuationMode.usesSharesAndPrice ? priceDateText : ""
            target.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
            target.assignCategory(chosenCategory)
            target.account = chosenAccount
            target.lastUpdated = .now
        } else {
            let nextOrder = (allHoldings.map(\.sortOrder).max() ?? -1) + 1
            let created = AssetHolding(
                name: trimmedName,
                valuationMode: valuationMode,
                code: cleanedCode,
                shares: valuationMode.usesSharesAndPrice ? parsedShares : 0,
                latestPrice: valuationMode.usesSharesAndPrice ? parsedPrice : 1.0,
                manualAmount: valuationMode.usesSharesAndPrice ? 0 : parsedManualAmount,
                totalCost: computedTotalCost,
                priceDateText: valuationMode.usesSharesAndPrice ? priceDateText : "",
                lastUpdated: .now,
                note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                sortOrder: nextOrder,
                fallbackPool: chosenCategory?.pool ?? .investable,
                category: chosenCategory,
                account: chosenAccount
            )
            modelContext.insert(created)
        }

        try? modelContext.save()
        dismiss()
    }
}
