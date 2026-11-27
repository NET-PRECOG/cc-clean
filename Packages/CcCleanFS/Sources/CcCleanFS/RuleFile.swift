import Foundation
import CcCleanCore

/// 规则评估范围（基线 6.2 RuleScope）。
public enum RuleScope: String, Codable, Sendable {
    case cleanup, security, devenv, healthCheck
}

/// 风险三级。
public enum RiskLevel: String, Codable, Sendable {
    case low, medium, high
}

/// 规则匹配定义（基线 6.2 RuleMatch）。
public struct RuleMatch: Codable, Sendable, Equatable {
    public var roots: [String]
    public var maxDepth: Int
    public var namePatterns: [String]?
    public var pathRegex: String?
    public var extensions: [String]?
    public var minSize: Int64?
    public var olderThanDays: Int?
    /// 内容包含（单文件读取 ≤ 64KB）
    public var contentContains: [String]?
    /// 排除项，优先生效（保护聊天数据库等）
    public var excludePatterns: [String]?

    public init(
        roots: [String], maxDepth: Int = 3, namePatterns: [String]? = nil,
        pathRegex: String? = nil, extensions: [String]? = nil,
        minSize: Int64? = nil, olderThanDays: Int? = nil,
        contentContains: [String]? = nil, excludePatterns: [String]? = nil
    ) {
        self.roots = roots
        self.maxDepth = maxDepth
        self.namePatterns = namePatterns
        self.pathRegex = pathRegex
        self.extensions = extensions
        self.minSize = minSize
        self.olderThanDays = olderThanDays
        self.contentContains = contentContains
        self.excludePatterns = excludePatterns
    }

    enum CodingKeys: String, CodingKey {
        case roots, maxDepth, namePatterns, pathRegex, extensions
        case minSize, olderThanDays, contentContains, excludePatterns
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        roots = try c.decode([String].self, forKey: .roots)
        maxDepth = try c.decodeIfPresent(Int.self, forKey: .maxDepth) ?? 3
        namePatterns = try c.decodeIfPresent([String].self, forKey: .namePatterns)
        pathRegex = try c.decodeIfPresent(String.self, forKey: .pathRegex)
        extensions = try c.decodeIfPresent([String].self, forKey: .extensions)
        minSize = try c.decodeIfPresent(Int64.self, forKey: .minSize)
        olderThanDays = try c.decodeIfPresent(Int.self, forKey: .olderThanDays)
        contentContains = try c.decodeIfPresent([String].self, forKey: .contentContains)
        excludePatterns = try c.decodeIfPresent([String].self, forKey: .excludePatterns)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(roots, forKey: .roots)
        try c.encode(maxDepth, forKey: .maxDepth)
        try c.encodeIfPresent(namePatterns, forKey: .namePatterns)
        try c.encodeIfPresent(pathRegex, forKey: .pathRegex)
        try c.encodeIfPresent(extensions, forKey: .extensions)
        try c.encodeIfPresent(minSize, forKey: .minSize)
        try c.encodeIfPresent(olderThanDays, forKey: .olderThanDays)
        try c.encodeIfPresent(contentContains, forKey: .contentContains)
        try c.encodeIfPresent(excludePatterns, forKey: .excludePatterns)
    }
}

/// 规则动作（S4 起 OperationJournal 承接；S3 只评估不执行）。
/// .report 为 I7 类「只报告不清理」规则（基线 9.6 规则 23/24 语义；schema kind 枚举的补充，
/// 需随变更单同步基线 9.2）。
public enum RuleAction: Codable, Sendable, Equatable {
    case report
    case trash
    case removeSystem
    case backupAndRemove(backupRoot: String)
    case bootout(plist: String)
    case runWhitelistedCommand(executable: String, args: [String])

    enum CodingKeys: String, CodingKey {
        case kind, executable, args, backupRoot, plist
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "report": self = .report
        case "trash": self = .trash
        case "removeSystem": self = .removeSystem
        case "backupAndRemove":
            self = .backupAndRemove(backupRoot: try c.decodeIfPresent(String.self, forKey: .backupRoot) ?? "")
        case "bootout":
            self = .bootout(plist: try c.decodeIfPresent(String.self, forKey: .plist) ?? "")
        case "runWhitelistedCommand":
            self = .runWhitelistedCommand(
                executable: try c.decode(String.self, forKey: .executable),
                args: try c.decodeIfPresent([String].self, forKey: .args) ?? []
            )
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown action kind: \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .report: try c.encode("report", forKey: .kind)
        case .trash: try c.encode("trash", forKey: .kind)
        case .removeSystem: try c.encode("removeSystem", forKey: .kind)
        case .backupAndRemove(let root):
            try c.encode("backupAndRemove", forKey: .kind)
            try c.encode(root, forKey: .backupRoot)
        case .bootout(let plist):
            try c.encode("bootout", forKey: .kind)
            try c.encode(plist, forKey: .plist)
        case .runWhitelistedCommand(let exec, let args):
            try c.encode("runWhitelistedCommand", forKey: .kind)
            try c.encode(exec, forKey: .executable)
            try c.encode(args, forKey: .args)
        }
    }
}

