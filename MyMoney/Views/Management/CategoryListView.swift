import SwiftUI
import SwiftData

/// 资产类别管理页（支持自由增删改、切换投资/固定资产池、选填目标比例与拖拽排序）
struct CategoryListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PortfolioRefreshStore.self) private var refreshStore
    @Query(sort: \AssetCategory.sortOrder) private var categories: [AssetCategory]
    @Query private var holdings: [AssetHolding]

    @State private var showingCreatePool: AssetPool?
    @State private var editingCategory: AssetCategory?
    @State private var pendingDeleteCategory: AssetCategory?

    private var investableCategories: [AssetCategory] {
        categories.filter { $0.pool == .investable }
    }

    private var fixedCategories: [AssetCategory] {
        categories.filter { $0.pool == .fixed }
    }

    private var configuredTargetSum: Double? {
        let targets = investableCategories.compactMap(\.targetRatio)
        return targets.isEmpty ? nil : targets.reduce(0, +)
    }

    private var investableTotal: Double {
        holdings.filter { $0.effectivePool == .investable }.reduce(0.0) { $0 + $1.marketValue }
    }

    private var canReorderAnySection: Bool {
        investableCategories.count >= 2 || fixedCategories.count >= 2
    }

    var body: some View {
        List {
            Section {
                if investableCategories.isEmpty {
                    Text("暂无投资资产类别")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(investableCategories) { category in
                        categoryRow(category)
                    }
                    .onMove(perform: moveInvestableCategories)
                }

                Button {
                    Haptics.lightImpact()
                    showingCreatePool = .investable
                } label: {
                    Label("新增投资资产类别", systemImage: "plus.circle.fill")
                }
            } header: {
                HStack {
                    Text("投资资产类别（参与配置比例）")
                    Spacer()
                    if let sum = configuredTargetSum {
                        Text("目标合计 \(Formatters.percentPoints(sum, digits: 0))")
                            .monospacedDigit()
                            .foregroundStyle(abs(sum - 100) < 0.1 ? Color.secondary : Color.orange)
                    }
                }
                .textCase(nil)
            } footer: {
                Text("目标占比选填，填后展示参考金额与差额。")
            }

            Section {
                if fixedCategories.isEmpty {
                    Text("暂无固定资产类别")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(fixedCategories) { category in
                        categoryRow(category)
                    }
                    .onMove(perform: moveFixedCategories)
                }

                Button {
                    Haptics.lightImpact()
                    showingCreatePool = .fixed
                } label: {
                    Label("新增固定资产类别", systemImage: "plus.circle.fill")
                }
            } header: {
                Text("固定资产类别（不稀释投资占比）")
                    .textCase(nil)
            } footer: {
                Text("定存、房产等大额资产，不稀释投资占比。")
            }
        }
        .listSectionSpacing(.compact)
        .navigationTitle("资产类别管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canReorderAnySection {
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                }
            }
        }
        .sheet(item: $showingCreatePool) { pool in
            CategoryEditorSheet(existingCategory: nil, defaultPool: pool)
        }
        .sheet(item: $editingCategory) { cat in
            CategoryEditorSheet(existingCategory: cat)
        }
        .confirmationDialog(
            deleteDialogTitle,
            isPresented: Binding(
                get: { pendingDeleteCategory != nil },
                set: { if !$0 { pendingDeleteCategory = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除类别", role: .destructive) {
                if let target = pendingDeleteCategory {
                    let deletedName = target.name
                    modelContext.delete(target)
                    try? modelContext.save()
                    Haptics.warning()
                    refreshStore.showToast(style: .info, message: "已删除类别「\(deletedName)」", autoDismissSeconds: 2.2)
                }
                pendingDeleteCategory = nil
            }
            Button("取消", role: .cancel) {
                pendingDeleteCategory = nil
            }
        } message: {
            if let target = pendingDeleteCategory {
                let count = holdings.filter { $0.category?.id == target.id }.count
                if count > 0 {
                    Text("该类别下关联了 \(count) 项资产。删除类别不会删除资产金额，它们将变为「未分类」。")
                }
            }
        }
    }

    private var deleteDialogTitle: String {
        guard let target = pendingDeleteCategory else { return "" }
        return "确认删除类别「\(target.name)」？"
    }

    private func categoryRow(_ category: AssetCategory) -> some View {
        let count = holdings.filter { $0.category?.id == category.id }.count
        return Button {
            Haptics.lightImpact()
            editingCategory = category
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(category.tintColor.opacity(0.15))
                        .frame(width: 30, height: 30)
                    Image(systemName: category.iconName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(category.tintColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(category.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text("\(count) 项资产")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if category.pool == .investable, let target = category.targetRatio {
                    let amtText: String = {
                        guard investableTotal > 0, !refreshStore.hideAmounts else { return "" }
                        return " · \(Formatters.wholeCurrency(investableTotal * target / 100.0))"
                    }()
                    Text("目标 \(Formatters.percentPoints(target, digits: 0))\(amtText)")
                        .font(.caption2.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }

                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                Haptics.lightImpact()
                pendingDeleteCategory = category
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func moveInvestableCategories(from source: IndexSet, to destination: Int) {
        var reordered = investableCategories
        reordered.move(fromOffsets: source, toOffset: destination)
        let combined = reordered + fixedCategories
        for (idx, item) in combined.enumerated() {
            item.sortOrder = idx
        }
        try? modelContext.save()
        Haptics.selection()
    }

    private func moveFixedCategories(from source: IndexSet, to destination: Int) {
        var reordered = fixedCategories
        reordered.move(fromOffsets: source, toOffset: destination)
        let combined = investableCategories + reordered
        for (idx, item) in combined.enumerated() {
            item.sortOrder = idx
        }
        try? modelContext.save()
        Haptics.selection()
    }
}

/// 新建 / 编辑单个资产类别弹窗
struct CategoryEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(PortfolioRefreshStore.self) private var refreshStore
    @Query(sort: \AssetCategory.sortOrder) private var allCategories: [AssetCategory]
    @Query private var allHoldings: [AssetHolding]

    let existingCategory: AssetCategory?
    var defaultPool: AssetPool = .investable
    var onSaved: ((AssetCategory) -> Void)? = nil

    @State private var name: String = ""
    @State private var pool: AssetPool = .investable
    @State private var colorToken: CategoryColorToken = .blue
    @State private var iconName: String = "chart.pie.fill"
    @State private var enableTargetRatio: Bool = false
    @State private var targetRatioText: String = ""
    @State private var showingDeleteConfirm = false
    @State private var hasLoadedInitial = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 5)
    private let iconColumns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 6)

    /// 其余已设目标的投资类别合计，方便一键填入剩余百分比
    private var remainingTargetRatio: Double? {
        let otherSum = allCategories
            .filter { $0.pool == .investable && $0.id != existingCategory?.id }
            .compactMap(\.targetRatio)
            .reduce(0.0, +)
        let rem = 100.0 - otherSum
        return (otherSum > 0 && rem > 0.05 && rem <= 100) ? rem : nil
    }

    private var hasUnsavedChanges: Bool {
        if let cat = existingCategory {
            let parsedTarget: Double? = (pool == .investable && enableTargetRatio) ? Formatters.parseDouble(targetRatioText) : nil
            return cat.name != name.trimmingCharacters(in: .whitespacesAndNewlines)
                || cat.pool != pool
                || cat.colorToken != colorToken
                || cat.iconName != iconName
                || cat.targetRatio != parsedTarget
        }
        return !name.isEmpty || enableTargetRatio
    }

    private var currentInvestableTotal: Double {
        allHoldings.filter { $0.effectivePool == .investable }.reduce(0.0) { $0 + $1.marketValue }
    }

    private var previewTargetAmount: Double? {
        guard pool == .investable, enableTargetRatio,
              currentInvestableTotal > 0,
              let pct = Formatters.parseDouble(targetRatioText), pct > 0 else {
            return nil
        }
        return currentInvestableTotal * (min(pct, 100) / 100.0)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本属性") {
                    TextField("类别名称（如：海外指数、定期存单）", text: $name)
                        .submitLabel(.done)

                    Picker("资金池归属", selection: $pool) {
                        ForEach(AssetPool.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: pool) { _, _ in
                        Haptics.selection()
                    }

                    Text(pool.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if pool == .investable {
                    Section {
                        Toggle("设置参考目标占比（选填）", isOn: $enableTargetRatio)

                        if enableTargetRatio {
                            HStack {
                                Text("目标占比")
                                Spacer()
                                TextField("如 30", text: $targetRatioText)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .monospacedDigit()
                                Text("%")
                                    .foregroundStyle(.secondary)
                            }

                            HStack {
                                Text("折合参考金额")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if let previewAmt = previewTargetAmount {
                                    Text(Formatters.wholeCurrency(previewAmt))
                                        .font(.subheadline.weight(.semibold))
                                        .monospacedDigit()
                                } else {
                                    Text("—")
                                        .font(.subheadline)
                                        .foregroundStyle(.tertiary)
                                }
                            }

                            if let remaining = remainingTargetRatio {
                                Button {
                                    Haptics.selection()
                                    targetRatioText = Formatters.editableDecimal(remaining, maxDecimals: 1)
                                } label: {
                                    Label("一键填入剩余 \(Formatters.percentPoints(remaining, digits: 1))", systemImage: "wand.and.stars")
                                        .font(.caption.weight(.medium))
                                }
                            }
                        }
                    } header: {
                        Text("目标比例（可选）")
                    } footer: {
                        if enableTargetRatio && currentInvestableTotal > 0 {
                            Text("按当前投资资产 \(Formatters.wholeCurrency(currentInvestableTotal)) 实时折算。")
                        }
                    }
                }

                Section("标识颜色") {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(CategoryColorToken.allCases) { token in
                            let selected = (colorToken == token)
                            Button {
                                Haptics.selection()
                                colorToken = token
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(token.color)
                                        .frame(width: 34, height: 34)
                                    if selected {
                                        Image(systemName: "checkmark")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                }

                Section("图标") {
                    LazyVGrid(columns: iconColumns, spacing: 12) {
                        ForEach(PresetIcons.categoryIcons, id: \.self) { symbol in
                            let selected = (iconName == symbol)
                            Button {
                                Haptics.selection()
                                iconName = symbol
                            } label: {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(selected ? colorToken.color.opacity(0.2) : Color(.tertiarySystemFill))
                                        .frame(width: 40, height: 40)
                                    Image(systemName: symbol)
                                        .font(.callout.weight(.semibold))
                                        .foregroundStyle(selected ? colorToken.color : .secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                }

                if existingCategory != nil {
                    Section {
                        Button(role: .destructive) {
                            Haptics.lightImpact()
                            showingDeleteConfirm = true
                        } label: {
                            HStack {
                                Spacer()
                                Text("删除该类别")
                                Spacer()
                            }
                        }
                    }
                }
            }
            .keyboardDismissOverlay()
            .navigationTitle(existingCategory == nil ? "新建资产类别" : "编辑资产类别")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(hasUnsavedChanges)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { saveCategory() }
                        .fontWeight(.semibold)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                guard !hasLoadedInitial else { return }
                hasLoadedInitial = true
                if let cat = existingCategory {
                    name = cat.name
                    pool = cat.pool
                    colorToken = cat.colorToken
                    iconName = cat.iconName
                    if let target = cat.targetRatio {
                        enableTargetRatio = true
                        targetRatioText = Formatters.editableDecimal(target, maxDecimals: 1)
                    }
                } else {
                    pool = defaultPool
                    colorToken = defaultPool == .fixed ? .amber : .blue
                    iconName = defaultPool == .fixed ? "lock.doc.fill" : "chart.pie.fill"
                }
            }
            .confirmationDialog(
                "确认删除类别「\(existingCategory?.name ?? "")」？",
                isPresented: $showingDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("删除类别", role: .destructive) {
                    if let target = existingCategory {
                        let deletedName = target.name
                        modelContext.delete(target)
                        try? modelContext.save()
                        Haptics.warning()
                        refreshStore.showToast(style: .info, message: "已删除类别「\(deletedName)」", autoDismissSeconds: 2.2)
                    }
                    dismiss()
                }
                Button("取消", role: .cancel) {}
            } message: {
                if let target = existingCategory {
                    let count = allHoldings.filter { $0.category?.id == target.id }.count
                    if count > 0 {
                        Text("该类别下关联了 \(count) 项资产。删除类别不会删除资产金额，它们将变为「未分类」。")
                    }
                }
            }
        }
    }

    private func saveCategory() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let parsedTarget: Double? = {
            guard pool == .investable, enableTargetRatio,
                  let v = Formatters.parseDouble(targetRatioText), v > 0 else {
                return nil
            }
            return min(v, 100)
        }()

        if let target = existingCategory {
            target.name = trimmed
            target.pool = pool
            target.colorToken = colorToken
            target.iconName = iconName
            target.targetRatio = parsedTarget
            try? modelContext.save()
            Haptics.success()
            refreshStore.showToast(style: .success, message: "已保存类别「\(trimmed)」", autoDismissSeconds: 2.0)
            onSaved?(target)
        } else {
            let nextOrder = (allCategories.map(\.sortOrder).max() ?? -1) + 1
            let created = AssetCategory(
                name: trimmed,
                pool: pool,
                colorToken: colorToken,
                iconName: iconName,
                targetRatio: parsedTarget,
                sortOrder: nextOrder
            )
            modelContext.insert(created)
            try? modelContext.save()
            Haptics.success()
            if onSaved == nil {
                refreshStore.showToast(style: .success, message: "已新建类别「\(trimmed)」", autoDismissSeconds: 2.0)
            }
            onSaved?(created)
        }
        dismiss()
    }
}
