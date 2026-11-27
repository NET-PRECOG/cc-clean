import Testing
import Foundation
import CcCleanCore
@testable import CcCleanFS

/// S3-4 规则 fixture 框架（基线 13.2）：
/// ① 全部内置规则文件通过 RuleValidator 8 条校验；
/// ② 每条规则自动构造 positive/negative fixture 并断言评估结果；
/// 新增规则未带 fixture 语义（无法构造正反例）则测试失败。

enum BundledRules {

    /// Shared/Resources 根目录。
    static func resourcesRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/CcCleanFSTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Packages/CcCleanFS
            .deletingLastPathComponent()   // Packages
            .deletingLastPathComponent()   // 仓库根
            .appendingPathComponent("Shared/Resources", isDirectory: true)
    }

    /// 加载 rules/**/*.json 全部规则包（zombie-launchd 计算型规则单独校验语法）。
    static func loadAll() throws -> (rules: [RuleFile], fileCount: Int) {
        let rulesRoot = resourcesRoot().appendingPathComponent("rules", isDirectory: true)
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: rulesRoot, includingPropertiesForKeys: nil) else {
            return ([], 0)
        }
        var allRules: [RuleFile] = []
        var fileCount = 0
        for case let url as URL in enumerator where url.pathExtension == "json" {
            fileCount += 1
            let data = try Data(contentsOf: url)
            // zombie-launchd 为计算型规则（computedRules 结构），非路径规则包
            if url.lastPathComponent == "zombie-launchd.json" {
                let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                #expect(obj?["computedRules"] != nil)
                continue
            }
            let pack = try JSONDecoder().decode(RulePack.self, from: data)
            let errors = RuleValidator.validate(pack)
            #expect(errors.isEmpty, "规则文件 \(url.lastPathComponent) 校验失败: \(errors)")
            allRules.append(contentsOf: pack.rules)
        }
        return (allRules, fileCount)
    }
}

@Suite("S3-3/S3-4 内置规则与 fixture 框架")
struct RuleFixtureHarnessTests {

    @Test("全部内置规则文件通过校验，共 24 条路径规则 + 1 个计算型规则")
    func bundledRulesValid() throws {
        let (rules, fileCount) = try BundledRules.loadAll()
        #expect(fileCount == 7)   // cleanup×4 + devenv×1 + security×1 + healthcheck×1
        #expect(rules.count == 24)
        // id 全局唯一
        let ids = rules.map(\.id)
        #expect(Set(ids).count == ids.count)
        // 每条规则都有非空 explain
        #expect(rules.allSatisfy { $0.explain.count >= 8 })
        // 高危规则全部不默认勾选
        #expect(rules.allSatisfy { $0.risk != .high || !$0.defaultSelected })
        // I7 敏感文件规则为只报告
        let sensitive = rules.filter { $0.module == "I7" }
        #expect(sensitive.count == 2)
        #expect(sensitive.allSatisfy { $0.action == .report })
    }

    /// 对单条规则构造 positive/negative fixture。
    /// roots 重定向：保留 "~" 后的子路径结构（映射到 fixtureRoot 下），
    /// negative 构造在全部规则 roots 之外（真实语义：roots 外的路径不应被清理）。
    func buildFixtures(for rule: RuleFile, in root: URL) throws -> [String] {
        let fm = FileManager.default
        let pastDate = Date().addingTimeInterval(-120 * 86400)   // 覆盖最大 olderThanDays(90)

        // --- roots 映射：~/.npm/_cacache → root/.npm/_cacache；绝对路径取末段 ---
        let mappedRoots = rule.match.roots.map { template -> String in
            if template.hasPrefix("~") {
                return root.path + template.dropFirst()
            }
            let last = (template as NSString).lastPathComponent
                .replacingOccurrences(of: "/", with: "-")
            return root.appendingPathComponent("abs-\(last)").path
        }
        for mapped in mappedRoots {
            try fm.createDirectory(at: URL(fileURLWithPath: mapped), withIntermediateDirectories: true)
        }

        // --- positive：构造在第一个 mapped root 内 ---
        // maxDepth==1 的规则（如 user-cache）只评估直接子项，positive 须放 root 根层
        let positiveParent: URL
        if rule.match.maxDepth == 1 {
            positiveParent = URL(fileURLWithPath: mappedRoots[0])
        } else {
            positiveParent = URL(fileURLWithPath: mappedRoots[0]).appendingPathComponent("positive", isDirectory: true)
        }
        try fm.createDirectory(at: positiveParent, withIntermediateDirectories: true)

        let entryName: String
        let isDirEntry: Bool
        if rule.match.contentContains != nil {
            // 内容规则强制文件型（文件名取第一个 pattern 或通用名）
            let p = rule.match.namePatterns?.first ?? "hit"
            entryName = p.contains("*") ? p.replacingOccurrences(of: "*", with: "hit") : p
            isDirEntry = false
        } else if let patterns = rule.match.namePatterns, let p = patterns.first {
            if p.contains("*") {
                entryName = p.replacingOccurrences(of: "*", with: "hit")
                isDirEntry = false
            } else {
                entryName = p
                isDirEntry = true   // 目录型规则（Caches/T/Cache）
            }
        } else if let exts = rule.match.extensions, let ext = exts.first {
            entryName = "hit.\(ext)"
            isDirEntry = false
        } else {
            entryName = "hit.item"
            isDirEntry = false
        }

        let entryPath = positiveParent.appendingPathComponent(entryName)
        if isDirEntry {
            try fm.createDirectory(at: entryPath, withIntermediateDirectories: true)
            try Data(repeating: 0x48, count: 128).write(to: entryPath.appendingPathComponent("payload.bin"))
        } else {
            var payload = Data(repeating: 0x48, count: 128)
            if let needles = rule.match.contentContains, let needle = needles.first {
                payload = Data("prefix \(needle) suffix\n".utf8)
            }
            try payload.write(to: entryPath)
        }
        if rule.match.olderThanDays != nil {
            try fm.setAttributes([.modificationDate: pastDate], ofItemAtPath: entryPath.path)
        }

        // --- negative：全部 mapped roots 之外 ---
        let negative = root.appendingPathComponent("negative-out-of-roots", isDirectory: true)
        try fm.createDirectory(at: negative, withIntermediateDirectories: true)
        try Data(repeating: 0x49, count: 64).write(to: negative.appendingPathComponent("noise.nomatch"))
        if rule.id.contains("im.") || rule.id.contains("wechat") || rule.id.contains("qq") {
            try Data(repeating: 0x4a, count: 64).write(to: negative.appendingPathComponent("msg_1.db"))
        }
        if rule.match.contentContains != nil {
            try Data("nothing sensitive here\n".utf8).write(
                to: negative.appendingPathComponent("plain.env"))
        }
        return mappedRoots
    }

