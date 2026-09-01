import Foundation
import GRDB

// ============================================================================
// Clipora 查询性能基准
//
// 复刻 Clipora/Core/DatabaseManager.swift 的 schema（v1~v4 迁移）、自定义
// CLIPORA_CONTAINS_CI 函数与全部热路径 SQL，向一个独立的基准数据库灌入
// 可复现的模拟数据（SplitMix64 定长种子），测量：
//   - 面板唤起查询（历史 / 收藏）
//   - 各形态搜索（1~2 字符走 CONTAINS_CI 扫描；≥3 字符走 FTS5 trigram）
//   - 写入路径（insertOrBump 去重 + 配额检查）
//   - 自动清理与「立即清除」
//
// 用法（在 scripts/perfbench 下）：
//   swift run -c release perfbench --count 50000
// 常用参数：
//   --count N        条目数（默认 50000）
//   --db PATH        基准库路径（默认 $TMPDIR/clipora-perfbench/bench-N.sqlite，复用免重灌）
//   --reseed         强制重灌数据
//   --scan-variant udf    短查询强制走旧 CONTAINS_CI 路径（复现优化前基线用）
//   --json PATH      结果另存 JSON（优化前后对比表用）
// ============================================================================

// MARK: - 参数

struct Options {
    var count = 50_000
    var dbPath: String?
    var reseed = false
    var scanVariant = "app"   // app = CLIPORA_CONTAINS_CI；like = 原生 LIKE
    var ftsVariant = "join"   // join = 现有 JOIN 写法；in = id IN (SELECT rowid ...)
    var useQueue = false      // --queue：用旧 DatabaseQueue 单连接对照（读写互斥）
    var seedOnly = false      // --seed-only：只灌数据不跑场景（构造迁移测试库用）
    var riskyPercent = 0      // --risky-percent N：文本行中混入 N% 含风险字符（like_safe=0）的行
    var semanticsCheck = false  // --semantics-check：验证双路径谓词与旧 UDF 扫描命中集相等
    var orderVariant = "relevance"  // --order-variant recency|relevance：搜索排序对照
    var jsonOut: String?
}

func parseOptions() -> Options {
    var opts = Options()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = it.next() {
        switch arg {
        case "--count": opts.count = Int(it.next() ?? "") ?? opts.count
        case "--db": opts.dbPath = it.next()
        case "--reseed": opts.reseed = true
        case "--scan-variant": opts.scanVariant = it.next() ?? "app"
        case "--fts-variant": opts.ftsVariant = it.next() ?? "join"
        case "--cleanup-bulk", "--cleanup-legacy", "--bump-legacy": break  // 读取见对应段落
        case "--queue": opts.useQueue = true
        case "--seed-only": opts.seedOnly = true
        case "--risky-percent": opts.riskyPercent = Int(it.next() ?? "") ?? 0
        case "--semantics-check": opts.semanticsCheck = true
        case "--order-variant": opts.orderVariant = it.next() ?? "relevance"

        case "--json": opts.jsonOut = it.next()
        default:
            fputs("未知参数: \(arg)\n", stderr)
            exit(2)
        }
    }
    return opts
}

// MARK: - 可复现随机数（种子固定，保证每次灌入的数据完全一致）

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - ClipItem 镜像（列名与 App 完全一致）

struct BenchItem: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "items"

    var id: Int64?
    var type: String
    var subtype: String?
    var content: String?
    var thumbnail: Data?
    var imagePath: String?
    var contentHash: String
    var isFavorite: Bool
    var favSortOrder: Int?
    var createdAt: Date
    var sourceApp: String?
    var alias: String?
    var groupId: Int64?
    var likeSafe: Bool = false
    var pasteCount: Int = 0
    var lastUsedAt: Date? = nil
    var frecency: Double? = nil

    enum CodingKeys: String, CodingKey {
        case id, type, subtype, content, thumbnail
        case imagePath = "image_path"
        case contentHash = "content_hash"
        case isFavorite = "is_favorite"
        case favSortOrder = "fav_sort_order"
        case createdAt = "created_at"
        case sourceApp = "source_app"
        case alias
        case groupId = "group_id"
        case likeSafe = "like_safe"
        case pasteCount = "paste_count"
        case lastUsedAt = "last_used_at"
        case frecency
    }

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

// MARK: - DatabaseManager 镜像

final class BenchDB {
    // —— 与 DatabaseManager.containsCI 逐字一致 ——
    static let containsCI = DatabaseFunction(
        "CLIPORA_CONTAINS_CI", argumentCount: 2, pure: true
    ) { values in
        guard let needle = String.fromDatabaseValue(values[1]) else { return false }
        if needle.isEmpty { return true }
        guard let haystack = String.fromDatabaseValue(values[0]) else { return false }
        return haystack.range(of: needle, options: [.caseInsensitive]) != nil
    }

    // —— 与 DatabaseManager.likeSafeFn / isLikeSafe 逐字一致 ——
    static let likeSafeFn = DatabaseFunction(
        "CLIPORA_LIKE_SAFE", argumentCount: 2, pure: true
    ) { values in
        isLikeSafe(
            content: String.fromDatabaseValue(values[0]),
            alias: String.fromDatabaseValue(values[1])
        )
    }

    static func isLikeSafe(content: String?, alias: String?) -> Bool {
        isLikeSafeText(content) && isLikeSafeText(alias)
    }

