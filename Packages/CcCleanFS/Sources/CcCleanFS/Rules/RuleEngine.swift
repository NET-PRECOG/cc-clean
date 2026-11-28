import Foundation
import CcCleanCore

// ProtectedPaths 已迁移至 CcCleanCore（Privileged 包 Helper 侧校验共用，
// 基线 5.2 依赖红线：Privileged 只允许依赖 Core）。

/// 规则驱动引擎（基线 6.2）。
/// 评估优先本地遍历（BulkDirectoryReader）；命中按总体积降序；预算超时返回部分结果。
public actor RuleEngine {

    private var rules: [RuleFile] = []
    private let protected: ProtectedPaths
    private let logger: Logger
    private let home: String

    public init(rules: [RuleFile] = [], protected: ProtectedPaths = .builtin, logger: Logger, home: String? = nil) {
        self.protected = protected
        self.logger = logger
        self.home = home ?? FileManager.default.homeDirectoryForCurrentUser.path
        self.rules = rules
    }

    /// 加载/热替换规则（校验失败抛错并保留原规则集，基线 6.2 要点 1）。
    public func load(_ rules: [RuleFile]) throws {
        let pack = RulePack(schemaVersion: 1, rules: rules)
        let errors = RuleValidator.validate(pack)
        guard errors.isEmpty else {
            throw RuleEngineError.validationFailed(errors)
        }
        // 4 高危强制改写并报警（基线 9.4 第 4 条运行时行为）
        self.rules = rules.map { rule in
            guard rule.risk == .high && rule.defaultSelected else { return rule }
            logger.warning("rule \(rule.id): high risk defaultSelected forced to false")
            var fixed = rule
            fixed.defaultSelected = false
            return fixed
        }
    }

    /// 评估指定范围内的规则，返回命中（按总体积降序）。
    /// 规则间无依赖，TaskGroup 并行评估（吞吐受磁盘 IO 而非串行排队限制）。
    public func evaluate(_ context: RuleContext) async -> [RuleHit] {
        let scoped = rules.filter { $0.scope == context.scope }
        let hits = await withTaskGroup(of: RuleHit.self) { group in
            for rule in scoped {
                // requiresRoot 未授权由 CapabilityGate 过滤（调用方侧）；引擎仅评估
                group.addTask { await self.evaluateRule(rule, context: context) }
            }
            var collected: [RuleHit] = []
            for await hit in group {
                collected.append(hit)
            }
            return collected
        }
        return hits.sorted { $0.totalBytes > $1.totalBytes }
    }

    /// 单规则试运行（供 UI 预览与单测）。
    public func dryRun(ruleID: String, extraRoots: [String] = []) async -> RuleHit? {
        guard let rule = rules.first(where: { $0.id == ruleID }) else { return nil }
        return await evaluateRule(rule, context: RuleContext(scope: rule.scope, extraRoots: extraRoots))
    }

    // MARK: - 单规则评估

    /// nonisolated：纯读规则 + 本地遍历，无共享可变状态，供并行 TaskGroup 并发执行。
    nonisolated private func evaluateRule(_ rule: RuleFile, context: RuleContext) async -> RuleHit {
        let deadline = ContinuousClock.now + context.budget
        var roots = RulePathExpander.expandRoots(rule.match.roots, home: home)
        roots.append(contentsOf: RulePathExpander.expandRoots(context.extraRoots, home: home)
            .compactMap { _ in nil })   // extraRoots 仅在规则 roots 指定时生效

        var matched: [(path: String, bytes: Int64)] = []
        var skipped: [String] = []
        var partial = false

        let regex = rule.match.pathRegex.flatMap { try? NSRegularExpression(pattern: $0) }
        let cutoffDate = rule.match.olderThanDays.map {
            Date().addingTimeInterval(-Double($0) * 86400)
        }

        for root in roots {
            // 遍历（深度受 maxDepth 限制；root 自身先判定）
            var stack: [(path: String, depth: Int)] = [(root, 0)]
            while let (current, depth) = stack.popLast() {
                if ContinuousClock.now >= deadline {
                    partial = true
                    break
                }
                // 排除优先（基线 9.3）
                let name = (current as NSString).lastPathComponent
                if let excludes = rule.match.excludePatterns,
                   excludes.contains(where: { RuleGlob.match(name, pattern: $0) }) {
                    continue
                }
                // 保护名单前置：命中即移除并记 skippedProtected（绝不静默丢弃）
                // 受保护路径（含子树）一律跳过；规则显式目标豁免 bundleId 前缀段
                if protected.isProtected(path: current, home: home, forRuleTarget: true) {
                    skipped.append(current)
                    continue
                }

                let isDir = Self.isDirectory(current)
                if !isDir {
                    if matchFile(current, name: name, rule: rule, regex: regex, cutoff: cutoffDate) {
                        let bytes = (try? FileManager.default.attributesOfItem(atPath: current)[.size] as? NSNumber)?.int64Value ?? 0
                        matched.append((current, bytes))
                    }
                    continue
                }

                // 目录自身按 namePatterns 匹配（如 DerivedData/*）
                if depth > 0, let patterns = rule.match.namePatterns,
                   patterns.contains(where: { RuleGlob.match(name, pattern: $0) }) {
                    let bytes = Int64(FSIndex.liveSize(of: current))
                    matched.append((current, bytes))
                    continue   // 命中目录即整目录计费，不再下探
                }

                // 下探
                if depth < rule.match.maxDepth {
                    let children = (try? BulkDirectoryReader.readEntries(atPath: current)) ?? []
                    for child in children {
                        if rule.match.skipHidden == true { /* 默认不跳隐藏，规则显式排除 */ }
                        stack.append((current + "/" + child.name, depth + 1))
                    }
                }
            }
            if partial { break }
        }

        // contentContains：对已命中文件做内容校验升精确（64KB/文件，32MB 总限）
        if let contents = rule.match.contentContains, !contents.isEmpty, !matched.isEmpty {
            matched = matched.filter { entry in
                Self.fileContains(path: entry.path, any: contents)
            }
        }

        return RuleHit(
            rule: rule,
            paths: matched.map(\.path),
            totalBytes: matched.reduce(0) { $0 + $1.bytes },
            risk: rule.risk,
            skippedProtected: skipped,
            partial: partial
        )
    }

    /// 单文件匹配（glob 名称 / 扩展名 / 大小 / 时间 / 正则）。
    nonisolated private func matchFile(
        _ path: String, name: String, rule: RuleFile,
        regex: NSRegularExpression?, cutoff: Date?
    ) -> Bool {
        // namePatterns
        if let patterns = rule.match.namePatterns,
           !patterns.contains(where: { RuleGlob.match(name, pattern: $0) }) {
            return false
        }
        // extensions
        if let exts = rule.match.extensions {
            let ext = (name as NSString).pathExtension.lowercased()
            if !exts.contains(where: { $0.lowercased() == ext }) { return false }
        }
        // pathRegex
        if let regex, regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) == nil {
            return false
        }
        // minSize / olderThanDays
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        if let minSize = rule.match.minSize {
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            if size < minSize { return false }
        }
        if let cutoff {
            let mtime = (attrs?[.modificationDate] as? Date) ?? .distantPast
            if mtime > cutoff { return false }
        }
        return true
    }

    /// 内容包含（≤ 64KB/文件；由调用层预算控制总读取量）。
    static func fileContains(path: String, any needles: [String]) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 64 * 1024)
        let text = String(decoding: data, as: UTF8.self)
        return needles.contains { text.contains($0) }
    }

    static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return isDir.boolValue
    }
}

public enum RuleEngineError: Error, Equatable {
    case validationFailed([ValidationError])
}

private extension RuleMatch {
    /// 评估期内部开关（JSON 无此字段，恒 false）。
    var skipHidden: Bool { false }
}