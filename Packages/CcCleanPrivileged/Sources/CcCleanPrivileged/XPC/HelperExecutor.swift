import Foundation
import GRDB
import CcCleanCore

/// Helper 侧审计存储（helper.sqlite，基线 10.3：逐请求审计 journal_id/action/结果/客户端 token）。
/// 与主库隔离（root 进程独立写，主 App 无写权限）。
public struct HelperAuditStore: Sendable {

    public let pool: DatabasePool

    /// 打开（或创建）helper.sqlite。
    public static func open(at url: URL, logger: Logger) throws -> HelperAuditStore {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let pool = try DatabasePool(path: url.path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("helper_v1") { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS helper_audit (
                id            INTEGER PRIMARY KEY AUTOINCREMENT,
                journal_id    TEXT NOT NULL,
                action        TEXT NOT NULL,
                paths_json    BLOB,
                result_json   BLOB,
                client_token  TEXT,
                created_at    REAL NOT NULL
            )
            """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_helper_audit_journal ON helper_audit(journal_id)")
        }
        try migrator.migrate(pool)
        return HelperAuditStore(pool: pool)
    }

    /// 写入审计记录。
    public func record(
        journalID: String, action: String, paths: [String],
        response: HelperResponse, clientToken: String?
    ) {
        let encoder = JSONCoding.encoder()
        let pathsData = try? encoder.encode(paths)
        let resultData = try? encoder.encode(response)
        _ = try? pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO helper_audit (journal_id, action, paths_json, result_json, client_token, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    journalID, action, pathsData, resultData,
                    clientToken, Date().timeIntervalSince1970,
                ]
            )
        }
    }
}

/// Helper 执行核心（四道关的第 ③④ 道 + root 操作执行）：
/// ③ 参数白名单（HelperPathValidator 六道关）→ ④ 审计（helper.sqlite）→ root 执行。
/// 签名自检（①）与客户端 audit_token 校验（②）在 XPC 连接层（HelperMain）执行。
public actor HelperExecutor {

    private let validator: HelperPathValidator
    private let audit: HelperAuditStore?
    private let runner = ProcessRunner()
    private let logger: Logger

    public init(validator: HelperPathValidator, audit: HelperAuditStore?, logger: Logger) {
        self.validator = validator
        self.audit = audit
        self.logger = logger
    }

    /// 执行 Helper 请求（XPC execute 入口调用）。
    /// - Parameter clientToken: XPC 层校验通过的客户端 audit token（写入审计）
    public func execute(_ request: HelperRequest, clientToken: String?) async -> HelperResponse {
        // ③ 参数白名单六道关
        let errors = validator.validate(request)
        guard errors.isEmpty else {
            let failed = ["*": errors.map { $0.localizedDescription }.joined(separator: "; ")]
            audit?.record(journalID: request.journalID, action: request.action.rawValue,
                          paths: [], response: HelperResponse(succeeded: [], failed: failed),
                          clientToken: clientToken)
            logger.error("helper rejected \(request.action.rawValue): \(failed["*"] ?? "")")
            return HelperResponse(succeeded: [], failed: failed)
        }

        // 执行（root 权限）
        let response: HelperResponse
        switch request.action {
        case .removeItems:
            response = await executeRemoveItems(request.paths)
        case .forgetReceipts:
            response = await executeBatch(request.pkgIDs) { pkgID in
                try await self.runner.run(.init(
                    executablePath: "/usr/sbin/pkgutil",
                    arguments: ["--forget", pkgID], timeout: .seconds(30)
                ))
            }
        case .resetTCC:
            // 逐服务重置（validateTCC 已硬禁 All）
            response = await executeBatch(request.services) { service in
                try await self.runner.run(.init(
                    executablePath: "/usr/bin/tccutil",
                    arguments: ["reset", service, request.bundleID], timeout: .seconds(30)
                ))
            }
        case .bootout:
            let result = try? await runner.run(.init(
                executablePath: "/bin/launchctl",
                arguments: ["bootout", "system/\(request.label)"], timeout: .seconds(30)
            ))
            if let result, result.succeeded {
                response = HelperResponse(succeeded: [request.plistPath], failed: [:])
            } else {
                response = HelperResponse(
                    succeeded: [],
                    failed: [request.plistPath: result?.stderr ?? "bootout 失败"]
                )
            }
        case .runWhitelisted:
            let result = try? await runner.run(.init(
                executablePath: request.executable,
                arguments: request.args, timeout: .seconds(300)
            ))
            if let result, result.succeeded {
                response = HelperResponse(succeeded: [request.executable], failed: [:])
            } else {
                response = HelperResponse(
                    succeeded: [],
                    failed: [request.executable: result?.stderr ?? "命令失败"]
                )
            }
        }

        // ④ 审计
        audit?.record(
            journalID: request.journalID, action: request.action.rawValue,
            paths: request.paths, response: response, clientToken: clientToken
        )
        logger.info(
            "helper executed \(request.action.rawValue): ok=\(response.succeeded.count) failed=\(response.failed.count)"
        )
        return response
    }

    // MARK: - root 操作实现

    /// 批量删除（C2/C3 系统级残留；不可撤销 removeSystem 语义，root 直接删除）。
    /// 六道关已在 validate 阶段完成（含保护名单/realpath）；此处逐项执行并记录失败原因。
    private func executeRemoveItems(_ paths: [String]) async -> HelperResponse {
        var succeeded: [String] = []
        var failed: [String: String] = [:]
        for path in paths {
            do {
                try FileManager.default.removeItem(atPath: path)
                succeeded.append(path)
            } catch {
                failed[path] = (error as NSError).localizedDescription
            }
        }
        return HelperResponse(succeeded: succeeded, failed: failed)
    }

    /// 逐项批处理（pkgutil --forget / tccutil reset）。
    private func executeBatch(
        _ items: [String],
        _ run: (String) async throws -> ProcessResult
    ) async -> HelperResponse {
        var succeeded: [String] = []
        var failed: [String: String] = [:]
        for item in items {
            do {
                let result = try await run(item)
                if result.succeeded {
                    succeeded.append(item)
                } else {
                    failed[item] = result.stderr.isEmpty
                        ? "退出码 \(result.exitCode)"
                        : String(result.stderr.prefix(300))
                }
            } catch {
                failed[item] = (error as NSError).localizedDescription
            }
        }
        return HelperResponse(succeeded: succeeded, failed: failed)
    }
}