    static func isLikeSafeText(_ text: String?) -> Bool {
        guard let text else { return true }
        return text.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII || isCJKIdeograph(scalar) || isByteMatchInertScalar(scalar)
        }
    }

    static func isCJKIdeograph(_ scalar: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(scalar.value)
            || (0x3400...0x4DBF).contains(scalar.value)
            || (0x20000...0x2EBEF).contains(scalar.value)
    }

    static let inertScalarLock = NSLock()
    static var inertScalarCache: [UInt32: Bool] = [:]

    static func isByteMatchInertScalar(_ scalar: Unicode.Scalar) -> Bool {
        inertScalarLock.lock()
        defer { inertScalarLock.unlock() }
        if let cached = inertScalarCache[scalar.value] { return cached }
        let inert = computeByteMatchInert(scalar)
        inertScalarCache[scalar.value] = inert
        return inert
    }

    static func computeByteMatchInert(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark, .format:
            return false
        default:
            break
        }
        let s = String(scalar)
        // 字素融合试探（半角浊点/emoji 肤色修饰符/SARA AM/Prepend 类，与 App 一致）
        if ("a" + s).count == 1 || (s + "a").count == 1
            || ("中" + s).count == 1 || (s + "中").count == 1 {
            return false
        }
        // Swift String == 按规范等价比较，分解检查必须在标量序列层面做（与 App 一致）
        let scalars = Array(s.unicodeScalars)
        guard s.decomposedStringWithCanonicalMapping.unicodeScalars.elementsEqual(scalars) else {
            return false
        }
        let folded = s.folding(options: [.caseInsensitive], locale: nil)
        if !folded.unicodeScalars.elementsEqual(scalars),
           folded.unicodeScalars.contains(where: \.isASCII) {
            return false
        }
        return true
    }

    let dbPool: any DatabaseWriter
    let imagesDir: URL
    var scanVariant: String
    var ftsVariant: String

    init(path: String, imagesDir: URL, scanVariant: String, ftsVariant: String, useQueue: Bool) throws {
        self.imagesDir = imagesDir
        self.scanVariant = scanVariant
        self.ftsVariant = ftsVariant
        var config = Configuration()
        config.maximumReaderCount = 2
        config.prepareDatabase { db in
            db.add(function: Self.containsCI)
            db.add(function: Self.likeSafeFn)
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        if useQueue {
            // 旧连接模型对照：单连接读写互斥（--queue）
            dbPool = try DatabaseQueue(path: path, configuration: config)
        } else {
            dbPool = try DatabasePool(path: path, configuration: config)
        }
        try Self.migrator.migrate(dbPool)
    }

    // —— 与 DatabaseManager.migrator（v1~v4）逐字一致 ——
    static var migrator: DatabaseMigrator {
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
            try db.alter(table: "items") { t in
                t.add(column: "alias", .text)
                t.add(column: "group_id", .integer)
            }
            try db.create(table: "clip_groups") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("sort_order", .integer).notNull().defaults(to: 0)
            }
            try db.create(index: "idx_items_group_id", on: "items", columns: ["group_id"])
        }
        migrator.registerMigration("v4_search_fts") { db in
            try db.execute(sql: """
                CREATE VIRTUAL TABLE items_fts USING fts5(
                    content,
                    alias,
                    content='items',
                    content_rowid='id',
                    tokenize='trigram case_sensitive 0 remove_diacritics 0'
                )
                """)
            try db.execute(sql: """
                CREATE TRIGGER items_fts_ai AFTER INSERT ON items BEGIN
                    INSERT INTO items_fts(rowid, content, alias)
                    VALUES (new.id, new.content, new.alias);
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER items_fts_ad AFTER DELETE ON items BEGIN
                    INSERT INTO items_fts(items_fts, rowid, content, alias)
                    VALUES ('delete', old.id, old.content, old.alias);
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER items_fts_au AFTER UPDATE OF content, alias ON items BEGIN
                    INSERT INTO items_fts(items_fts, rowid, content, alias)
                    VALUES ('delete', old.id, old.content, old.alias);
                    INSERT INTO items_fts(rowid, content, alias)
                    VALUES (new.id, new.content, new.alias);
                END
                """)
            try db.execute(sql: """
                INSERT INTO items_fts(rowid, content, alias)
                SELECT id, content, alias FROM items
                """)
        }
        migrator.registerMigration("v5_perf_indexes") { db in
            try db.execute(sql: """
                CREATE INDEX idx_items_nonfav_created
                ON items(created_at) WHERE is_favorite = 0
                """)
            try db.execute(sql: """
                CREATE INDEX idx_items_fav_order
                ON items(fav_sort_order) WHERE is_favorite = 1
                """)
        }
        migrator.registerMigration("v6_like_safe") { db in
            try db.execute(sql: "ALTER TABLE items ADD COLUMN like_safe INTEGER NOT NULL DEFAULT 0")
            try db.execute(sql: "UPDATE items SET like_safe = CLIPORA_LIKE_SAFE(content, alias)")
        }
        migrator.registerMigration("v7_search_ranking") { db in
            try db.execute(sql: "ALTER TABLE items ADD COLUMN paste_count INTEGER NOT NULL DEFAULT 0")
            try db.execute(sql: "ALTER TABLE items ADD COLUMN last_used_at DATETIME")
            try db.execute(sql: "ALTER TABLE items ADD COLUMN frecency REAL")
            try db.execute(sql: "UPDATE items SET frecency = unixepoch(created_at)")
            try db.execute(sql: "INSERT INTO items_fts(items_fts, rank) VALUES('rank', 'bm25(1.0, 3.0)')")
        }
        migrator.registerMigration("v8_like_safe_recompute") { db in
            try db.execute(sql: "UPDATE items SET like_safe = CLIPORA_LIKE_SAFE(content, alias)")
        }
        return migrator
    }

    // —— 与 DatabaseManager.bumpedFrecency 逐字一致 ——
    static let frecencyLambda = log(2.0) / (7 * 86400.0)
    static let frecencyMaxHorizon: TimeInterval = 365 * 86400

    static func bumpedFrecency(old: Double?, weight: Double, now: TimeInterval) -> Double {
        let clamped = old.map { $0.isFinite ? min($0, now + frecencyMaxHorizon) : now }
        let decayed = clamped.map { exp(frecencyLambda * ($0 - now)) } ?? 0
        return now + log(decayed + weight) / frecencyLambda
    }

    // —— 与 DatabaseManager.listColumns 逐字一致 ——
    static func listColumns(table: String = "items") -> String {
        "\(table).id, \(table).type, \(table).subtype, " +
        "CASE WHEN \(table).type = 'text' THEN substr(\(table).content, 1, 512) ELSE \(table).content END AS content, " +
        "\(table).image_path, \(table).content_hash, \(table).is_favorite, \(table).fav_sort_order, " +
        "\(table).created_at, \(table).source_app, \(table).alias, \(table).group_id, \(table).like_safe, " +
        "\(table).paste_count, \(table).last_used_at, \(table).frecency"
    }

    // —— 与 DatabaseManager.fetchHistory / fetchFavorites / appendSearchFilter 一致 ——
    enum SearchBranch { case none, fts, scan }

    var orderVariant = "relevance"  // relevance = 现行两段式相关度；recency = 旧纯时间序对照

    func fetchHistory(in db: Database, matching query: String) throws -> [BenchItem] {
        var sql = "SELECT \(Self.listColumns()) FROM items"
        var arguments: [DatabaseValueConvertible] = []
        let branch = appendSearchFilter(to: &sql, arguments: &arguments, query: query, joinsFTS: false)
        guard branch != .none, orderVariant == "relevance" else {
            sql += " ORDER BY items.created_at DESC, items.id DESC LIMIT 2000"
            return try BenchItem.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
        }
        // 与 App 一致的两段式；ftsVariant=in 的对照形态无 rank 可用，内层退回时间序
        sql += branch == .fts && ftsVariant == "join"
            ? " ORDER BY rank LIMIT 2000"
            : " ORDER BY items.created_at DESC, items.id DESC LIMIT 2000"
        let prefix = Self.likeEscaped(query) + "%"
        let substring = "%" + Self.likeEscaped(query) + "%"
        let ranked = "SELECT w.* FROM (\(sql)) AS w ORDER BY"
            + " CASE WHEN w.alias LIKE ? ESCAPE '\\' THEN 0"
            + " WHEN w.alias LIKE ? ESCAPE '\\' THEN 1"
            + " WHEN w.content LIKE ? ESCAPE '\\' THEN 2"
            + " ELSE 3 END,"
            + " w.frecency DESC, w.created_at DESC, w.id DESC"
        arguments += [prefix, substring, prefix]
        return try BenchItem.fetchAll(db, sql: ranked, arguments: StatementArguments(arguments))
    }

    func fetchFavorites(in db: Database, matching query: String, groupId: Int64?) throws -> [BenchItem] {
        let useFTS = Self.usesFTS(for: query)
        var sql = "SELECT \(Self.listColumns()) FROM items"
        if useFTS, ftsVariant == "join" { sql += " JOIN items_fts ON items_fts.rowid = items.id" }
        sql += " WHERE items.is_favorite = 1"
        var arguments: [DatabaseValueConvertible] = []
        if let groupId {
            sql += " AND items.group_id = ?"
            arguments.append(groupId)
        }
        appendSearchFilter(to: &sql, arguments: &arguments, query: query, joinsFTS: useFTS)
        sql += " ORDER BY items.fav_sort_order ASC, items.id ASC"
        return try BenchItem.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
    }

    @discardableResult
    func appendSearchFilter(
        to sql: inout String, arguments: inout [DatabaseValueConvertible], query: String, joinsFTS: Bool
    ) -> SearchBranch {
        guard !query.isEmpty else { return .none }
        if joinsFTS {
            if ftsVariant == "in" {
                sql += " AND items.id IN (SELECT rowid FROM items_fts WHERE items_fts MATCH ?)"
            } else {
                sql += " AND items_fts MATCH ?"
            }
            arguments.append(Self.ftsPhrase(query))
            return .fts
        } else if Self.usesFTS(for: query) {
            if ftsVariant == "in" {
                // 优化候选：IN 子查询物化 FTS 命中集合，外层沿 created_at 索引反扫，
                // 高频词提前命中 LIMIT 2000 即停
                sql += " WHERE items.id IN (SELECT rowid FROM items_fts WHERE items_fts MATCH ?)"
            } else {
                sql = sql.replacingOccurrences(of: " FROM items", with: " FROM items JOIN items_fts ON items_fts.rowid = items.id")
                sql += " WHERE items_fts MATCH ?"
            }
            arguments.append(Self.ftsPhrase(query))
            return .fts
        } else if scanVariant == "rawlike", Self.isNativeLikeSafe(query) {
            // 中间版本对照：无 like_safe 行级路由的纯 LIKE（语义有偏差，仅供性能对比）
            let pattern = "%" + Self.likeEscaped(query) + "%"
            sql += sql.contains(" WHERE ") ? " AND" : " WHERE"
            sql += " (items.content LIKE ? ESCAPE '\\' OR items.alias LIKE ? ESCAPE '\\')"
            arguments += [pattern, pattern]
            return .scan
        } else if scanVariant != "udf", Self.isNativeLikeSafe(query) {
            // 与 App 现行实现一致：like_safe 行走原生 LIKE、风险行回退 CONTAINS_CI；
            // --scan-variant udf 可复现旧全量 UDF 路径
            let pattern = "%" + Self.likeEscaped(query) + "%"
            sql += sql.contains(" WHERE ") ? " AND" : " WHERE"
            sql += " ((items.like_safe = 1 AND (items.content LIKE ? ESCAPE '\\' OR items.alias LIKE ? ESCAPE '\\'))"
            sql += " OR (items.like_safe = 0 AND (CLIPORA_CONTAINS_CI(items.content, ?) OR CLIPORA_CONTAINS_CI(items.alias, ?))))"
            arguments += [pattern, pattern, query, query]
            return .scan
        } else {
            sql += sql.contains(" WHERE ") ? " AND" : " WHERE"
            sql += " (CLIPORA_CONTAINS_CI(items.content, ?) OR CLIPORA_CONTAINS_CI(items.alias, ?))"
            arguments += [query, query]
            return .scan
        }
    }

    static func isNativeLikeSafe(_ query: String) -> Bool {
        query.unicodeScalars.allSatisfy { $0.isASCII || isCJKIdeograph($0) }
    }

    static func likeEscaped(_ query: String) -> String {
        query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    static func usesFTS(for query: String) -> Bool { query.count >= 3 }

    static func ftsPhrase(_ query: String) -> String {
        "\"\(query.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    // —— insertOrBump / enforceHistoryLimit 镜像（historyLimit 可调，避免灌入即淘汰）——
    var historyLimit = 500

    func insertOrBump(_ item: BenchItem) throws {
        var item = item
        // 与 App 一致：行级 LIKE 安全标志在事务外计算；首次复制 frecency = 复制时刻
        item.likeSafe = Self.isLikeSafe(content: item.content, alias: item.alias)
        item.frecency = item.createdAt.timeIntervalSince1970
        try dbPool.write { db in
            let existing = try Row.fetchOne(
                db,
                sql: "SELECT image_path, frecency FROM items WHERE type = ? AND content_hash = ?",
                arguments: [item.type, item.contentHash]
            )
            if let existing {
                let frecency = Self.bumpedFrecency(
                    old: existing["frecency"] as Double?, weight: 1.0,
                    now: item.createdAt.timeIntervalSince1970
                )
                try db.execute(
                    sql: "UPDATE items SET created_at = ?, frecency = ? WHERE type = ? AND content_hash = ?",
                    arguments: [item.createdAt, frecency, item.type, item.contentHash]
                )
            } else {
                var newItem = item
                try newItem.insert(db)
                try enforceHistoryLimit(db)
            }
        }
    }

    // —— 与 DatabaseManager.recordPaste 的写路径一致（同步版，便于计时）——
    func recordPaste(id: Int64) throws {
        try dbPool.write { db in
            let old = try Double.fetchOne(
                db, sql: "SELECT frecency FROM items WHERE id = ?", arguments: [id]
            )
            let now = Date()
            let frecency = Self.bumpedFrecency(old: old, weight: 3.0, now: now.timeIntervalSince1970)
            try db.execute(
                sql: "UPDATE items SET frecency = ?, paste_count = paste_count + 1, last_used_at = ? WHERE id = ?",
                arguments: [frecency, now, id]
            )
        }
    }

    /// 旧实现：整行 fetchOne + update(db)（SET 全列，含 content → 触发 FTS 全文重建）
    func insertOrBumpLegacy(_ item: BenchItem) throws {
        try dbPool.write { db in
            if var existing = try BenchItem
                .filter(Column("type") == item.type)
                .filter(Column("content_hash") == item.contentHash)
                .fetchOne(db) {
                existing.createdAt = item.createdAt
                try existing.update(db)
            } else {
                var newItem = item
                try newItem.insert(db)
                try enforceHistoryLimit(db)
            }
        }
    }

    func enforceHistoryLimit(_ db: Database) throws {
        let count = try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM items WHERE is_favorite = 0"
        ) ?? 0
        let overflow = count - historyLimit
        guard overflow > 0 else { return }
        let victimsSQL =
            "SELECT id FROM items WHERE is_favorite = 0 ORDER BY created_at ASC, id ASC LIMIT ?"
        let paths = try String.fetchAll(
            db,
            sql: "SELECT image_path FROM items WHERE id IN (\(victimsSQL)) AND image_path IS NOT NULL",
            arguments: [overflow]
        )
        try db.execute(sql: "DELETE FROM items WHERE id IN (\(victimsSQL))", arguments: [overflow])
        for path in paths {
            try? FileManager.default.removeItem(at: imagesDir.appendingPathComponent(path))
        }
    }

    // —— deleteItems / deleteNonFavorites 镜像（ImageStore.delete → 本地 unlink）——
    func deleteItems(_ victims: [BenchItem], _ db: Database) throws {
        for victim in victims {
            if let path = victim.imagePath {
                try? FileManager.default.removeItem(at: imagesDir.appendingPathComponent(path))
            }
            try victim.delete(db)
        }
    }

    func deleteNonFavorites(olderThan cutoff: Date?) throws -> Int {
        try dbPool.write { db in
            var request = BenchItem.filter(Column("is_favorite") == false)
            if let cutoff {
                request = request.filter(Column("created_at") < cutoff)
            }
            let victims = try request.fetchAll(db)
            try deleteItems(victims, db)
            return victims.count
        }
    }

    /// 优化候选：只取 (id, image_path) 清理文件，再单条 SQL 批量 DELETE（FTS 触发器逐行维护索引）
    func deleteNonFavoritesBulk(olderThan cutoff: Date?) throws -> Int {
        try dbPool.write { db in
            var where_ = "is_favorite = 0"
            var args: [DatabaseValueConvertible] = []
            if let cutoff {
                where_ += " AND created_at < ?"
                args.append(cutoff)
            }
            let paths = try String.fetchAll(
                db, sql: "SELECT image_path FROM items WHERE \(where_) AND image_path IS NOT NULL",
                arguments: StatementArguments(args)
            )
            for path in paths {
                try? FileManager.default.removeItem(at: imagesDir.appendingPathComponent(path))
            }
            try db.execute(sql: "DELETE FROM items WHERE \(where_)", arguments: StatementArguments(args))
            return db.changesCount
        }
    }

    /// 与 App readAsync 相同的读连接路径（WAL 快照 reader），同步等待结果以计时
    func timedRead<T>(_ block: @escaping (Database) throws -> T) throws -> T {
        try dbPool.read(block)
    }
}

