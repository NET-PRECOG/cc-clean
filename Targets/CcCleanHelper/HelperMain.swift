import Foundation
import AppKit
import Security
import CcCleanCore
import CcCleanPrivileged

/// CcClean Helper daemon 入口（基线 10.3）：
/// SMAppService 注册为 launchd daemon（root）→ NSXPCListener 常驻；
/// 四道关：① 签名自检 ② 客户端签名校验（PID + requirement）③ 参数白名单（HelperPathValidator）④ 审计（helper.sqlite）；
/// 空闲 30 分钟自动退出（HelperConstants.idleTimeoutSeconds）。
///
/// 客户端校验说明：SDK 未公开 NSXPCConnection.auditToken，采用
/// SecCodeCopyGuestWithAttributes(kSecGuestAttributePid) + teamId requirement 校验；
/// pid 复用的 race 窗口由「签名有效 + teamId 一致」双重条件缓解，真机验证时评估升级方案。
@main
struct HelperMain {

    static func main() {
        // ① 签名自检：无有效签名或 teamId 缺失 → 拒绝启动（基线 10.3 第一道关）
        guard let teamID = verifySelfSignature() else {
            FileHandle.standardError.write(
                "helper: signature self-check failed（需 Apple Development 签名含 teamId）\n".data(using: .utf8)!
            )
            exit(1)
        }

        // 审计存储（helper.sqlite，root 独立写）
        let logger = Logger(category: .helper)
        let audit: HelperAuditStore?
        do {
            audit = try HelperAuditStore.open(at: Paths.helperDatabase, logger: logger)
        } catch {
            logger.error("helper.sqlite open failed: \(String(describing: error))")
            audit = nil
        }

        let executor = HelperExecutor(
            validator: HelperPathValidator(),
            audit: audit,
            logger: logger
        )
        let delegate = HelperListenerDelegate(executor: executor, teamID: teamID, logger: logger)

        let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
        listener.delegate = delegate
        listener.resume()

        logger.info("helper started (teamId=\(teamID))")

        // 空闲自杀：最后一次请求后 30 分钟退出（launchd 会按需重新拉起）
        var lastActivity = Date()
        delegate.onActivity = { lastActivity = Date() }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            if Date().timeIntervalSince(lastActivity) > HelperConstants.idleTimeoutSeconds {
                logger.info("helper idle timeout, exiting")
                exit(0)
            }
        }

        withExtendedLifetime(delegate) {
            RunLoop.main.run()   // 常驻，不返回
        }
    }

    /// 四道关 ①：签名自检（自身可执行文件 → teamIdentifier）。
    static func verifySelfSignature() -> String? {
        // 自身可执行文件路径（daemon 由 launchd 拉起，argv[0] 为 helper 二进制）
        let executablePath = ProcessInfo.processInfo.arguments.first
            ?? Bundle.main.executableURL?.path ?? ""
        guard !executablePath.isEmpty,
              FileManager.default.fileExists(atPath: executablePath) else { return nil }

        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            URL(fileURLWithPath: executablePath) as CFURL, SecCSFlags(rawValue: 0), &staticCode
        ) == errSecSuccess, let code = staticCode else { return nil }
        var infoCF: CFDictionary?
        guard SecCodeCopySigningInformation(
            code, SecCSFlags(rawValue: kSecCSSigningInformation), &infoCF
        ) == errSecSuccess, let info = infoCF as? [String: Any] else { return nil }
        let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String
        return (teamID?.isEmpty == false) ? teamID : nil
    }
}

/// XPC listener delegate：四道关 ② 客户端签名校验（PID + teamId requirement）。
final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {

    let executor: HelperExecutor
    let teamID: String
    let logger: Logger
    var onActivity: (() -> Void)?

    init(executor: HelperExecutor, teamID: String, logger: Logger) {
        self.executor = executor
        self.teamID = teamID
        self.logger = logger
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        // ② 客户端校验：签名有效 + teamId 与自身一致（防伪造客户端，R12）
        guard Self.verifyClientTeam(
            pid: newConnection.processIdentifier, expectedTeamID: teamID
        ) else {
            logger.warning("helper rejected connection (pid \(newConnection.processIdentifier): signature/teamId mismatch)")
            return false
        }

        newConnection.exportedInterface = NSXPCInterface(with: CcCleanHelperXPCProtocol.self)
        newConnection.exportedObject = HelperServiceProxy(executor: executor, teamID: teamID) { [weak self] in
            self?.onActivity?()
        }
        newConnection.resume()
        return true
    }

    /// SecCodeCopyGuestWithAttributes(kSecGuestAttributePid) + teamId requirement 校验。
    static func verifyClientTeam(pid: pid_t, expectedTeamID: String) -> Bool {
        guard pid > 0 else { return false }
        var attributes: [String: Any] = [
            kSecGuestAttributePid as String: pid,
        ]
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(
            nil, attributes as CFDictionary, SecCSFlags(rawValue: 0), &code
        ) == errSecSuccess, let code else { return false }
        let requirementString =
            "anchor apple generic and certificate leaf[subject.OU] = \"\(expectedTeamID)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            requirementString as CFString, SecCSFlags(rawValue: 0), &requirement
        ) == errSecSuccess, let req = requirement else { return false }
        return SecCodeCheckValidity(code, SecCSFlags(rawValue: 0), req) == errSecSuccess
    }
}

/// XPC 导出对象：单一 execute 入口（降低接口面，基线 10.4）。
/// @unchecked Sendable：NSXPCConnection 对 exportedObject 的调用为串行投递，
/// executor 为 actor（自身隔离），teamID/onActivity 均为不可变。
final class HelperServiceProxy: NSObject, CcCleanHelperXPCProtocol, @unchecked Sendable {

    let executor: HelperExecutor
    let teamID: String
    let onActivity: () -> Void

    init(executor: HelperExecutor, teamID: String, onActivity: @escaping () -> Void) {
        self.executor = executor
        self.teamID = teamID
        self.onActivity = onActivity
    }

    func execute(_ requestJSON: Data, reply: @escaping (Data) -> Void) {
        onActivity()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let request = try? decoder.decode(HelperRequest.self, from: requestJSON) else {
            let error = HelperResponse(succeeded: [], failed: ["*": "请求解码失败"])
            reply(Self.encode(error))
            return
        }
        // reply 闭包由 XPC 框架保证线程安全，用 Sendable 包装盒跨 Task 传递
        let replyBox = ReplyBox(reply: reply)
        let proxy = self
        Task {
            let response = await proxy.executor.execute(request, clientToken: proxy.teamID)
            replyBox.call(Self.encode(response))
        }
    }

    static func encode(_ response: HelperResponse) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(response)) ?? Data()
    }
    func ping(_ reply: @escaping (Bool) -> Void) {
        onActivity()
        reply(true)
    }

}

/// XPC reply 闭包的 Sendable 包装（XPC 框架内部保证串行投递）。
final class ReplyBox: @unchecked Sendable {
    let reply: (Data) -> Void
    init(reply: @escaping (Data) -> Void) { self.reply = reply }
    func call(_ data: Data) { reply(data) }
}