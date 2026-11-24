import SwiftUI
import SwiftData

/// 主 Tab 容器视图（3 个极简原生 Tab：总览 / 资产 / 管理）
struct RootTabView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var refreshStore = PortfolioRefreshStore()

    var body: some View {
        TabView {
            OverviewView()
                .tabItem {
                    Label("总览", systemImage: "chart.pie.fill")
                }

            HoldingsView()
                .tabItem {
                    Label("资产", systemImage: "list.bullet.rectangle.portrait.fill")
                }

            ManagementView()
                .tabItem {
                    Label("管理", systemImage: "slider.horizontal.3")
                }
        }
        .environment(refreshStore)
        .preferredColorScheme(refreshStore.themeMode.preferredColorScheme)
        .task {
            DataBackupService.ensureBaseDictionariesIfNeeded(in: modelContext)
        }
    }
}
