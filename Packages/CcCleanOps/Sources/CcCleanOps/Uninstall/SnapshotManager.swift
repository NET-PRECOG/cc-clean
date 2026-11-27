import Foundation
import CcCleanCore
import CcCleanFS

/// APFS 本地快照管理（F9，基线 7.6 算法 3；归属 CcCleanOps——删除走 OperationJournal）：
/// `tmutil listlocalsnapshots /` 只读枚举；删除走 runWhitelistedCommand
/// （tmutil 在白名单 ✓；二次确认由 UI 层承担；POC-T9 失败时 F9 降级只读）。
public actor SnapshotManager {

    private let runner = ProcessRunner()
    private let logger: Logger

    public init(logger: Logger) {
        self.logger = logger
    }

    /// 列出根卷的本地 APFS 快照（只读）。
    public func listSnapshots(volume: String = "/") async -> [String] {
        let result = try? await runner.run(.init(
            executablePath: "/usr/bin/tmutil",
            arguments: ["listlocalsnapshots", volume],
            timeout: .seconds(30)
        ))
        guard let result, result.succeeded else { return [] }
        // 输出行格式：com.apple.TimeMachine.2026-11-26-103000.local
        return result.stdout.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("com.apple.TimeMachine.") }
    }

    /// 删除指定快照（走 OperationJournal tmutil 白名单命令记账；需 Helper 或用户级 root 提权）。
    public func deleteSnapshot(_ name: String, volume: String = "/", journal: OperationJournal) async -> Bool {
        let id = await journal.begin("删除 APFS 快照 \(name)")
        try? await journal.append(
            .runWhitelistedCommand(
                executable: "/usr/bin/tmutil",
                args: ["deletelocalsnapshots", name]
            ),
            to: id
        )
        let result = await journal.commit(id)
        let ok = result.succeededCount > 0
        logger.info("snapshot delete \(name): \(ok)")
        return ok
    }
}