import Foundation

/// XPC 传输 DTO（基线 10.3：只含数据，不含业务逻辑）。
/// Helper 因此不会把扫描/UI 代码带进 root 进程。

/// Helper 支持的操作类型（与 OperationJournal 的系统级操作一一对应）。
public enum HelperActionKind: String, Codable, Sendable {
    case removeItems          // 批量删除（C2/C3 系统级残留）
    case forgetReceipts       // pkgutil --forget（C2）
    case resetTCC             // tccutil 逐服务重置（I3；禁 reset All）
    case bootout              // launchctl bootout（H2/C10）
    case runWhitelisted       // 白名单可执行命令（root 场景）
}

/// 单条 Helper 请求。
public struct HelperRequest: Codable, Sendable {
    public let journalID: String       // 审计关联
    public let action: HelperActionKind
    public let paths: [String]         // removeItems 的目标
    public let pkgIDs: [String]        // forgetReceipts
    public let bundleID: String        // resetTCC
    public let services: [String]      // resetTCC 逐服务
    public let plistPath: String       // bootout
    public let label: String           // bootout
    public let executable: String      // runWhitelisted
    public let args: [String]

    public init(
        journalID: String, action: HelperActionKind,
        paths: [String] = [], pkgIDs: [String] = [],
        bundleID: String = "", services: [String] = [],
        plistPath: String = "", label: String = "",
        executable: String = "", args: [String] = []
    ) {
        self.journalID = journalID
        self.action = action
        self.paths = paths
        self.pkgIDs = pkgIDs
        self.bundleID = bundleID
        self.services = services
        self.plistPath = plistPath
        self.label = label
        self.executable = executable
        self.args = args
    }
}

/// Helper 响应（逐项结果，基线 10.3）。
public struct HelperResponse: Codable, Sendable {
    public let succeeded: [String]
    public let failed: [String: String]

    public init(succeeded: [String], failed: [String: String]) {
        self.succeeded = succeeded
        self.failed = failed
    }
}

/// Helper 常量。
public enum HelperConstants {
    /// MachServiceName（与 Helper target 的 Info.plist/SMS 入口一致）
    public static let machServiceName = "app.cclean.helper"
    /// Helper 可执行签名要求
    public static let helperBundleID = "app.cclean.helper"
    /// 单批路径上限（基线 10.3：单次 ≤ 500 条 / 1MB）
    public static let maxBatchPaths = 500
    public static let maxPayloadBytes = 1_000_000
    /// Helper 空闲自杀时限（基线 10.3：30 分钟）
    public static let idleTimeoutSeconds: TimeInterval = 30 * 60
}

/// Helper 校验错误。
public enum HelperValidationError: Error, Equatable {
    case notAbsolutePath(String)
    case containsDotDot(String)
    case containsWildcard(String)
    case protectedPath(String)
    case realpathMismatch(String)
    case emptyPaths
    case batchTooLarge(count: Int)
    case forbiddenResetAll
    case nonWhitelistedExecutable(String)
    case systemVolumeItem(String)
}

extension HelperValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notAbsolutePath(let p): return "非绝对路径: \(p)"
        case .containsDotDot(let p): return "路径含 ..: \(p)"
        case .containsWildcard(let p): return "路径含通配符: \(p)"
        case .protectedPath(let p): return "受保护路径: \(p)"
        case .realpathMismatch(let p): return "realpath 与请求路径不一致: \(p)"
        case .emptyPaths: return "路径列表为空"
        case .batchTooLarge(let count): return "单批路径数超限: \(count)"
        case .forbiddenResetAll: return "禁止 tccutil reset All"
        case .nonWhitelistedExecutable(let e): return "非白名单可执行文件: \(e)"
        case .systemVolumeItem(let p): return "系统卷项目: \(p)"
        }
    }
}

/// Helper 可执行白名单（与 RuleValidator.whitelistedExecutables 同源维护）。
public enum HelperWhitelist {
    public static let executables: Set<String> = [
        "/usr/sbin/pkgutil", "/usr/bin/tccutil", "/bin/launchctl",
        "/usr/bin/plutil", "/usr/bin/lipo", "/usr/bin/codesign", "/usr/bin/tmutil",
    ]
}