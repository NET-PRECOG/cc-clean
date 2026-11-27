import Foundation
import CcCleanCore

/// 规则校验错误。
public struct ValidationError: Sendable, Equatable, Error {
    public let ruleId: String
    public let code: Int
    public let message: String
}

/// 校验失败集合（可作 Result.Failure）。
public struct ValidationFailure: Sendable, Equatable, Error {
    public let errors: [ValidationError]
}

/// 规则校验器（基线 9.4：8 条校验，CI 与运行时双重执行）。
public enum RuleValidator {

    /// 白名单可执行文件（基线 9.3 action.kind 语义）。
    public static let whitelistedExecutables: Set<String> = [
        "tmutil", "pkgutil", "tccutil", "launchctl", "plutil", "lipo", "codesign",
        "/usr/bin/tmutil", "/usr/sbin/pkgutil", "/usr/bin/tccutil", "/bin/launchctl",
        "/usr/bin/plutil", "/usr/bin/lipo", "/usr/bin/codesign",
    ]

    /// 硬保护路径前缀（基线 9.4 第 3 条；healthCheck 只读侦察例外）。
    static let forbiddenRootPrefixes = ["/System", "/usr", "/bin", "/sbin", "/private"]

    /// /private 例外：基线 9.6 规则 4（cleanup.system.tmp）使用 /private/var/folders，
    /// 与 9.4 第 3 条冲突——按 9.6 原样放行该前缀，需变更单裁决后固化（任务拆解第 4 节）。
    static let privateExceptionPrefixes = ["/private/var/folders"]

    /// 校验整个规则包，返回全部错误（CI 门槛：0 错误才通过）。
    public static func validate(_ pack: RulePack) -> [ValidationError] {
        var errors: [ValidationError] = []

        // 8 schemaVersion 兼容
        guard pack.schemaVersion == 1 else {
            errors.append(ValidationError(
                ruleId: "*",
                code: 8,
                message: "schemaVersion \(pack.schemaVersion) 与 App 支持范围 (1) 不兼容"
            ))
            return errors
        }

        var seenIds = Set<String>()
        for rule in pack.rules {
            errors.append(contentsOf: validateRule(rule))

            // 2 id 唯一（跨全部文件）
            if !seenIds.insert(rule.id).inserted {
                errors.append(ValidationError(ruleId: rule.id, code: 2, message: "id 重复"))
            }

            // 7 explain ≥ 8 且不含占位符
            if rule.explain.count < 8 || rule.explain.contains("TODO") || rule.explain.contains("xxx") {
                errors.append(ValidationError(ruleId: rule.id, code: 7, message: "explain 长度 < 8 或含占位符"))
            }

            // 4 risk == high ⇒ defaultSelected == false（强制改写并报警由 load 侧处理）
            if rule.risk == .high && rule.defaultSelected {
                errors.append(ValidationError(ruleId: rule.id, code: 4, message: "高危规则 defaultSelected 必须为 false"))
            }

            // 5 runWhitelistedCommand ⇒ executable ∈ 白名单
            if case .runWhitelistedCommand(let exec, _) = rule.action {
                let name = (exec as NSString).lastPathComponent
                if !whitelistedExecutables.contains(exec) && !whitelistedExecutables.contains(name) {
                    errors.append(ValidationError(ruleId: rule.id, code: 5, message: "非白名单可执行文件: \(exec)"))
                }
            }

            // 3 roots 黑名单（healthCheck 只读侦察例外；/private/var/folders 按 9.6 规则 4 放行）
            if rule.scope != .healthCheck {
                for root in rule.match.roots {
                    if Self.privateExceptionPrefixes.contains(where: { root.hasPrefix($0) }) {
                        continue
                    }
                    if forbiddenRootPrefixes.contains(where: { root == $0 || root.hasPrefix($0 + "/") }) {
                        errors.append(ValidationError(
                            ruleId: rule.id, code: 3,
                            message: "roots 含受保护前缀 \(root)（healthCheck 只读例外不适用）"
                        ))
                    }
                }
            }

            // 6 excludePatterns 强制（IM 类规则必须排除数据库文件）
            if rule.id.contains("im.") || rule.id.contains("wechat") || rule.id.contains("qq") {
                let excludes = rule.match.excludePatterns ?? []
                let protectedDB = ["*.db", "*.sqlite"]
                let covered = protectedDB.contains { pattern in
                    excludes.contains { $0.contains(pattern.replacingOccurrences(of: "*", with: "")) }
                }
                if !covered {
                    errors.append(ValidationError(ruleId: rule.id, code: 6, message: "IM 规则必须排除聊天数据库 (*.db/*.sqlite)"))
                }
            }
        }
        return errors
    }

    /// 单条规则校验。
    static func validateRule(_ rule: RuleFile) -> [ValidationError] {
        var errors: [ValidationError] = []
        // id 格式：<域>.<类别>.<对象>
        let idPattern = "^[a-z0-9]+(\\.[a-z0-9\\-]+)+$"
        if rule.id.range(of: idPattern, options: .regularExpression) == nil || rule.id.count > 64 {
            errors.append(ValidationError(ruleId: rule.id, code: 1, message: "id 格式或长度非法"))
        }
        // roots 禁 ..
        for root in rule.match.roots where root.contains("..") {
            errors.append(ValidationError(ruleId: rule.id, code: 3, message: "roots 含 .."))
        }
        // explain 为空
        if rule.explain.trimmingCharacters(in: .whitespaces).isEmpty {
            errors.append(ValidationError(ruleId: rule.id, code: 7, message: "explain 为空"))
        }
        return errors
    }

    /// 远端更新快速校验（基线 9.4：运行时执行 1/3/4/5 条）。
    public static func quickValidate(_ pack: RulePack) -> [ValidationError] {
        validate(pack).filter { [1, 3, 4, 5].contains($0.code) }
    }

    /// 从 JSON 数据解码并校验。
    public static func validateJSON(_ data: Data) -> Result<RulePack, ValidationFailure> {
        do {
            let pack = try JSONDecoder().decode(RulePack.self, from: data)
            let errors = validate(pack)
            return errors.isEmpty ? .success(pack) : .failure(ValidationFailure(errors: errors))
        } catch {
            return .failure(ValidationFailure(errors: [
                ValidationError(ruleId: "*", code: 1, message: "JSON 解码失败: \(error.localizedDescription)"),
            ]))
        }
    }
}