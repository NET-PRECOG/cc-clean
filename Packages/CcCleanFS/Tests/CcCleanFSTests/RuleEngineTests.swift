import Testing
import Foundation
import CcCleanCore
@testable import CcCleanFS

/// 构造规则文件。
func makeRule(
    id: String, scope: RuleScope = .cleanup, risk: RiskLevel = .low,
    selected: Bool = true, roots: [String], maxDepth: Int = 3,
    namePatterns: [String]? = nil, extensions: [String]? = nil,
    minSize: Int64? = nil, olderThanDays: Int? = nil,
    excludes: [String]? = nil, content: [String]? = nil,
    explain: String = "测试规则说明文案", action: RuleAction = .trash
) -> RuleFile {
    RuleFile(
        id: id, module: "G1", scope: scope, title: id, explain: explain,
        risk: risk, defaultSelected: selected, requiresRoot: false,
        action: action,
        match: RuleMatch(
            roots: roots, maxDepth: maxDepth, namePatterns: namePatterns,
            pathRegex: nil, extensions: extensions, minSize: minSize,
            olderThanDays: olderThanDays, contentContains: content,
            excludePatterns: excludes
        ),
        schemaVersion: 1
    )
}

@Suite("RuleValidator")
struct RuleValidatorTests {

    @Test("合法规则包：0 错误")
    func validPack() {
        let pack = RulePack(schemaVersion: 1, rules: [
            makeRule(id: "cleanup.test.valid", roots: ["~/Library/Logs"]),
        ])
        #expect(RuleValidator.validate(pack).isEmpty)
    }

    @Test("高危规则 defaultSelected=true 被拒（第 4 条）")
    func highRiskSelected() {
        let pack = RulePack(schemaVersion: 1, rules: [
            makeRule(id: "cleanup.test.high", risk: .high, selected: true, roots: ["~/Downloads"]),
        ])
        #expect(RuleValidator.validate(pack).contains { $0.code == 4 })
    }

    @Test("roots 含 /System 被拒（第 3 条，healthCheck 例外放行）")
    func forbiddenRoots() {
        let pack = RulePack(schemaVersion: 1, rules: [
            makeRule(id: "cleanup.test.system", roots: ["/System/Library"]),
        ])
        #expect(RuleValidator.validate(pack).contains { $0.code == 3 })

        let probe = RulePack(schemaVersion: 1, rules: [
            makeRule(id: "healthcheck.probe.system", scope: .healthCheck, roots: ["/System/Library/LaunchDaemons"]),
        ])
        #expect(RuleValidator.validate(probe).isEmpty)
    }

    @Test("IM 规则未排除数据库被拒（第 6 条）")
    func imRuleExcludes() {
        let noExclude = RulePack(schemaVersion: 1, rules: [
            makeRule(id: "cleanup.im.wechat-cache", roots: ["~/Library/Containers"]),
        ])
        #expect(RuleValidator.validate(noExclude).contains { $0.code == 6 })

        let withExclude = RulePack(schemaVersion: 1, rules: [
            makeRule(
                id: "cleanup.im.wechat-cache", roots: ["~/Library/Containers"],
                excludes: ["*.db", "*.sqlite", "MM.sqlite"]
            ),
        ])
        #expect(RuleValidator.validate(withExclude).isEmpty)
    }

    @Test("id 重复 / explain 占位符 / 非白名单命令 / 非法 schemaVersion")
    func miscViolations() {
        let dup = RulePack(schemaVersion: 1, rules: [
            makeRule(id: "cleanup.test.dup", roots: ["~/Library/Logs"]),
            makeRule(id: "cleanup.test.dup", roots: ["~/Library/Caches"]),
        ])
        #expect(RuleValidator.validate(dup).contains { $0.code == 2 })

        let todo = RulePack(schemaVersion: 1, rules: [
            makeRule(id: "cleanup.test.todo", roots: ["~/Library/Logs"], explain: "TODO 待补充"),
        ])
        #expect(RuleValidator.validate(todo).contains { $0.code == 7 })

        let evil = RulePack(schemaVersion: 1, rules: [
            makeRule(
                id: "cleanup.test.evil", roots: ["~/Library/Logs"],
                action: .runWhitelistedCommand(executable: "/bin/rm", args: [])
            ),
        ])
        #expect(RuleValidator.validate(evil).contains { $0.code == 5 })

        let badVersion = RulePack(schemaVersion: 99, rules: [])
        #expect(RuleValidator.validate(badVersion).contains { $0.code == 8 })
    }

    @Test("validateJSON：解码 + 校验一体")
    func jsonRoundtrip() throws {
        let json = """
        {
          "schemaVersion": 1,
          "rules": [{
            "id": "cleanup.json.valid", "module": "G1", "scope": "cleanup",
            "title": "JSON 规则", "explain": "来自 JSON 的规则说明",
            "risk": "low", "defaultSelected": true, "requiresRoot": false,
            "action": {"kind": "trash"},
            "match": {"roots": ["~/Library/Logs"], "maxDepth": 2}
          }]
        }
        """
        let result = RuleValidator.validateJSON(Data(json.utf8))
        guard case .success(let pack) = result else {
            // 独立解码以获取完整底层错误
            do {
                _ = try JSONDecoder().decode(RulePack.self, from: Data(json.utf8))
                print("DEBUG jsonRoundtrip: decode ok, validation must have failed")
            } catch {
                print("DEBUG jsonRoundtrip decode error: \(error)")
            }
            Issue.record("应解码成功")
            return
        }
        #expect(pack.rules.count == 1)
        #expect(pack.rules[0].match.maxDepth == 2)
        #expect(pack.rules[0].action == .trash)
    }
}

