import Foundation
import CcCleanCore

/// XPC 传输协议（@objc：NSXPCInterface 要求 ObjC 协议）。
/// Helper target 侧实现同一协议；载荷为 HelperRequest/HelperResponse 的 JSON。
/// 四道关在 Helper 侧执行（基线 10.3：签名自检 / 客户端 audit_token / 参数白名单 / 审计）；
/// 客户端侧仅负责连接、编码与中断处理。
@objc public protocol CcCleanHelperXPCProtocol {
    /// 单一入口：HelperRequest JSON → HelperResponse JSON（降低接口面，基线 10.4）
    func execute(_ requestJSON: Data, reply: @escaping (Data) -> Void)
    /// 健康检查（客户端探测 Helper 是否已注册）
    func ping(_ reply: @escaping (Bool) -> Void)
}

/// HelperClient（基线 10.3）：XPC 连接管理 + 请求发送 + interruptionHandler。
/// 实现 Core 的 HelperClientProtocol；由 App 层注入 OperationJournal(helper:)。
/// 连接失败/Helper 未注册时逐项返回明确失败原因（灰显占位语义）。
public final class XPCHelperClient: HelperClientProtocol, @unchecked Sendable {

    private let lock = NSLock()
    private var connection: NSXPCConnection?

    public init() {}

    // MARK: - 连接管理

    private func currentConnection() -> NSXPCConnection? {
        lock.lock(); defer { lock.unlock() }
        if let connection { return connection }
        let conn = NSXPCConnection(machServiceName: HelperConstants.machServiceName)
        conn.remoteObjectInterface = NSXPCInterface(with: CcCleanHelperXPCProtocol.self)
        // 中断处理：连接断开时清空缓存，下次调用自动重连（基线 10.3 interruptionHandler）
        conn.interruptionHandler = { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.connection = nil
            self.lock.unlock()
        }
        conn.invalidationHandler = { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.connection = nil
            self.lock.unlock()
        }
        conn.resume()
        connection = conn
        return conn
    }

    private func invalidate() {
        lock.lock(); defer { lock.unlock() }
        connection?.invalidate()
        connection = nil
    }

    // MARK: - 传输

    private func send(_ request: HelperRequest) async -> HelperResponse {
        let encoder = JSONCoding.encoder()
        guard let payload = try? encoder.encode(request) else {
            return HelperResponse(succeeded: [], failed: ["*": "请求编码失败"])
        }
        // 载荷上限（基线 10.3：单次 ≤ 1MB）
        if payload.count > HelperConstants.maxPayloadBytes {
            return HelperResponse(succeeded: [], failed: ["*": "载荷超限（\(payload.count) > \(HelperConstants.maxPayloadBytes)）"])
        }

        return await withCheckedContinuation { continuation in
            let conn = self.currentConnection()
            let proxy = conn?.remoteObjectProxyWithErrorHandler { error in
                self.invalidate()
                continuation.resume(returning: HelperResponse(
                    succeeded: [], failed: ["*": "XPC 通信错误：\(error.localizedDescription)"]
                ))
            } as? CcCleanHelperXPCProtocol
            guard let proxy else {
                continuation.resume(returning: HelperResponse(
                    succeeded: [],
                    failed: ["*": "Helper 连接失败（未安装或未注册，请执行「安装辅助程序」）"]
                ))
                return
            }
            proxy.execute(payload) { replyData in
                let response = (try? JSONCoding.decoder().decode(HelperResponse.self, from: replyData))
                    ?? HelperResponse(succeeded: [], failed: ["*": "Helper 响应解码失败"])
                continuation.resume(returning: response)
            }
        }
    }

    /// 探测 Helper 是否可用（能力总览卡状态灯数据源）。
    public func ping() async -> Bool {
        let request = HelperRequest(journalID: "ping", action: .removeItems)
        let encoder = JSONEncoder()
        guard let payload = try? encoder.encode(request) else { return false }
        return await withCheckedContinuation { continuation in
            let conn = self.currentConnection()
            let proxy = conn?.remoteObjectProxyWithErrorHandler { _ in
                continuation.resume(returning: false)
            } as? CcCleanHelperXPCProtocol
            guard let proxy else {
                continuation.resume(returning: false)
                return
            }
            proxy.ping { alive in
                continuation.resume(returning: alive)
            }
        }
    }

    // MARK: - HelperClientProtocol（逐项构造 HelperRequest）

    public func removeItems(
        _ paths: [String], journalID: String
    ) async -> (succeeded: [String], failed: [String: String]) {
        await send(HelperRequest(
            journalID: journalID, action: .removeItems, paths: paths
        )).tuple
    }

    public func forgetReceipts(
        _ pkgIDs: [String], journalID: String
    ) async -> (succeeded: [String], failed: [String: String]) {
        await send(HelperRequest(
            journalID: journalID, action: .forgetReceipts, pkgIDs: pkgIDs
        )).tuple
    }

    public func resetTCC(
        bundleID: String, services: [String], journalID: String
    ) async -> (succeeded: [String], failed: [String: String]) {
        await send(HelperRequest(
            journalID: journalID, action: .resetTCC,
            bundleID: bundleID, services: services
        )).tuple
    }

    public func bootout(
        label: String, plistPath: String, journalID: String
    ) async -> (succeeded: [String], failed: [String: String]) {
        await send(HelperRequest(
            journalID: journalID, action: .bootout,
            plistPath: plistPath, label: label
        )).tuple
    }

    public func runWhitelisted(
        _ executable: String, args: [String], journalID: String
    ) async -> (succeeded: [String], failed: [String: String]) {
        await send(HelperRequest(
            journalID: journalID, action: .runWhitelisted,
            executable: executable, args: args
        )).tuple
    }
}

private extension HelperResponse {
    var tuple: (succeeded: [String], failed: [String: String]) {
        (succeeded, failed)
    }
}