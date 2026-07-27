import Foundation
import GRDB

extension Notification.Name {
    /// 数据变更（新增/删除/收藏/排序），面板监听后刷新
    static let clipStoreDidChange = Notification.Name("clipStoreDidChange")
}

final class DatabaseManager {
    static let shared = DatabaseManager()

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

    /// 行级 LIKE 安全标志（items.like_safe 列）的计算函数，v6 回填与 setAlias 复用。
    /// 见 isLikeSafe(content:alias:)。
    private static let likeSafeFn = DatabaseFunction(
        "CLIPORA_LIKE_SAFE", argumentCount: 2, pure: true
    ) { values in
        isLikeSafe(
            content: String.fromDatabaseValue(values[0]),
            alias: String.fromDatabaseValue(values[1])
        )
    }

    /// content 与 alias 都只含「字节匹配 ≡ Foundation 大小写不敏感子串语义」的字符时为 true。
    /// 短查询据此路由：安全行走原生 LIKE（快一个数量级），风险行回退 CLIPORA_CONTAINS_CI，
    /// 整体命中语义与全量 UDF 扫描逐行一致。
    static func isLikeSafe(content: String?, alias: String?) -> Bool {
        isLikeSafeText(content) && isLikeSafeText(alias)
    }

    private static func isLikeSafeText(_ text: String?) -> Bool {
        guard let text else { return true }
        return text.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII || isCJKIdeograph(scalar) || isByteMatchInertScalar(scalar)
        }
    }

    private static func isCJKIdeograph(_ scalar: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(scalar.value)          // CJK 统一表意文字
            || (0x3400...0x4DBF).contains(scalar.value)   // 扩展 A
            || (0x20000...0x2EBEF).contains(scalar.value) // 扩展 B~F（均无规范分解；
            // 兼容表意补充区 U+2F800+ 每个码位都规范等价于统一表意字，不在此列）
    }

    private static let inertScalarLock = NSLock()
    private static var inertScalarCache: [UInt32: Bool] = [:]

    private static func isByteMatchInertScalar(_ scalar: Unicode.Scalar) -> Bool {
        inertScalarLock.lock()
        defer { inertScalarLock.unlock() }
        if let cached = inertScalarCache[scalar.value] { return cached }
        let inert = computeByteMatchInert(scalar)
        inertScalarCache[scalar.value] = inert
        return inert
    }

    /// 标量对「ASCII/CJK 表意查询的字节匹配」惰性 = 满足四条：
    /// 1. 非组合附标/格式字符（否则会并入相邻字素，改变 Foundation 的字素级匹配边界，
    ///    如 NFD 分解文本 "e" + U+0301）；
    /// 2. 不与相邻 ASCII/CJK 融合为同一字素簇（半角浊点 U+FF9E 是 Lm、emoji 肤色
    ///    修饰符是 Sk、泰文 SARA AM 是 Lo、Prepend 类散布多个类别——无法按
    ///    generalCategory 枚举穷尽，直接用运行时字素分段试探）；
    /// 3. 无规范分解（否则与其他写法规范等价，如兼容表意 U+F914 ≡ 樂、U+212B ≡ Å）；
    /// 4. 大小写折叠不产生 ASCII（排除 ß→ss、ﬁ→fi、ſ→s、K→k 这类跨到 ASCII 的折叠）。
    /// 常见中文标点、全角符号、弯引号、独立 emoji 都满足；可疑字符一律回退 UDF 路径（fail-safe）。
    private static func computeByteMatchInert(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark, .format:
            return false
        default:
            break
        }
        let s = String(scalar)
        // 字素融合试探：与 ASCII/CJK 基字相拼后若合并为单一字素簇（扩展/前置标量），
        // 字节 LIKE 会命中 Foundation 拒绝的「字素中间」位置
        if ("a" + s).count == 1 || (s + "a").count == 1
            || ("中" + s).count == 1 || (s + "中").count == 1 {
            return false
        }
        // 注意：Swift 的 String == 本身按规范等价比较（"\u{F914}" == "樂" 为 true），
        // 判断「有无规范分解」必须在标量序列层面逐一比较，否则永远相等。
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

    /// 列表查询投影：排除 thumbnail BLOB（按行懒加载），文本 content 截断为预览，
    /// 避免 500 条历史把全部缩略图/长文本一次性载入内存。
    private static func listColumns(table: String = "items") -> String {
        "\(table).id, \(table).type, \(table).subtype, " +
        "CASE WHEN \(table).type = 'text' THEN substr(\(table).content, 1, 512) ELSE \(table).content END AS content, " +
        "\(table).image_path, \(table).content_hash, \(table).is_favorite, \(table).fav_sort_order, " +
        "\(table).created_at, \(table).source_app, \(table).alias, \(table).group_id, \(table).like_safe, " +
        "\(table).paste_count, \(table).last_used_at, \(table).frecency"
    }

    /// 正常为 DatabasePool：写走独占串行连接，读走 WAL 快照并发连接——读永不被写阻塞，
    /// 单连接 DatabaseQueue 时代「大图入库/清理事务期间面板唤起排队」的长尾由此消除。
    /// WAL 模式不可用时（罕见：异常文件系统/一次性日志转换失败）回退 DatabaseQueue 保证可用。
    private let dbPool: any DatabaseWriter
    /// 批量维护（自动清理/立即清除/上限裁剪）专用后台队列：这类删除可达秒级，不允许占用调用方线程
    private let maintenanceQueue = DispatchQueue(label: "com.clipora.database.maintenance", qos: .utility)

    private init() {
        let dir = AppPaths.appSupportDirectory
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        // 2 个 reader 上限（惰性创建）：面板列表 + 缩略图两路并发读足够，常驻内存可控
        config.maximumReaderCount = 2
        config.prepareDatabase { db in
            db.add(function: Self.containsCI)
            db.add(function: Self.likeSafeFn)
            // WAL 下的标准组合：NORMAL 只放弃断电瞬间最后一笔提交的持久性，无损坏风险，
            // 换取写提交少一次 fsync（剪贴板历史可接受）
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        let path = dir.appendingPathComponent("clipora.sqlite").path
        do {
            dbPool = try DatabasePool(path: path, configuration: config)
        } catch {
            // 回退单连接串行模式：只损失读写并发，不再让 App 启动即崩溃。
            // 回退连接可能处于回滚日志模式（非 WAL），不设 synchronous=NORMAL，
            // 保持默认 FULL 的断电安全性。
            NSLog("DatabasePool unavailable, falling back to DatabaseQueue: \(error)")
            var queueConfig = Configuration()
            queueConfig.prepareDatabase { db in
                db.add(function: Self.containsCI)
                db.add(function: Self.likeSafeFn)
            }
            dbPool = try! DatabaseQueue(path: path, configuration: queueConfig)
        }
        try! migrator.migrate(dbPool)
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
        migrator.registerMigration("v4_search_fts") { db in
            // 三元索引保留子串搜索体验，同时避开每次输入都扫描全部剪贴板正文。
            // 外部内容表不复制正文；触发器让原有所有写路径自动保持索引一致。
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
            // 非收藏行 (created_at) 部分索引：覆盖每次插入的配额 COUNT、
            // FIFO 淘汰 victims 的排序取值、按天清理的范围删除。
            // 5 万条实测：插入路径的 COUNT 全表扫描 6.3ms → 索引扫描亚毫秒。
            try db.execute(sql: """
                CREATE INDEX idx_items_nonfav_created
                ON items(created_at) WHERE is_favorite = 0
                """)
            // 收藏行 (fav_sort_order) 部分索引：覆盖收藏页排序读取与
            // toggleFavorite 的 MAX(fav_sort_order) 取值，免全表扫描。
            try db.execute(sql: """
                CREATE INDEX idx_items_fav_order
                ON items(fav_sort_order) WHERE is_favorite = 1
                """)
        }
        migrator.registerMigration("v6_like_safe") { db in
            // 行级 LIKE 安全标志（见 CLIPORA_LIKE_SAFE）。默认 0 = 走 UDF 兜底路径，
            // 任何漏算都只损失速度不损失正确性。SET 子句不含 content/alias，
            // 回填不会触发 FTS 重建触发器。
            try db.execute(sql: "ALTER TABLE items ADD COLUMN like_safe INTEGER NOT NULL DEFAULT 0")
            try db.execute(sql: "UPDATE items SET like_safe = CLIPORA_LIKE_SAFE(content, alias)")
        }
        migrator.registerMigration("v7_search_ranking") { db in
            // 搜索相关度排序的行为信号列。frecency 用 Mozilla NewFrecency 的
            // 「对数域时间戳」表示：列值 = 分数恰好衰减到 1 的未来时刻，
            // ORDER BY frecency DESC 即精确指数衰减排序，无需任何定时重算。
            // 回填 = unixepoch(created_at) 使「只复制过一次」的条目层内顺序
            // 与现状 created_at DESC 逐条一致（升级当天排序零回归）。
            // 回填 SET 不含 content/alias，不触发 FTS 重建。
            try db.execute(sql: "ALTER TABLE items ADD COLUMN paste_count INTEGER NOT NULL DEFAULT 0")
            try db.execute(sql: "ALTER TABLE items ADD COLUMN last_used_at DATETIME")
            try db.execute(sql: "ALTER TABLE items ADD COLUMN frecency REAL")
            try db.execute(sql: "UPDATE items SET frecency = unixepoch(created_at)")
            // FTS 列权重持久化（content:alias = 1:3，用户手工命名的别名是最强相关度信号）。
            // 之后查询统一写 ORDER BY rank——单键才走 FTS5 内部快路径（无 temp b-tree）。
            try db.execute(sql: "INSERT INTO items_fts(items_fts, rank) VALUES('rank', 'bm25(1.0, 3.0)')")
        }
        migrator.registerMigration("v8_like_safe_recompute") { db in
            // 审查发现初版惰性分类漏掉字素簇扩展/前置标量（半角浊点/emoji 肤色修饰符/
            // SARA AM 等），规则收紧后按新规则重算全表（CLIPORA_LIKE_SAFE 即新规则；
            // SET 不含 content/alias，不触发 FTS 重建）
            try db.execute(sql: "UPDATE items SET like_safe = CLIPORA_LIKE_SAFE(content, alias)")
        }
        return migrator
    }

    // MARK: - frecency（搜索相关度的行为信号）

    /// 半衰期 7 天：一次粘贴（权重 3）约等效于把纯新近度前移两周
    private static let frecencyLambda = log(2.0) / (7 * 86400.0)
    private static let copyFrecencyWeight = 1.0
    private static let pasteFrecencyWeight = 3.0

    /// 钳制上界一年：合法积累永远到不了（需 e^36 量级的粘贴次数），而时钟异常
    /// 写入的未来时间戳不会在 exp 中溢出为 +Inf 永久置顶，且能随真实时间衰减回落
    private static let frecencyMaxHorizon: TimeInterval = 365 * 86400

    /// Mozilla NewFrecency 对数域更新：F_new = now + ln(e^{λ(F_old−now)} + w) / λ。
    /// 旧值越久远 e^{λΔ} 越接近 0（自然下溢，无需特判）；首次事件（old=nil，w=1）恰为 now，
    /// 与 v7 回填 unixepoch(created_at) 的语义一致。
    static func bumpedFrecency(old: Double?, weight: Double, now: TimeInterval) -> Double {
        let clamped = old.map { $0.isFinite ? min($0, now + frecencyMaxHorizon) : now }
        let decayed = clamped.map { exp(frecencyLambda * ($0 - now)) } ?? 0
        return now + log(decayed + weight) / frecencyLambda
    }

    private func notifyChange() {
        // 任何写入都可能改变风险行分布，去抖档位的缓存计数一并失效（惰性重算）
        riskyCountLock.lock()
        cachedRiskyCount = nil
        riskyCountLock.unlock()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .clipStoreDidChange, object: nil)
        }
    }

    /// 写库统一外壳：成功后广播变更，失败仅记日志（保持“写库不会崩 App”的既有行为）。
    /// 返回是否提交成功，供调用方决定事务外的连带清理（如删除落盘图片）是否执行。
    @discardableResult
    private func performWrite(_ name: String, _ block: (Database) throws -> Void) -> Bool {
        do {
            try dbPool.write(block)
            notifyChange()
            return true
        } catch {
            NSLog("\(name) failed: \(error)")
            return false
        }
    }

    /// 批量删除条目，并连带清理各自落盘的原图（保证“删条目必删图”，杜绝孤儿 PNG）。
    /// 文件删除挂到事务提交之后：回滚时行还在，先删文件会留下悬空 image_path。
    private static func deleteItems(_ victims: [ClipItem], _ db: Database) throws {
        let paths = victims.compactMap(\.imagePath)
        for victim in victims {
            try victim.delete(db)
        }
        if !paths.isEmpty {
            db.afterNextTransaction(onCommit: { _ in
                for path in paths { ImageStore.delete(path: path) }
            })
        }
    }

    // MARK: - 写入

    /// 插入新条目；同 (type, hash) 已存在时仅更新时间戳置顶（去重）
    func insertOrBump(_ item: ClipItem) {
        var item = item
        // 行级 LIKE 安全标志在事务外计算（大文本需线性扫描，不占写锁）
        item.likeSafe = Self.isLikeSafe(content: item.content, alias: item.alias)
        // 首次复制的 frecency = 复制时刻（与 v7 回填语义一致）
        item.frecency = item.createdAt.timeIntervalSince1970
        performWrite("insertOrBump") { db in
            // 去重命中只需要旧行的 image_path（清理重复落盘的原图）与 frecency，不取整行；
            // 置顶只 SET created_at/frecency——SET 子句一旦含 content，AFTER UPDATE OF content
            // 触发器就会对全文重建 trigram 索引（无论值是否变化），大文本可达百 ms 级。
            let existing = try Row.fetchOne(
                db,
                sql: "SELECT image_path, frecency FROM items WHERE type = ? AND content_hash = ?",
                arguments: [item.type.rawValue, item.contentHash]
            )
            if let existing {
                // 重复复制也是相关度信号（权重 1）
                let frecency = Self.bumpedFrecency(
                    old: existing["frecency"] as Double?,
                    weight: Self.copyFrecencyWeight,
                    now: item.createdAt.timeIntervalSince1970
                )
                try db.execute(
                    sql: "UPDATE items SET created_at = ?, frecency = ? WHERE type = ? AND content_hash = ?",
                    arguments: [item.createdAt, frecency, item.type.rawValue, item.contentHash]
                )
                let existingPath = existing["image_path"] as String?
                if let newPath = item.imagePath, newPath != existingPath {
                    if let existingPath, ImageStore.fileExists(path: existingPath) {
                        // 新条目为重复项且旧原图完好：清理刚落盘的重复原图
                        ImageStore.delete(path: newPath)
                    } else {
                        // 旧原图缺失（清理竞态/外部删除）：收养新落盘的原图自愈。
                        // SET 不含 content/alias，不触发 FTS 重建。
                        try db.execute(
                            sql: "UPDATE items SET image_path = ? WHERE type = ? AND content_hash = ?",
                            arguments: [newPath, item.type.rawValue, item.contentHash]
                        )
                    }
                }
            } else {
                var newItem = item
                try newItem.insert(db)
                try Self.enforceHistoryLimit(db)
            }
        }
    }

    /// FIFO 淘汰：非收藏条目超过上限时删最旧，并清理落盘图片。
    /// 只取 image_path 轻列 + 单条批量 DELETE，不整行解码（含 BLOB）也不逐行删。
    private static func enforceHistoryLimit(_ db: Database) throws {
        let count = try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM items WHERE is_favorite = 0"
        ) ?? 0
        let overflow = count - AppSettings.historyLimit
        guard overflow > 0 else { return }
        let victimsSQL =
            "SELECT id FROM items WHERE is_favorite = 0 ORDER BY created_at ASC, id ASC LIMIT ?"
        let paths = try String.fetchAll(
            db,
            sql: "SELECT image_path FROM items WHERE id IN (\(victimsSQL)) AND image_path IS NOT NULL",
            arguments: [overflow]
        )
        try db.execute(sql: "DELETE FROM items WHERE id IN (\(victimsSQL))", arguments: [overflow])
        // 文件删除挂到事务提交之后：COMMIT 失败回滚时行还在，先删文件会留下悬空 image_path
        if !paths.isEmpty {
            db.afterNextTransaction(onCommit: { _ in
                for path in paths { ImageStore.delete(path: path) }
            })
        }
    }

    // MARK: - 查询

    /// 异步加载历史。数据库读取和记录解码都在后台读连接（WAL 快照，不被写阻塞），回调固定回到主线程。
    func loadHistory(matching query: String = "", completion: @escaping ([ClipItem]) -> Void) {
        readAsync("loadHistory", { db in
            try Self.fetchHistory(in: db, matching: query)
        }) { result in
            switch result {
            case .success(let items): completion(items)
            case .failure: completion([])
            }
        }
    }

    /// 异步加载收藏和分组，保证面板不会为了更新胶囊栏在主线程读取数据库。
    func loadFavorites(
        matching query: String = "", groupId: Int64? = nil,
        completion: @escaping ([ClipItem], [ClipGroup]) -> Void
    ) {
        readAsync("loadFavorites", { db in
            let items = try Self.fetchFavorites(in: db, matching: query, groupId: groupId)
            let groups = try ClipGroup
                .order(ClipGroup.Columns.sortOrder.asc, ClipGroup.Columns.id.asc)
                .fetchAll(db)
            return (items, groups)
        }) { result in
            switch result {
            case .success(let value): completion(value.0, value.1)
            case .failure: completion([], [])
            }
        }
    }

    /// 缩略图也在后台读连接加载，避免列表 reload 时可见图片行阻塞输入事件。
    func loadThumbnail(id: Int64, completion: @escaping (Data?) -> Void) {
        readAsync("loadThumbnail", { db in
            try Data.fetchOne(db, sql: "SELECT thumbnail FROM items WHERE id = ?", arguments: [id])
        }) { result in
            switch result {
            case .success(let data): completion(data)
            case .failure: completion(nil)
            }
        }
    }

    private func readAsync<T>(
        _ name: String, _ block: @escaping (Database) throws -> T,
        completion: @escaping (Result<T, Error>) -> Void
    ) {
        dbPool.asyncRead { dbResult in
            do {
                let result = try block(dbResult.get())
                DispatchQueue.main.async { completion(.success(result)) }
            } catch {
                NSLog("\(name) failed: \(error)")
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private static func fetchHistory(in db: Database, matching query: String) throws -> [ClipItem] {
        var sql = "SELECT \(listColumns()) FROM items"
        var arguments: [DatabaseValueConvertible] = []
        let branch = appendSearchFilter(to: &sql, arguments: &arguments, query: query, joinsFTS: false)
        guard branch != .none, AppSettings.searchByRelevance else {
            // 空查询保持时间线（唤起 → 回车 = 粘贴刚复制的，肌肉记忆）；
            // 「按时间」设置项是相关度排序的逃生门
            sql += " ORDER BY items.created_at DESC, items.id DESC LIMIT 2000"
            return try ClipItem.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
        }
        // 相关度两段式：内层选候选窗口——FTS 分支取 bm25 top-2000（单键 ORDER BY rank
        // 才走 FTS5 内部快路径，加第二键或显式 bm25() 都会退化出 temp b-tree），
        // 扫描分支保持 created_at 索引早停；外层只对 ≤2000 行窗口精排：
        // 匹配质量分层（别名前缀 > 别名子串 > 内容前缀 > 正文深处）→ frecency
        // （复制/粘贴行为的指数衰减分）→ created_at, id 确定性平局键。
        // 层级 LIKE 只是排序提示，不改命中集（召回语义仍由内层 WHERE 决定）。
        sql += branch == .fts
            ? " ORDER BY rank LIMIT 2000"
            : " ORDER BY items.created_at DESC, items.id DESC LIMIT 2000"
        let prefix = likeEscaped(query) + "%"
        let substring = "%" + likeEscaped(query) + "%"
        let ranked = "SELECT w.* FROM (\(sql)) AS w ORDER BY"
            + " CASE WHEN w.alias LIKE ? ESCAPE '\\' THEN 0"
            + " WHEN w.alias LIKE ? ESCAPE '\\' THEN 1"
            + " WHEN w.content LIKE ? ESCAPE '\\' THEN 2"
            + " ELSE 3 END,"
            + " w.frecency DESC, w.created_at DESC, w.id DESC"
        arguments += [prefix, substring, prefix]
        return try ClipItem.fetchAll(db, sql: ranked, arguments: StatementArguments(arguments))
    }

    private static func fetchFavorites(
        in db: Database, matching query: String, groupId: Int64?
    ) throws -> [ClipItem] {
        let useFTS = usesFTS(for: query)
        var sql = "SELECT \(listColumns()) FROM items"
        if useFTS { sql += " JOIN items_fts ON items_fts.rowid = items.id" }
        sql += " WHERE items.is_favorite = 1"
        var arguments: [DatabaseValueConvertible] = []
        if let groupId {
            sql += " AND items.group_id = ?"
            arguments.append(groupId)
        }
        appendSearchFilter(to: &sql, arguments: &arguments, query: query, joinsFTS: useFTS)
        // id ASC 作为平局兜底，防止历史脏数据里重复的 fav_sort_order 导致顺序不确定
        sql += " ORDER BY items.fav_sort_order ASC, items.id ASC"
        return try ClipItem.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
    }

    /// 搜索谓词分支：none = 空查询；fts = trigram MATCH；scan = LIKE/UDF 全表扫描
    private enum SearchBranch { case none, fts, scan }

    @discardableResult
    private static func appendSearchFilter(
        to sql: inout String, arguments: inout [DatabaseValueConvertible], query: String, joinsFTS: Bool
    ) -> SearchBranch {
        guard !query.isEmpty else { return .none }
        if joinsFTS {
            sql += " AND items_fts MATCH ?"
            arguments.append(ftsPhrase(query))
            return .fts
        } else if usesFTS(for: query) {
            // History starts without a WHERE clause, so attach its FTS join and predicate together.
            sql = sql.replacingOccurrences(of: " FROM items", with: " FROM items JOIN items_fts ON items_fts.rowid = items.id")
            sql += " WHERE items_fts MATCH ?"
            arguments.append(ftsPhrase(query))
            return .fts
        } else if isNativeLikeSafe(query) {
            // 1-2 字符的短词不被 trigram 覆盖，需全表子串扫描。查询只含 ASCII/CJK 表意
            // 且行内容字节匹配惰性（like_safe = 1）时，原生 LIKE 与 Foundation 大小写
            // 不敏感语义逐字节等价，而 C 实现比逐行回调 Swift 函数快一个数量级；
            // 含组合附标/可分解字符/跨 ASCII 折叠字符的行（like_safe = 0）回退
            // CONTAINS_CI，保证整体命中集与旧全量 UDF 扫描完全一致。
            let pattern = "%" + likeEscaped(query) + "%"
            sql += sql.contains(" WHERE ") ? " AND" : " WHERE"
            sql += " ((items.like_safe = 1 AND (items.content LIKE ? ESCAPE '\\' OR items.alias LIKE ? ESCAPE '\\'))"
            sql += " OR (items.like_safe = 0 AND (CLIPORA_CONTAINS_CI(items.content, ?) OR CLIPORA_CONTAINS_CI(items.alias, ?))))"
            arguments += [pattern, pattern, query, query]
            return .scan
        } else {
            // 其余脚本（重音拉丁/西里尔/假名/谚文等）涉及 Unicode 大小写折叠与规范等价，
            // 保持原有 Foundation 子串语义。
            sql += sql.contains(" WHERE ") ? " AND" : " WHERE"
            sql += " (CLIPORA_CONTAINS_CI(items.content, ?) OR CLIPORA_CONTAINS_CI(items.alias, ?))"
            arguments += [query, query]
            return .scan
        }
    }

    /// 查询里只有 ASCII 与 CJK 统一表意文字（无规范分解、无跨 ASCII 折叠）时，
    /// 对 like_safe = 1 的行原生 LIKE 与 Foundation 大小写不敏感子串语义一致
    private static func isNativeLikeSafe(_ query: String) -> Bool {
        query.unicodeScalars.allSatisfy { $0.isASCII || isCJKIdeograph($0) }
    }

    /// LIKE 通配符转义（% _ 与转义符自身），保持与 CONTAINS_CI 相同的「全字面量」语义
    private static func likeEscaped(_ query: String) -> String {
        query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static func usesFTS(for query: String) -> Bool { query.count >= 3 }

    /// like_safe = 0（UDF 回退）行数的惰性缓存：短查询即使通过查询门槛，
    /// 实际速度也取决于库内风险行规模（谚文/越南语等可分解脚本为主的语料
    /// 几乎全部回退 UDF）。写库后失效、后台重算；未知期间按快路径处理
    /// （偏差至多一轮去抖间隔）。
    private let riskyCountLock = NSLock()
    private var cachedRiskyCount: Int?
    private var riskyCountRefreshing = false

    private func riskyRowCount() -> Int? {
        riskyCountLock.lock()
        let cached = cachedRiskyCount
        var shouldRefresh = false
        if cached == nil && !riskyCountRefreshing {
            riskyCountRefreshing = true
            shouldRefresh = true
        }
        riskyCountLock.unlock()
        if shouldRefresh {
            dbPool.asyncRead { [weak self] result in
                let count = (try? result.get()).flatMap { db in
                    try? Int.fetchOne(db, sql: "SELECT COUNT(*) FROM items WHERE like_safe = 0")
                }
                guard let self else { return }
                self.riskyCountLock.lock()
                self.cachedRiskyCount = count ?? 0
                self.riskyCountRefreshing = false
                self.riskyCountLock.unlock()
            }
        }
        return cached
    }

    /// 查询是否走快路径。UDF 全表回退（1-2 字符谚文/假名/重音拉丁查询，
    /// 或风险行占比高的库里任意短查询）在大库上单次可达数百 ms，
    /// 调用方据此选择更长的去抖间隔防止查询积压。
    func isFastSearchQuery(_ query: String) -> Bool {
        if query.isEmpty || Self.usesFTS(for: query) { return true }
        guard Self.isNativeLikeSafe(query) else { return false }
        // 风险行超阈值时 UDF 回退子集本身就是慢查询（全风险语料实测与旧全量扫描同量级）
        return (riskyRowCount() ?? 0) < 2000
    }

    private static func ftsPhrase(_ query: String) -> String {
        "\"\(query.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    /// 列表行的 content 为截断预览；复制文本时按 id 取全文回写剪贴板
    func fullContent(id: Int64) -> String? {
        (try? dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT content FROM items WHERE id = ?", arguments: [id])
        }) ?? nil
    }

    /// 缩略图按可见行懒加载，避免列表查询携带全部 BLOB
    func thumbnail(id: Int64) -> Data? {
        (try? dbPool.read { db in
            try Data.fetchOne(db, sql: "SELECT thumbnail FROM items WHERE id = ?", arguments: [id])
        }) ?? nil
    }

    /// 图片去重预检：同哈希行已存在且其原图文件仍在磁盘上。
    /// 行在文件不在（清理竞态/外部删除）时返回 false，让调用方重新落盘、
    /// 由 insertOrBump 收养新图自愈。
    func hasStoredImage(contentHash: String) -> Bool {
        let imagePath: String? = (try? dbPool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT image_path FROM items WHERE type = ? AND content_hash = ? AND image_path IS NOT NULL",
                arguments: [ClipType.image.rawValue, contentHash]
            )
        }) ?? nil
        guard let imagePath else { return false }
        return ImageStore.fileExists(path: imagePath)
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
                // created_at 人为前移时同步抬升 frecency（取 max 保留粘贴积累），
                // 维持「未被使用条目的层内序 = 时间序」的不变量，避免该条在相关度
                // 搜索里沉到层内底部而时间线上却排最前的割裂
                item.frecency = max(
                    item.frecency ?? 0, item.createdAt.timeIntervalSince1970
                )
            } else {
                let maxOrder = try Int.fetchOne(
                    db, sql: "SELECT MAX(fav_sort_order) FROM items WHERE is_favorite = 1"
                ) ?? 0
                item.isFavorite = true
                item.favSortOrder = maxOrder + 1
            }
            // 定向更新五列，SET 不含 content/alias 即不触发 FTS 重建触发器
            try item.update(db, columns: [
                ClipItem.Columns.isFavorite,
                ClipItem.Columns.favSortOrder,
                ClipItem.Columns.groupId,
                ClipItem.Columns.createdAt,
                ClipItem.Columns.frecency,
            ])
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
            // 别名参与短查询路由，需同步重算行级 LIKE 安全标志（UDF 就地读 content）
            try db.execute(
                sql: "UPDATE items SET alias = ?, like_safe = CLIPORA_LIKE_SAFE(content, ?) WHERE id = ?",
                arguments: [value, value, id]
            )
        }
    }

    // MARK: - 收藏分组

    func groups() -> [ClipGroup] {
        (try? dbPool.read { db in
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
            let id = try dbPool.write { db -> Int64? in
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

    /// 自动清理：删除 cutoff 之前的非收藏条目（后台执行，调用方线程不阻塞）
    func cleanup(olderThan days: Int) {
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-TimeInterval(days) * 86400)
        maintenanceQueue.async { [self] in
            deleteNonFavorites("cleanup", olderThan: cutoff)
        }
    }

    /// 「立即清除」：清空确认时刻已存在的非收藏历史（后台执行）。
    /// 以确认时刻的最大 id 为删除上界（rowid 单调递增，不受时钟异常影响）：
    /// 点击后新复制的条目不误删，时钟错乱产生的「未来时间戳」旧行也不漏删。
    func clearNonFavorites() {
        let maxId = (try? dbPool.read { db in
            try Int64.fetchOne(db, sql: "SELECT MAX(id) FROM items")
        }) ?? nil
        guard let maxId else { return }
        maintenanceQueue.async { [self] in
            deleteNonFavorites("clearNonFavorites", olderThan: nil, upToId: maxId)
        }
    }

    /// 粘贴回写信号：粘贴是比复制更强的「这条有用」信号（权重 3），提升其搜索排序。
    /// 后台执行（不阻塞面板关闭动画）、静默写不广播（面板已关闭，无需刷新）；
    /// SET 不含 content/alias，不触发 FTS 重建。挂在 maintenanceQueue 上，
    /// 退出前的 drainMaintenance 一并保证落库。
    func recordPaste(id: Int64) {
        maintenanceQueue.async { [self] in
            do {
                try dbPool.write { db in
                    let old = try Double.fetchOne(
                        db, sql: "SELECT frecency FROM items WHERE id = ?", arguments: [id]
                    )
                    let now = Date()
                    let frecency = Self.bumpedFrecency(
                        old: old, weight: Self.pasteFrecencyWeight,
                        now: now.timeIntervalSince1970
                    )
                    try db.execute(
                        sql: "UPDATE items SET frecency = ?, paste_count = paste_count + 1, last_used_at = ? WHERE id = ?",
                        arguments: [frecency, now, id]
                    )
                }
            } catch {
                NSLog("recordPaste failed: \(error)")
            }
        }
    }

    /// 退出前排空维护队列：让已入队的删除（含用户确认过的「立即清除」）先完成再退出，
    /// 不静默丢弃。completion 固定回主线程；超时兜底防止异常时卡死退出流程。
    func drainMaintenance(timeout: TimeInterval, completion: @escaping () -> Void) {
        var completed = false
        let finish = {  // 两条路径都在主线程执行，无并发访问
            if !completed {
                completed = true
                completion()
            }
        }
        maintenanceQueue.async {
            DispatchQueue.main.async(execute: finish)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: finish)
    }

    /// 历史上限调低后立即按新上限裁剪（后台执行；无超额时为空操作）
    func trimHistoryToLimit() {
        maintenanceQueue.async { [self] in
            performWrite("trimHistoryToLimit") { db in
                try Self.enforceHistoryLimit(db)
            }
        }
    }

    /// 删除非收藏条目；cutoff 限定创建时间上界（自动清理），upToId 限定 id 上界
    /// （「立即清除」的确认时刻快照），都为 nil 时清空全部非收藏。
    /// 轻列查询 + 单条批量 DELETE（FTS 触发器逐行维护索引）；
    /// 落盘图片在事务提交后删除——中途崩溃至多留下无引用的孤儿文件，绝不出现悬空引用。
    private func deleteNonFavorites(_ name: String, olderThan cutoff: Date?, upToId: Int64? = nil) {
        var whereClause = "is_favorite = 0"
        var arguments: [DatabaseValueConvertible] = []
        if let cutoff {
            whereClause += " AND created_at < ?"
            arguments.append(cutoff)
        }
        if let upToId {
            whereClause += " AND id <= ?"
            arguments.append(upToId)
        }
        var orphanedImages: [String] = []
        let committed = performWrite(name) { db in
            orphanedImages = try String.fetchAll(
                db,
                sql: "SELECT image_path FROM items WHERE \(whereClause) AND image_path IS NOT NULL",
                arguments: StatementArguments(arguments)
            )
            try db.execute(
                sql: "DELETE FROM items WHERE \(whereClause)",
                arguments: StatementArguments(arguments)
            )
        }
        // 只在事务确认提交后删除文件：回滚时行还在，不能留下悬空 image_path
        guard committed else { return }
        for path in orphanedImages { ImageStore.delete(path: path) }
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
