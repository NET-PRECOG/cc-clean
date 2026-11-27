import Foundation
import GRDB
import CcCleanCore

/// 应用台账仓库（A1）：扫描 → app_record 全量覆盖写入；二次启动读缓存（< 1.5s，基线 2.5）。
public actor AppInventoryRepository {

    private let store: DatabaseStore
    private let scanner: AppScanner

    public init(store: DatabaseStore, scanner: AppScanner) {
        self.store = store
        self.scanner = scanner
    }

    /// 全量刷新：扫描（元数据阶段）→ 覆盖写 app_record → 返回记录。
    public func refresh() async -> [AppRecord] {
        let records = await scanner.scan()
        await upsert(records)
        return records
    }

    /// 读缓存台账（二次启动路径）。
    public func loadCached() async -> [AppRecord] {
        do {
            return try await store.pool.read { db in
                try Row.fetchAll(db, sql: """
                SELECT bundle_id, bundle_path, display_name, bundle_name, executable_name,
                       short_version, build_version, team_identifier, minimum_system,
                       install_source, signature, architecture, size_bytes, data_bytes,
                       cache_bytes, install_date, install_confidence, last_used_date,
                       is_protected, is_running, scanned_at
                FROM app_record
                """).map(Self.rowToRecord)
            }
        } catch {
            return []
        }
    }

    /// 按 bundleId 查单条。
    public func record(bundleId: String) async -> AppRecord? {
        (await loadCached()).first { $0.bundleId == bundleId }
    }

    /// 更新体积字段（SizeCache 增量推送后落库）。
    public func updateSize(bundlePath: String, sizeBytes: Int64) async {
        _ = try? await store.pool.write { db in
            try db.execute(
                sql: "UPDATE app_record SET size_bytes = ? WHERE bundle_path = ?",
                arguments: [sizeBytes, bundlePath]
            )
        }
    }

    // MARK: - 落库

    private func upsert(_ records: [AppRecord]) async {
        guard !records.isEmpty else { return }
        do {
            try await store.pool.write { db in
                try db.execute(sql: "DELETE FROM app_record")
                for r in records {
                    try db.execute(
                        sql: """
                        INSERT INTO app_record (
                            bundle_id, bundle_path, display_name, bundle_name, executable_name,
                            short_version, build_version, team_identifier, minimum_system,
                            install_source, signature, architecture, size_bytes, data_bytes,
                            cache_bytes, install_date, install_confidence, last_used_date,
                            is_protected, is_running, scanned_at
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        arguments: Self.recordToArguments(r)
                    )
                }
            }
        } catch {
            // 记录失败由调用方下次 refresh 重试；台账可全量重建（基线 8.5）
        }
    }

    // MARK: - 映射

    static func recordToArguments(_ r: AppRecord) -> StatementArguments {
        let values: [DatabaseValueConvertible?] = [
            r.bundleId, r.bundlePath, r.displayName, r.bundleName, r.executableName,
            r.shortVersion, r.buildVersion, r.teamIdentifier, r.minimumSystem,
            r.installSource.rawValue, r.signature.rawValue, r.architecture,
            r.sizeBytes, r.dataBytes, r.cacheBytes,
            r.installDate?.timeIntervalSince1970, r.installConfidence,
            r.lastUsedDate?.timeIntervalSince1970,
            r.isProtected, r.isRunning, r.scannedAt.timeIntervalSince1970,
        ]
        return StatementArguments(values)
    }

    static func rowToRecord(_ row: Row) -> AppRecord {
        let installDate: Double? = row["install_date"]
        let lastUsed: Double? = row["last_used_date"]
        let scanned: Double? = row["scanned_at"]
        return AppRecord(
            bundleId: row["bundle_id"] ?? "",
            bundlePath: row["bundle_path"] ?? "",
            displayName: row["display_name"] ?? "",
            bundleName: row["bundle_name"],
            executableName: row["executable_name"],
            shortVersion: row["short_version"],
            buildVersion: row["build_version"],
            teamIdentifier: row["team_identifier"],
            minimumSystem: row["minimum_system"],
            installSource: InstallSource(rawValue: row["install_source"] ?? "") ?? .unknown,
            signature: SignatureState(rawValue: row["signature"] ?? "") ?? .unknown,
            architecture: row["architecture"],
            sizeBytes: row["size_bytes"],
            dataBytes: row["data_bytes"],
            cacheBytes: row["cache_bytes"],
            installDate: installDate.map { Date(timeIntervalSince1970: $0) },
            installConfidence: row["install_confidence"] ?? 0,
            lastUsedDate: lastUsed.map { Date(timeIntervalSince1970: $0) },
            isProtected: (row["is_protected"] ?? 0) != 0,
            isRunning: (row["is_running"] ?? 0) != 0,
            scannedAt: scanned.map { Date(timeIntervalSince1970: $0) } ?? Date()
        )
    }
}