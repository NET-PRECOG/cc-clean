import Foundation
import GRDB

/// SQLite 数据库入口（基线 8：GRDB DatabasePool WAL 模式 + DatabaseMigrator 逐版本迁移
/// + 损坏自愈）。迁移只增不改（基线 8.3：新增列用 ALTER ADD COLUMN，禁止修改已发布迁移）。
public struct DatabaseStore: Sendable {

    public let pool: DatabasePool
    public let fileURL: URL

    private init(pool: DatabasePool, fileURL: URL) {
        self.pool = pool
        self.fileURL = fileURL
    }

    /// 打开（或创建）数据库并执行迁移；损坏时自动重建（基线 8.5 要点 2）。
    public static func open(at url: URL, logger: Logger) throws -> DatabaseStore {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        do {
            return try openAndMigrate(url: url, logger: logger)
        } catch {
            logger.error("database unusable at \(url.path), rebuilding: \(String(describing: error))")
            quarantineCorrupt(at: url)
            return try openAndMigrate(url: url, logger: logger)
        }
    }

    private static func openAndMigrate(url: URL, logger: Logger) throws -> DatabaseStore {
        let pool = try DatabasePool(path: url.path)
        var migrator = migrator()
        try migrator.migrate(pool)
        logger.info("database ready: \(url.path)")
        return DatabaseStore(pool: pool, fileURL: url)
    }

