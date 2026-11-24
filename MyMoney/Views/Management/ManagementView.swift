import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Tab 3：分类/账户管理、外观偏好与离线 JSON 备份恢复页
/// - 常规成功提示改用非阻塞 Toast，不打断用户操作
/// - 导入恢复前先预解析备份，确认弹窗里明示备份时间与条数
/// - 真实资产非空时隐藏演示数据按钮，防止误碰污染账本；危险清空独立隔离
struct ManagementView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PortfolioRefreshStore.self) private var refreshStore

    @Query(sort: \AssetCategory.sortOrder) private var categories: [AssetCategory]
    @Query(sort: \AssetAccount.sortOrder) private var accounts: [AssetAccount]
    @Query(sort: \AssetHolding.sortOrder) private var holdings: [AssetHolding]

    @State private var exportDocument: BackupDocument?
    @State private var showingFileExporter = false
    @State private var showingFileImporter = false

    @State private var pendingImportPayload: BackupPayload?
    @State private var showingRestoreConfirm = false
    @State private var showingClearHoldingsConfirm = false

    @State private var errorAlertMessage: String?

    private var totalAmount: Double {
        holdings.reduce(0.0) { $0 + $1.marketValue }
    }

    var body: some View {
        @Bindable var bindableStore = refreshStore

        NavigationStack {
            List {
                // 1. 字典维度管理
                Section("分类与账户") {
                    NavigationLink {
                        CategoryListView()
                    } label: {
                        HStack {
                            Label("资产类别管理", systemImage: "square.grid.2x2.fill")
                            Spacer()
                            Text("\(categories.count) 个类别")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    NavigationLink {
                        AccountListView()
                    } label: {
                        HStack {
                            Label("账户/渠道管理", systemImage: "building.columns.fill")
                            Spacer()
                            Text("\(accounts.count) 个账户")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // 2. 显示与偏好设置
                Section("显示与偏好") {
                    Picker("盈亏颜色", selection: $bindableStore.pnlColorScheme) {
                        ForEach(PnLColorScheme.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }

                    Picker("外观模式", selection: $bindableStore.themeMode) {
                        ForEach(AppThemeMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }

                    Toggle("隐藏具体金额（隐私模式）", isOn: $bindableStore.hideAmounts)
                }

                // 3. 本地 JSON 备份与恢复
                Section {
                    Button {
                        Haptics.lightImpact()
                        prepareAndExportBackup()
                    } label: {
                        Label("导出 JSON 备份文件", systemImage: "square.and.arrow.up")
                    }

                    Button {
                        Haptics.lightImpact()
                        showingFileImporter = true
                    } label: {
                        Label("从 JSON 备份恢复数据", systemImage: "square.and.arrow.down")
                    }
                } header: {
                    Text("本地备份")
                } footer: {
                    Text("数据 100% 存在本机，不上传云端。换机或重装前建议导出备份至「文件」或 iCloud 云盘。")
                }

                // 4. 空账本时才出现演示体验入口（已有真实资产后隐藏，杜绝误点污染账本）
                if holdings.isEmpty {
                    Section("快速体验") {
                        Button {
                            do {
                                try DataBackupService.loadSampleShowcase(in: modelContext)
                                Haptics.success()
                                refreshStore.showToast(
                                    style: .success,
                                    message: "已载入演示数据，可去「总览」查看双池隔离效果",
                                    autoDismissSeconds: 3.0
                                )
                            } catch {
                                errorAlertMessage = error.localizedDescription
                            }
                        } label: {
                            Label("载入演示数据", systemImage: "wand.and.stars")
                        }
                    }
                }

                Section {
                    HStack {
                        Text("存储方式")
                        Spacer()
                        Text("SwiftData 纯本地")
                            .foregroundStyle(.secondary)
                    }
                    .font(.footnote)

                    HStack {
                        Text("行情来源")
                        Spacer()
                        Text("腾讯行情 · 东财官方净值")
                            .foregroundStyle(.secondary)
                    }
                    .font(.footnote)
                } header: {
                    Text("关于")
                }

                // 5. 危险操作独立隔离在页面最底部，且仅在有持仓时出现
                if !holdings.isEmpty {
                    Section {
                        Button(role: .destructive) {
                            Haptics.warning()
                            showingClearHoldingsConfirm = true
                        } label: {
                            Label("清空全部持仓记录", systemImage: "trash")
                        }
                    } header: {
                        Text("危险操作")
                    } footer: {
                        Text("清空前建议先导出 JSON 备份。此操作会删除所有资产金额，但保留自定义分类与账户。")
                    }
                }
            }
            .listSectionSpacing(.compact)
            .navigationTitle("管理")
            .navigationBarTitleDisplayMode(.inline)
            .fileExporter(
                isPresented: $showingFileExporter,
                document: exportDocument,
                contentType: .json,
                defaultFilename: Formatters.backupFilename()
            ) { result in
                switch result {
                case .success:
                    Haptics.success()
                    refreshStore.showToast(style: .success, message: "JSON 备份文件已保存", autoDismissSeconds: 2.4)
                case .failure(let error):
                    errorAlertMessage = "导出失败：\(error.localizedDescription)"
                }
            }
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                handleImportedFile(result)
            }
            .confirmationDialog(
                "确认用备份覆盖当前全部数据？",
                isPresented: $showingRestoreConfirm,
                titleVisibility: .visible
            ) {
                Button("确认覆盖并恢复", role: .destructive) {
                    performRestore()
                }
                Button("取消", role: .cancel) {
                    pendingImportPayload = nil
                }
            } message: {
                if let payload = pendingImportPayload {
                    Text("备份时间 \(Formatters.shortDateTime(payload.exportedAt))，包含 \(payload.categories.count) 个类别、\(payload.accounts.count) 个账户、\(payload.holdings.count) 项资产。恢复将替换当前 \(holdings.count) 项资产。")
                }
            }
            .confirmationDialog(
                "确认清空全部 \(holdings.count) 项资产？",
                isPresented: $showingClearHoldingsConfirm,
                titleVisibility: .visible
            ) {
                Button("确认清空（不可撤销）", role: .destructive) {
                    do {
                        let count = holdings.count
                        try DataBackupService.clearAllHoldings(in: modelContext)
                        refreshStore.clearDrilldown()
                        Haptics.warning()
                        refreshStore.showToast(style: .info, message: "已清空 \(count) 项资产记录", autoDismissSeconds: 2.5)
                    } catch {
                        errorAlertMessage = "清空失败：\(error.localizedDescription)"
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("当前总资产 \(Formatters.currency(totalAmount, hidden: refreshStore.hideAmounts)) 将被清零，自定义的分类与账户结构会保留。")
            }
            .alert("操作失败", isPresented: Binding(
                get: { errorAlertMessage != nil },
                set: { if !$0 { errorAlertMessage = nil } }
            )) {
                Button("好", role: .cancel) { errorAlertMessage = nil }
            } message: {
                Text(errorAlertMessage ?? "")
            }
        }
    }

    private func prepareAndExportBackup() {
        let payload = DataBackupService.makeBackupPayload(
            categories: categories,
            accounts: accounts,
            holdings: holdings
        )
        do {
            exportDocument = try BackupDocument(payload: payload)
            showingFileExporter = true
        } catch {
            errorAlertMessage = "生成备份失败：\(error.localizedDescription)"
        }
    }

    private func handleImportedFile(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            errorAlertMessage = "读取文件失败：\(error.localizedDescription)"
        case .success(let urls):
            guard let fileURL = urls.first else { return }
            let accessed = fileURL.startAccessingSecurityScopedResource()
            defer {
                if accessed { fileURL.stopAccessingSecurityScopedResource() }
            }
            do {
                let data = try Data(contentsOf: fileURL)
                // 先校验解析再弹窗确认，让用户看到确切的备份内容摘要
                let parsed = try DataBackupService.parseBackup(from: data)
                pendingImportPayload = parsed
                showingRestoreConfirm = true
            } catch {
                Haptics.warning()
                errorAlertMessage = "所选文件不是有效的「我的资产」JSON 备份文件。"
            }
        }
    }

    private func performRestore() {
        guard let payload = pendingImportPayload else { return }
        defer { pendingImportPayload = nil }

        do {
            let counts = try DataBackupService.restoreBackup(payload: payload, into: modelContext)
            refreshStore.clearDrilldown()
            Haptics.success()
            refreshStore.showToast(
                style: .success,
                message: "已恢复 \(counts.holdings) 项资产、\(counts.categories) 个类别、\(counts.accounts) 个账户",
                autoDismissSeconds: 3.0
            )
        } catch {
            Haptics.warning()
            errorAlertMessage = "恢复失败：\(error.localizedDescription)"
        }
    }
}
