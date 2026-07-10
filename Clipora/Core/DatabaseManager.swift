import Foundation
import GRDB

extension Notification.Name {
    /// 数据变更（新增/删除/收藏/排序），面板监听后刷新
    static let clipStoreDidChange = Notification.Name("clipStoreDidChange")
}

final class DatabaseManager {
    static let shared = DatabaseManager()

    static let historyLimit = 500

    /// Unicode 大小写不敏感的子串匹配。SQLite 内置 LIKE 仅折叠 ASCII A-Z，
    /// 会让重音拉丁/西里尔/希腊等文本的搜索实际区分大小写，故用 Foundation 折叠。
    private static let containsCI = DatabaseFunction(
        "CLIPORA_CONTAINS_CI", argumentCount: 2, pure: true
    ) { values in
        guard let needle = String.fromDatabaseValue(values[1]) else { return false }
        if needle.isEmpty { return true }
        guard let haystack = String.fromDatabaseValue(values[0]) else { return false }
        return haystack.range(of: needle, options: [.caseInsensitive]) != nil
    }

    /// 列表查询投影：排除 thumbnail BLOB（按行懒加载），文本 content 截断为预览，
    /// 避免 500 条历史把全部缩略图/长文本一次性载入内存。
    private static let listColumns =
        "id, type, subtype, " +
        "CASE WHEN type = 'text' THEN substr(content, 1, 512) ELSE content END AS content, " +
        "image_path, content_hash, is_favorite, fav_sort_order, created_at, source_app, alias, group_id"

    private let dbQueue: DatabaseQueue

