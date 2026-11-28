import Foundation
import GRDB
import CcCleanCore

// HelperClientProtocol 已迁移至 CcCleanCore（Privileged 包的 XPCHelperClient 实现，
// 基线 5.2 依赖红线：Privileged 只允许依赖 Core）。

/// 写操作唯一通道（基线 6.3）：begin → append → commit 三段式；
/// 逐项记账落 operation_journal；撤销语义分级；失败不吞（commit 永不抛错）。
public actor OperationJournal {

    private let store: DatabaseStore
    private let helper: HelperClientProtocol?
    private let logger: Logger
    private let trashService = TrashService()
    private let journalDirectory: URL
    /// 用户级白名单命令执行器（D2 brew zap 等；Helper 缺席时的降级通道，仍走唯一出口）
    private let userCommandRunner: BrewCommandRunning

    /// begin→append 的未提交事务（先计划后执行，未 commit 零副作用）
    private var openJournals: [UUID: JournalRecord] = [:]
    /// trash 撤销映射：journalID → [原路径: 废纸篓 URL]（重启后由 .Trash 同名扫描兜底）
    private var trashMapping: [UUID: [String: URL]] = [:]

    public init(store: DatabaseStore, helper: HelperClientProtocol? = nil, logger: Logger, userCommandRunner: BrewCommandRunning = SystemBrewRunner()) {
        self.store = store
        self.helper = helper
        self.logger = logger
        self.userCommandRunner = userCommandRunner
        self.journalDirectory = Paths.journalDirectory
        try? FileManager.default.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
    }

    // MARK: - 三段式事务

    /// 开启事务（仅记录，不产生任何副作用）。
    public func begin(_ title: String) -> UUID {
        let id = UUID()
        let record = JournalRecord(
            journalID: id, title: title, ops: [], results: nil,
            status: "planned", createdAt: Date(), committedAt: nil, undoneAt: nil
        )
        openJournals[id] = record
        // 不异步落库：避免 fire-and-forget Task 与 commit 的同步落库竞态
        //（planned 状态由 commit 一次性写入；未 commit 崩溃场景的 interrupted 标记在 S8 处理）
        return id
    }

    /// 追加操作（只入计划，不执行）。
    public func append(_ op: Operation, to journalID: UUID) throws {
        guard var record = openJournals[journalID] else {
            throw JournalError.unknownJournal(journalID)
        }
        record.ops.append(op)
        openJournals[journalID] = record
    }

    /// 提交：按顺序执行，逐项记账；单项失败不回滚已完成项。
    /// 永不抛错（基线 6.3 要点 5：失败用返回值表达）。
    public func commit(
        _ journalID: UUID,
        progress: (@Sendable (OperationResult) -> Void)? = nil
    ) async -> JournalResult {
        guard var record = openJournals.removeValue(forKey: journalID) else {
            // 未知/已提交事务：返回空结果而非抛错
            logger.warning("commit on unknown journal \(journalID)")
            return JournalResult(journalID: journalID, results: [])
        }

        var results: [OperationResult] = []
        var trashMap: [String: URL] = [:]

        for op in record.ops {
            let started = Date()
            let result = await execute(op, journalID: journalID)
            let finished = Date()
            let opResult = OperationResult(
                operation: op,
                succeeded: result.succeeded,
                failed: result.failed,
                bytesReclaimed: result.bytesReclaimed,
                startedAt: started,
                finishedAt: finished
            )
            if !result.trashLocations.isEmpty {
                trashMap.merge(result.trashLocations) { _, new in new }
            }
            results.append(opResult)
            progress?(opResult)
        }

        if !trashMap.isEmpty {
            trashMapping[journalID] = trashMap
        }

        record.results = results
        record.status = "committed"
        record.committedAt = Date()
        // 同步落库（undo 依赖此记录；避免 fire-and-forget Task 与 undo 的 DB 读竞态）
        await persist(record)
        await writeAuditFile(record)

        logger.info(
            "journal \(journalID) committed: ok=\(results.reduce(0) { $0 + $1.succeeded.count }) failed=\(results.reduce(0) { $0 + $1.failed.count })"
        )
        return JournalResult(journalID: journalID, results: results)
    }

    // MARK: - 撤销

    /// 撤销：仅对可逆且已成功执行的项生效（反向顺序）。
    public func undo(_ journalID: UUID) async -> UndoResult {
        let record = await journal(journalID)
        guard let record = record, record.status == "committed",
              let results = record.results else {
            return UndoResult(restored: [], unrestorable: [:], passed: false)
        }

        var restored: [String] = []
        var unrestorable: [String: String] = [:]
        let trashMap = trashMapping[journalID] ?? [:]

        for opResult in results.reversed() {
            let op = opResult.operation
            guard op.undoable, !opResult.succeeded.isEmpty else {
                for path in opResult.succeeded {
                    unrestorable[path] = "该操作类型不可撤销"
                }
                continue
            }
            switch op {
            case .trash(let paths):
                for path in paths where opResult.succeeded.contains(path) {
                    let trashURL = trashMap[path] ?? findInTrash(named: (path as NSString).lastPathComponent)
                    guard let trashURL else {
                        unrestorable[path] = "废纸篓中未找到对应文件"
                        continue
                    }
                    switch await trashService.restore(trashURL: trashURL, originalPath: path) {
                    case .success(let restoredPath):
                        restored.append(restoredPath)
                    case .failure(let error):
                        unrestorable[path] = TrashRestoreError.describe(error)
                    }
                }
            case .editPlist(let path, let mutations):
                // 从首见记录取真实旧值，反向回写（undo 反向顺序）
                let stored = storedMutations[path] ?? [:]
                let oldMutations = mutations.compactMap { m -> PlistMutation? in
                    guard let first = stored[m.key], let oldValue = first.oldValue else {
                        return nil
                    }
                    return PlistMutation(key: m.key, oldValue: m.newValue, newValue: oldValue)
                }
                if oldMutations.isEmpty {
                    logger.error("undo editPlist: no stored old values for \(path), stored keys=\(stored.keys.sorted())")
                }
                guard !oldMutations.isEmpty else {
                    for path in opResult.succeeded {
                        unrestorable[path] = "无旧值记录，无法回写"
                    }
                    continue
                }
                let result = await applyPlistMutation(path: path, mutations: oldMutations)
                if result.succeeded.isEmpty {
                    unrestorable[path] = result.failed[path] ?? "plist 回写失败"
                } else {
                    restored.append(path)
                }
            default:
                for path in opResult.succeeded {
                    unrestorable[path] = "该操作类型不可撤销"
                }
            }
        }

        // 更新记录
        if var updated = await journal(journalID) {
            updated.status = restored.isEmpty ? "committed" : "undone"
            updated.undoneAt = restored.isEmpty ? nil : Date()
            await persist(updated)
        }

        let passed = unrestorable.isEmpty
        logger.info("journal \(journalID) undo: restored=\(restored.count) unrestorable=\(unrestorable.count)")
        return UndoResult(restored: restored, unrestorable: unrestorable, passed: passed)
    }

    // MARK: - 执行引擎

    private struct ExecutionOutcome {
        var succeeded: [String] = []
        var failed: [String: String] = [:]
        var bytesReclaimed: Int64 = 0
        var trashLocations: [String: URL] = [:]
    }

    private func execute(_ op: Operation, journalID: UUID) async -> ExecutionOutcome {
        var outcome = ExecutionOutcome()

        switch op {
        case .trash(let paths):
            // trash 前统计体积（供回收量记账）
            for path in paths {
                if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                   let size = (attrs[.size] as? NSNumber)?.int64Value {
                    outcome.bytesReclaimed += size
                }
            }
            let result = await trashService.trash(paths: paths)
            outcome.succeeded = Array(result.succeeded.keys)
            outcome.failed = result.failed
            outcome.trashLocations = result.succeeded

        case .editPlist(let path, let mutations):
            let result = await applyPlistMutation(path: path, mutations: mutations)
            outcome.succeeded = result.succeeded
            outcome.failed = result.failed

        case .removeSystem(let paths):
            // 系统级操作：仅 Helper XPC（S9 接入）；S4 无 Helper 时全部失败且原因明确
            guard let helper else {
                for path in paths { outcome.failed[path] = "需要辅助程序（Helper 未安装）" }
                break
            }
            let result = await helper.removeItems(paths, journalID: journalID.uuidString)
            outcome.succeeded = result.succeeded
            outcome.failed = result.failed

        case .forgetReceipt(let pkgID):
            guard let helper else {
                outcome.failed[pkgID] = "需要辅助程序（Helper 未安装）"
                break
            }
            let result = await helper.forgetReceipts([pkgID], journalID: journalID.uuidString)
            outcome.succeeded = result.succeeded
            outcome.failed = result.failed

        case .resetTCC(let bundleID, let services):
            guard let helper else {
                outcome.failed[bundleID] = "需要辅助程序（Helper 未安装）"
                break
            }
            let result = await helper.resetTCC(
                bundleID: bundleID, services: services, journalID: journalID.uuidString
            )
            outcome.succeeded = result.succeeded
            outcome.failed = result.failed

        case .bootout(let plistPath):
            guard let helper else {
                outcome.failed[plistPath] = "需要辅助程序（Helper 未安装）"
                break
            }
            let label = (plistPath as NSString).deletingPathExtension
            let result = await helper.bootout(
                label: (label as NSString).lastPathComponent,
                plistPath: plistPath, journalID: journalID.uuidString
            )
            outcome.succeeded = result.succeeded
            outcome.failed = result.failed

        case .runWhitelistedCommand(let exec, let args):
            // 用户级白名单命令（D2 brew zap 等）：无 Helper 时经 ProcessRunner 直跑
            //（命令 argv 已在 UI 预览且记账；root 场景仍走 Helper）
            if let helper {
                let result = await helper.runWhitelisted(exec, args: args, journalID: journalID.uuidString)
                outcome.succeeded = result.succeeded
                outcome.failed = result.failed
            } else {
                let runnerResult = (try? await userCommandRunner.run(
                    brewPath: exec, args: args, timeout: .seconds(300)
                ))
                guard let runnerResult else {
                    outcome.failed[exec] = "命令执行失败"
                    break
                }
                if runnerResult.succeeded {
                    outcome.succeeded.append(exec)
                } else {
                    outcome.failed[exec] = "退出码 \(runnerResult.exitCode)：\(runnerResult.stderr.prefix(500))"
                }
            }

        case .backupAndRemove, .bootstrap, .thinBinaries:
            // backupAndRemove/bootstrap/thinBinaries 在对应需求版本（C8/H3/G4）接入 Helper
            for path in op.affectedPaths {
                outcome.failed[path] = "该操作将由对应功能项接入（当前版本未启用）"
            }
        }
        return outcome
    }

    // MARK: - plist 编辑（旧值记录 → 可撤销）

    private struct PlistEditOutcome {
        var succeeded: [String] = []
        var failed: [String: String] = [:]
    }

    private func applyPlistMutation(path: String, mutations: [PlistMutation]) async -> PlistEditOutcome {
        var outcome = PlistEditOutcome()
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            outcome.failed[path] = "plist 不存在"
            return outcome
        }
        guard let data = fm.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              var dict = plist as? [String: Any]
        else {
            outcome.failed[path] = "plist 解析失败"
            return outcome
        }

        for mutation in mutations {
            let old = PlistValue.from(plistValue: dict[mutation.key])
            // 记录首次旧值（undo 反向回写用）
            var stored = storedMutations[path] ?? [:]
            if stored[mutation.key] == nil {
                stored[mutation.key] = PlistMutation(
                    key: mutation.key, oldValue: old, newValue: mutation.newValue
                )
                storedMutations[path] = stored
            }
            dict[mutation.key] = PlistValue.toAny(mutation.newValue)
        }

        // 原子写（基线 6.3 要点 6：Data.write 的 .atomic 处理原子性，序列化 options 传 0）
        guard let format = try? PropertyListSerialization.data(
            fromPropertyList: dict, format: .xml, options: 0
        ) else {
            outcome.failed[path] = "plist 序列化失败"
            return outcome
        }
        do {
            try format.write(to: URL(fileURLWithPath: path), options: .atomic)
            outcome.succeeded.append(path)
        } catch {
            outcome.failed[path] = TrashService.describe(error)
        }
        return outcome
    }

    /// plist 旧值存储：path → key → 首次旧值（undo 用）。
    private var storedMutations: [String: [String: PlistMutation]] = [:]

    // MARK: - 审计与查询

    /// 审计文件：journal/<id>.json（基线 6.3 要点 8；保留 90 天由启动清理负责）。
    private func writeAuditFile(_ record: JournalRecord) async {
        guard let data = try? JSONCoding.encoder(prettyPrinted: true).encode(record) else { return }
        let url = journalDirectory.appendingPathComponent("\(record.journalID.uuidString).json")
        try? data.write(to: url, options: .atomic)
    }

    /// 历史查询（卸载记录页 / 清理审计）。
    public func history(limit: Int) async -> [JournalRecord] {
        do {
            return try await store.pool.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                    SELECT journal_id, title, ops_json, result_json, status,
                           created_at, committed_at, undone_at
                    FROM operation_journal
                    WHERE status != 'planned'
                    ORDER BY created_at DESC LIMIT ?
                    """,
                    arguments: [limit]
                ).compactMap(Self.rowToRecord)
            }
        } catch {
            return []
        }
    }

    /// 单条事务查询。
    public func journal(_ id: UUID) async -> JournalRecord? {
        if let open = openJournals[id] { return open }
        do {
            return try await store.pool.read { db in
                try Row.fetchOne(
                    db,
                    sql: """
                    SELECT journal_id, title, ops_json, result_json, status,
                           created_at, committed_at, undone_at
                    FROM operation_journal WHERE journal_id = ?
                    """,
                    arguments: [id.uuidString]
                ).flatMap(Self.rowToRecord)
            }
        } catch {
            return nil
        }
    }

    // MARK: - 落库

    private func persist(_ record: JournalRecord) async {
        let encoder = JSONCoding.encoder()
        guard let opsData = try? encoder.encode(record.ops) else { return }
        let resultData = record.results.flatMap { try? encoder.encode($0) }
        _ = try? await store.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO operation_journal (
                    journal_id, title, module, ops_json, result_json,
                    status, created_at, committed_at, undone_at
                ) VALUES (?, ?, NULL, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(journal_id) DO UPDATE SET
                    title = excluded.title,
                    ops_json = excluded.ops_json,
                    result_json = excluded.result_json,
                    status = excluded.status,
                    committed_at = excluded.committed_at,
                    undone_at = excluded.undone_at
                """,
                arguments: [
                    record.journalID.uuidString, record.title, opsData, resultData,
                    record.status, record.createdAt.timeIntervalSince1970,
                    record.committedAt?.timeIntervalSince1970,
                    record.undoneAt?.timeIntervalSince1970,
                ]
            )
        }
    }

    static func rowToRecord(_ row: Row) -> JournalRecord? {
        let decoder = JSONCoding.decoder()
        guard let idString: String = row["journal_id"],
              let id = UUID(uuidString: idString),
              let title: String = row["title"],
              let opsData: Data = row["ops_json"],
              let ops = try? decoder.decode([Operation].self, from: opsData) else {
            return nil
        }
        let resultData: Data? = row["result_json"]
        let results = resultData.flatMap { try? decoder.decode([OperationResult].self, from: $0) }
        let created: Double? = row["created_at"]
        let committed: Double? = row["committed_at"]
        let undone: Double? = row["undone_at"]
        return JournalRecord(
            journalID: id,
            title: title,
            ops: ops,
            results: results,
            status: row["status"] ?? "planned",
            createdAt: created.map { Date(timeIntervalSince1970: $0) } ?? Date(),
            committedAt: committed.map { Date(timeIntervalSince1970: $0) },
            undoneAt: undone.map { Date(timeIntervalSince1970: $0) }
        )
    }

    /// 重启兜底：按文件名在废纸篓中查找（内存映射丢失时）。
    private func findInTrash(named name: String) -> URL? {
        let trashDir = URL(fileURLWithPath: NSHomeDirectory() + "/.Trash")
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: trashDir, includingPropertiesForKeys: nil
        )) ?? []
        return contents.first { $0.lastPathComponent == name }
    }
}

public enum JournalError: Error, Equatable {
    case unknownJournal(UUID)
}

extension TrashRestoreError {
    static func describe(_ error: TrashRestoreError) -> String {
        switch error {
        case .reason(let message): return message
        }
    }
}

extension PlistValue {
    /// Foundation Any → PlistValue（读取旧值）。
    static func from(plistValue: Any?) -> PlistValue? {
        guard let value = plistValue else { return nil }
        switch value {
        case let s as String: return .string(s)
        case let b as Bool: return .boolean(b)
        case let i as Int: return .integer(i)
        case let d as Data: return .data(d)
        case let n as NSNumber:
            // Bool 在 Foundation 中也是 NSNumber
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return .boolean(n.boolValue)
            }
            return .integer(n.intValue)
        default: return nil
        }
    }

    /// PlistValue → Foundation Any（写回）。
    static func toAny(_ value: PlistValue?) -> Any? {
        switch value {
        case .string(let s): return s
        case .integer(let i): return i
        case .boolean(let b): return b
        case .data(let d): return d
        case nil: return nil
        }
    }
}