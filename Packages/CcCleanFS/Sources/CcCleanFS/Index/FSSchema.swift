import Foundation
import GRDB
import CcCleanCore

/// FS 层统一 schema：fsindex_v1（node/root_index）+ fsindex_v2（size_cache）。
/// 所有 FS 包 actor 共用同一 migrator（基线 8.3：迁移只增不改）。
enum FSSchema {
    static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("fsindex_v1") { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS node (
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
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_node_parent ON node(parent)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_node_size   ON node(alloc_size DESC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_node_root   ON node(root_id, depth)")
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS root_index (
                root_path    TEXT PRIMARY KEY,
                last_indexed REAL NOT NULL,
                node_count   INTEGER NOT NULL,
                cursor       TEXT,
                stale        INTEGER NOT NULL DEFAULT 0
            )
            """)
        }

        migrator.registerMigration("fsindex_v2") { db in
            // 基线 8.2 size_cache
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS size_cache (
                bundle_path TEXT PRIMARY KEY,
                mtime       REAL NOT NULL,
                size_bytes  INTEGER NOT NULL,
                updated_at  REAL NOT NULL
            )
            """)
        }

        return migrator
    }
}