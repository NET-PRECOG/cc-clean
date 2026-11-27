import Foundation
import CcCleanCore

/// Helper 侧路径校验器（基线 10.3 HelperPathValidator）：
/// 六道关——绝对路径 / 禁 .. / 禁通配符 / 保护名单 / realpath 复核 / 白名单命令。
/// 恶意路径 20 例单测全覆盖（基线 S9-2 验收：覆盖率 ≥ 85%）。
public struct HelperPathValidator: Sendable {

    private let protected: ProtectedPaths
    private let home: String

    public init(protected: ProtectedPaths = .builtin, home: String? = nil) {
        self.protected = protected
        self.home = home ?? NSHomeDirectory()
    }

    // MARK: - 批量路径校验

    /// 校验批量删除请求。
    public func validateBatch(_ paths: [String]) -> [HelperValidationError] {
        var errors: [HelperValidationError] = []
        if paths.isEmpty { errors.append(.emptyPaths) }
        if paths.count > HelperConstants.maxBatchPaths {
            errors.append(.batchTooLarge(count: paths.count))
        }
        for path in paths {
            errors.append(contentsOf: validatePath(path))
        }
        return errors
    }

    /// 单路径六道关。
    public func validatePath(_ path: String) -> [HelperValidationError] {
        var errors: [HelperValidationError] = []
        // ① 绝对路径
        guard path.hasPrefix("/") else {
            errors.append(.notAbsolutePath(path))
            return errors
        }
        // ② 禁 ..
        if path.contains("..") {
            errors.append(.containsDotDot(path))
        }
        // ③ 禁通配符
        if path.contains("*") || path.contains("?") || path.contains("[") {
            errors.append(.containsWildcard(path))
        }
        // ④ 保护名单（复用 RuleEngine 的硬保护清单，严格模式）
        if protected.isProtected(path: path, home: home, forRuleTarget: false) {
            errors.append(.protectedPath(path))
        }
        // ⑤ realpath 复核（防符号链接逃逸：路径与真实路径必须一致）
        let real = realpath(path)
        if real != nil, real != (path as NSString).standardizingPath {
            errors.append(.realpathMismatch(path))
        }
        return errors
    }

    /// realpath（解析符号链接与规范化；/tmp → /private/tmp 等卷映射一并归一）。
    func realpath(_ path: String) -> String? {
        let standardized = (path as NSString).standardizingPath
        guard FileManager.default.fileExists(atPath: standardized) else { return nil }
        return URL(fileURLWithPath: standardized).resolvingSymlinksInPath().path
    }

    // MARK: - 命令白名单

    /// 校验白名单命令请求。
    public func validateCommand(executable: String, args: [String]) -> [HelperValidationError] {
        var errors: [HelperValidationError] = []
        if !HelperWhitelist.executables.contains(executable) {
            errors.append(.nonWhitelistedExecutable(executable))
        }
        // tccutil reset All 硬禁（代码级，基线 10.4）
        if (executable as NSString).lastPathComponent == "tccutil"
            && args.first == "reset" && args.count >= 2 && args[1] == "All" {
            errors.append(.forbiddenResetAll)
        }
        for arg in args {
            if arg.contains("..") {
                errors.append(.containsDotDot(arg))
            }
        }
        return errors
    }

    /// 校验 tccutil 重置请求（逐服务，禁 All）。
    public func validateTCC(bundleID: String, services: [String]) -> [HelperValidationError] {
        var errors: [HelperValidationError] = []
        if bundleID.isEmpty { errors.append(.emptyPaths) }
        if services.isEmpty { errors.append(.emptyPaths) }
        for service in services {
            if service.lowercased() == "all" {
                errors.append(.forbiddenResetAll)
            }
        }
        return errors
    }

    /// 校验完整请求（按 action 分派）。
    public func validate(_ request: HelperRequest) -> [HelperValidationError] {
        switch request.action {
        case .removeItems:
            return validateBatch(request.paths)
        case .forgetReceipts:
            return request.pkgIDs.isEmpty ? [.emptyPaths] : []
        case .resetTCC:
            return validateTCC(bundleID: request.bundleID, services: request.services)
        case .bootout:
            return validatePath(request.plistPath)
        case .runWhitelisted:
            return validateCommand(executable: request.executable, args: request.args)
        }
    }
}