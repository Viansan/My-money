import SwiftUI
import SwiftData

/// 账户 / 渠道管理页（支持自由增删改与拖拽排序，严格遵循全局隐私模式）
struct AccountListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PortfolioRefreshStore.self) private var refreshStore
    @Query(sort: \AssetAccount.sortOrder) private var accounts: [AssetAccount]
    @Query private var holdings: [AssetHolding]

    @State private var showingCreateSheet = false
    @State private var editingAccount: AssetAccount?
    @State private var pendingDeleteAccount: AssetAccount?

    var body: some View {
        List {
            Section {
                if accounts.isEmpty {
                    Text("暂无账户记录")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(accounts) { account in
                        accountRow(account)
                    }
                    .onMove(perform: moveAccounts)
                }

                Button {
                    Haptics.lightImpact()
                    showingCreateSheet = true
                } label: {
                    Label("新增存放账户", systemImage: "plus.circle.fill")
                }
            } footer: {
                Text("将不同券商、银行或理财平台建为独立账户后，可在「资产」页切为「按账户对账」，逐个核对账面余额。")
            }
        }
        .navigationTitle("账户/渠道管理")
        .toolbar {
            if accounts.count >= 2 {
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                }
            }
        }
        .sheet(isPresented: $showingCreateSheet) {
            AccountEditorSheet(existingAccount: nil)
        }
        .sheet(item: $editingAccount) { acc in
            AccountEditorSheet(existingAccount: acc)
        }
        .confirmationDialog(
            "确认删除账户「\(pendingDeleteAccount?.name ?? "")」？",
            isPresented: Binding(
                get: { pendingDeleteAccount != nil },
                set: { if !$0 { pendingDeleteAccount = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除账户", role: .destructive) {
                if let target = pendingDeleteAccount {
                    let deletedName = target.name
                    modelContext.delete(target)
                    try? modelContext.save()
                    Haptics.warning()
                    refreshStore.showToast(style: .info, message: "已删除账户「\(deletedName)」", autoDismissSeconds: 2.2)
                }
                pendingDeleteAccount = nil
            }
            Button("取消", role: .cancel) {
                pendingDeleteAccount = nil
            }
        } message: {
            if let target = pendingDeleteAccount {
                let count = holdings.filter { $0.account?.id == target.id }.count
                if count > 0 {
                    Text("该账户下有 \(count) 项资产。删除账户不会删除资产，它们将变为「未指定账户」。")
                }
            }
        }
    }

    private func accountRow(_ account: AssetAccount) -> some View {
        let accHoldings = holdings.filter { $0.account?.id == account.id }
        let sum = accHoldings.reduce(0.0) { $0 + $1.marketValue }

        return Button {
            Haptics.lightImpact()
            editingAccount = account
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(account.tintColor.opacity(0.15))
                        .frame(width: 32, height: 32)
                    Image(systemName: account.iconName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(account.tintColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(account.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    if !account.subtitle.isEmpty {
                        Text(account.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(accHoldings.count) 项资产")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Text(Formatters.currency(sum, hidden: refreshStore.hideAmounts, compact: true))
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                Haptics.lightImpact()
                pendingDeleteAccount = account
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func moveAccounts(from source: IndexSet, to destination: Int) {
        var reordered = accounts
        reordered.move(fromOffsets: source, toOffset: destination)
        for (idx, item) in reordered.enumerated() {
            item.sortOrder = idx
        }
        try? modelContext.save()
        Haptics.selection()
    }
}

/// 新建 / 编辑账户弹窗
struct AccountEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(PortfolioRefreshStore.self) private var refreshStore
    @Query(sort: \AssetAccount.sortOrder) private var allAccounts: [AssetAccount]
    @Query private var allHoldings: [AssetHolding]

    let existingAccount: AssetAccount?
    var onSaved: ((AssetAccount) -> Void)? = nil

    @State private var name: String = ""
    @State private var subtitle: String = ""
    @State private var colorToken: CategoryColorToken = .indigo
    @State private var iconName: String = "building.columns.fill"
    @State private var showingDeleteConfirm = false
    @State private var hasLoadedInitial = false

    private enum Field: Hashable {
        case name
        case subtitle
    }

    @FocusState private var focusedField: Field?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 5)
    private let iconColumns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

    private var hasUnsavedChanges: Bool {
        if let acc = existingAccount {
            return acc.name != name.trimmingCharacters(in: .whitespacesAndNewlines)
                || acc.subtitle != subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
                || acc.colorToken != colorToken
                || acc.iconName != iconName
        }
        return !name.isEmpty || !subtitle.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("账户信息") {
                    TextField("账户名称（如：招商银行、某券商、支付宝）", text: $name)
                        .focused($focusedField, equals: .name)

                    TextField("副标题或备注（选填，如尾号或用途）", text: $subtitle)
                        .focused($focusedField, equals: .subtitle)
                }

                Section("标识颜色") {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(CategoryColorToken.allCases) { token in
                            Button {
                                Haptics.selection()
                                colorToken = token
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(token.color)
                                        .frame(width: 34, height: 34)
                                    if colorToken == token {
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
                        ForEach(PresetIcons.accountIcons, id: \.self) { symbol in
                            Button {
                                Haptics.selection()
                                iconName = symbol
                            } label: {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(iconName == symbol ? colorToken.color.opacity(0.2) : Color(.tertiarySystemFill))
                                        .frame(width: 44, height: 40)
                                    Image(systemName: symbol)
                                        .font(.callout.weight(.semibold))
                                        .foregroundStyle(iconName == symbol ? colorToken.color : .secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                }

                if existingAccount != nil {
                    Section {
                        Button(role: .destructive) {
                            Haptics.lightImpact()
                            showingDeleteConfirm = true
                        } label: {
                            HStack {
                                Spacer()
                                Text("删除该账户")
                                Spacer()
                            }
                        }
                    }
                }
            }
            .navigationTitle(existingAccount == nil ? "新建账户" : "编辑账户")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(hasUnsavedChanges)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { saveAccount() }
                        .fontWeight(.semibold)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { focusedField = nil }
                }
            }
            .onAppear {
                guard !hasLoadedInitial else { return }
                hasLoadedInitial = true
                if let acc = existingAccount {
                    name = acc.name
                    subtitle = acc.subtitle
                    colorToken = acc.colorToken
                    iconName = acc.iconName
                }
            }
            .confirmationDialog(
                "确认删除账户「\(existingAccount?.name ?? "")」？",
                isPresented: $showingDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("删除账户", role: .destructive) {
                    if let target = existingAccount {
                        let deletedName = target.name
                        modelContext.delete(target)
                        try? modelContext.save()
                        Haptics.warning()
                        refreshStore.showToast(style: .info, message: "已删除账户「\(deletedName)」", autoDismissSeconds: 2.2)
                    }
                    dismiss()
                }
                Button("取消", role: .cancel) {}
            } message: {
                if let target = existingAccount {
                    let count = allHoldings.filter { $0.account?.id == target.id }.count
                    if count > 0 {
                        Text("该账户下有 \(count) 项资产。删除账户不会删除资产，它们将变为「未指定账户」。")
                    }
                }
            }
        }
    }

    private func saveAccount() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let target = existingAccount {
            target.name = trimmed
            target.subtitle = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
            target.colorToken = colorToken
            target.iconName = iconName
            try? modelContext.save()
            Haptics.success()
            refreshStore.showToast(style: .success, message: "已保存账户「\(trimmed)」", autoDismissSeconds: 2.0)
            onSaved?(target)
        } else {
            let nextOrder = (allAccounts.map(\.sortOrder).max() ?? -1) + 1
            let created = AssetAccount(
                name: trimmed,
                subtitle: subtitle.trimmingCharacters(in: .whitespacesAndNewlines),
                colorToken: colorToken,
                iconName: iconName,
                sortOrder: nextOrder
            )
            modelContext.insert(created)
            try? modelContext.save()
            Haptics.success()
            if onSaved == nil {
                refreshStore.showToast(style: .success, message: "已新建账户「\(trimmed)」", autoDismissSeconds: 2.0)
            }
            onSaved?(created)
        }
        dismiss()
    }
}
