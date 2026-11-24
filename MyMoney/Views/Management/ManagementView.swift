import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Tab 3：分类/账户管理、外观偏好与离线 JSON 备份恢复页
struct ManagementView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PortfolioRefreshStore.self) private var refreshStore

    @Query(sort: \AssetCategory.sortOrder) private var categories: [AssetCategory]
    @Query(sort: \AssetAccount.sortOrder) private var accounts: [AssetAccount]
    @Query(sort: \AssetHolding.sortOrder) private var holdings: [AssetHolding]

    @State private var exportDocument: BackupDocument?
    @State private var showingFileExporter = false
    @State private var showingFileImporter = false

    @State private var pendingImportData: Data?
    @State private var showingRestoreConfirm = false
    @State private var showingClearHoldingsConfirm = false

    @State private var alertTitle: String = ""
    @State private var alertMessage: String?

    var body: some View {
        @Bindable var bindableStore = refreshStore

        NavigationStack {
            List {
                // 1. 字典维度管理
                Section("分类与账户字典") {
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
                        prepareAndExportBackup()
                    } label: {
                        Label("导出 JSON 备份文件", systemImage: "square.and.arrow.up")
                    }

                    Button {
                        showingFileImporter = true
                    } label: {
                        Label("从 JSON 备份恢复数据", systemImage: "square.and.arrow.down")
                    }
                } header: {
                    Text("本地数据备份")
                } footer: {
                    Text("所有资产数据 100% 存储在手机本地，无需注册或上传云端。更换手机或重装前建议导出 JSON 备份至 iCloud 云盘或文件 App。")
                }

                // 4. 辅助与清空
                Section("数据维护") {
                    Button {
                        do {
                            try DataBackupService.loadSampleShowcase(in: modelContext)
                            showAlert(title: "已载入演示数据", message: "包含投资资产与一笔 100 万固定底仓示例，可在总览页查看双池隔离效果。")
                        } catch {
                            showAlert(title: "载入失败", message: error.localizedDescription)
                        }
                    } label: {
                        Label("追加演示数据", systemImage: "wand.and.stars")
                    }

                    Button(role: .destructive) {
                        showingClearHoldingsConfirm = true
                    } label: {
                        Label("清空全部持仓记录", systemImage: "trash")
                    }
                    .disabled(holdings.isEmpty)
                }

                Section {
                    HStack {
                        Text("存储模式")
                        Spacer()
                        Text("SwiftData 纯本地存储")
                            .foregroundStyle(.secondary)
                    }
                    .font(.footnote)

                    HStack {
                        Text("行情数据源")
                        Spacer()
                        Text("腾讯行情 / 天天基金官方净值")
                            .foregroundStyle(.secondary)
                    }
                    .font(.footnote)
                } header: {
                    Text("关于")
                }
            }
            .navigationTitle("管理")
            .fileExporter(
                isPresented: $showingFileExporter,
                document: exportDocument,
                contentType: .json,
                defaultFilename: Formatters.backupFilename()
            ) { result in
                switch result {
                case .success:
                    showAlert(title: "备份导出成功", message: "JSON 备份文件已保存。")
                case .failure(let error):
                    showAlert(title: "导出失败", message: error.localizedDescription)
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
                "确认用备份文件覆盖当前全部数据？",
                isPresented: $showingRestoreConfirm,
                titleVisibility: .visible
            ) {
                Button("确认覆盖并恢复", role: .destructive) {
                    performRestore()
                }
                Button("取消", role: .cancel) {
                    pendingImportData = nil
                }
            } message: {
                Text("当前手机上的所有分类、账户与持仓将被替换为备份文件中的内容。")
            }
            .confirmationDialog(
                "确认清空全部 \(holdings.count) 项持仓？",
                isPresented: $showingClearHoldingsConfirm,
                titleVisibility: .visible
            ) {
                Button("清空持仓（保留分类和账户）", role: .destructive) {
                    do {
                        try DataBackupService.clearAllHoldings(in: modelContext)
                    } catch {
                        showAlert(title: "清空失败", message: error.localizedDescription)
                    }
                }
                Button("取消", role: .cancel) {}
            }
            .alert(alertTitle, isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } }
            )) {
                Button("好", role: .cancel) { alertMessage = nil }
            } message: {
                Text(alertMessage ?? "")
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
            showAlert(title: "生成备份失败", message: error.localizedDescription)
        }
    }

    private func handleImportedFile(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            showAlert(title: "读取文件失败", message: error.localizedDescription)
        case .success(let urls):
            guard let fileURL = urls.first else { return }
            let accessed = fileURL.startAccessingSecurityScopedResource()
            defer {
                if accessed { fileURL.stopAccessingSecurityScopedResource() }
            }
            do {
                let data = try Data(contentsOf: fileURL)
                pendingImportData = data
                showingRestoreConfirm = true
            } catch {
                showAlert(title: "无法读取所选文件", message: error.localizedDescription)
            }
        }
    }

    private func performRestore() {
        guard let data = pendingImportData else { return }
        defer { pendingImportData = nil }

        do {
            let counts = try DataBackupService.restoreBackup(from: data, into: modelContext)
            showAlert(
                title: "恢复成功",
                message: "已成功导入 \(counts.categories) 个类别、\(counts.accounts) 个账户、\(counts.holdings) 项资产持仓。"
            )
        } catch {
            showAlert(title: "备份文件格式无效", message: error.localizedDescription)
        }
    }

    private func showAlert(title: String, message: String) {
        alertTitle = title
        alertMessage = message
    }
}