/// 规则文件单条（基线 6.2 RuleFile）。
public struct RuleFile: Codable, Sendable {
    public var id: String
    public var module: String
    public var scope: RuleScope
    public var title: String
    /// 展示给用户的解释，禁止为空（校验器强制）
    public var explain: String
    public var risk: RiskLevel
    public var defaultSelected: Bool
    public var requiresRoot: Bool
    public var action: RuleAction
    public var match: RuleMatch
    public var schemaVersion: Int

    public init(
        id: String, module: String, scope: RuleScope, title: String,
        explain: String, risk: RiskLevel, defaultSelected: Bool,
        requiresRoot: Bool, action: RuleAction, match: RuleMatch, schemaVersion: Int
    ) {
        self.id = id
        self.module = module
        self.scope = scope
        self.title = title
        self.explain = explain
        self.risk = risk
        self.defaultSelected = defaultSelected
        self.requiresRoot = requiresRoot
        self.action = action
        self.match = match
        self.schemaVersion = schemaVersion
    }

    enum CodingKeys: String, CodingKey {
        case id, module, scope, title, explain, risk
        case defaultSelected, requiresRoot, action, match, schemaVersion
    }

    /// 9.2 schema 中 rules items 的 schemaVersion 为可选（缺省继承包版本 1）。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        module = try c.decode(String.self, forKey: .module)
        scope = try c.decode(RuleScope.self, forKey: .scope)
        title = try c.decode(String.self, forKey: .title)
        explain = try c.decode(String.self, forKey: .explain)
        risk = try c.decode(RiskLevel.self, forKey: .risk)
        defaultSelected = try c.decode(Bool.self, forKey: .defaultSelected)
        requiresRoot = try c.decodeIfPresent(Bool.self, forKey: .requiresRoot) ?? false
        action = try c.decode(RuleAction.self, forKey: .action)
        match = try c.decode(RuleMatch.self, forKey: .match)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    }
}

/// 规则文件包（schemaVersion + rules 数组，基线 9.2）。
public struct RulePack: Codable, Sendable {
    public var schemaVersion: Int
    public var rules: [RuleFile]
}

/// 规则命中（基线 6.2 RuleHit）。
public struct RuleHit: Sendable {
    public let rule: RuleFile
    public let paths: [String]
    public let totalBytes: Int64
    public let risk: RiskLevel
    /// 被保护名单拦下的路径（透明展示，绝不静默丢弃）
    public let skippedProtected: [String]
    /// 预算超时部分结果
    public let partial: Bool

    public init(
        rule: RuleFile, paths: [String], totalBytes: Int64,
        risk: RiskLevel, skippedProtected: [String] = [], partial: Bool = false
    ) {
        self.rule = rule
        self.paths = paths
        self.totalBytes = totalBytes
        self.risk = risk
        self.skippedProtected = skippedProtected
        self.partial = partial
    }
}

/// 评估上下文（基线 6.2 RuleContext）。
public struct RuleContext: Sendable {
    public let scope: RuleScope
    /// 额外搜索根（如选中的 app bundle）
    public let extraRoots: [String]
    /// 单条规则评估预算，超时返回部分结果
    public let budget: Duration

    public init(scope: RuleScope, extraRoots: [String] = [], budget: Duration = .seconds(10)) {
        self.scope = scope
        self.extraRoots = extraRoots
        self.budget = budget
    }
}

// MARK: - 路径模板展开

public enum RulePathExpander {

    /// 展开 roots：`~` → 家目录；`{a,b}` 花括号展开；展开后校验禁 `..`。
    public static func expandRoots(_ roots: [String], home: String) -> [String] {
        var result: [String] = []
        for root in roots {
            var expanded = [root]
            // 花括号展开（单层）
            if let start = root.firstIndex(of: "{"), let end = root.firstIndex(of: "}") {
                let prefix = String(root[..<start])
                let suffix = String(root[root.index(after: end)...])
                let options = root[root.index(after: start)..<end].split(separator: ",")
                expanded = options.map { prefix + $0 + suffix }
            }
            for var path in expanded {
                if path.hasPrefix("~") {
                    path = home + path.dropFirst()
                }
                path = (path as NSString).standardizingPath
                if path.contains("..") { continue }   // 校验器层也会拒绝，双保险
                result.append(path)
            }
        }
        return result
    }
}

// MARK: - glob 匹配

enum RuleGlob {
    /// 大小写不敏感 glob（Darwin fnmatch，FNM_CASEFOLD）。
    static func match(_ name: String, pattern: String) -> Bool {
        fnmatch(pattern, name, FNM_CASEFOLD) == 0
    }
}