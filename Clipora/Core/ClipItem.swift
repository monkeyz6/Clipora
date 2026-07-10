import Foundation
import GRDB

enum ClipType: String, Codable {
    case text
    case image
    case file
}

enum ClipSubtype: String, Codable {
    case url
    case command
    case hash
    case plain
}

struct ClipItem: Identifiable, Equatable {
    var id: Int64?
    var type: ClipType
    var subtype: ClipSubtype?
    var content: String?      // 文本内容，或文件路径列表(JSON)
    var thumbnail: Data?
    var imagePath: String?
    var contentHash: String
    var isFavorite: Bool
    var favSortOrder: Int?
    var createdAt: Date
    var sourceApp: String? = nil   // 来源应用 bundle id（文本行显示其图标）
    var alias: String? = nil       // 用户自定义别名：只改展示、不改原始内容（复制仍用 content）
    var groupId: Int64? = nil      // 所属收藏分组（clip_groups.id），nil = 未分组；仅收藏页有意义

    /// 文件类型条目的路径列表（content 存 JSON 数组）
    var filePaths: [String] {
        guard type == .file, let data = content?.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    /// 列表单行展示文字（原始内容派生，别名的兜底与 tooltip 原文）
    var displayText: String {
        switch type {
        case .text:
            return (content ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
        case .image:
            return L("图片", "Image")
        case .file:
            let names = filePaths.map { ($0 as NSString).lastPathComponent }
            return names.joined(separator: ", ")
        }
    }

    /// 别名归一化：去空白，空串归 nil（存库与展示共用同一规则）
    static func normalizedAlias(_ alias: String?) -> String? {
        guard let alias = alias?.trimmingCharacters(in: .whitespacesAndNewlines),
              !alias.isEmpty else { return nil }
        return alias
    }

    /// 去空白后的有效别名（空串视为无别名）
    var trimmedAlias: String? {
        Self.normalizedAlias(alias)
    }

    /// 行内展示：有别名显示别名，否则显示原文
    var resolvedDisplay: String {
        trimmedAlias ?? displayText
    }
}

extension ClipItem: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "items"

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case subtype
        case content
        case thumbnail
        case imagePath = "image_path"
        case contentHash = "content_hash"
        case isFavorite = "is_favorite"
        case favSortOrder = "fav_sort_order"
        case createdAt = "created_at"
        case sourceApp = "source_app"
        case alias
        case groupId = "group_id"
    }

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let type = Column(CodingKeys.type)
        static let content = Column(CodingKeys.content)
        static let contentHash = Column(CodingKeys.contentHash)
        static let isFavorite = Column(CodingKeys.isFavorite)
        static let favSortOrder = Column(CodingKeys.favSortOrder)
        static let createdAt = Column(CodingKeys.createdAt)
        static let alias = Column(CodingKeys.alias)
        static let groupId = Column(CodingKeys.groupId)
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - 收藏分组

struct ClipGroup: Identifiable, Equatable {
    var id: Int64?
    var name: String
    var sortOrder: Int
}

extension ClipGroup: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "clip_groups"

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case sortOrder = "sort_order"
    }

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let name = Column(CodingKeys.name)
        static let sortOrder = Column(CodingKeys.sortOrder)
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