// MARK: - 数据灌入

enum Seeder {
    static let englishWords = [
        "meeting", "deploy", "release", "invoice", "server", "docker", "swift", "python",
        "database", "index", "network", "password", "token", "billing", "commit", "branch",
        "layout", "render", "thread", "queue", "cache", "memory", "profile", "search",
        "clipboard", "history", "panel", "shortcut", "window", "screen", "backup", "export",
    ]
    static let chineseWords = [
        "工作", "会议", "项目", "计划", "报告", "需求", "设计", "开发", "测试", "上线",
        "服务器", "数据库", "索引", "缓存", "内存", "线程", "队列", "性能", "优化", "搜索",
        "剪贴板", "历史", "面板", "快捷键", "窗口", "截图", "备份", "导出", "中午", "下班",
        "微信", "邮件", "地址", "电话", "发票", "合同", "工资", "假期", "出差", "周报",
    ]
    static let domains = ["github.com", "stackoverflow.com", "developer.apple.com", "sqlite.org", "example.com"]
    static let apps = ["com.apple.Safari", "com.google.Chrome", "com.microsoft.VSCode",
                       "com.apple.dt.Xcode", "com.tencent.xinWeChat", "com.apple.finder"]

    static func randomSentence(_ rng: inout SplitMix64, wordCount: Int) -> String {
        var parts: [String] = []
        for _ in 0..<wordCount {
            if Int.random(in: 0..<2, using: &rng) == 0 {
                parts.append(englishWords.randomElement(using: &rng)!)
            } else {
                parts.append(chineseWords.randomElement(using: &rng)!)
            }
        }
        return parts.joined(separator: " ")
    }

