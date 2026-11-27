import Foundation
import GRDB
import CcCleanCore
import CcCleanFS

/// 登录项/守护项服务（H1/H2/H5，基线 7.8；归属 CcCleanOps，依赖 FS 的 LaunchdParser）：
/// H1 登录项 = 用户 LaunchAgents（launchd 型登录项）开关走 plist trash/恢复（可撤销）；
/// H2 守护项 = 四目录全量扫描 + 归属四级回退（LaunchdParser）→ launchd_entry 落库；
/// H5 异常诊断 = 僵尸诊断整合（program 缺失 / exit 非 0）。
public actor LaunchdStore {

    private let store: DatabaseStore
    private let logger: Logger

    public init(store: DatabaseStore, logger: Logger) {
        self.store = store
        self.logger = logger
    }

    // MARK: - H2 守护项扫描与落库

    /// 全量扫描守护项/登录项并落库（launchd_entry 表覆盖写）。
    /// - Parameters:
    ///   - roots: 自定义扫描根（测试注入；nil = 全部含系统只读目录）
    ///   - knownBundles: 应用台账（归属四级回退数据源）
    ///   - lastExitOverrides: launchctl print 结果注入（S10 真机接入）
    public func refresh(
        home: String, knownBundles: [AppRecord],
        roots: [(path: String, isSystem: Bool)]? = nil,
        lastExitOverrides: [String: Int] = [:]
    ) async -> [LaunchdEntry] {
        var entries = LaunchdParser.scan(
            home: home, knownBundles: knownBundles, roots: roots
        )
        // H5 僵尸诊断（program 缺失 / exit 非 0 → healthy=false）
        entries = entries.map { entry in
            var diagnosed = LaunchdParser.diagnose(entry)
            if let exit = lastExitOverrides[diagnosed.label], exit != 0 {
                diagnosed = LaunchdEntry(
                    label: diagnosed.label, plistPath: diagnosed.plistPath,
                    domain: diagnosed.domain, program: diagnosed.program, args: diagnosed.args,
                    runAtLoad: diagnosed.runAtLoad, keepAlive: diagnosed.keepAlive,
                    startInterval: diagnosed.startInterval, ownerBundle: diagnosed.ownerBundle,
                    isSystem: diagnosed.isSystem, healthy: false,
                    lastExit: exit, scannedAt: diagnosed.scannedAt
                )
            }
            return diagnosed
        }
        await upsert(entries)
        logger.info("launchd refresh: \(entries.count) entries, unhealthy=\(entries.filter { !$0.healthy }.count)")
        return entries
    }

    /// 查询落库记录（健康过滤可选）。
    public func entries(onlyUnhealthy: Bool = false) async -> [LaunchdEntry] {
        (try? await store.pool.read { db in
            var sql = """
            SELECT label, plist_path, domain, program, args_json, run_at_load, keep_alive,
                   owner_bundle, is_system, healthy, last_exit, scanned_at
            FROM launchd_entry
            """
            if onlyUnhealthy { sql += " WHERE healthy = 0" }
            sql += " ORDER BY is_system ASC, label ASC"
            return try Row.fetchAll(db, sql: sql).compactMap(Self.rowToEntry)
        }) ?? []
    }

    // MARK: - H1 开关（plist trash = 停用可撤销；恢复 = 启用）

    /// 单条启停状态切换。系统组件（isSystem）拒绝操作（基线 H 边界：只读展示）。
    public func setEnabled(
        _ entry: LaunchdEntry, enabled: Bool,
        journal: OperationJournal, undoJournalID: UUID?
    ) async -> (succeeded: Bool, message: String) {
        guard !entry.isSystem else {
            return (false, "系统组件只读展示，禁止操作（基线 H 边界）")
        }
        if !enabled {
            // 停用：plist 移入废纸篓（可撤销恢复）
            guard FileManager.default.fileExists(atPath: entry.plistPath) else {
                return (false, "plist 已不存在")
            }
            let id = await journal.begin("停用 \(entry.label)")
            try? await journal.append(.trash(paths: [entry.plistPath]), to: id)
            let result = await journal.commit(id)
            let ok = result.results.first?.succeeded.contains(entry.plistPath) == true
            if ok { await markHealth(label: entry.label, healthy: false) }
            return (ok, ok ? "已停用（废纸篓可撤销）" : "停用失败")
        } else {
            // 启用：撤销对应的停用事务（调用方传入停用时的 journalID）
            guard let undoID = undoJournalID else {
                // 兜底：废纸篓同名恢复
                let trashDir = URL(fileURLWithPath: NSHomeDirectory() + "/.Trash")
                let name = (entry.plistPath as NSString).lastPathComponent
                let found = (try? FileManager.default.contentsOfDirectory(
                    at: trashDir, includingPropertiesForKeys: nil))?.first { $0.lastPathComponent == name }
                guard let found else { return (false, "废纸篓中未找到对应 plist") }
                do {
                    try FileManager.default.createDirectory(
                        atPath: (entry.plistPath as NSString).deletingLastPathComponent,
                        withIntermediateDirectories: true)
                    try FileManager.default.moveItem(
                        at: found, to: URL(fileURLWithPath: entry.plistPath))
                    await markHealth(label: entry.label, healthy: true)
                    return (true, "已从废纸篓恢复并启用")
                } catch {
                    return (false, "恢复失败：\((error as NSError).localizedDescription)")
                }
            }
            let undo = await journal.undo(undoID)
            guard undo.passed else { return (false, "撤销失败：\(undo.unrestorable.values.first ?? "")") }
            await markHealth(label: entry.label, healthy: true)
            return (true, "已重新启用")
        }
    }

    private func markHealth(label: String, healthy: Bool) async {
        _ = try? await store.pool.write { db in
            try db.execute(
                sql: "UPDATE launchd_entry SET healthy = ? WHERE label = ?",
                arguments: [healthy, label]
            )
        }
    }

    // MARK: - H5 异常诊断建议

    /// 异常项诊断（H5：program 缺失 / exit 非 0 → 建议）。
    public func diagnoseSuggestions(_ entry: LaunchdEntry) -> [String] {
        var suggestions: [String] = []
        let executable = entry.program ?? entry.args.first
        if let executable, !FileManager.default.fileExists(atPath: executable) {
            suggestions.append("目标程序已不存在（可能是残留安装）")
            suggestions.append("建议：删除 plist（可撤销）")
        }
        if let exit = entry.lastExit, exit != 0 {
            suggestions.append("上次退出码 \(exit)（非正常退出）")
            suggestions.append("建议：禁用（bootout，S10 Helper 接入）或修复目标程序")
        }
        if suggestions.isEmpty {
            suggestions.append("该项运行正常")
        }
        return suggestions
    }

    // MARK: - 落库

    private func upsert(_ entries: [LaunchdEntry]) async {
        guard !entries.isEmpty else { return }
        _ = try? await store.pool.write { db in
            try db.execute(sql: "DELETE FROM launchd_entry")
            for e in entries {
                try db.execute(
                    sql: """
                    INSERT OR REPLACE INTO launchd_entry (
                        label, plist_path, domain, program, args_json, run_at_load, keep_alive,
                        owner_bundle, is_system, healthy, last_exit, scanned_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        e.label, e.plistPath, e.domain, e.program,
                        (try? JSONEncoder().encode(e.args)), e.runAtLoad, e.keepAlive,
                        e.ownerBundle, e.isSystem, e.healthy, e.lastExit,
                        e.scannedAt.timeIntervalSince1970,
                    ]
                )
            }
        }
    }

    static func rowToEntry(_ row: Row) -> LaunchdEntry? {
        guard let label: String = row["label"],
              let plistPath: String = row["plist_path"] else { return nil }
        let argsData: Data? = row["args_json"]
        let args = argsData.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        let scanned: Double? = row["scanned_at"]
        let runAtLoadInt: Int? = row["run_at_load"]
        let keepAliveInt: Int? = row["keep_alive"]
        return LaunchdEntry(
            label: label, plistPath: plistPath,
            domain: row["domain"] ?? "system",
            program: row["program"], args: args,
            runAtLoad: runAtLoadInt.map { $0 != 0 },
            keepAlive: keepAliveInt.map { $0 != 0 },
            startInterval: nil,
            ownerBundle: row["owner_bundle"],
            isSystem: (row["is_system"] ?? 0) != 0,
            healthy: (row["healthy"] ?? 1) != 0,
            lastExit: row["last_exit"],
            scannedAt: scanned.map { Date(timeIntervalSince1970: $0) } ?? Date()
        )
    }
}