    /// 损坏隔离：主库 + WAL/SHM 一并重命名为 .corrupt-<ts>（保留供用户诊断，不静默删除）。
    static func quarantineCorrupt(at url: URL) {
        let stamp = Int(Date().timeIntervalSince1970)
        for suffix in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: url.path + suffix)
            let dst = URL(fileURLWithPath: url.path + suffix)
                .deletingLastPathComponent()
                .appendingPathComponent(url.deletingPathExtension().lastPathComponent + suffix)
                .appendingPathExtension("corrupt-\(stamp)")
            try? FileManager.default.moveItem(at: src, to: dst)
        }
    }

    /// 迁移定义。v1_0 全部建表 SQL 来自基线 8.2，禁止修改已发布迁移。
    public static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_0") { db in
            // 应用台账
            try db.execute(sql: """
            CREATE TABLE app_record (
                bundle_id           TEXT PRIMARY KEY,
                bundle_path         TEXT NOT NULL,
                display_name        TEXT NOT NULL,
                bundle_name         TEXT,
                executable_name     TEXT,
                short_version       TEXT,
                build_version       TEXT,
                team_identifier     TEXT,
                minimum_system      TEXT,
                install_source      TEXT NOT NULL,
                signature           TEXT NOT NULL,
                architecture        TEXT,
                size_bytes          INTEGER,
                data_bytes          INTEGER,
                cache_bytes         INTEGER,
                install_date        REAL,
                install_confidence  INTEGER NOT NULL,
                last_used_date      REAL,
                is_protected        INTEGER NOT NULL DEFAULT 0,
                is_running          INTEGER NOT NULL DEFAULT 0,
                scanned_at          REAL NOT NULL
            )
            """)
            try db.execute(sql: "CREATE INDEX idx_app_source ON app_record(install_source)")
            try db.execute(sql: "CREATE INDEX idx_app_size   ON app_record(size_bytes DESC)")

            // 体积缓存
            try db.execute(sql: """
            CREATE TABLE size_cache (
                bundle_path TEXT PRIMARY KEY,
                mtime       REAL NOT NULL,
                size_bytes  INTEGER NOT NULL,
                updated_at  REAL NOT NULL
            )
            """)

            // FS 索引
            try db.execute(sql: """
            CREATE TABLE node (
                path         TEXT PRIMARY KEY,
                parent       TEXT NOT NULL,
                root_id      INTEGER NOT NULL,
                is_dir       INTEGER NOT NULL,
                alloc_size   INTEGER NOT NULL,
                logical_size INTEGER NOT NULL,
                mtime        REAL NOT NULL,
                inode        INTEGER NOT NULL,
                depth        INTEGER NOT NULL
            )
            """)
            try db.execute(sql: "CREATE INDEX idx_node_parent ON node(parent)")
            try db.execute(sql: "CREATE INDEX idx_node_size   ON node(alloc_size DESC)")
            try db.execute(sql: "CREATE INDEX idx_node_root   ON node(root_id, depth)")

            try db.execute(sql: """
            CREATE TABLE root_index (
                root_path    TEXT PRIMARY KEY,
                last_indexed REAL NOT NULL,
                node_count   INTEGER NOT NULL,
                cursor       TEXT,
                stale        INTEGER NOT NULL DEFAULT 0
            )
            """)

            // pkgutil receipt 缓存（基线 8.1 表清单）
            try db.execute(sql: """
            CREATE TABLE pkg_receipts (
                pkg_id       TEXT PRIMARY KEY,
                install_time REAL,
                volume       TEXT,
                location     TEXT,
                fetched_at   REAL NOT NULL
            )
            """)

            // 版本缓存
            try db.execute(sql: """
            CREATE TABLE version_cache (
                bundle_id    TEXT PRIMARY KEY,
                latest       TEXT,
                source       TEXT NOT NULL,
                confidence   TEXT NOT NULL,
                download_url TEXT,
                notes_url    TEXT,
                checked_at   REAL NOT NULL
            )
            """)

            // 守护项
            try db.execute(sql: """
            CREATE TABLE launchd_entry (
                label        TEXT PRIMARY KEY,
                plist_path   TEXT NOT NULL,
                domain       TEXT NOT NULL,
                program      TEXT,
                args_json    TEXT,
                run_at_load  INTEGER,
                keep_alive   INTEGER,
                owner_bundle TEXT,
                is_system    INTEGER NOT NULL DEFAULT 0,
                healthy      INTEGER NOT NULL DEFAULT 1,
                last_exit    INTEGER,
                scanned_at   REAL NOT NULL
            )
            """)
            try db.execute(sql: "CREATE INDEX idx_launchd_owner ON launchd_entry(owner_bundle)")

            // 卸载历史
            try db.execute(sql: """
            CREATE TABLE uninstall_history (
                plan_id     TEXT PRIMARY KEY,
                app_id      TEXT NOT NULL,
                app_name    TEXT NOT NULL,
                plan_json   BLOB NOT NULL,
                report_json BLOB,
                created_at  REAL NOT NULL,
                finished_at REAL,
                undone_at   REAL
            )
            """)

            // 事务日志
            try db.execute(sql: """
            CREATE TABLE operation_journal (
                journal_id   TEXT PRIMARY KEY,
                title        TEXT NOT NULL,
                module       TEXT,
                ops_json     BLOB NOT NULL,
                result_json  BLOB,
                status       TEXT NOT NULL,
                created_at   REAL NOT NULL,
                committed_at REAL,
                undone_at    REAL
            )
            """)

            // 清理审计
            try db.execute(sql: """
            CREATE TABLE cleanup_history (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                rule_id    TEXT NOT NULL,
                paths_json BLOB NOT NULL,
                bytes      INTEGER NOT NULL,
                journal_id TEXT,
                created_at REAL NOT NULL
            )
            """)

            // 能力审计
            try db.execute(sql: """
            CREATE TABLE capability_audit (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                capability TEXT NOT NULL,
                status     TEXT NOT NULL,
                reason     TEXT,
                probed_at  REAL NOT NULL
            )
            """)
        }

        // metric_sample / rule_cache 引入版本为 v1_1 / v1_2（基线 8.1），
        // 到对应版本开发时以新迁移项添加，禁止并入 v1_0。

        // v1_1：metric_sample（S12 监控内核，降采样落库）
        migrator.registerMigration("v1_1_metric_sample") { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS metric_sample (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                kind        TEXT NOT NULL,
                value       REAL NOT NULL,
                detail      TEXT,
                sampled_at  REAL NOT NULL
            )
            """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_metric_kind ON metric_sample(kind, sampled_at)")
        }

        return migrator
    }

    /// 全部已建表名（诊断与测试用）。
    public func tableNames() async throws -> Set<String> {
        try await pool.read { db in
            let rows = try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
            )
            return Set(rows)
        }
    }

    /// 最新一条指标值（kind = MetricKind.rawValue；无记录 → nil）。E14 Widget 数据源。
    public func latestMetricValue(kind: String) async -> Double? {
        (try? await pool.read { db in
            try Double.fetchOne(
                db, sql: """
                SELECT value FROM metric_sample WHERE kind = ? ORDER BY sampled_at DESC LIMIT 1
                """, arguments: [kind])
        }) ?? nil
    }

    /// E12 监控历史导出（metric_sample 全量 → CSV 字符串；基线 E12）。
    public func exportMetricHistoryCSV() async -> String? {
        do {
            // Row 非 Sendable——在 @Sendable 闭包内转换为简单元组
            let rows: [(ts: Double, kind: String, value: Double, detail: String?)] = try await pool.read { db in
                try Row.fetchAll(db, sql: """
                SELECT sampled_at, kind, value, detail FROM metric_sample ORDER BY sampled_at ASC
                """).map { row -> (Double, String, Double, String?) in
                    (
                        row["sampled_at"] ?? 0,
                        row["kind"] ?? "",
                        row["value"] ?? 0,
                        row["detail"]
                    )
                }
            }
            guard !rows.isEmpty else { return nil }
            var csv = "timestamp,kind,value,detail\n"
            for row in rows {
                let tsStr = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: row.ts))
                let detailEscaped = (row.detail ?? "").replacingOccurrences(of: ",", with: "\"")
                csv += "\(tsStr),\(row.kind),\(String(format: "%.2f", row.value)),\(detailEscaped)\n"
            }
            return csv
        } catch {
            return nil
        }
    }
}