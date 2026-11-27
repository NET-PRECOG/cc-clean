import Foundation
import AppKit
import GRDB
import CcCleanCore
import CcCleanFS

/// 定时自动清理（G6，基线 7.6 算法 4）：
/// NSBackgroundActivityScheduler（24h 间隔 + 1h tolerance，系统节能调度）；
/// 仅执行 defaultSelected && risk == .low 的规则项（高危永不自动清理，基线 9.4 第 4 条）；
/// **连败 2 次自动暂停**（基线 G6 验收）；cleanup_history 审计（基线 6.3 要点 8）；默认关闭。
public actor AutomaticCleaner {

    private let ruleEngine: RuleEngine
    private let store: DatabaseStore
    private let logger: Logger

    private var scheduler: NSBackgroundActivityScheduler?
    private var consecutiveFailures = 0
    /// 上次执行结果（UI 展示）
    public private(set) var lastRunSummary: (cleaned: Int, failed: Int, at: Date)?
    /// 是否已启用（默认关闭，基线 G6）
    public private(set) var isEnabled = false

    public init(ruleEngine: RuleEngine, store: DatabaseStore, logger: Logger) {
        self.ruleEngine = ruleEngine
        self.store = store
        self.logger = logger
    }

    // MARK: - 启停

    /// 启用定时清理（设置页开关调用）。
    public func enable() {
        isEnabled = true
        consecutiveFailures = 0
        let scheduler = NSBackgroundActivityScheduler(identifier: "app.cclean.autoclean")
        scheduler.interval = 24 * 60 * 60              // 24h
        scheduler.tolerance = 60 * 60                  // 1h tolerance（基线 G6）
        scheduler.repeats = true
        scheduler.qualityOfService = .utility
        scheduler.schedule { [weak self] completion in
            guard let self else { return }
            Task {
                await self.runOnce()
                completion(NSBackgroundActivityScheduler.Result.finished)
            }
        }
        self.scheduler = scheduler
        logger.info("automatic cleaner enabled")
    }

    /// 禁用（连败暂停或用户关闭）。
    public func disable() {
        scheduler?.invalidate()
        scheduler = nil
        isEnabled = false
        logger.info("automatic cleaner disabled")
    }

    /// 手动触发一次（设置页「立即清理」）。
    public func runOnce() async {
        guard isEnabled else { return }

        // 只取 low 风险且默认勾选的规则（高危永不自动清理）
        let hits = await ruleEngine.evaluate(RuleContext(scope: .cleanup, budget: .seconds(10)))
        let autoPaths = hits
            .filter { $0.rule.risk == .low && $0.rule.defaultSelected }
            .flatMap { $0.paths }
        guard !autoPaths.isEmpty else {
            lastRunSummary = (0, 0, Date())
            return
        }

        // 执行（trash 可撤销；走 OperationJournal 唯一通道）
        let journalID = UUID()
        var succeeded: [String] = []
        var failed: [String: String] = [:]
        let journal = await makeJournal()
        _ = journalID
        let id = await journal.begin("定时自动清理")
        try? await journal.append(.trash(paths: autoPaths), to: id)
        let result = await journal.commit(id)
        succeeded = result.results.first?.succeeded ?? []
        failed = result.results.first?.failed ?? [:]

        // 连败计数（基线 G6：连败 2 次自动暂停）
        if !failed.isEmpty && succeeded.isEmpty {
            consecutiveFailures += 1
            if consecutiveFailures >= 2 {
                logger.warning("automatic cleaner paused after \(consecutiveFailures) consecutive failures")
                disable()
                return
            }
        } else {
            consecutiveFailures = 0
        }

        lastRunSummary = (succeeded.count, failed.count, Date())
        await audit(ruleIds: hits.filter { $0.rule.risk == .low }.map(\.rule.id),
                    paths: succeeded, journalID: id)
        logger.info("automatic clean: ok=\(succeeded.count) failed=\(failed.count)")
    }

    // MARK: - 审计（cleanup_history 表）

    private func makeJournal() async -> OperationJournal {
        OperationJournal(store: store, logger: logger)
    }

    private func audit(ruleIds: [String], paths: [String], journalID: UUID) async {
        let encoder = JSONEncoder()
        guard let pathsData = try? encoder.encode(paths) else { return }
        _ = try? await store.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO cleanup_history (rule_id, paths_json, bytes, journal_id, created_at)
                VALUES (?, ?, 0, ?, ?)
                """,
                arguments: [
                    ruleIds.joined(separator: ","), pathsData,
                    journalID.uuidString, Date().timeIntervalSince1970,
                ]
            )
        }
    }

    /// 审计历史查询（设置页展示）。
    public func auditHistory(limit: Int = 20) async -> [(ruleId: String, paths: [String], at: Date)] {
        (try? await store.pool.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT rule_id, paths_json, created_at FROM cleanup_history ORDER BY created_at DESC LIMIT ?",
                arguments: [limit]
            ).compactMap { row -> (String, [String], Date)? in
                guard let ruleId: String = row["rule_id"],
                      let pathsData: Data = row["paths_json"],
                      let paths = try? JSONDecoder().decode([String].self, from: pathsData),
                      let created: Double = row["created_at"] else { return nil }
                return (ruleId, paths, Date(timeIntervalSince1970: created))
            }
        }) ?? []
    }
}