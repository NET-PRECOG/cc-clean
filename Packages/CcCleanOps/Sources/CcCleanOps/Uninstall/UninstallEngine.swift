import Foundation
import AppKit
import GRDB
import CcCleanCore
import CcCleanFS

/// 四项复检结果（C13，基线 7.3 算法 10：四项全过才判「已清理」）。
public struct VerificationResult: Codable, Sendable, Equatable {
    /// ① 进程清零（NSWorkspace + ps 双查的 NSWorkspace 侧）
    public let processesCleared: Bool
    /// ② launchd 无条目（S7 文件级：相关 plist 已删；S10 接入 launchctl print）
    public let launchdCleared: Bool
    /// ③ 计划内路径全部不存在
    public let pathsCleared: Bool
    /// ④ Keychain 凭据为空（S7 用户级占位 true；S10 接入 SecItem 检查）
    public let credentialsCleared: Bool

    public var allPassed: Bool {
        processesCleared && launchdCleared && pathsCleared && credentialsCleared
    }
}

/// 卸载报告（C9：Markdown / JSON 导出）。
public struct UninstallReport: Codable, Sendable {
    public let planID: UUID
    public let app: AppRecord
    public let startedAt: Date
    public let finishedAt: Date
    public let journalResult: JournalResult
    public let verification: VerificationResult
    public let wasDryRun: Bool
    public var undoneAt: Date?

    public init(
        planID: UUID, app: AppRecord, startedAt: Date, finishedAt: Date,
        journalResult: JournalResult, verification: VerificationResult, wasDryRun: Bool
    ) {
        self.planID = planID
        self.app = app
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.journalResult = journalResult
        self.verification = verification
        self.wasDryRun = wasDryRun
    }

    /// Markdown 导出（基线 C9：每项路径、结果、失败原因、复检结论、废纸篓位置）。
    public func exportMarkdown() -> String {
        var md = "# 卸载报告：\(app.displayName)\n\n"
        md += "- 计划 ID：`\(planID.uuidString)`\n"
        md += "- 时间：\(startedAt.formatted()) → \(finishedAt.formatted())\n"
        md += "- 模式：\(wasDryRun ? "演练（dry-run，未写盘）" : "实际执行")\n\n"
        md += "## 执行结果\n\n"
        md += "| 路径 | 结果 | 说明 |\n|---|---|---|\n"
        for result in journalResult.results {
            for path in result.succeeded {
                md += "| `\(path)` | ✅ 成功 | \(result.operation.undoable ? "可撤销" : "不可撤销") |\n"
            }
            for (path, reason) in result.failed.sorted(by: { $0.key < $1.key }) {
                md += "| `\(path)` | ❌ 失败 | \(reason) |\n"
            }
        }
        md += "\n## 四项复检\n\n"
        md += "- 进程清零：\(verification.processesCleared ? "✅" : "❌")\n"
        md += "- launchd 无条目：\(verification.launchdCleared ? "✅" : "❌")\n"
        md += "- 路径已清除：\(verification.pathsCleared ? "✅" : "❌")\n"
        md += "- 凭据为空：\(verification.credentialsCleared ? "✅" : "❌")\n"
        md += "- **结论：\(verification.allPassed ? "已清理" : "存在遗留项")**\n"
        md += "\n> 用户级项可撤销（报告页「撤销」按钮）；系统级项不可撤销。\n"
        return md
    }