    /// 灌入 count 条形态混合的数据；分布参照真实使用：
    /// 60% 短文本、24% 中文本、4% 长文本(2~40KB)、6% 图片(带 ~25KB 缩略图 BLOB + 落盘原图)、6% 文件
    static func seed(db: BenchDB, count: Int, riskyPercent: Int = 0) throws {
        var rng = SplitMix64(seed: 0xC110_0A0A)
        let now = Date()
        let secondsIn180Days: TimeInterval = 180 * 86400

        try FileManager.default.createDirectory(at: db.imagesDir, withIntermediateDirectories: true)
        // 缩略图 BLOB：随机字节不可压缩，贴近 PNG 真实存储密度
        var thumbTemplate = Data(count: 25_000)
        thumbTemplate.withUnsafeMutableBytes { buf in
            for i in 0..<buf.count { buf[i] = UInt8(truncatingIfNeeded: Int(rng.next() & 0xFF)) }
        }
        let dummyOriginal = Data(repeating: 0x89, count: 4096)

        let batchSize = 2000
        var inserted = 0
        var favOrder = 0
        while inserted < count {
            let n = min(batchSize, count - inserted)
            try db.dbPool.write { sql in
                for i in 0..<n {
                    let serial = inserted + i
                    let age = TimeInterval(Double.random(in: 0..<1, using: &rng)) * secondsIn180Days
                    let createdAt = now.addingTimeInterval(-age)
                    let roll = Int.random(in: 0..<100, using: &rng)
                    var item: BenchItem
                    if roll < 60 {
                        // 短文本（含 URL / 命令等子类型）
                        let sub = ["plain", "plain", "plain", "url", "command"][Int.random(in: 0..<5, using: &rng)]
                        var text: String
                        switch sub {
                        case "url":
                            text = "https://\(domains.randomElement(using: &rng)!)/\(englishWords.randomElement(using: &rng)!)/\(serial)"
                        case "command":
                            text = "git \(englishWords.randomElement(using: &rng)!) --\(englishWords.randomElement(using: &rng)!) #\(serial)"
                        default:
                            text = randomSentence(&rng, wordCount: Int.random(in: 2...12, using: &rng)) + " #\(serial)"
                        }
                        item = makeText(text, subtype: sub, createdAt: createdAt, rng: &rng)
                    } else if roll < 84 {
                        // 中文本：一段话（几十到几百字符）
                        let text = (0..<Int.random(in: 3...10, using: &rng))
                            .map { _ in randomSentence(&rng, wordCount: Int.random(in: 5...15, using: &rng)) }
                            .joined(separator: "。") + " #\(serial)"
                        item = makeText(text, subtype: "plain", createdAt: createdAt, rng: &rng)
                    } else if roll < 88 {
                        // 长文本：2~40KB（代码片段/日志粘贴）
                        let target = Int.random(in: 2_000...40_000, using: &rng)
                        var text = ""
                        while text.utf8.count < target {
                            text += randomSentence(&rng, wordCount: 12) + "\n"
                        }
                        text += "#\(serial)"
                        item = makeText(text, subtype: "plain", createdAt: createdAt, rng: &rng)
                    } else if roll < 94 {
                        // 图片：缩略图 BLOB 入库 + 原图落盘
                        let name = "bench-\(serial).png"
                        try? dummyOriginal.write(to: db.imagesDir.appendingPathComponent(name))
                        item = BenchItem(
                            id: nil, type: "image", subtype: nil, content: nil,
                            thumbnail: thumbTemplate, imagePath: name,
                            contentHash: "imghash-\(serial)", isFavorite: false,
                            favSortOrder: nil, createdAt: createdAt,
                            sourceApp: apps.randomElement(using: &rng), alias: nil, groupId: nil
                        )
                    } else {
                        // 文件路径列表（JSON）
                        let paths = (0..<Int.random(in: 1...3, using: &rng)).map {
                            "/Users/bench/Documents/\(englishWords.randomElement(using: &rng)!)-\(serial)-\($0).pdf"
                        }
                        let json = String(data: try! JSONEncoder().encode(paths), encoding: .utf8)!
                        item = BenchItem(
                            id: nil, type: "file", subtype: nil, content: json,
                            thumbnail: nil, imagePath: nil,
                            contentHash: "filehash-\(serial)", isFavorite: false,
                            favSortOrder: nil, createdAt: createdAt,
                            sourceApp: "com.apple.finder", alias: nil, groupId: nil
                        )
                    }
                    // ~1.5% 收藏，少量带别名
                    if Int.random(in: 0..<1000, using: &rng) < 15 {
                        favOrder += 1
                        item.isFavorite = true
                        item.favSortOrder = favOrder
                        if favOrder % 4 == 0 { item.alias = "常用 \(favOrder)" }
                        if favOrder % 3 == 0 { item.groupId = Int64(favOrder % 3 + 1) }
                    }
                    // --risky-percent：文本行混入风险字符（NFD 组合附标/ß/连字），
                    // like_safe=0 走 UDF 回退。默认 0，不额外消耗随机数流，语料与历史版本逐字一致。
                    if riskyPercent > 0, item.type == "text",
                       Int.random(in: 0..<100, using: &rng) < riskyPercent {
                        item.content = (item.content ?? "") + " cafe\u{0301} straße ﬁle"
                    }
                    var copy = item
                    copy.likeSafe = BenchDB.isLikeSafe(content: copy.content, alias: copy.alias)
                    try copy.insert(sql)
                }
            }
            inserted += n
            print("  已灌入 \(inserted)/\(count)")
        }
        try db.dbPool.write { sql in
            for (i, name) in ["常用", "代码", "地址"].enumerated() {
                try sql.execute(
                    sql: "INSERT INTO clip_groups (name, sort_order) VALUES (?, ?)",
                    arguments: [name, i + 1]
                )
            }
        }
    }

