import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// JSON 本地备份顶层结构（纯值类型，跨版本向后兼容）
struct BackupPayload: Codable {
    var schemaVersion: Int = 1
    var exportedAt: Date
    var categories: [CategoryDTO]
    var accounts: [AccountDTO]
    var holdings: [HoldingDTO]

    struct CategoryDTO: Codable {
        var id: UUID
        var name: String
        var poolRaw: String
        var colorTokenRaw: String
        var iconName: String
        var targetRatio: Double?
        var sortOrder: Int
        var createdAt: Date
    }

    struct AccountDTO: Codable {
        var id: UUID
        var name: String
        var subtitle: String
        var colorTokenRaw: String
        var iconName: String
        var sortOrder: Int
        var createdAt: Date
    }

    struct HoldingDTO: Codable {
        var id: UUID
        var name: String
        var valuationModeRaw: String
        var code: String
        var shares: Double
        var latestPrice: Double
        var manualAmount: Double
        var totalCost: Double?
        var priceDateText: String
        var lastUpdated: Date
        var note: String
        var sortOrder: Int
        var fallbackPoolRaw: String
        var annualRate: Double? = nil
        var startDate: Date? = nil
        var maturityDate: Date? = nil
        var categoryID: UUID?
        var accountID: UUID?
    }
}

/// 适配系统 `.fileExporter` 的 JSON 文档封装
struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(payload: BackupPayload) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.data = try encoder.encode(payload)
    }

    init(configuration: ReadConfiguration) throws {
        guard let fileData = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = fileData
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
