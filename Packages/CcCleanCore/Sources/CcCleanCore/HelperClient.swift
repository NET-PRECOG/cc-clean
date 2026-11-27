import Foundation

/// Helper 客户端协议（基线 10.3）。
/// 归属 Core：Ops 的 OperationJournal 以此注入 Helper 能力；
/// Privileged 的 XPCHelperClient 实现它（基线 5.2 依赖红线：Privileged 只依赖 Core）。
/// Helper 未安装/未注册时调用方传 nil → 系统级操作全部失败并明确原因（灰显占位）。
public protocol HelperClientProtocol: Sendable {
    /// 批量删除（C2/C3 系统级残留；单次 ≤ 500 条/1MB，Helper 内二次白名单校验）
    func removeItems(_ paths: [String], journalID: String) async -> (succeeded: [String], failed: [String: String])
    /// pkgutil --forget（C2 receipts）
    func forgetReceipts(_ pkgIDs: [String], journalID: String) async -> (succeeded: [String], failed: [String: String])
    /// tccutil 逐服务重置（I3；代码级禁 reset All）
    func resetTCC(bundleID: String, services: [String], journalID: String) async -> (succeeded: [String], failed: [String: String])
    /// launchctl bootout（H2/C10 停用守护项）
    func bootout(label: String, plistPath: String, journalID: String) async -> (succeeded: [String], failed: [String: String])
    /// 白名单可执行命令（root 场景；用户级命令由 OperationJournal 经 ProcessRunner 直跑）
    func runWhitelisted(_ executable: String, args: [String], journalID: String) async -> (succeeded: [String], failed: [String: String])
}