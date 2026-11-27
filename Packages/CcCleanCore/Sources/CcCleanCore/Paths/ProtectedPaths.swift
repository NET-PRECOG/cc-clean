import Foundation

/// 硬保护名单（基线 7.3 要点 6 / 10.4 硬拦截清单 2）：
/// RuleEngine / ResidueScanner / OperationJournal / HelperPathValidator 多方共用；
/// 命中即从候选中移除并记 skippedProtected（绝不静默丢弃）。
/// 归属 Core：Privileged 包（Helper 侧校验）只允许依赖 Core（基线 5.2 依赖红线）。
public struct ProtectedPaths: Sendable {

    public let pathPrefixes: [String]
    public let exactPaths: [String]
    public let bundleIdPrefixes: [String]

    public init(
        pathPrefixes: [String], exactPaths: [String], bundleIdPrefixes: [String]
    ) {
        self.pathPrefixes = pathPrefixes
        self.exactPaths = exactPaths
        self.bundleIdPrefixes = bundleIdPrefixes
    }

    /// 内置默认（Shared/Resources/protected-paths.json 的兜底镜像）。
    public static let builtin = ProtectedPaths(
        pathPrefixes: ["/System", "/usr", "/bin", "/sbin", "/private", "/Library/Extensions"],
        exactPaths: ["~/Library/Application Support/Apple", "~/Library/Keychains"],
        bundleIdPrefixes: ["com.apple.", "system."]
    )

    /// 从 JSON 加载（Shared/Resources/protected-paths.json）。
    public static func load(from url: URL) -> ProtectedPaths {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .builtin
        }
        return ProtectedPaths(
            pathPrefixes: (json["pathPrefixes"] as? [String]) ?? builtin.pathPrefixes,
            exactPaths: ((json["exactPaths"] as? [String]) ?? builtin.exactPaths).map {
                ($0 as NSString).expandingTildeInPath
            },
            bundleIdPrefixes: (json["bundleIdPrefixes"] as? [String]) ?? builtin.bundleIdPrefixes
        )
    }

    /// /private 例外：基线 9.6 规则 4（cleanup.system.tmp）使用 /private/var/folders，
    /// 与 9.4 第 3 条冲突——按 9.6 原样放行该前缀，需变更单裁决后固化（任务拆解第 4 节）。
    public static let privateExceptionPrefixes = ["/private/var/folders"]

    /// 路径是否被保护（前缀 + 精确路径 + bundleId 前缀段判定）。
    /// - Parameter forRuleTarget: 规则显式清理目标模式（RuleEngine 评估）——
    ///   豁免 bundleId 前缀段拦截（safari-cache 等规则目标即 com.apple.*）并放行
    ///   /private/var/folders 例外；卸载残留扫描（ResidueScanner）与 Helper 校验保持严格模式。
    public func isProtected(path: String, home: String, forRuleTarget: Bool = false) -> Bool {
        let normalized = (path as NSString).standardizingPath
        if forRuleTarget, Self.privateExceptionPrefixes.contains(where: { normalized.hasPrefix($0) }) {
            return false
        }
        for prefix in pathPrefixes {
            if normalized == prefix || normalized.hasPrefix(prefix + "/") { return true }
        }
        for exact in exactPaths {
            let resolved = exact.hasPrefix("~") ? home + exact.dropFirst() : exact
            if normalized == resolved || normalized.hasPrefix(resolved + "/") { return true }
        }
        // bundleId 前缀：路径中任一组件以 com.apple./system. 开头 → Apple 资产保护
        //（如 ~/Library/Caches/com.apple.Safari；仅卸载残留扫描严格模式拦截）
        if !forRuleTarget {
            let components = normalized.split(separator: "/").map(String.init)
            for component in components {
                if bundleIdPrefixes.contains(where: { component.hasPrefix($0) }) {
                    return true
                }
            }
        }
        return false
    }
}