    private init() {
        let dir = AppPaths.appSupportDirectory
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.prepareDatabase { db in
            db.add(function: Self.containsCI)
        }
        dbQueue = try! DatabaseQueue(
            path: dir.appendingPathComponent("clipora.sqlite").path, configuration: config
        )
        try! migrator.migrate(dbQueue)
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "items") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("type", .text).notNull()
                t.column("subtype", .text)
                t.column("content", .text)
                t.column("thumbnail", .blob)
                t.column("image_path", .text)
                t.column("content_hash", .text).notNull()
                t.column("is_favorite", .boolean).notNull().defaults(to: false)
                t.column("fav_sort_order", .integer)
                t.column("created_at", .datetime).notNull()
            }
            try db.create(
                index: "idx_items_type_hash", on: "items",
                columns: ["type", "content_hash"], unique: true
            )
            try db.create(index: "idx_items_created_at", on: "items", columns: ["created_at"])
        }
        migrator.registerMigration("v2_source_app") { db in
            try db.alter(table: "items") { t in
                t.add(column: "source_app", .text)
            }
        }
        migrator.registerMigration("v3_alias_groups") { db in
            // 别名：仅改展示、不改原始内容；分组：仅对收藏项有意义
            try db.alter(table: "items") { t in
                t.add(column: "alias", .text)
                t.add(column: "group_id", .integer)
            }
            try db.create(table: "clip_groups") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("sort_order", .integer).notNull().defaults(to: 0)
            }
            // 已入分组的收藏项在分组被删时置空，加速按分组过滤
            try db.create(index: "idx_items_group_id", on: "items", columns: ["group_id"])
        }
        return migrator
    }

    private func notifyChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .clipStoreDidChange, object: nil)
        }
    }

    /// 写库统一外壳：成功后广播变更，失败仅记日志（保持“写库不会崩 App”的既有行为）。
    private func performWrite(_ name: String, _ block: (Database) throws -> Void) {
        do {
            try dbQueue.write(block)
            notifyChange()
        } catch {
            NSLog("\(name) failed: \(error)")
        }
    }

    /// 批量删除条目，并连带清理各自落盘的原图（保证“删条目必删图”，杜绝孤儿 PNG）。
    private static func deleteItems(_ victims: [ClipItem], _ db: Database) throws {
        for victim in victims {
            if let path = victim.imagePath { ImageStore.delete(path: path) }
            try victim.delete(db)
        }
    }

    // MARK: - 写入

    /// 插入新条目；同 (type, hash) 已存在时仅更新时间戳置顶（去重）
    func insertOrBump(_ item: ClipItem) {
        performWrite("insertOrBump") { db in
            if var existing = try ClipItem
                .filter(ClipItem.Columns.type == item.type.rawValue)
                .filter(ClipItem.Columns.contentHash == item.contentHash)
                .fetchOne(db) {
                existing.createdAt = item.createdAt
                try existing.update(db)
                // 新条目为重复项，若已为图片落盘则清理刚写入的原图
                if let path = item.imagePath, path != existing.imagePath {
                    ImageStore.delete(path: path)
                }
            } else {
                var newItem = item
                try newItem.insert(db)
                try Self.enforceHistoryLimit(db)
            }
        }
    }

    /// FIFO 淘汰：非收藏条目超过上限时删最旧，并清理落盘图片
    private static func enforceHistoryLimit(_ db: Database) throws {
        let count = try ClipItem
            .filter(ClipItem.Columns.isFavorite == false)
            .fetchCount(db)
        let overflow = count - historyLimit
        guard overflow > 0 else { return }
        let victims = try ClipItem
            .filter(ClipItem.Columns.isFavorite == false)
            .order(ClipItem.Columns.createdAt.asc, ClipItem.Columns.id.asc)
            .limit(overflow)
            .fetchAll(db)
        try deleteItems(victims, db)
    }

    // MARK: - 查询

    func history(matching query: String = "") -> [ClipItem] {
        (try? dbQueue.read { db in
            var sql = "SELECT \(Self.listColumns) FROM items"
            var arguments: [DatabaseValueConvertible] = []
            if !query.isEmpty {
                // 别名也纳入搜索：原文或别名任一命中即匹配
                sql += " WHERE (CLIPORA_CONTAINS_CI(content, ?) OR CLIPORA_CONTAINS_CI(alias, ?))"
                arguments += [query, query]
            }
            sql += " ORDER BY created_at DESC, id DESC LIMIT 2000"
            return try ClipItem.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
        }) ?? []
    }

    /// 收藏列表。groupId 为 nil 时返回全部收藏；指定分组时仅返回该分组内的收藏。
    func favorites(matching query: String = "", groupId: Int64? = nil) -> [ClipItem] {
        (try? dbQueue.read { db in
            var sql = "SELECT \(Self.listColumns) FROM items WHERE is_favorite = 1"
            var arguments: [DatabaseValueConvertible] = []
            if let groupId {
                sql += " AND group_id = ?"
                arguments.append(groupId)
            }
            if !query.isEmpty {
                sql += " AND (CLIPORA_CONTAINS_CI(content, ?) OR CLIPORA_CONTAINS_CI(alias, ?))"
                arguments += [query, query]
            }
            // id ASC 作为平局兜底，防止历史脏数据里重复的 fav_sort_order 导致顺序不确定
            sql += " ORDER BY fav_sort_order ASC, id ASC"
            return try ClipItem.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
        }) ?? []
    }

    /// 列表行的 content 为截断预览；复制文本时按 id 取全文回写剪贴板
    func fullContent(id: Int64) -> String? {
        (try? dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT content FROM items WHERE id = ?", arguments: [id])
        }) ?? nil
    }

    /// 缩略图按可见行懒加载，避免列表查询携带全部 BLOB
    func thumbnail(id: Int64) -> Data? {
        (try? dbQueue.read { db in
            try Data.fetchOne(db, sql: "SELECT thumbnail FROM items WHERE id = ?", arguments: [id])
        }) ?? nil
    }

    func exists(type: ClipType, contentHash: String) -> Bool {
        (try? dbQueue.read { db in
            try ClipItem
                .filter(ClipItem.Columns.type == type.rawValue)
                .filter(ClipItem.Columns.contentHash == contentHash)
                .fetchCount(db) > 0
        }) ?? false
    }

    // MARK: - 收藏

    func toggleFavorite(id: Int64) {
        performWrite("toggleFavorite") { db in
            guard var item = try ClipItem.fetchOne(db, key: id) else { return }
            if item.isFavorite {
                item.isFavorite = false
                item.favSortOrder = nil
                // 分组仅对收藏项有意义：移出收藏时一并清空分组归属，避免以后重新收藏时
                // 旧分组悄悄复活（分组过滤会把它当作从未指派过的成员重新纳入）。
                item.groupId = nil
                // 移出收藏 = 重新计入非收藏历史配额。时间戳刷新到窗口最新端，
                // 否则老收藏项一旦超限会被下方 enforceHistoryLimit 当即物理删除（连同落盘原图），
                // 违反“收藏页删除 = 移出收藏、不删历史本体”。
                item.createdAt = Date()
            } else {
                let maxOrder = try Int.fetchOne(
                    db, sql: "SELECT MAX(fav_sort_order) FROM items WHERE is_favorite = 1"
                ) ?? 0
                item.isFavorite = true
                item.favSortOrder = maxOrder + 1
            }
            try item.update(db)
            // 取消收藏后历史可能超限（该条重新计入非收藏配额）
            try Self.enforceHistoryLimit(db)
        }
    }

    /// 收藏内拖拽排序后整体持久化
    func updateFavoriteOrder(ids: [Int64]) {
        performWrite("updateFavoriteOrder") { db in
            for (index, id) in ids.enumerated() {
                try db.execute(
                    sql: "UPDATE items SET fav_sort_order = ? WHERE id = ?",
                    arguments: [index + 1, id]
                )
            }
        }
    }

    // MARK: - 别名（重命名，仅改展示）

    /// 设置或清除别名。空白别名等价于清除（回退显示原文）。
    func setAlias(id: Int64, alias: String?) {
        let value = ClipItem.normalizedAlias(alias)
        performWrite("setAlias") { db in
            try db.execute(sql: "UPDATE items SET alias = ? WHERE id = ?", arguments: [value, id])
        }
    }

    // MARK: - 收藏分组

    func groups() -> [ClipGroup] {
        (try? dbQueue.read { db in
            try ClipGroup
                .order(ClipGroup.Columns.sortOrder.asc, ClipGroup.Columns.id.asc)
                .fetchAll(db)
        }) ?? []
    }

    /// 新建分组，排到末尾。返回新分组 id（名称为空则不建）。
    @discardableResult
    func createGroup(name: String) -> Int64? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            let id = try dbQueue.write { db -> Int64? in
                let maxOrder = try Int.fetchOne(
                    db, sql: "SELECT MAX(sort_order) FROM clip_groups"
                ) ?? 0
                var group = ClipGroup(id: nil, name: trimmed, sortOrder: maxOrder + 1)
                try group.insert(db)
                return group.id
            }
            notifyChange()
            return id
        } catch {
            NSLog("createGroup failed: \(error)")
            return nil
        }
    }

    func renameGroup(id: Int64, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        performWrite("renameGroup") { db in
            try db.execute(
                sql: "UPDATE clip_groups SET name = ? WHERE id = ?", arguments: [trimmed, id]
            )
        }
    }

    /// 删除分组：组内收藏项归入「未分组」（group_id 置空），条目本身不受影响。
    func deleteGroup(id: Int64) {
        performWrite("deleteGroup") { db in
            try db.execute(
                sql: "UPDATE items SET group_id = NULL WHERE group_id = ?", arguments: [id]
            )
            try db.execute(sql: "DELETE FROM clip_groups WHERE id = ?", arguments: [id])
        }
    }

    /// 分组拖拽排序后整体持久化
    func updateGroupOrder(ids: [Int64]) {
        performWrite("updateGroupOrder") { db in
            for (index, id) in ids.enumerated() {
                try db.execute(
                    sql: "UPDATE clip_groups SET sort_order = ? WHERE id = ?",
                    arguments: [index + 1, id]
                )
            }
        }
    }

    /// 把条目归入某分组；groupId 为 nil 表示移出分组。
    func setItemGroup(id: Int64, groupId: Int64?) {
        performWrite("setItemGroup") { db in
            try db.execute(
                sql: "UPDATE items SET group_id = ? WHERE id = ?", arguments: [groupId, id]
            )
        }
    }

    // MARK: - 删除与清理

    func delete(id: Int64) {
        performWrite("delete") { db in
            guard let item = try ClipItem.fetchOne(db, key: id) else { return }
            try Self.deleteItems([item], db)
        }
    }

    /// 自动清理：删除 cutoff 之前的非收藏条目
    func cleanup(olderThan days: Int) {
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-TimeInterval(days) * 86400)
        deleteNonFavorites("cleanup", olderThan: cutoff)
    }

    /// 「立即清除」：清空全部非收藏历史
    func clearNonFavorites() {
        deleteNonFavorites("clearNonFavorites", olderThan: nil)
    }

    /// 删除非收藏条目；cutoff 为 nil 时清空全部非收藏，否则仅删该时间点之前的。
    private func deleteNonFavorites(_ name: String, olderThan cutoff: Date?) {
        performWrite(name) { db in
            var request = ClipItem.filter(ClipItem.Columns.isFavorite == false)
            if let cutoff {
                request = request.filter(ClipItem.Columns.createdAt < cutoff)
            }
            try Self.deleteItems(try request.fetchAll(db), db)
        }
    }
}

enum AppPaths {
    static var appSupportDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clipora", isDirectory: true)
    }

    static var imagesDirectory: URL {
        appSupportDirectory.appendingPathComponent("images", isDirectory: true)
    }
}
