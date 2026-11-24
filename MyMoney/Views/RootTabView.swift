import SwiftUI
import SwiftData

/// 主 Tab 容器视图（3 个原生 Tab：总览 / 资产 / 管理）
/// 统一托管：1）跨页下钻路由 2）回到前台静默自动刷行情 3）全 App 一致的非阻塞 Toast 与撤销条
struct RootTabView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    @Query(sort: \AssetHolding.sortOrder) private var holdings: [AssetHolding]
    @State private var refreshStore = PortfolioRefreshStore()

    var body: some View {
        @Bindable var bindableStore = refreshStore

        ZStack(alignment: .bottom) {
            TabView(selection: $bindableStore.selectedTab) {
                OverviewView()
                    .tabItem {
                        Label("总览", systemImage: "chart.pie.fill")
                    }
                    .tag(AppTab.overview)

                HoldingsView()
                    .tabItem {
                        Label("资产", systemImage: "list.bullet.rectangle.portrait.fill")
                    }
                    .tag(AppTab.holdings)

                ManagementView()
                    .tabItem {
                        Label("管理", systemImage: "slider.horizontal.3")
                    }
                    .tag(AppTab.management)
            }

            if let toast = refreshStore.currentToast {
                ToastBannerView(
                    toast: toast,
                    onAction: toast.actionTitle == nil ? nil : {
                        withAnimation(.snappy) {
                            refreshStore.triggerToastAction()
                        }
                    },
                    onDismiss: {
                        withAnimation(.snappy) {
                            refreshStore.dismissToast()
                        }
                    }
                )
                .padding(.bottom, 60)
                .zIndex(10)
            }
        }
        .animation(.snappy(duration: 0.25), value: refreshStore.currentToast)
        .environment(refreshStore)
        .preferredColorScheme(refreshStore.themeMode.preferredColorScheme)
        .task {
            DataBackupService.ensureBaseDictionariesIfNeeded(in: modelContext)
            await refreshStore.autoRefreshIfStale(holdings: holdings, in: modelContext)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task {
                    await refreshStore.autoRefreshIfStale(holdings: holdings, in: modelContext)
                }
            }
        }
    }
}