    /// 灌入后模拟粘贴行为（独立 RNG，不动主语料流的随机数序列）：
    /// ~10% 条目有粘贴记录，次数 Zipf 型（多数 1-2 次、少数高频），
    /// frecency 按事件时间逐次累加——否则相关度排序场景测不出分层。
    static func seedPasteSignals(db: BenchDB) throws {
        var rng = SplitMix64(seed: 0xFEED_FACE)
        let now = Date().timeIntervalSince1970
        let rows = try db.dbPool.read { sql in
            try Row.fetchAll(sql, sql: "SELECT id, frecency FROM items")
        }
        try db.dbPool.write { sql in
            for row in rows {
                guard Int.random(in: 0..<100, using: &rng) < 10 else { continue }
                let id: Int64 = row["id"]
                var frecency: Double? = row["frecency"]
                let base = frecency ?? now
                let pastes = [1, 1, 1, 1, 2, 2, 3, 5, 8, 15][Int.random(in: 0..<10, using: &rng)]
                var lastUsed = base
                for _ in 0..<pastes {
                    lastUsed = base + Double.random(in: 0...(max(1, now - base)), using: &rng)
                    frecency = BenchDB.bumpedFrecency(old: frecency, weight: 3.0, now: lastUsed)
                }
                try sql.execute(
                    sql: "UPDATE items SET paste_count = ?, last_used_at = ?, frecency = ? WHERE id = ?",
                    arguments: [pastes, Date(timeIntervalSince1970: lastUsed), frecency, id]
                )
            }
        }
    }

    private static func makeText(
        _ text: String, subtype: String, createdAt: Date, rng: inout SplitMix64
    ) -> BenchItem {
        BenchItem(
            id: nil, type: "text", subtype: subtype, content: text,
            thumbnail: nil, imagePath: nil,
            contentHash: "texthash-\(text.hashValue)-\(text.utf8.count)",
            isFavorite: false, favSortOrder: nil, createdAt: createdAt,
            sourceApp: apps.randomElement(using: &rng), alias: nil, groupId: nil
        )
    }
}

// MARK: - 计时

