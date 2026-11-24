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
    @Environment(PortfolioRefreshStore.self) private var refreshStore

    @Query(sort: \AssetCategory.sortOrder) private var categories: [AssetCategory]
    @Query(sort: \AssetAccount.sortOrder) private var accounts: [AssetAccount]

    let existingHolding: AssetHolding?
    var preselectedCategory: AssetCategory? = nil
    var preselectedAccount: AssetAccount? = nil
    var preselectedPool: AssetPool = .investable

    private struct TermPreset: Identifiable {
        let label: String
        let months: Int
        var id: Int { months }
    }

    private static let termPresets: [TermPreset] = [
        TermPreset(label: "3个月", months: 3),
        TermPreset(label: "6个月", months: 6),
        TermPreset(label: "1年", months: 12),
        TermPreset(label: "2年", months: 24),
        TermPreset(label: "3年", months: 36),
        TermPreset(label: "5年", months: 60),
    ]

    @State private var entryKind: EntryKind = .manualAmount
    /// 系统自动识别出的真实底层模式（.exchangeSecurity 或 .otcFund）
    @State private var resolvedQuoteMode: ValuationMode = .exchangeSecurity

    @State private var code: String = ""
    @State private var name: String = ""
    @State private var userEditedName: Bool = false
    @State private var autoFillingName: Bool = false
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

    // 固定资产 / 存单专属输入项
    @State private var annualRateText: String = ""
    @State private var hasMaturityDate: Bool = false
    @State private var startDate: Date = .now
    @State private var maturityDate: Date = Calendar.current.date(byAdding: .year, value: 1, to: .now) ?? .now

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

    private var isEditing: Bool { existingHolding != nil }

    private var selectedCategory: AssetCategory? {
        categories.first(where: { $0.id == selectedCategoryID })
    }

    private var isFixedAsset: Bool {
        if let selectedCategory {
            return selectedCategory.pool == .fixed
        }
        if let item = existingHolding {
            return item.effectivePool == .fixed
        }
        return preselectedPool == .fixed
    }

    private var showEntryKindPicker: Bool {
        !isFixedAsset || entryKind == .quoteTracked
    }

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
        guard !isFixedAsset, trackCost, let val = Formatters.parseDouble(costInputText), val >= 0 else {
            return nil
        }
        if entryKind == .quoteTracked && costEntryStyle == .unitCostPrice {
            return parsedShares * val
        }
        return val
    }

    private var parsedAnnualRate: Double? {
        guard isFixedAsset, let val = Formatters.parseDouble(annualRateText), val > 0 else {
            return nil
        }
        return val
    }

    private var termDaysCount: Int? {
        guard isFixedAsset, hasMaturityDate, maturityDate > startDate else { return nil }
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: startDate), to: cal.startOfDay(for: maturityDate)).day ?? 0
        return days > 0 ? days : nil
    }

    private var previewAnnualInterest: Double? {
        guard let rate = parsedAnnualRate, previewMarketValue > 0 else { return nil }
        return previewMarketValue * (rate / 100.0)
    }

    private var previewMaturityInterest: Double? {
        guard let annual = previewAnnualInterest, let days = termDaysCount else { return nil }
        return annual * (Double(days) / 365.0)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasUnsavedChanges: Bool {
        if let item = existingHolding {
            let rateChanged: Bool = {
                switch (item.annualRate, parsedAnnualRate) {
                case (nil, nil): return false
                case (let old?, let new?): return abs(old - new) > 0.001
                default: return true
                }
            }()
            let maturityChanged: Bool = {
                let cal = Calendar.current
                let newMat: Date? = (isFixedAsset && hasMaturityDate) ? maturityDate : nil
                let newStart: Date? = (isFixedAsset && hasMaturityDate) ? startDate : nil
                let matDiff: Bool = {
                    switch (item.maturityDate, newMat) {
                    case (nil, nil): return false
                    case (let a?, let b?): return !cal.isDate(a, inSameDayAs: b)
                    default: return true
                    }
                }()
                let startDiff: Bool = {
                    switch (item.startDate, newStart) {
                    case (nil, nil): return false
                    case (let a?, let b?): return !cal.isDate(a, inSameDayAs: b)
                    default: return true
                    }
                }()
                return matDiff || startDiff
            }()
            return item.name != name.trimmingCharacters(in: .whitespacesAndNewlines)
                || item.valuationMode != effectiveValuationMode
                || item.code != (entryKind == .quoteTracked ? code.trimmingCharacters(in: .whitespacesAndNewlines) : "")
                || abs(item.shares - (entryKind == .quoteTracked ? parsedShares : 0)) > 0.001
                || abs(item.manualAmount - (entryKind == .manualAmount ? parsedManualAmount : 0)) > 0.01
                || item.category?.id != selectedCategoryID
                || item.account?.id != selectedAccountID
                || item.note != note.trimmingCharacters(in: .whitespacesAndNewlines)
                || rateChanged
                || maturityChanged
        }
        return !name.isEmpty || !code.isEmpty || !sharesText.isEmpty || !manualAmountText.isEmpty || !note.isEmpty || !annualRateText.isEmpty || hasMaturityDate
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    // 1. 基本信息（固定资产自动隐藏证券/基金切换）
                    GroupedFormSection(header: "基本信息") {
                        if showEntryKindPicker {
                            Picker("记录方式", selection: $entryKind) {
                                ForEach(EntryKind.allCases) { kind in
                                    Text(kind.rawValue).tag(kind)
                                }
                            }
                            .pickerStyle(.segmented)
                            .onChange(of: entryKind) { _, _ in
                                Haptics.selection()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)

                            GroupedFormDivider()
                        }

                        if entryKind == .quoteTracked {
                            HStack(spacing: 8) {
                                TextField("输入代码自动识别（515800、050025、SPY）", text: $code)
                                    .textInputAutocapitalization(.characters)
                                    .autocorrectionDisabled()
                                    .submitLabel(.done)
                                    .frame(minHeight: 24)
                                    .onChange(of: code) { _, newValue in
                                        scheduleAutoLookupIfAppropriate(for: newValue)
                                    }

                                ZStack {
                                    if isLookingUpQuote {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else if !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        Button {
                                            Task { await performSmartLookup(rawCode: code, force: true) }
                                        } label: {
                                            Image(systemName: "arrow.clockwise.circle.fill")
                                                .font(.title3)
                                                .foregroundStyle(Color.accentColor)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("重新识别行情")
                                    }
                                }
                                .frame(width: 24, height: 24)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 11)
                            .frame(minHeight: 44)

                            // 仅在极少数真实重码（如 000001 / LOF）时显示 1 键切换候选
                            if lookupCandidates.count > 1 {
                                GroupedFormDivider()

                                VStack(alignment: .leading, spacing: 8) {
                                    Text("检测到同名场内与场外标的，点选你实际持有的渠道：")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    ForEach(lookupCandidates) { candidate in
                                        let isSelected = (candidate.mode == resolvedQuoteMode)
                                        Button {
                                            Haptics.selection()
                                            applyCandidate(candidate, overwriteName: true)
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
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                            } else if let lookupStatusText {
                                GroupedFormDivider()

                                HStack(spacing: 6) {
                                    Image(systemName: lookupIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(lookupIsError ? .orange : .green)
                                    Text(lookupStatusText)
                                        .font(.caption)
                                        .foregroundStyle(lookupIsError ? .orange : .secondary)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                            }

                            GroupedFormDivider()
                        }

                        TextField(
                            entryKind == .quoteTracked
                                ? "名称（输入代码后自动填充，也可自定）"
                                : (isFixedAsset ? "资产名称（如：三年期大额存单、定期、房产）" : "资产名称（必填，如：活期存款、货币基金）"),
                            text: $name
                        )
                        .submitLabel(.done)
                        .frame(minHeight: 24)
                        .onChange(of: name) { _, newValue in
                            if !autoFillingName {
                                userEditedName = !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .frame(minHeight: 44)
                    }

                    // 2. 金额与利率（固定资产将金额与年化利率同放顶部，均位于键盘安全区上方）
                    GroupedFormSection(header: isFixedAsset ? "金额与利率" : "当前价值") {
                        if entryKind == .quoteTracked {
                            HStack(spacing: 8) {
                                Text("持有份额 / 股数")
                                    .lineLimit(1)
                                    .layoutPriority(1)
                                TextField("0", text: $sharesText)
                                    .keyboardType(.decimalPad)
                                    .autocorrectionDisabled()
                                    .multilineTextAlignment(.trailing)
                                    .monospacedDigit()
                                    .frame(maxWidth: .infinity, minHeight: 24)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 11)
                            .frame(minHeight: 44)

                            GroupedFormDivider()

                            HStack(spacing: 8) {
                                Text(resolvedQuoteMode.priceFieldLabel)
                                    .lineLimit(1)
                                    .layoutPriority(1)
                                TextField("1.0000", text: $latestPriceText)
                                    .keyboardType(.decimalPad)
                                    .autocorrectionDisabled()
                                    .multilineTextAlignment(.trailing)
                                    .monospacedDigit()
                                    .frame(maxWidth: .infinity, minHeight: 24)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 11)
                            .frame(minHeight: 44)

                            GroupedFormDivider()

                            HStack {
                                Text("折算当前市值")
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Spacer()
                                Text(Formatters.currency(previewMarketValue))
                                    .font(.callout.weight(.semibold))
                                    .monospacedDigit()
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 11)
                            .frame(minHeight: 44)
                        } else {
                            HStack(spacing: 6) {
                                Text(isFixedAsset ? "存款金额（元）" : "当前金额（元）")
                                    .lineLimit(1)
                                    .layoutPriority(1)
                                AmountUnitBadge(text: manualAmountText)
                                TextField("0.00", text: $manualAmountText)
                                    .keyboardType(.decimalPad)
                                    .autocorrectionDisabled()
                                    .multilineTextAlignment(.trailing)
                                    .monospacedDigit()
                                    .frame(maxWidth: .infinity, minHeight: 24)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 11)
                            .frame(minHeight: 44)

                            if isFixedAsset {
                                GroupedFormDivider()

                                HStack(spacing: 6) {
                                    Text("年化利率")
                                        .lineLimit(1)
                                        .layoutPriority(1)
                                    TextField("如 2.35", text: $annualRateText)
                                        .keyboardType(.decimalPad)
                                        .autocorrectionDisabled()
                                        .multilineTextAlignment(.trailing)
                                        .monospacedDigit()
                                        .frame(maxWidth: .infinity, minHeight: 24)
                                    Text("%")
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 11)
                                .frame(minHeight: 44)
                            }
                        }
                    }

                    // 3. 归属维度（单行 Menu 选单 + 右侧一键新建类别/账户，彻底杜绝 Picker(.menu) 竖排折行）
                    GroupedFormSection(
                        header: "归属维度",
                        footer: selectedCategory.map {
                            $0.pool == .fixed
                                ? "归属「固定资产」，计入总净值，不稀释投资占比。"
                                : "归属「投资资产」，计入投资组合结构占比。"
                        }
                    ) {
                        HStack(spacing: 10) {
                            Text("资产类别")
                                .lineLimit(1)
                                .layoutPriority(1)

                            Spacer(minLength: 12)

                            Menu {
                                Button {
                                    selectedCategoryID = nil
                                } label: {
                                    if selectedCategoryID == nil {
                                        Label("未分类", systemImage: "checkmark")
                                    } else {
                                        Text("未分类")
                                    }
                                }

                                ForEach(categories) { cat in
                                    let title = "[\(cat.pool == .investable ? "投资" : "固定")] \(cat.name)"
                                    Button {
                                        selectedCategoryID = cat.id
                                    } label: {
                                        if selectedCategoryID == cat.id {
                                            Label(title, systemImage: "checkmark")
                                        } else {
                                            Text(title)
                                        }
                                    }
                                }

                                Divider()

                                Button {
                                    showingNewCategorySheet = true
                                } label: {
                                    Label("新建资产类别...", systemImage: "plus")
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(
                                        selectedCategory.map {
                                            "[\($0.pool == .investable ? "投资" : "固定")] \($0.name)"
                                        } ?? "未分类"
                                    )
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.caption2.weight(.semibold))
                                }
                                .foregroundStyle(.secondary)
                            }
                            .onChange(of: selectedCategoryID) { _, _ in
                                if isFixedAsset && entryKind == .quoteTracked
                                    && code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    && sharesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    entryKind = .manualAmount
                                }
                            }

                            Button {
                                Haptics.lightImpact()
                                showingNewCategorySheet = true
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .font(.body)
                                    .foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("新建资产类别")
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .frame(minHeight: 44)

                        GroupedFormDivider()

                        HStack(spacing: 10) {
                            Text("存放账户")
                                .lineLimit(1)
                                .layoutPriority(1)

                            Spacer(minLength: 12)

                            Menu {
                                Button {
                                    selectedAccountID = nil
                                } label: {
                                    if selectedAccountID == nil {
                                        Label("未指定账户", systemImage: "checkmark")
                                    } else {
                                        Text("未指定账户")
                                    }
                                }

                                ForEach(accounts) { acc in
                                    Button {
                                        selectedAccountID = acc.id
                                    } label: {
                                        if selectedAccountID == acc.id {
                                            Label(acc.name, systemImage: "checkmark")
                                        } else {
                                            Text(acc.name)
                                        }
                                    }
                                }

                                Divider()

                                Button {
                                    showingNewAccountSheet = true
                                } label: {
                                    Label("新建存放账户...", systemImage: "plus")
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(accounts.first(where: { $0.id == selectedAccountID })?.name ?? "未指定账户")
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.caption2.weight(.semibold))
                                }
                                .foregroundStyle(.secondary)
                            }

                            Button {
                                Haptics.lightImpact()
                                showingNewAccountSheet = true
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .font(.body)
                                    .foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("新建存放账户")
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .frame(minHeight: 44)
                    }

                    // 4. 固定资产「存期与试算」 / 投资资产「成本与备注」
                    GroupedFormSection(
                        header: isFixedAsset ? "存期与到期（选填）" : "选填信息",
                        footer: isFixedAsset ? "房产、车产等非生息资产可直接留空利率与到期日。" : nil
                    ) {
                        if isFixedAsset {
                            Toggle("设置起息与到期日", isOn: $hasMaturityDate)
                                .onChange(of: hasMaturityDate) { _, _ in
                                    Haptics.selection()
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 9)
                                .frame(minHeight: 44)

                            if hasMaturityDate {
                                GroupedFormDivider()

                                DatePicker("起息日", selection: $startDate, displayedComponents: .date)
                                    .datePickerStyle(.compact)
                                    .onChange(of: startDate) { _, newStart in
                                        if maturityDate <= newStart {
                                            maturityDate = Calendar.current.date(byAdding: .year, value: 1, to: newStart) ?? newStart
                                        }
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 9)
                                    .frame(minHeight: 44)

                                GroupedFormDivider()

                                VStack(alignment: .leading, spacing: 8) {
                                    Text("快捷存期")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    HStack(spacing: 6) {
                                        ForEach(Self.termPresets) { preset in
                                            let expected = Calendar.current.date(byAdding: .month, value: preset.months, to: startDate)
                                            let isSelected = expected.map { Calendar.current.isDate(maturityDate, inSameDayAs: $0) } ?? false
                                            Button {
                                                Haptics.selection()
                                                if let target = expected {
                                                    maturityDate = target
                                                }
                                            } label: {
                                                Text(preset.label)
                                                    .font(.caption2.weight(.medium))
                                                    .lineLimit(1)
                                                    .foregroundStyle(isSelected ? .white : .primary)
                                                    .frame(maxWidth: .infinity)
                                                    .padding(.vertical, 6)
                                                    .background(
                                                        isSelected ? Color.accentColor : Color(.tertiarySystemFill),
                                                        in: Capsule()
                                                    )
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)

                                GroupedFormDivider()

                                DatePicker("到期日", selection: $maturityDate, displayedComponents: .date)
                                    .datePickerStyle(.compact)
                                    .onChange(of: maturityDate) { _, newMaturity in
                                        if newMaturity <= startDate {
                                            maturityDate = Calendar.current.date(byAdding: .day, value: 1, to: startDate) ?? startDate
                                        }
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 9)
                                    .frame(minHeight: 44)
                            }

                            GroupedFormDivider()

                            HStack {
                                Text(hasMaturityDate ? "预计到期利息" : "预计年利息")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if let maturityInterest = previewMaturityInterest {
                                    Text("+\(Formatters.currency(maturityInterest))")
                                        .font(.subheadline.weight(.semibold))
                                        .monospacedDigit()
                                        .foregroundStyle(CategoryColorToken.amber.color)
                                } else if let annualInterest = previewAnnualInterest {
                                    Text("+\(Formatters.currency(annualInterest)) / 年")
                                        .font(.subheadline.weight(.semibold))
                                        .monospacedDigit()
                                        .foregroundStyle(CategoryColorToken.amber.color)
                                } else {
                                    Text("填写金额与利率后自动试算")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 11)
                            .frame(minHeight: 44)

                            if hasMaturityDate {
                                GroupedFormDivider()

                                HStack {
                                    let daysLabel = termDaysCount.map { "到期预计本息（共 \($0) 天）" } ?? "到期预计本息"
                                    Text(daysLabel)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    if let maturityInterest = previewMaturityInterest {
                                        Text(Formatters.currency(previewMarketValue + maturityInterest))
                                            .font(.subheadline.weight(.semibold))
                                            .monospacedDigit()
                                    } else {
                                        Text("—")
                                            .font(.subheadline)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 11)
                                .frame(minHeight: 44)
                            }

                            GroupedFormDivider()

                            TextField("备注（选填，如存单号、可否提前支取等）", text: $note)
                                .submitLabel(.done)
                                .frame(minHeight: 24)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 11)
                                .frame(minHeight: 44)
                        } else {
                            Toggle("记录成本（展示盈亏与收益率）", isOn: $trackCost)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 9)
                                .frame(minHeight: 44)

                            if trackCost {
                                if entryKind == .quoteTracked {
                                    GroupedFormDivider()

                                    Picker("成本口径", selection: $costEntryStyle) {
                                        ForEach(CostEntryStyle.allCases) { style in
                                            Text(style.title).tag(style)
                                        }
                                    }
                                    .pickerStyle(.segmented)
                                    .onChange(of: costEntryStyle) { _, newStyle in
                                        Haptics.selection()
                                        convertCostStyle(to: newStyle)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                }

                                GroupedFormDivider()

                                HStack(spacing: 6) {
                                    let isUnitCost = (entryKind == .quoteTracked && costEntryStyle == .unitCostPrice)
                                    Text(isUnitCost ? "持仓成本单价" : "累计投入本金（元）")
                                        .lineLimit(1)
                                        .layoutPriority(1)
                                    if !isUnitCost {
                                        AmountUnitBadge(text: costInputText)
                                    }
                                    TextField("0.00", text: $costInputText)
                                        .keyboardType(.decimalPad)
                                        .autocorrectionDisabled()
                                        .multilineTextAlignment(.trailing)
                                        .monospacedDigit()
                                        .frame(maxWidth: .infinity, minHeight: 24)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 11)
                                .frame(minHeight: 44)

                                GroupedFormDivider()

                                HStack {
                                    Text("预计累计盈亏")
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    if let totalCost = computedTotalCost {
                                        let pnl = previewMarketValue - totalCost
                                        Text(Formatters.signedCurrency(pnl))
                                            .font(.subheadline.weight(.semibold))
                                            .monospacedDigit()
                                            .foregroundStyle(refreshStore.pnlColorScheme.color(for: pnl))
                                    } else {
                                        Text("—")
                                            .font(.subheadline)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 11)
                                .frame(minHeight: 44)
                            }

                            GroupedFormDivider()

                            TextField("备注（选填，如定投计划等）", text: $note)
                                .submitLabel(.done)
                                .frame(minHeight: 24)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 11)
                                .frame(minHeight: 44)
                        }
                    }

                    if isEditing {
                        GroupedFormSection {
                            Button(role: .destructive) {
                                Haptics.lightImpact()
                                showingDeleteConfirm = true
                            } label: {
                                Text("删除该笔资产")
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .background(Color(.systemGroupedBackground))
            .keyboardDismissOverlay()
            .navigationTitle(isEditing ? (isFixedAsset ? "编辑固定资产" : "编辑资产") : (isFixedAsset ? "新增固定资产" : "新增资产"))
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
            }
            .onAppear(perform: loadInitialDataIfNeeded)
            .onDisappear {
                debounceLookupTask?.cancel()
            }
            .sheet(isPresented: $showingNewCategorySheet) {
                CategoryEditorSheet(existingCategory: nil, defaultPool: isFixedAsset ? .fixed : preselectedPool) { created in
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
            autoFillingName = true
            name = item.name
            autoFillingName = false
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

            if let rate = item.annualRate, rate > 0 {
                annualRateText = Formatters.editableDecimal(rate, maxDecimals: 2)
            }
            if let mat = item.maturityDate {
                hasMaturityDate = true
                maturityDate = mat
                startDate = item.startDate ?? .now
            } else if let start = item.startDate {
                startDate = start
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
            lookupCandidates = candidates
            if let primary = candidates.first {
                applyCandidate(primary, overwriteName: !userEditedName || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if !candidates.isEmpty {
                Haptics.success()
            }
        } catch {
            guard !Task.isCancelled else { return }
            lookupCandidates = []
            lookupStatusText = error.localizedDescription
            lookupIsError = true
            Haptics.warning()
        }
    }

    private func applyCandidate(_ candidate: QuoteResult, overwriteName: Bool) {
        resolvedQuoteMode = candidate.mode
        if overwriteName {
            autoFillingName = true
            name = candidate.name
            autoFillingName = false
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

        let chosenCategory = selectedCategory
        let chosenAccount = accounts.first(where: { $0.id == selectedAccountID })
        let cleanedCode = entryKind == .quoteTracked ? code.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let savedAnnualRate: Double? = isFixedAsset ? parsedAnnualRate : nil
        let savedStartDate: Date? = (isFixedAsset && hasMaturityDate) ? startDate : nil
        let savedMaturityDate: Date? = (isFixedAsset && hasMaturityDate) ? maturityDate : nil

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
            target.annualRate = savedAnnualRate
            target.startDate = savedStartDate
            target.maturityDate = savedMaturityDate
            target.assignCategory(chosenCategory)
            target.account = chosenAccount
            target.lastUpdated = .now
        } else {
            var descriptor = FetchDescriptor<AssetHolding>(sortBy: [SortDescriptor(\.sortOrder, order: .reverse)])
            descriptor.fetchLimit = 1
            let maxOrder = (try? modelContext.fetch(descriptor).first?.sortOrder) ?? -1
            let nextOrder = maxOrder + 1
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
                annualRate: savedAnnualRate,
                startDate: savedStartDate,
                maturityDate: savedMaturityDate,
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