    @Test("逐条规则正反例：positive 命中、negative 不命中")
    func perRuleFixtures() async throws {
        let (rules, _) = try BundledRules.loadAll()
        #expect(rules.count == 24)

        for rule in rules {
            let fixtureRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("rule-fixture-\(rule.id)-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: fixtureRoot) }
            let mappedRoots = try buildFixtures(for: rule, in: fixtureRoot)

            // roots 重定向到映射后的子路径（保留规则语义深度）
            var redirected = rule
            redirected.match.roots = mappedRoots

            let engine = RuleEngine(logger: Logger(category: .scan, buffer: LogBuffer(capacity: 20)))
            try await engine.load([redirected])
            let hit = try #require(
                await engine.dryRun(ruleID: rule.id),
                "规则 \(rule.id) 评估失败"
            )
            if !hit.paths.allSatisfy({ $0.contains("/positive/") }) || hit.paths.isEmpty {
                print("DEBUG rule-failure: id=\(rule.id) patterns=\(rule.match.namePatterns ?? []) exts=\(rule.match.extensions ?? []) paths=\(hit.paths)")
            }

            // positive 命中（maxDepth==1 的规则命中项在 mappedRoot 直接子层）
            #expect(
                !hit.paths.isEmpty,
                "规则 \(rule.id) 未命中 positive fixture：\(hit.paths)"
            )
            // 全部命中都在规则 roots 内
            #expect(
                hit.paths.allSatisfy { path in
                    mappedRoots.contains { path.hasPrefix($0) }
                },
                "规则 \(rule.id) 命中了 roots 之外：\(hit.paths)"
            )
            // 无 negative（roots 外）命中
            #expect(
                !hit.paths.contains { $0.contains("/negative-out-of-roots/") },
                "规则 \(rule.id) 误命中 negative fixture：\(hit.paths)"
            )
        }
    }

    @Test("预算控制：超时返回部分结果并标记 partial")
    func budgetPartial() async throws {
        let (rules, _) = try BundledRules.loadAll()
        guard let rule = rules.first(where: { $0.match.maxDepth >= 2 }) else {
            Issue.record("无可用规则")
            return
        }
        // 构造较深的目录树
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("budget-fixture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var dir = root
        for i in 0..<6 {
            dir = dir.appendingPathComponent("lvl-\(i)")
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 64).write(to: dir.appendingPathComponent("deep.dat"))

        var redirected = rule
        redirected.match.roots = [root.path]
        redirected.match.maxDepth = 12
        redirected.match.extensions = ["dat"]

        let engine = RuleEngine(logger: Logger(category: .scan, buffer: LogBuffer(capacity: 10)))
        try await engine.load([redirected])
        // 极小预算 → partial（evaluate 透传 context.budget）
        let hits = await engine.evaluate(RuleContext(scope: rule.scope, budget: .nanoseconds(1)))
        let hit = hits.first { $0.rule.id == rule.id }
        #expect(hit != nil)
        #expect(hit?.partial == true, "预算耗尽应标记 partial")
    }
}