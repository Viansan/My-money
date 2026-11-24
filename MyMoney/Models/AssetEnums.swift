import Foundation
import SwiftUI

/// 资金池归属：将「参与配置比例的投资资产」与「大额固定/底仓资产」彻底解耦
/// 避免房产、大额存单、专项底仓（如 100 万定期）稀释日常投资组合的配置占比
enum AssetPool: String, Codable, CaseIterable, Identifiable {
    case investable = "investable"
    case fixed = "fixed"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .investable:
            return "投资资产"
        case .fixed:
            return "固定/底仓"
        }
    }

    var subtitle: String {
        switch self {
        case .investable:
            return "计入投资池比例，可选填目标占比"
        case .fixed:
            return "仅计入总净值，不稀释投资组合占比"
        }
    }

    var systemImage: String {
        switch self {
        case .investable:
            return "chart.pie.fill"
        case .fixed:
            return "shield.lefthalf.filled"
        }
    }
}

/// 单条资产的计价模式
enum ValuationMode: String, Codable, CaseIterable, Identifiable {
    /// 直接记录当前总金额（适用于现金、存款、银行理财、房产、公积金等）
    case manualAmount = "manualAmount"
    /// 场内证券：按「股数/份额 × 最新现价」计价，支持拉取沪深京港美实时行情
    case exchangeSecurity = "exchangeSecurity"
    /// 场外基金：按「持有份额 × 最新官方单位净值」计价，兼容普通公募、债基与 QDII
    case otcFund = "otcFund"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manualAmount:
            return "直接填金额"
        case .exchangeSecurity:
            return "场内证券"
        case .otcFund:
            return "场外基金"
        }
    }

    var shortBadge: String {
        switch self {
        case .manualAmount:
            return "金额"
        case .exchangeSecurity:
            return "场内"
        case .otcFund:
            return "场外"
        }
    }

    var codePlaceholder: String {
        switch self {
        case .manualAmount:
            return ""
        case .exchangeSecurity:
            return "如 515800、159915、00700、SPY"
        case .otcFund:
            return "6 位基金代码，如 050025、003376"
        }
    }

    var usesSharesAndPrice: Bool {
        self != .manualAmount
    }
}

/// 分类与账户可选配色（针对 iOS 浅色/深色模式调校对比度）
enum CategoryColorToken: String, Codable, CaseIterable, Identifiable {
    case blue
    case teal
    case green
    case indigo
    case amber
    case orange
    case coral
    case purple
    case cyan
    case slate

    var id: String { rawValue }

    var label: String {
        switch self {
        case .blue: return "深海蓝"
        case .teal: return "青碧色"
        case .green: return "翡翠绿"
        case .indigo: return "靛青色"
        case .amber: return "琥珀金"
        case .orange: return "暖阳橙"
        case .coral: return "珊瑚红"
        case .purple: return "暮光紫"
        case .cyan: return "晴空青"
        case .slate: return "岩石灰"
        }
    }

    var color: Color {
        switch self {
        case .blue:
            return Color(red: 0.16, green: 0.48, blue: 0.96)
        case .teal:
            return Color(red: 0.08, green: 0.68, blue: 0.64)
        case .green:
            return Color(red: 0.16, green: 0.72, blue: 0.45)
        case .indigo:
            return Color(red: 0.36, green: 0.38, blue: 0.90)
        case .amber:
            return Color(red: 0.92, green: 0.65, blue: 0.12)
        case .orange:
            return Color(red: 0.95, green: 0.48, blue: 0.20)
        case .coral:
            return Color(red: 0.91, green: 0.33, blue: 0.38)
        case .purple:
            return Color(red: 0.62, green: 0.36, blue: 0.88)
        case .cyan:
            return Color(red: 0.12, green: 0.66, blue: 0.88)
        case .slate:
            return Color(red: 0.45, green: 0.52, blue: 0.62)
        }
    }
}

/// 盈亏涨跌颜色偏好
enum PnLColorScheme: String, Codable, CaseIterable, Identifiable {
    case redUpGreenDown = "redUpGreenDown"
    case greenUpRedDown = "greenUpRedDown"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .redUpGreenDown:
            return "红涨绿跌（A股习惯）"
        case .greenUpRedDown:
            return "绿涨红跌（国际习惯）"
        }
    }

    func color(for delta: Double) -> Color {
        if abs(delta) < 0.0001 {
            return .secondary
        }
        switch self {
        case .redUpGreenDown:
            return delta > 0 ? Color(red: 0.88, green: 0.24, blue: 0.26) : Color(red: 0.13, green: 0.66, blue: 0.40)
        case .greenUpRedDown:
            return delta > 0 ? Color(red: 0.13, green: 0.66, blue: 0.40) : Color(red: 0.88, green: 0.24, blue: 0.26)
        }
    }
}

/// 外观模式偏好
enum AppThemeMode: String, Codable, CaseIterable, Identifiable {
    case system = "system"
    case light = "light"
    case dark = "dark"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// 成本录入辅助切换（最终统一折算为投入总本金持久化）
enum CostEntryStyle: String, CaseIterable, Identifiable {
    case totalPrincipal = "totalPrincipal"
    case unitCostPrice = "unitCostPrice"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .totalPrincipal: return "按投入本金"
        case .unitCostPrice: return "按成本单价"
        }
    }
}

/// SF Symbols 预设图标库
enum PresetIcons {
    static let categoryIcons: [String] = [
        "chart.pie.fill",
        "chart.line.uptrend.xyaxis",
        "globe.americas.fill",
        "shield.lefthalf.filled",
        "banknote.fill",
        "building.columns.fill",
        "lock.doc.fill",
        "house.fill",
        "car.fill",
        "sparkles",
        "leaf.fill",
        "briefcase.fill"
    ]

    static let accountIcons: [String] = [
        "building.columns.fill",
        "chart.bar.xaxis",
        "creditcard.fill",
        "wallet.pass.fill",
        "iphone.gen3",
        "globe.asia.australia.fill",
        "lock.shield.fill",
        "folder.fill"
    ]
}