@Suite("RuleEngine")
struct RuleEngineTests {

    @Test("评估：olderThanDays + namePatterns 命中与排除")
    func evaluation() async throws {
        let layout = try FSTestFixture.makeTree()
        defer { FSTestFixture.remove(layout.root) }
        // deep.log 设为 10 天前（满足 olderThanDays: 1）
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-10 * 86400)],
            ofItemAtPath: layout.nestedDir.appendingPathComponent("deep.log").path
        )

        let engine = RuleEngine(logger: Logger(category: .scan, buffer: LogBuffer(capacity: 10)))
        try await engine.load([
            makeRule(
                id: "cleanup.test.logs", roots: ["\(layout.root.path)/n1"],
                maxDepth: 5, namePatterns: ["*.log"], olderThanDays: 1
            ),
        ])
        let hits = await engine.evaluate(RuleContext(scope: .cleanup))
        #expect(hits.count == 1)
        let hit = try #require(hits.first)
        #expect(hit.paths.contains { $0.hasSuffix("n1/n2/n3/deep.log") })
        #expect(hit.totalBytes >= 80)
        #expect(!hit.partial)
    }

    @Test("排除优先：excludePatterns 拦下 *.db")
    func excludeWins() async throws {
        let layout = try FSTestFixture.makeTree()
        defer { FSTestFixture.remove(layout.root) }
        // 造一个 .db 文件 + 一个 .dat 文件
        try Data(repeating: 1, count: 100).write(
            to: layout.dirCJK.appendingPathComponent("msg_1.db"))

        let engine = RuleEngine(logger: Logger(category: .scan, buffer: LogBuffer(capacity: 10)))
        try await engine.load([
            makeRule(
                id: "cleanup.test.im", roots: ["\(layout.root.path)/中文 目录"],
                maxDepth: 3, extensions: ["db", "dat"], excludes: ["*.db"]
            ),
        ])
        let hits = await engine.evaluate(RuleContext(scope: .cleanup))
        let hit = try #require(hits.first)
        #expect(hit.paths.contains { $0.hasSuffix(".dat") })
        #expect(!hit.paths.contains { $0.hasSuffix(".db") })
    }

    @Test("保护名单：受保护子树跳过并记 skippedProtected")
    func protectedSkipped() async throws {
        let layout = try FSTestFixture.makeTree()
        defer { FSTestFixture.remove(layout.root) }
        // 构造受保护子树与正常文件
        let protectedDir = layout.root.appendingPathComponent("protected")
        try FileManager.default.createDirectory(
            at: protectedDir.appendingPathComponent("com.apple.stuff"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 100).write(to: protectedDir.appendingPathComponent("com.apple.stuff/a.log"))
        try Data(repeating: 1, count: 100).write(to: layout.root.appendingPathComponent("normal.log"))

        let customProtected = ProtectedPaths(
            pathPrefixes: [protectedDir.path], exactPaths: [], bundleIdPrefixes: []
        )
        let engine = RuleEngine(
            protected: customProtected, logger: Logger(category: .scan, buffer: LogBuffer(capacity: 10))
        )
        try await engine.load([
            makeRule(id: "cleanup.test.sys", roots: [layout.root.path], maxDepth: 4, namePatterns: ["*.log"]),
        ])
        let hit = try #require(await engine.dryRun(ruleID: "cleanup.test.sys"))
        #expect(hit.paths.contains { $0.hasSuffix("normal.log") })
        #expect(!hit.paths.contains { $0.hasPrefix(protectedDir.path) })
        #expect(!hit.skippedProtected.isEmpty)
    }

    @Test("dryRun：指定规则单跑；未知 id 返回 nil")
    func dryRun() async throws {
        let layout = try FSTestFixture.makeTree()
        defer { FSTestFixture.remove(layout.root) }

        let engine = RuleEngine(logger: Logger(category: .scan, buffer: LogBuffer(capacity: 10)))
        try await engine.load([
            makeRule(id: "cleanup.test.dry", roots: ["\(layout.root.path)/🎉dir"], maxDepth: 2),
        ])
        let hit = await engine.dryRun(ruleID: "cleanup.test.dry")
        #expect(hit?.paths.contains { $0.hasSuffix("x.bin") } == true)
        let missing = await engine.dryRun(ruleID: "nonexistent.id.rule")
        #expect(missing == nil)
    }

    @Test("校验失败的规则集拒绝加载，原规则集保留")
    func loadRejectsInvalid() async throws {
        let engine = RuleEngine(logger: Logger(category: .scan, buffer: LogBuffer(capacity: 10)))
        try await engine.load([
            makeRule(id: "cleanup.test.keep", roots: ["\(layoutRoot)"], maxDepth: 1),
        ])
        do {
            try await engine.load([
                makeRule(id: "cleanup.test.bad", risk: .high, selected: true, roots: ["~/x"]),
            ])
            Issue.record("应抛验证错误")
        } catch {}

        // 原规则仍在（dryRun 可用）
        let hit = await engine.dryRun(ruleID: "cleanup.test.keep")
        #expect(hit != nil)
    }

    private var layoutRoot: String { "/" }   // 占位根（load 校验通过即可）
}