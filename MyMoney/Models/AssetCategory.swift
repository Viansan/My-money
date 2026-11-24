import Foundation
import SwiftUI
import SwiftData

/// 资产类别模型（用户可完全自由增删改排序）
/// 通过 `pool` 区分「投资资产」与「固定资产」，并支持为投资类别选填目标占比
@Model
final class AssetCategory {
    var id: UUID
    var name: String
    var poolRaw: String
    var colorTokenRaw: String
    var iconName: String
    /// 选填目标配置比例（百分比数值，如 30.0 代表 30%；nil 表示不设目标占比）
    var targetRatio: Double?
    var sortOrder: Int
    var createdAt: Date

    @Relationship(deleteRule: .nullify, inverse: \AssetHolding.category)
    var holdings: [AssetHolding]? = []

    init(
        id: UUID = UUID(),
        name: String,
        pool: AssetPool = .investable,
        colorToken: CategoryColorToken = .blue,
        iconName: String = "chart.pie.fill",
        targetRatio: Double? = nil,
        sortOrder: Int = 0,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.poolRaw = pool.rawValue
        self.colorTokenRaw = colorToken.rawValue
        self.iconName = iconName
        self.targetRatio = (pool == .investable) ? targetRatio : nil
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }

    var pool: AssetPool {
        get { AssetPool(rawValue: poolRaw) ?? .investable }
        set {
            poolRaw = newValue.rawValue
            if newValue == .fixed {
                targetRatio = nil
            }
            // 同步更新关联持仓的兜底资金池标记
            for holding in holdings ?? [] {
                holding.fallbackPoolRaw = newValue.rawValue
            }
        }
    }

    var colorToken: CategoryColorToken {
        get { CategoryColorToken(rawValue: colorTokenRaw) ?? .blue }
        set { colorTokenRaw = newValue.rawValue }
    }

    var tintColor: Color {
        colorToken.color
    }
}
