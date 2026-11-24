import SwiftUI
import SwiftData

@main
struct MyMoneyApp: App {
    private let sharedModelContainer: ModelContainer = {
        let schema = Schema([
            AssetCategory.self,
            AssetAccount.self,
            AssetHolding.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("无法初始化本地 SwiftData 数据库: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
        .modelContainer(sharedModelContainer)
    }
}