struct Stat {
    var label: String
    var medianMS: Double
    var minMS: Double
    var maxMS: Double
    var rows: Int
    var note: String
}

func measure(_ label: String, note: String = "", runs: Int = 9, _ block: () throws -> Int) rethrows -> Stat {
    _ = try block()  // 预热（statement 缓存、页缓存）
    var times: [Double] = []
    var rows = 0
    for _ in 0..<runs {
        let start = DispatchTime.now().uptimeNanoseconds
        rows = try block()
        let end = DispatchTime.now().uptimeNanoseconds
        times.append(Double(end - start) / 1_000_000)
    }
    times.sort()
    return Stat(
        label: label, medianMS: times[times.count / 2],
        minMS: times.first!, maxMS: times.last!, rows: rows, note: note
    )
}

func fmt(_ ms: Double) -> String {
    ms >= 100 ? String(format: "%.0f", ms) : String(format: "%.2f", ms)
}

// MARK: - 主流程

let opts = parseOptions()
let fm = FileManager.default

// —— --semantics-check：验证 like_safe 双路径谓词与旧全量 UDF 扫描命中集逐一相等 ——
// 覆盖 diff 审查实证过的全部偏差字符：ß 折叠、NFD 组合附标、连字、开尔文符号、
// 兼容表意（BMP 与补充区）、以及 ASCII/中文对照组。
if opts.semanticsCheck {
    let tmp = fm.temporaryDirectory.appendingPathComponent("clipora-semcheck-\(UUID().uuidString)")
    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmp) }
    let checkDB = try BenchDB(path: tmp.appendingPathComponent("sem.sqlite").path,
                              imagesDir: tmp, scanVariant: "app", ftsVariant: "join",
                              useQueue: false)
    checkDB.historyLimit = 10_000
    let contents = [
        "straße 地址", "cafe\u{0301}.txt", "\u{FB01}le report", "temp \u{212A} sign",
        "long \u{017F}tring", "樂團 K-pop", "\u{F914}園", "美\u{2F800}山",
        "hello WORLD", "中文测试样本", "50% off_sale\\path", "日本語のかな",
        // 字素簇扩展/前置标量（二轮审查发现的分叉类）：半角浊点(Lm)、emoji 肤色
        // 修饰符(Sk)、泰文 SARA AM(Lo)、Prepend U+0D4E(Lo)
        "log a\u{FF9E} tail", "中\u{FF9E}文标记", "skin b\u{1F3FB} tone",
        "thai c\u{0E33} am", "\u{0D4E}ka prepend",
    ]
    for (i, text) in contents.enumerated() {
        try checkDB.insertOrBump(BenchItem(
            id: nil, type: "text", subtype: "plain", content: text,
            thumbnail: nil, imagePath: nil, contentHash: "sem-\(i)",
            isFavorite: false, favSortOrder: nil, createdAt: Date(),
            sourceApp: nil, alias: nil, groupId: nil
        ))
    }
    let queries = ["ss", "fe", "fi", "k", "s", "樂", "丽", "\u{2F800}", "lo", "文",
                   "50%", "_s", "\\p", "の", "SS", "ST", "café", "no",
                   "a", "中", "b", "c", "ka"]
    var failures = 0
    for query in queries {
        func ids(_ variant: String) throws -> Set<Int64> {
            checkDB.scanVariant = variant
            return Set(try checkDB.dbPool.read { db in
                try checkDB.fetchHistory(in: db, matching: query).compactMap(\.id)
            })
        }
        let app = try ids("app"), udf = try ids("udf")
        let status = app == udf ? "PASS" : "FAIL"
        if app != udf { failures += 1 }
        print("[\(status)] query=\(query.debugDescription) app=\(app.sorted()) udf=\(udf.sorted())")
    }
    checkDB.scanVariant = "app"

    // —— 相关度排序断言：别名前缀层 > 粘贴提升 > 纯新近度；--order-variant recency 回到时间序 ——
    let now = Date()
    let rankRows: [(String, String?, TimeInterval)] = [
        ("alpha release note", nil, -3 * 86400),   // A：3 天前复制，将粘贴 3 次
        ("alpha build script", nil, -60),          // B：刚复制，无粘贴
        ("deploy alpha target", "alpha 常用", -30 * 86400),  // C：30 天前，别名前缀命中
    ]
    var rankIds: [Int64] = []
    for (i, row) in rankRows.enumerated() {
        var item = BenchItem(
            id: nil, type: "text", subtype: "plain", content: row.0,
            thumbnail: nil, imagePath: nil, contentHash: "rank-\(i)",
            isFavorite: false, favSortOrder: nil,
            createdAt: now.addingTimeInterval(row.2), sourceApp: nil,
            alias: row.1, groupId: nil
        )
        item.likeSafe = BenchDB.isLikeSafe(content: item.content, alias: item.alias)
        item.frecency = item.createdAt.timeIntervalSince1970
        try checkDB.dbPool.write { try item.insert($0) }
        rankIds.append(item.id!)
    }
    for _ in 0..<3 { try checkDB.recordPaste(id: rankIds[0]) }
    func order(_ variant: String) throws -> [Int64] {
        checkDB.orderVariant = variant
        return try checkDB.dbPool.read { db in
            try checkDB.fetchHistory(in: db, matching: "alpha").compactMap(\.id)
                .filter { rankIds.contains($0) }
        }
    }
    let relevance = try order("relevance"), recency = try order("recency")
    let expectRelevance = [rankIds[2], rankIds[0], rankIds[1]]  // 别名层 → 粘贴提升 → 新近
    let expectRecency = [rankIds[1], rankIds[0], rankIds[2]]    // 纯时间序
    for (label, got, want) in [("relevance", relevance, expectRelevance),
                               ("recency", recency, expectRecency)] {
        let ok = got == want
        if !ok { failures += 1 }
        print("[\(ok ? "PASS" : "FAIL")] 排序断言 \(label): got=\(got) want=\(want)")
    }

    // —— EQP 断言：FTS 内层 ORDER BY rank 不得出现 temp b-tree（快路径回归探测）——
    let eqp = try checkDB.dbPool.read { db in
        try Row.fetchAll(db, sql: """
            EXPLAIN QUERY PLAN SELECT items.id FROM items
            JOIN items_fts ON items_fts.rowid = items.id
            WHERE items_fts MATCH '"alpha"' ORDER BY rank LIMIT 2000
            """).map { "\($0)" }.joined(separator: "\n")
    }
    let eqpOK = !eqp.uppercased().contains("TEMP B-TREE")
    if !eqpOK { failures += 1 }
    print("[\(eqpOK ? "PASS" : "FAIL")] EQP FTS 内层无 temp b-tree\n\(eqp)")

    print(failures == 0 ? "语义校验全部通过（命中集相等 + 排序断言 + EQP 快路径）"
                        : "语义校验失败 \(failures) 项")
    exit(failures == 0 ? 0 : 1)
}

