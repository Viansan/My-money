import Foundation
import SwiftUI

/// 统一数字格式化与输入解析工具
enum Formatters {
    private static let currencyFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f
    }()

    private static let compactCurrencyFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f
    }()

    private static let shareFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 2
        return f
    }()

    private static let unitPriceFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 3
        f.maximumFractionDigits = 4
        return f
    }()

    private static let shortTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    private static let backupFileDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmm"
        return f
    }()

    /// 格式化人民币金额（支持隐私隐藏掩码）
    static func currency(_ value: Double, hidden: Bool = false, compact: Bool = false) -> String {
        if hidden {
            return "¥ ••••••"
        }
        let safeValue = value.isFinite ? value : 0
        let sign = safeValue < 0 ? "-" : ""
        let absVal = abs(safeValue)

        if compact && absVal >= 100_000 {
            let wan = absVal / 10_000.0
            let formatted = compactCurrencyFormatter.string(from: NSNumber(value: wan)) ?? String(format: "%.2f", wan)
            return "\(sign)¥\(formatted)万"
        }

        let formatted = currencyFormatter.string(from: NSNumber(value: absVal)) ?? String(format: "%.2f", absVal)
        return "\(sign)¥\(formatted)"
    }

    /// 格式化带正负号的盈亏金额
    static func signedCurrency(_ value: Double, hidden: Bool = false) -> String {
        if hidden {
            return "••••"
        }
        let safeValue = value.isFinite ? value : 0
        let prefix = safeValue > 0.004 ? "+" : (safeValue < -0.004 ? "-" : "")
        let absVal = abs(safeValue)
        let formatted = currencyFormatter.string(from: NSNumber(value: absVal)) ?? String(format: "%.2f", absVal)
        return "\(prefix)¥\(formatted)"
    }

    /// 格式化百分比（输入 0 ~ 100 的百分点数，如 30.5 -> "30.5%"）
    static func percentPoints(_ points: Double, digits: Int = 1) -> String {
        let safe = points.isFinite ? points : 0
        return String(format: "%.\(digits)f%%", safe)
    }

    /// 格式化带正负号的偏差百分点数（如 +2.3% / -1.8%）
    static func signedPercentPoints(_ points: Double, digits: Int = 1) -> String {
        let safe = points.isFinite ? points : 0
        if abs(safe) < 0.05 {
            return "0.0%"
        }
        return String(format: "%+.\(digits)f%%", safe)
    }

    /// 格式化收益率比例（输入如 0.0825 -> "+8.25%"）
    static func signedRate(_ ratio: Double, hidden: Bool = false) -> String {
        if hidden {
            return "••%"
        }
        let pct = (ratio.isFinite ? ratio : 0) * 100.0
        if abs(pct) < 0.005 {
            return "0.00%"
        }
        return String(format: "%+.2f%%", pct)
    }

    /// 格式化持有份额/股数
    static func shares(_ value: Double, hidden: Bool = false) -> String {
        if hidden {
            return "••••"
        }
        return shareFormatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    /// 格式化证券/基金单价（保留 3~4 位小数）
    static func unitPrice(_ value: Double) -> String {
        unitPriceFormatter.string(from: NSNumber(value: value)) ?? String(format: "%.4f", value)
    }

    /// 输入框初始回填纯数字字符串（去除多余尾随零与千分位，方便键盘编辑）
    static func editableDecimal(_ value: Double, maxDecimals: Int = 4) -> String {
        if abs(value) < 0.0000001 {
            return "0"
        }
        let raw = String(format: "%.\(maxDecimals)f", value)
        var trimmed = raw
        while trimmed.contains(".") && (trimmed.hasSuffix("0") || trimmed.hasSuffix(".")) {
            let last = trimmed.removeLast()
            if last == "." { break }
        }
        return trimmed
    }

    /// 解析用户输入的数字文本（兼容千分位逗号、空格、人民币符号与正负号）
    static func parseDouble(_ text: String) -> Double? {
        let cleaned = text
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "，", with: "")
            .replacingOccurrences(of: "¥", with: "")
            .replacingOccurrences(of: "￥", with: "")
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return Double(cleaned)
    }

    static func shortDateTime(_ date: Date) -> String {
        shortTimeFormatter.string(from: date)
    }

    static func backupFilename(date: Date = .now) -> String {
        "MyMoney_Backup_\(backupFileDateFormatter.string(from: date)).json"
    }
}
