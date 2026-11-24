import Foundation
import SwiftUI
import SwiftData

/// 资产存放账户/渠道模型（如某券商、某银行、某基金平台、冷钱包或房产户头）
/// 方便按平台切换视图进行月度/季度对账
@Model
final class AssetAccount {
    var id: UUID
    var name: String
    var subtitle: String
    var colorTokenRaw: String
    var iconName: String
    var sortOrder: Int
    var createdAt: Date

    @Relationship(deleteRule: .nullify, inverse: \AssetHolding.account)
    var holdings: [AssetHolding]? = []

    init(
        id: UUID = UUID(),
        name: String,
        subtitle: String = "",
        colorToken: CategoryColorToken = .indigo,
        iconName: String = "building.columns.fill",
        sortOrder: Int = 0,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.colorTokenRaw = colorToken.rawValue
        self.iconName = iconName
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }

    var colorToken: CategoryColorToken {
        get { CategoryColorToken(rawValue: colorTokenRaw) ?? .indigo }
        set { colorTokenRaw = newValue.rawValue }
    }

    var tintColor: Color {
        colorToken.color
    }
}