let benchRoot: URL
if let p = opts.dbPath {
    benchRoot = URL(fileURLWithPath: p).deletingLastPathComponent()
} else {
    benchRoot = fm.temporaryDirectory.appendingPathComponent("clipora-perfbench", isDirectory: true)
}
try fm.createDirectory(at: benchRoot, withIntermediateDirectories: true)
let dbPath = opts.dbPath ?? benchRoot.appendingPathComponent("bench-\(opts.count).sqlite").path
let imagesDir = benchRoot.appendingPathComponent("images-\(opts.count)", isDirectory: true)

if opts.reseed, fm.fileExists(atPath: dbPath) {
    try fm.removeItem(atPath: dbPath)
    try? fm.removeItem(at: imagesDir)
}

print("基准库: \(dbPath)")
let db = try BenchDB(path: dbPath, imagesDir: imagesDir,
                     scanVariant: opts.scanVariant, ftsVariant: opts.ftsVariant,
                     useQueue: opts.useQueue)
db.orderVariant = opts.orderVariant

let existing = try db.dbPool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM items") ?? 0 }
if existing < opts.count {
    print("灌入 \(opts.count) 条模拟数据（当前 \(existing)）…")
    if existing > 0 {
        try db.dbPool.write { try $0.execute(sql: "DELETE FROM items") }
    }
    let t0 = DispatchTime.now().uptimeNanoseconds
    try Seeder.seed(db: db, count: opts.count, riskyPercent: opts.riskyPercent)
    try Seeder.seedPasteSignals(db: db)
    let seedMS = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
    print(String(format: "灌入完成，耗时 %.1fs", seedMS / 1000))
} else {
    print("复用现有数据（\(existing) 条）")
}

let dbSizeMB = (try? fm.attributesOfItem(atPath: dbPath)[.size] as? Int64).flatMap { $0 }.map { Double($0) / 1_048_576 } ?? 0
let journalMode = try db.dbPool.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") ?? "?" }
let counts = try db.dbPool.read { sql -> (Int, Int) in
    let total = try Int.fetchOne(sql, sql: "SELECT COUNT(*) FROM items") ?? 0
    let favs = try Int.fetchOne(sql, sql: "SELECT COUNT(*) FROM items WHERE is_favorite = 1") ?? 0
    return (total, favs)
}
print(String(format: "库大小 %.1f MB | journal_mode=%@ | 条目 %d（收藏 %d）| scan-variant=%@ | fts-variant=%@ | order-variant=%@\n",
             dbSizeMB, journalMode, counts.0, counts.1, opts.scanVariant, opts.ftsVariant, opts.orderVariant))

if opts.seedOnly { exit(0) }

var stats: [Stat] = []

// —— 面板唤起 ——
stats.append(try measure("唤起:历史列表(空查询)", note: "fetchHistory \"\" LIMIT 2000") {
    try db.timedRead { try db.fetchHistory(in: $0, matching: "").count }
})
stats.append(try measure("唤起:收藏页(空查询)", note: "fetchFavorites + groups") {
    try db.timedRead {
        let items = try db.fetchFavorites(in: $0, matching: "", groupId: nil)
        _ = try Row.fetchAll($0, sql: "SELECT * FROM clip_groups ORDER BY sort_order, id")
        return items.count
    }
})

// —— 搜索（<3 字符：CONTAINS_CI 全表扫描；≥3 字符：FTS5 trigram）——
let searches: [(String, String)] = [
    ("a", "1字符英文(扫描)"),
    ("中", "1字符中文(扫描)"),
    ("工作", "2字符中文(扫描)"),
    ("qz", "2字符无命中(扫描,最差)"),
    ("http", "4字符英文(FTS)"),
    ("剪贴板", "3字符中文(FTS)"),
    ("服务器 数据库", "长中文词组(FTS)"),
    ("github.com/se", "13字符长查询(FTS)"),
    ("zzzzqqqq", "无命中(FTS)"),
]
for (q, desc) in searches {
    stats.append(try measure("搜索:\(desc)", note: "\"\(q)\"") {
        try db.timedRead { try db.fetchHistory(in: $0, matching: q).count }
    })
}
stats.append(try measure("搜索:收藏页 2字符(扫描)", note: "\"工作\" 仅收藏") {
    try db.timedRead { try db.fetchFavorites(in: $0, matching: "工作", groupId: nil).count }
})

// —— 行级懒加载（可见行缩略图，模拟滚动时 10 行）——
let thumbIds = try db.dbPool.read {
    try Int64.fetchAll($0, sql: "SELECT id FROM items WHERE type = 'image' ORDER BY created_at DESC LIMIT 10")
}
if !thumbIds.isEmpty {
    stats.append(try measure("滚动:10 行缩略图懒加载", note: "loadThumbnail × \(thumbIds.count)") {
        try db.timedRead { sql in
            var total = 0
            for id in thumbIds {
                total += try Data.fetchOne(sql, sql: "SELECT thumbnail FROM items WHERE id = ?", arguments: [id])?.count ?? 0
            }
            return thumbIds.count
        }
    })
}