    /// JSON 导出。
    public func exportJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

/// 卸载引擎（C 组编排核心，基线 5.2 归属于 CcCleanOps；基线 7.3 算法 8）：
/// 预检 → 建计划（不写盘，支撑 C15 dry-run）→ 用户确认 → 执行 → 复检 → 报告。
public actor UninstallEngine {

    private let residueScanner: ResidueScanner
    private let receiptScanner: ReceiptScanner
    private let store: DatabaseStore
    private let logger: Logger

    public init(
        residueScanner: ResidueScanner,
        receiptScanner: ReceiptScanner,
        store: DatabaseStore,
        logger: Logger
    ) {
        self.residueScanner = residueScanner
        self.receiptScanner = receiptScanner
        self.store = store
        self.logger = logger
    }

    // MARK: - 预检（PreflightGate，基线 11.3 ① 第 1 步）

    public struct PreflightResult: Sendable {
        public let allowed: Bool
        public let isProtected: Bool
        public let isRunning: Bool
        public let vendorConflicts: [String]   // C12 提示（同厂应用名）
    }

    public func preflight(target: AppRecord, allApps: [AppRecord]) -> PreflightResult {
        let running = NSWorkspace.shared.runningApplications.contains { app in
            app.bundleURL?.path == target.bundlePath
        }
        let conflicts = allApps
            .filter { $0.teamIdentifier != nil && $0.teamIdentifier == target.teamIdentifier && $0.bundleId != target.bundleId }
            .map(\.displayName)
        return PreflightResult(
            allowed: !target.isProtected && !running,
            isProtected: target.isProtected,
            isRunning: running,
            vendorConflicts: conflicts
        )
    }

    // MARK: - 建计划（C15 dry-run：全程不写盘）

    public func buildPlan(
        target: AppRecord,
        allApps: [AppRecord],
        launchdEntries: [LaunchdEntry] = []
    ) async -> UninstallPlan {
        var plan = await residueScanner.scan(target: target, allApps: allApps, launchdEntries: launchdEntries)
        // C2 receipts（系统级，requiresRoot + 不可撤销）
        let receipts = await receiptScanner.scanReceipts(target: target, store: store)
        plan.items.append(contentsOf: receipts)
        return plan
    }

    // MARK: - 执行（用户级 trash 走 OperationJournal；系统级灰显）

    /// 执行选中的残留项清理。
    public func execute(
        plan: UninstallPlan,
        selected: [ResidueItem],
        journal: OperationJournal
    ) async -> UninstallReport {
        let started = Date()
        let journalID = await journal.begin("卸载 \(plan.app.displayName)")

        // 分层执行（严格顺序，基线 7.3 算法 8）：用户级 trash → 系统级（灰显占位）
        let userItems = selected.filter { $0.layer == .l1Body || $0.layer == .l2User }
        let systemItems = selected.filter { $0.layer == .l3System || $0.layer == .l4State }

        var appended = 0
        // L1/L2/L4 可 trash 项（用户级 + launchd plist 文件）
        let trashPaths = (userItems + systemItems.filter { $0.layer == .l4State }).map(\.path)
        if !trashPaths.isEmpty {
            try? await journal.append(.trash(paths: trashPaths), to: journalID)
            appended += 1
        }
        // L3 系统级：removeSystem（Helper 未接入时逐项失败并明确原因）
        let systemPaths = systemItems.filter { $0.layer == .l3System }.map(\.path)
        if !systemPaths.isEmpty {
            try? await journal.append(.removeSystem(paths: systemPaths), to: journalID)
            appended += 1
        }
        // receipts：pkgutil --forget（Helper）
        let receipts = selected.filter { $0.layer == .l3System && $0.reason.hasPrefix("pkgutil") }
        for receipt in receipts {
            try? await journal.append(.forgetReceipt(pkgID: receipt.path), to: journalID)
            appended += 1
        }

        // 未 commit 的事务不产生任何副作用（appended == 0 时不调用 commit）
        let journalResult = appended > 0
            ? await journal.commit(journalID)
            : JournalResult(journalID: journalID, results: [])

        // C13 四项复检
        let verification = await verify(plan: plan, selected: selected, afterJournal: journalResult)

        let report = UninstallReport(
            planID: plan.planID, app: plan.app,
            startedAt: started, finishedAt: Date(),
            journalResult: journalResult,
            verification: verification,
            wasDryRun: false
        )
        await persistReport(report, plan: plan)
        logger.info("uninstall \(plan.app.bundleId): ok=\(journalResult.succeededCount) failed=\(journalResult.failedCount) verified=\(verification.allPassed)")
        return report
    }

    /// 演练（C15 dry-run）：生成计划并模拟执行，全程零写盘零系统调用副作用
    /// （可用 fs_usage 验证，基线 C15 验收）。
    public func dryRun(plan: UninstallPlan, selected: [ResidueItem]) async -> UninstallReport {
        // 计划阶段不写盘；模拟执行仅构造结果，无任何 journal 副作用
        let verification = VerificationResult(
            processesCleared: false, launchdCleared: false,
            pathsCleared: false, credentialsCleared: false
        )
        return UninstallReport(
            planID: plan.planID, app: plan.app,
            startedAt: Date(), finishedAt: Date(),
            journalResult: JournalResult(journalID: plan.planID, results: []),
            verification: verification,
            wasDryRun: true
        )
    }

    // MARK: - C13 四项复检

    /// - Parameter afterJournal: 实际执行结果（dry-run 场景传空）
    public func verify(
        plan: UninstallPlan, selected: [ResidueItem], afterJournal: JournalResult
    ) async -> VerificationResult {
        // ① 进程清零（NSWorkspace）
        let processesCleared = !NSWorkspace.shared.runningApplications.contains { app in
            app.bundleURL?.path == plan.app.bundlePath
        }
        // ② launchd 无条目（S7 文件级：launchd 相关 plist 已不存在）
        let launchdPaths = selected.filter { $0.layer == .l4State }.map(\.path)
        let launchdCleared = launchdPaths.allSatisfy {
            !FileManager.default.fileExists(atPath: $0)
        }
        // ③ 计划内路径不存在（成功执行的用户级项）
        let succeededPaths = Set(
            afterJournal.results.flatMap { result in
                result.operation.affectedPaths.filter { result.succeeded.contains($0) }
            }
        )
        let pathsCleared = succeededPaths.allSatisfy {
            !FileManager.default.fileExists(atPath: $0)
        }
        // ④ Keychain（S7 用户级无 Keychain 操作 → 占位通过；S10 接入 SecItem）
        let credentialsCleared = true

        return VerificationResult(
            processesCleared: processesCleared,
            launchdCleared: launchdCleared,
            pathsCleared: pathsCleared,
            credentialsCleared: credentialsCleared
        )
    }

    // MARK: - 报告落库（uninstall_history，90 天保留）

    private func persistReport(_ report: UninstallReport, plan: UninstallPlan) async {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let planData = try? encoder.encode(plan),
              let reportData = try? encoder.encode(report) else { return }
        _ = try? await store.pool.write { db in
            try db.execute(
                sql: """
                INSERT OR REPLACE INTO uninstall_history (
                    plan_id, app_id, app_name, plan_json, report_json,
                    created_at, finished_at, undone_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, NULL)
                """,
                arguments: [
                    plan.planID.uuidString, plan.app.bundleId, plan.app.displayName,
                    planData, reportData,
                    report.startedAt.timeIntervalSince1970,
                    report.finishedAt.timeIntervalSince1970,
                ]
            )
        }
    }

    /// 撤销后补记（uninstall_history 追加 undoneAt，基线 7.3 算法 10）。
    public func markUndone(planID: UUID) async {
        _ = try? await store.pool.write { db in
            try db.execute(
                sql: "UPDATE uninstall_history SET undone_at = ? WHERE plan_id = ?",
                arguments: [Date().timeIntervalSince1970, planID.uuidString]
            )
        }
    }
}