import SwiftUI
import SwiftData

/// 资金池筛选胶囊枚举
enum PoolFilterOption: String, CaseIterable, Identifiable {
    case all = "全部"
    case investable = "投资资产"
    case fixed = "固定资产"

    var id: String { rawValue }
}

/// 分组渲染载体
private struct HoldingGroupSection: Identifiable {
    let id: String
    let title: String
    let badgeText: String?
    let subtitleText: String?
    let subtotal: Double
    let category: AssetCategory?
    let account: AssetAccount?
    let items: [AssetHolding]
}

/// 携带预选上下文的新增表单触发器
private struct CreateHoldingRequest: Identifiable {
    let id = UUID()
    let category: AssetCategory?
    let account: AssetAccount?
    let pool: AssetPool
}

/// Tab 2：资产明细与对账工作台
/// - 0 持仓时隐藏全部筛选与刷新噪点，直给新增入口
/// - 支持「按类别 / 按账户对账」切换、总览下钻筛选与一键收回、分组内快速「+」新增
/// - 右滑单条刷新行情，左滑编辑或删除（删除支持 5 秒撤销）
struct HoldingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PortfolioRefreshStore.self) private var refreshStore

    @Query(sort: \AssetHolding.sortOrder) private var holdings: [AssetHolding]
    @Query(sort: \AssetCategory.sortOrder) private var categories: [AssetCategory]
    @Query(sort: \AssetAccount.sortOrder) private var accounts: [AssetAccount]

    @State private var searchText: String = ""

    @State private var quickAdjustTarget: AssetHolding?
    @State private var queuedFullEditTarget: AssetHolding?
    @State private var fullEditTarget: AssetHolding?
    @State private var createRequest: CreateHoldingRequest?
    @State private var pendingDeleteHolding: AssetHolding?

    private var hasInvestable: Bool {
        holdings.contains { $0.effectivePool == .investable }
    }

    private var hasFixed: Bool {
        holdings.contains { $0.effectivePool == .fixed }
    }

    private var hasBothPools: Bool {
        hasInvestable && hasFixed
    }

    private var hasRefreshableHoldings: Bool {
        holdings.contains { $0.supportsQuoteRefresh }
    }

    private var investableTotal: Double {
        holdings.filter { $0.effectivePool == .investable }.reduce(0.0) { $0 + $1.marketValue }
    }

    private var filteredHoldings: [AssetHolding] {
        holdings.filter { item in
            // 1. 下钻精准筛选优先
            if let drilldown = refreshStore.activeDrilldown {
                switch drilldown.kind {
                case .category(let catID):
                    if item.category?.id != catID { return false }
                case .account(let accID):
                    if item.account?.id != accID { return false }
                }
            }

            // 2. 资金池筛选
            switch refreshStore.holdingsPoolFilter {
            case .all:
                break
            case .investable:
                if item.effectivePool != .investable { return false }
            case .fixed:
                if item.effectivePool != .fixed { return false }
            }

            // 3. 关键词搜索
            let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !keyword.isEmpty else { return true }
            return item.name.localizedCaseInsensitiveContains(keyword)
                || item.code.localizedCaseInsensitiveContains(keyword)
                || item.note.localizedCaseInsensitiveContains(keyword)
                || (item.category?.name.localizedCaseInsensitiveContains(keyword) ?? false)
                || (item.account?.name.localizedCaseInsensitiveContains(keyword) ?? false)
        }
    }

    private var groupedSections: [HoldingGroupSection] {
        switch refreshStore.holdingsGroupMode {
        case .byCategory:
            return buildCategorySections()
        case .byAccount:
            return buildAccountSections()
        }
    }

    var body: some View {
        @Bindable var bindableStore = refreshStore

        NavigationStack {
            Group {
                if holdings.isEmpty {
                    ContentUnavailableView {
                        Label("还没有记录任何资产", systemImage: "tray")
                    } description: {
                        Text("支持股票、ETF、场外基金自动拉价，以及现金、定期存单、房产等按金额记录。")
                    } actions: {
                        Button {
                            Haptics.lightImpact()
                            createRequest = CreateHoldingRequest(category: nil, account: nil, pool: .investable)
                        } label: {
                            Label("新增第一笔资产", systemImage: "plus.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemGroupedBackground))
                } else {
                    List {
                        // 顶部控制栏：仅在有资产时展示，且按需展示下钻提示条 / 双池胶囊
                        Section {
                            VStack(spacing: 10) {
                                if let drilldown = refreshStore.activeDrilldown {
                                    drilldownBanner(drilldown)
                                } else {
                                    Picker("分组维度", selection: $bindableStore.holdingsGroupMode) {
                                        ForEach(HoldingsGroupMode.allCases) { mode in
                                            Text(mode.rawValue).tag(mode)
                                        }
                                    }
                                    .pickerStyle(.segmented)
                                    .onChange(of: refreshStore.holdingsGroupMode) { _, _ in
                                        Haptics.selection()
                                    }

                                    if hasBothPools {
                                        HStack(spacing: 8) {
                                            ForEach(PoolFilterOption.allCases) { opt in
                                                filterChip(opt)
                                            }
                                            Spacer()
                                            Text(Formatters.currency(filteredHoldings.reduce(0) { $0 + $1.marketValue }, hidden: refreshStore.hideAmounts, compact: true))
                                                .font(.caption.weight(.medium))
                                                .monospacedDigit()
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))

                        if groupedSections.isEmpty {
                            Section {
                                ContentUnavailableView {
                                    Label("无匹配资产", systemImage: "magnifyingglass")
                                } description: {
                                    Text("换个关键词，或清除当前筛选条件。")
                                } actions: {
                                    if refreshStore.activeDrilldown != nil || refreshStore.holdingsPoolFilter != .all || !searchText.isEmpty {
                                        Button("显示全部资产") {
                                            Haptics.selection()
                                            searchText = ""
                                            refreshStore.clearDrilldown()
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                }
                                .padding(.vertical, 16)
                            }
                        } else {
                            ForEach(groupedSections) { section in
                                Section {
                                    ForEach(section.items) { item in
                                        Button {
                                            Haptics.lightImpact()
                                            quickAdjustTarget = item
                                        } label: {
                                            HoldingRowView(
                                                holding: item,
                                                groupMode: refreshStore.holdingsGroupMode,
                                                hideAmounts: refreshStore.hideAmounts,
                                                pnlColorScheme: refreshStore.pnlColorScheme
                                            )
                                        }
                                        .buttonStyle(.plain)
                                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                            if item.supportsQuoteRefresh {
                                                Button {
                                                    Task {
                                                        await refreshStore.refreshSingleHolding(item, in: modelContext)
                                                    }
                                                } label: {
                                                    Label("刷新现价", systemImage: "arrow.clockwise")
                                                }
                                                .tint(.blue)
                                            }
                                        }
                                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                            Button(role: .destructive) {
                                                Haptics.lightImpact()
                                                pendingDeleteHolding = item
                                            } label: {
                                                Label("删除", systemImage: "trash")
                                            }

                                            Button {
                                                Haptics.lightImpact()
                                                fullEditTarget = item
                                            } label: {
                                                Label("编辑", systemImage: "pencil")
                                            }
                                            .tint(.indigo)
                                        }
                                    }
                                } header: {
                                    sectionHeader(section)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .searchable(text: $searchText, prompt: "搜索名称、代码、分类或账户")
                    .refreshable {
                        if hasRefreshableHoldings {
                            await refreshStore.refreshAllQuotes(holdings: holdings, in: modelContext, silent: false)
                        }
                    }
                }
            }
            .navigationTitle("资产")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 14) {
                        if !holdings.isEmpty {
                            Button {
                                Haptics.selection()
                                refreshStore.hideAmounts.toggle()
                            } label: {
                                Image(systemName: refreshStore.hideAmounts ? "eye.slash" : "eye")
                            }
                            .accessibilityLabel(refreshStore.hideAmounts ? "显示金额" : "隐藏金额")
                        }

                        if hasRefreshableHoldings {
                            Button {
                                Task {
                                    await refreshStore.refreshAllQuotes(holdings: holdings, in: modelContext, silent: false)
                                }
                            } label: {
                                if refreshStore.isRefreshing {
                                    ProgressView()
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                            }
                            .disabled(refreshStore.isRefreshing)
                            .accessibilityLabel("刷新行情")
                        }

                        Button {
                            Haptics.lightImpact()
                            let defaultPool: AssetPool = (refreshStore.holdingsPoolFilter == .fixed) ? .fixed : .investable
                            createRequest = CreateHoldingRequest(category: nil, account: nil, pool: defaultPool)
                        } label: {
                            Image(systemName: "plus")
                                .fontWeight(.semibold)
                        }
                        .accessibilityLabel("新增资产")
                    }
                }
            }
            .sheet(item: $quickAdjustTarget, onDismiss: {
                if let nextEdit = queuedFullEditTarget {
                    queuedFullEditTarget = nil
                    fullEditTarget = nextEdit
                }
            }) { target in
                QuickAdjustHoldingSheet(holding: target) {
                    queuedFullEditTarget = target
                }
            }
            .sheet(item: $fullEditTarget) { target in
                HoldingFormSheet(existingHolding: target)
            }
            .sheet(item: $createRequest) { req in
                HoldingFormSheet(
                    existingHolding: nil,
                    preselectedCategory: req.category,
                    preselectedAccount: req.account,
                    preselectedPool: req.pool
                )
            }
            .confirmationDialog(
                "确认删除「\(pendingDeleteHolding?.name ?? "")」？",
                isPresented: Binding(
                    get: { pendingDeleteHolding != nil },
                    set: { if !$0 { pendingDeleteHolding = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("删除（5 秒内可撤销）", role: .destructive) {
                    if let target = pendingDeleteHolding {
                        refreshStore.deleteHoldingWithUndo(target, in: modelContext)
                    }
                    pendingDeleteHolding = nil
                }
                Button("取消", role: .cancel) {
                    pendingDeleteHolding = nil
                }
            }
            .onChange(of: hasBothPools) { _, both in
                if !both && refreshStore.activeDrilldown == nil {
                    refreshStore.holdingsPoolFilter = .all
                }
            }
        }
    }

    private func drilldownBanner(_ drilldown: HoldingsDrilldownFilter) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .foregroundStyle(Color.accentColor)
            Text("筛选：\(drilldown.label)")
                .font(.subheadline.weight(.medium))
            Spacer()
            Button {
                withAnimation(.snappy) {
                    refreshStore.clearDrilldown()
                }
            } label: {
                Label("显示全部", systemImage: "xmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func filterChip(_ option: PoolFilterOption) -> some View {
        let selected = refreshStore.holdingsPoolFilter == option
        return Button {
            Haptics.selection()
            withAnimation(.snappy) {
                // 再按已选胶囊即可收回恢复「全部」
                if selected && option != .all {
                    refreshStore.holdingsPoolFilter = .all
                } else {
                    refreshStore.holdingsPoolFilter = option
                }
            }
        } label: {
            Text(option.rawValue)
                .font(.caption.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(
                    selected ? Color.accentColor : Color(.secondarySystemGroupedBackground),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }

    private func sectionHeader(_ section: HoldingGroupSection) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Text(section.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .textCase(nil)

            if let badge = section.badgeText {
                Text(badge)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .textCase(nil)
            }

            if let sub = section.subtitleText {
                Text(sub)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .textCase(nil)
            }

            Spacer()

            Text(Formatters.currency(section.subtotal, hidden: refreshStore.hideAmounts))
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .textCase(nil)

            if section.category != nil || section.account != nil {
                Button {
                    Haptics.lightImpact()
                    createRequest = CreateHoldingRequest(
                        category: section.category,
                        account: section.account,
                        pool: section.category?.pool ?? .investable
                    )
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(Color.accentColor.opacity(0.85))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("在\(section.title)下新增资产")
            }
        }
    }

    // MARK: - 分组组装

    private func buildCategorySections() -> [HoldingGroupSection] {
        var result: [HoldingGroupSection] = []
        for cat in categories {
            let items = filteredHoldings.filter { $0.category?.id == cat.id }
            guard !items.isEmpty else { continue }
            let sum = items.reduce(0.0) { $0 + $1.marketValue }

            var ratioNote: String? = nil
            if cat.pool == .investable && investableTotal > 0 {
                let actualPct = (sum / investableTotal) * 100.0
                if let target = cat.targetRatio {
                    ratioNote = "\(Formatters.percentPoints(actualPct)) / 目标\(Formatters.percentPoints(target, digits: 0))"
                } else {
                    ratioNote = Formatters.percentPoints(actualPct)
                }
            }

            result.append(
                HoldingGroupSection(
                    id: "cat-\(cat.id.uuidString)",
                    title: cat.name,
                    badgeText: cat.pool == .fixed ? "固定资产" : nil,
                    subtitleText: ratioNote,
                    subtotal: sum,
                    category: cat,
                    account: nil,
                    items: items
                )
            )
        }

        let uncategorized = filteredHoldings.filter { $0.category == nil }
        if !uncategorized.isEmpty {
            result.append(
                HoldingGroupSection(
                    id: "cat-none",
                    title: "未分类",
                    badgeText: nil,
                    subtitleText: nil,
                    subtotal: uncategorized.reduce(0.0) { $0 + $1.marketValue },
                    category: nil,
                    account: nil,
                    items: uncategorized
                )
            )
        }
        return result
    }

    private func buildAccountSections() -> [HoldingGroupSection] {
        var result: [HoldingGroupSection] = []
        for acc in accounts {
            let items = filteredHoldings.filter { $0.account?.id == acc.id }
            guard !items.isEmpty else { continue }
            let sum = items.reduce(0.0) { $0 + $1.marketValue }
            result.append(
                HoldingGroupSection(
                    id: "acc-\(acc.id.uuidString)",
                    title: acc.name,
                    badgeText: acc.subtitle.isEmpty ? nil : acc.subtitle,
                    subtitleText: nil,
                    subtotal: sum,
                    category: nil,
                    account: acc,
                    items: items
                )
            )
        }

        let unassigned = filteredHoldings.filter { $0.account == nil }
        if !unassigned.isEmpty {
            result.append(
                HoldingGroupSection(
                    id: "acc-none",
                    title: "未指定账户",
                    badgeText: nil,
                    subtitleText: nil,
                    subtotal: unassigned.reduce(0.0) { $0 + $1.marketValue },
                    category: nil,
                    account: nil,
                    items: unassigned
                )
            )
        }
        return result
    }
}