// —— 写入路径的组成部分 ——
stats.append(try measure("写入:非收藏计数扫描", note: "enforceHistoryLimit 每次插入执行") {
    try db.timedRead { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM items WHERE is_favorite = 0") ?? 0 }
})
stats.append(try measure("收藏:MAX(fav_sort_order)", note: "toggleFavorite 每次执行") {
    try db.timedRead { try Int.fetchOne($0, sql: "SELECT MAX(fav_sort_order) FROM items WHERE is_favorite = 1") ?? 0 }
})

// —— 重复置顶最长文本（旧实现整行回写会触发 FTS 全文 trigram 重建；--bump-legacy 复现）——
let bumpLegacy = CommandLine.arguments.contains("--bump-legacy")
if let longRow = try db.dbPool.read({
    try Row.fetchOne($0, sql: """
        SELECT content_hash, length(content) AS len FROM items
        WHERE type = 'text' ORDER BY length(content) DESC LIMIT 1
        """)
}) {
    let hash: String = longRow["content_hash"]
    let len: Int = longRow["len"] ?? 0
    stats.append(try measure(
        "写入:重复置顶长文本(\(len / 1000)KB)",
        note: bumpLegacy ? "旧:整行回写+FTS 重建" : "新:仅 UPDATE created_at"
    ) {
        let dup = BenchItem(
            id: nil, type: "text", subtype: "plain", content: nil, thumbnail: nil,
            imagePath: nil, contentHash: hash, isFavorite: false, favSortOrder: nil,
            createdAt: Date(), sourceApp: nil, alias: nil, groupId: nil
        )
        if bumpLegacy { try db.insertOrBumpLegacy(dup) } else { try db.insertOrBump(dup) }
        return 1
    })
}

// —— insertOrBump（80 新条目 + 20 重复置顶；historyLimit 抬高避免连锁淘汰）——
db.historyLimit = opts.count * 2
var rng = SplitMix64(seed: 987)
let dupHashes = try db.dbPool.read {
    try String.fetchAll($0, sql: "SELECT content_hash FROM items WHERE type='text' ORDER BY id LIMIT 20")
}
var insertTimes: [Double] = []
for i in 0..<100 {
    let item: BenchItem
    if i % 5 == 4, !dupHashes.isEmpty {
        item = BenchItem(
            id: nil, type: "text", subtype: "plain", content: "dup", thumbnail: nil,
            imagePath: nil, contentHash: dupHashes[i / 5 % dupHashes.count],
            isFavorite: false, favSortOrder: nil, createdAt: Date(), sourceApp: nil, alias: nil, groupId: nil
        )
    } else {
        item = BenchItem(
            id: nil, type: "text", subtype: "plain",
            content: "bench insert \(Seeder.randomSentence(&rng, wordCount: 8)) №\(i)",
            thumbnail: nil, imagePath: nil, contentHash: "benchhash-\(i)",
            isFavorite: false, favSortOrder: nil, createdAt: Date(), sourceApp: nil, alias: nil, groupId: nil
        )
    }
    let t0 = DispatchTime.now().uptimeNanoseconds
    try db.insertOrBump(item)
    insertTimes.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
}
insertTimes.sort()
stats.append(Stat(
    label: "写入:insertOrBump", medianMS: insertTimes[insertTimes.count / 2],
    minMS: insertTimes.first!, maxMS: insertTimes.last!, rows: 100,
    note: "去重查询+插入+FTS 触发器+配额检查"
))

// —— recordPaste（粘贴回写 frecency；SET 不含 content/alias，不应触发 FTS 重建）——
if let pasteId = try db.dbPool.read({
    try Int64.fetchOne($0, sql: "SELECT id FROM items WHERE type = 'text' ORDER BY length(content) DESC LIMIT 1")
}) {
    stats.append(try measure("写入:recordPaste(最长文本行)", note: "frecency+paste_count 定向 UPDATE") {
        try db.recordPaste(id: pasteId)
        return 1
    })
}

// —— 并发：1MB 文本写入进行中发起唤起读（Pool 的 WAL 快照读 vs Queue 的互斥排队）——
var bigBase = ""
var bigRng = SplitMix64(seed: 777)
while bigBase.utf8.count < 1_000_000 {
    bigBase += Seeder.randomSentence(&bigRng, wordCount: 12) + "\n"
}
var concTimes: [Double] = []
for i in 0..<5 {
    let big = BenchItem(
        id: nil, type: "text", subtype: "plain", content: bigBase + "#conc\(i)",
        thumbnail: nil, imagePath: nil, contentHash: "bigconc-\(i)", isFavorite: false,
        favSortOrder: nil, createdAt: Date(), sourceApp: nil, alias: nil, groupId: nil
    )
    let done = DispatchSemaphore(value: 0)
    let started = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        started.signal()
        try? db.insertOrBump(big)
        done.signal()
    }
    started.wait()
    usleep(2000)  // 让写事务先行 2ms，模拟「复制大文本后立刻唤起」
    let t0 = DispatchTime.now().uptimeNanoseconds
    _ = try? db.timedRead { try db.fetchHistory(in: $0, matching: "").count }
    concTimes.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
    done.wait()
}
concTimes.sort()
stats.append(Stat(
    label: "并发:1MB 写入中的唤起读", medianMS: concTimes[concTimes.count / 2],
    minMS: concTimes.first!, maxMS: concTimes.last!, rows: 5,
    note: opts.useQueue ? "单连接互斥(旧)" : "WAL 快照并发读"
))

// —— 清理（破坏性，放最后；各执行一次；默认镜像 App 现行批量实现，--cleanup-legacy 复现旧路径）——
let bulkCleanup = !CommandLine.arguments.contains("--cleanup-legacy")
let cleanupNote = bulkCleanup ? "轻列查询 + 单条批量 DELETE" : "fetchAll 全列解码+逐行 DELETE"
let cutoff = Date().addingTimeInterval(-90 * 86400)
var t0 = DispatchTime.now().uptimeNanoseconds
let cleaned = bulkCleanup
    ? try db.deleteNonFavoritesBulk(olderThan: cutoff)
    : try db.deleteNonFavorites(olderThan: cutoff)
let cleanupMS = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
stats.append(Stat(label: "清理:90天前(启动路径)", medianMS: cleanupMS, minMS: cleanupMS, maxMS: cleanupMS,
                  rows: cleaned, note: cleanupNote))

t0 = DispatchTime.now().uptimeNanoseconds
let clearedAll = bulkCleanup
    ? try db.deleteNonFavoritesBulk(olderThan: nil)
    : try db.deleteNonFavorites(olderThan: nil)
let clearMS = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
stats.append(Stat(label: "清理:立即清除(全部非收藏)", medianMS: clearMS, minMS: clearMS, maxMS: clearMS,
                  rows: clearedAll, note: cleanupNote))

// —— 输出 ——
print("| 场景 | 中位 ms | 最小 | 最大 | 行数 | 说明 |")
print("|---|---|---|---|---|---|")
for s in stats {
    print("| \(s.label) | \(fmt(s.medianMS)) | \(fmt(s.minMS)) | \(fmt(s.maxMS)) | \(s.rows) | \(s.note) |")
}
print("\n注:清理场景为破坏性操作,重跑完整基准请加 --reseed。")

if let jsonPath = opts.jsonOut {
    var dict: [String: Any] = [:]
    for s in stats {
        dict[s.label] = ["median_ms": s.medianMS, "min_ms": s.minMS, "max_ms": s.maxMS, "rows": s.rows]
    }
    dict["_meta"] = [
        "count": opts.count, "db_size_mb": dbSizeMB, "journal_mode": journalMode,
        "scan_variant": opts.scanVariant,
    ]
    let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: URL(fileURLWithPath: jsonPath))
    print("JSON 已写入 \(jsonPath)")
}
