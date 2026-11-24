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
                Text("按券商、银行分账户，方便逐一核对余额。")
            }
        }
        .listSectionSpacing(.compact)
        .navigationTitle("账户/渠道管理")
        .navigationBarTitleDisplayMode(.inline)
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

    private var totalNetWorth: Double {
        holdings.reduce(0.0) { $0 + $1.marketValue }
    }

    private func accountRow(_ account: AssetAccount) -> some View {
        let accHoldings = holdings.filter { $0.account?.id == account.id }
        let sum = accHoldings.reduce(0.0) { $0 + $1.marketValue }
        let shareText: String? = totalNetWorth > 0 && sum > 0
            ? Formatters.percentPoints((sum / totalNetWorth) * 100.0)
            : nil

        return Button {
            Haptics.lightImpact()
            editingAccount = account
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(account.tintColor.opacity(0.15))
                        .frame(width: 30, height: 30)
                    Image(systemName: account.iconName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(account.tintColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(account.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    if !account.subtitle.isEmpty {
                        Text(account.subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(accHoldings.count) 项资产")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(Formatters.currency(sum, hidden: refreshStore.hideAmounts, compact: true))
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.primary)

                    if let shareText {
                        Text(shareText)
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
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
            ScrollView {
                VStack(spacing: 18) {
                    GroupedFormSection(header: "账户信息") {
                        TextField("账户名称（如：招商银行、某券商、支付宝）", text: $name)
                            .submitLabel(.done)
                            .frame(minHeight: 24)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 11)
                            .frame(minHeight: 44)

                        GroupedFormDivider()

                        TextField("副标题或备注（选填，如尾号或用途）", text: $subtitle)
                            .submitLabel(.done)
                            .frame(minHeight: 24)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 11)
                            .frame(minHeight: 44)
                    }

                    GroupedFormSection(header: "标识颜色") {
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
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                    }

                    GroupedFormSection(header: "图标") {
                        LazyVGrid(columns: iconColumns, spacing: 12) {
                            ForEach(PresetIcons.accountIcons, id: \.self) { symbol in
                                let selected = (iconName == symbol)
                                Button {
                                    Haptics.selection()
                                    iconName = symbol
                                } label: {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(selected ? colorToken.color.opacity(0.2) : Color(.tertiarySystemFill))
                                            .frame(width: 44, height: 40)
                                        Image(systemName: symbol)
                                            .font(.callout.weight(.semibold))
                                            .foregroundStyle(selected ? colorToken.color : .secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                    }

                    if existingAccount != nil {
                        GroupedFormSection {
                            Button(role: .destructive) {
                                Haptics.lightImpact()
                                showingDeleteConfirm = true
                            } label: {
                                Text("删除该账户")
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
