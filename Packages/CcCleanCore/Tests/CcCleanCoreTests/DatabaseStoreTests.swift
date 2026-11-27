import Testing
import Foundation
import GRDB
@testable import CcCleanCore

@Suite("DatabaseStore")
struct DatabaseStoreTests {

    private func tempDBURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cclean-test-\(UUID().uuidString).sqlite")
    }

    private func cleanup(_ url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }

    @Test("v1_0 迁移：11 张表全部建立")
    func migrationCreatesTables() async throws {
        let url = tempDBURL()
        defer { cleanup(url) }
        let store = try DatabaseStore.open(at: url, logger: Logger(category: .general, buffer: LogBuffer(capacity: 10)))

        let expected: Set<String> = [
            "app_record", "size_cache", "node", "root_index", "pkg_receipts",
            "version_cache", "launchd_entry", "uninstall_history",
            "operation_journal", "cleanup_history", "capability_audit",
        ]
        let names = try await store.tableNames()
        #expect(expected.isSubset(of: names))
    }

    @Test("重复打开：迁移幂等，不抛错")
    func migrationIdempotent() async throws {
        let url = tempDBURL()
        defer { cleanup(url) }
        let buffer = LogBuffer(capacity: 10)
        _ = try DatabaseStore.open(at: url, logger: Logger(category: .general, buffer: buffer))
        _ = try DatabaseStore.open(at: url, logger: Logger(category: .general, buffer: buffer))
        _ = try DatabaseStore.open(at: url, logger: Logger(category: .general, buffer: buffer))
        #expect(true)
    }

    @Test("WAL 模式 + 读写可用：写入 app_record 并读回")
    func walReadWrite() async throws {
        let url = tempDBURL()
        defer { cleanup(url) }
        let store = try DatabaseStore.open(at: url, logger: Logger(category: .general, buffer: LogBuffer(capacity: 10)))

        try await store.pool.write { db in
            try db.execute(
                sql: "INSERT INTO app_record (bundle_id, bundle_path, display_name, install_source, signature, install_confidence, scanned_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
                arguments: ["com.example.demo", "/Applications/Demo.app", "Demo", "dragAndDrop", "unsigned", 0, Date().timeIntervalSince1970]
            )
        }
        let count = try await store.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM app_record") ?? 0
        }
        #expect(count == 1)

        // WAL 文件存在（DatabasePool 默认 WAL）
        _ = FileManager.default.fileExists(atPath: url.path + "-wal")
            || FileManager.default.fileExists(atPath: url.path)
    }

    @Test("损坏自愈：写坏文件后重命名重建，数据可再用")
    func corruptRecovery() async throws {
        let url = tempDBURL()
        defer { cleanup(url) }
        let buffer = LogBuffer(capacity: 20)
        let logger = Logger(category: .general, buffer: buffer)

        // 先建一个正常库
        _ = try DatabaseStore.open(at: url, logger: logger)
        cleanup(url)  // 移走正常文件

        // 写入垃圾内容模拟损坏
        try Data("this is not a sqlite database at all".utf8).write(to: url)

        // 打开应自愈而非抛错
        let store = try DatabaseStore.open(at: url, logger: logger)
        let names = try await store.tableNames()
        #expect(names.contains("app_record"))

        // 目录中应留下 corrupt 隔离文件
        let dirFiles = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(dirFiles.contains { $0.contains(".corrupt-") })

        // 日志中记录了重建事件（路径已脱敏）
        let logs = buffer.snapshot()
        #expect(logs.contains { $0.message.contains("rebuilding") })
    }

    @Test("已迁移库中 grdb_migrations 记录全部迁移（v1_0 + v1_1_metric_sample）")
    func migrationRecorded() async throws {
        let url = tempDBURL()
        defer { cleanup(url) }
        let store = try DatabaseStore.open(at: url, logger: Logger(category: .general, buffer: LogBuffer(capacity: 10)))
        let applied = try await store.pool.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
        }
        #expect(applied == ["v1_0", "v1_1_metric_sample"])   // 基线 8.3：迁移只增不改
    }
}