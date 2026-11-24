import SwiftUI
import SwiftData

/// 资金池筛选胶囊枚举
enum PoolFilterOption: String, CaseIterable, Identifiable {
    case all = "全部"
    case investable = "投资资产"
    case fixed = "固定/底仓"

    var id: String { rawValue }
}

/// 分组渲染载体
private struct HoldingGroupSection: Identifiable {
    let id: String
    let title: String
    let badgeText: String?
    let subtitleText: String?
    let subtotal: Double
    let items: [AssetHolding]
}

/// Tab 2：资产明细与对账工作台
/// 支持「按类别 / 按账户对账」一键切换、资金池筛选、搜索、轻点改数、左滑删除与下拉刷新全部行情
struct HoldingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PortfolioRefreshStore.self) private var refreshStore

    @Query(sort: \AssetHolding.sortOrder) private var holdings: [AssetHolding]
    @Query(sort: \AssetCategory.sortOrder) private var categories: [AssetCategory]
    @Query(sort: \AssetAccount.sortOrder) private var accounts: [AssetAccount]

    @State private var groupMode: HoldingsGroupMode = .byCategory
    @State private var poolFilter: PoolFilterOption = .all
    @State private var searchText: String = ""

    @State private var quickAdjustTarget: AssetHolding?
    @State private var fullEditTarget: AssetHolding?
    @State private var showingCreateSheet = false
    @State private var pendingDeleteHolding: AssetHolding?

    private var investableTotal: Double {
        holdings.filter { $0.effectivePool == .investable }.reduce(0.0) { $0 + $1.marketValue }
    }

    private var filteredHoldings: [AssetHolding] {
        holdings.filter { item in
            let matchesPool: Bool
            switch poolFilter {
            case .all:
                matchesPool = true
            case .investable:
                matchesPool = item.effectivePool == .investable
            case .fixed:
                matchesPool = item.effectivePool == .fixed
            }
            guard matchesPool else { return false }

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
        switch groupMode {
        case .byCategory:
            return buildCategorySections()
        case .byAccount:
            return buildAccountSections()
        }
    }

    var body: some View {
        NavigationStack {
            List {
                // 顶部双维度切换与资金池筛选栏
                Section {
                    VStack(spacing: 10) {
                        Picker("分组维度", selection: $groupMode) {
                            ForEach(HoldingsGroupMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)

                        HStack(spacing: 8) {
                            ForEach(PoolFilterOption.allCases) { opt in
                                filterChip(opt)
                            }
                            Spacer()
                            Text("小计 \(Formatters.currency(filteredHoldings.reduce(0) { $0 + $1.marketValue }, hidden: refreshStore.hideAmounts, compact: true))")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))

                if groupedSections.isEmpty {
                    Section {
                        ContentUnavailableView {
                            Label(holdings.isEmpty ? "暂无资产持仓" : "无匹配资产", systemImage: "tray")
                        } description: {
                            Text(holdings.isEmpty ? "点击右上角「+」录入股票、基金、现金或固定底仓。" : "尝试切换上方筛选条件或修改搜索关键词。")
                        } actions: {
                            if holdings.isEmpty {
                                Button("新增资产") {
                                    showingCreateSheet = true
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                        .padding(.vertical, 20)
                    }
                } else {
                    ForEach(groupedSections) { section in
                        Section {
                            ForEach(section.items) { item in
                                Button {
                                    quickAdjustTarget = item
                                } label: {
                                    HoldingRowView(
                                        holding: item,
                                        groupMode: groupMode,
                                        hideAmounts: refreshStore.hideAmounts,
                                        pnlColorScheme: refreshStore.pnlColorScheme
                                    )
                                }
                                .buttonStyle(.plain)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        pendingDeleteHolding = item
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }

                                    Button {
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
            .navigationTitle("资产")
            .searchable(text: $searchText, prompt: "搜索名称、代码、分类或账户")
            .refreshable {
                await refreshStore.refreshAllQuotes(holdings: holdings, in: modelContext)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 14) {
                        Button {
                            Task {
                                await refreshStore.refreshAllQuotes(holdings: holdings, in: modelContext)
                            }
                        } label: {
                            if refreshStore.isRefreshing {
                                ProgressView()
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .disabled(refreshStore.isRefreshing)

                        Button {
                            showingCreateSheet = true
                        } label: {
                            Image(systemName: "plus")
                                .fontWeight(.semibold)
                        }
                    }
                }
            }
            .sheet(item: $quickAdjustTarget) { target in
                QuickAdjustHoldingSheet(holding: target) {
                    fullEditTarget = target
                }
            }
            .sheet(item: $fullEditTarget) { target in
                HoldingFormSheet(existingHolding: target)
            }
            .sheet(isPresented: $showingCreateSheet) {
                HoldingFormSheet(existingHolding: nil)
            }
            .confirmationDialog(
                "确认删除「\(pendingDeleteHolding?.name ?? "")」？",
                isPresented: Binding(
                    get: { pendingDeleteHolding != nil },
                    set: { if !$0 { pendingDeleteHolding = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) {
                    if let target = pendingDeleteHolding {
                        modelContext.delete(target)
                        try? modelContext.save()
                    }
                    pendingDeleteHolding = nil
                }
                Button("取消", role: .cancel) {
                    pendingDeleteHolding = nil
                }
            }
        }
    }

    private func filterChip(_ option: PoolFilterOption) -> some View {
        let selected = poolFilter == option
        return Button {
            withAnimation(.snappy) { poolFilter = option }
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
        HStack(alignment: .firstTextBaseline, spacing: 6) {
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
                    badgeText: cat.pool == .fixed ? "固定/底仓" : nil,
                    subtitleText: ratioNote,
                    subtotal: sum,
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
                    items: unassigned
                )
            )
        }
        return result
    }
}
