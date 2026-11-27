import Testing
import Foundation
import CcCleanCore
@testable import CcCleanFS

/// Spotlight Fake（基线 13.1：协议注入，不依赖真实系统输出）。
final class FakeSpotlight: SpotlightProviding, @unchecked Sendable {
    var bundleIdResults: [String] = []
    var nameResults: [String] = []

    func findByBundleId(_ bundleId: String) async -> [String] { bundleIdResults }
    func findByName(_ name: String) async -> [String] { nameResults }
}

@Suite("BundleIdMatcher (S7-4 前置)")
struct BundleIdMatcherTests {

    let matcher = BundleIdMatcher()

    @Test("bundleId 词边界：QQ 不命中 QQMusic")
    func wordBoundary() {
        #expect(matcher.pathContains(bundleId: "com.tencent.qq", path: "/Users/x/Library/Caches/com.tencent.qq"))
        #expect(matcher.pathContains(bundleId: "com.tencent.qq", path: "/Users/x/Library/Caches/com.tencent.qq.helper"))
        #expect(!matcher.pathContains(bundleId: "com.tencent.qq", path: "/Users/x/Library/Caches/com.tencent.qqmusic"))
        #expect(!matcher.pathContains(bundleId: "com.tencent.qq", path: "/Users/x/Library/Caches/other"))
    }

    @Test("显示名全词：QQ 不命中 QQMusic（禁前缀删除）")
    func wholeWord() {
        #expect(matcher.pathContainsWholeWord(name: "QQ", path: "/Users/x/Library/Application Support/QQ/Cache"))
        #expect(!matcher.pathContainsWholeWord(name: "QQ", path: "/Users/x/Library/Application Support/QQMusic"))
    }

    @Test("C12 判定：路径属于其他应用")
    func belongsToOther() {
        let target = AppRecord(bundleId: "com.tencent.qq", bundlePath: "/Applications/QQ.app", displayName: "QQ")
        let wechat = AppRecord(bundleId: "com.tencent.xinWeChat", bundlePath: "/Applications/WeChat.app", displayName: "微信")
        let other = matcher.belongsToOtherApp(
            path: "/Users/x/Library/Containers/com.tencent.xinWeChat/Data/Library/Caches",
            target: target, allApps: [target, wechat]
        )
        #expect(other?.bundleId == "com.tencent.xinWeChat")

        // 目标自身路径不算冲突
        #expect(matcher.belongsToOtherApp(
            path: "/Users/x/Library/Containers/com.tencent.qq", target: target,
            allApps: [target, wechat]
        ) == nil)
    }
}

@Suite("ResidueScanner (C1/S7-2)")
struct ResidueScannerTests {

    func makeTemplates(home: String) -> [ResidueTemplate] {
        [
            ResidueTemplate(
                id: "l2.caches", path: "~/Library/Caches/{{bundleId}}",
                layer: "L2", risk: "low", confidence: "probable"
            ),
            ResidueTemplate(
                id: "l2.app-support", path: "~/Library/Application Support/{{bundleId}}",
                layer: "L2", risk: "medium", confidence: "probable"
            ),
            ResidueTemplate(
                id: "l2.preferences", path: "~/Library/Preferences/{{bundleId}}.plist",
                layer: "L2", risk: "medium", confidence: "probable"
            ),
            ResidueTemplate(
                id: "l2.launchagents-user", path: "~/Library/LaunchAgents/{{bundleId}}*.plist",
                layer: "L4", risk: "medium", confidence: "probable"
            ),
        ]
    }

    /// 构造目标应用与残留 fixture。
    func makeFixture() throws -> (home: URL, target: AppRecord, others: [AppRecord]) {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("residue-home-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default

        // 目标应用本体（含 .app 内可执行）
        let app = home.appendingPathComponent("Applications/Demo.app/Contents/MacOS")
        try fm.createDirectory(at: app, withIntermediateDirectories: true)
        try "bin".data(using: .utf8)!.write(to: app.appendingPathComponent("Demo"))

        let target = AppRecord(
            bundleId: "com.vendor.demo", bundlePath: home.path + "/Applications/Demo.app",
            displayName: "Demo", executableName: "Demo", teamIdentifier: "TEAM1234"
        )

        // 残留：缓存目录 + plist（含 bundleId → exact）
        let caches = home.appendingPathComponent("Library/Caches/com.vendor.demo")
        try fm.createDirectory(at: caches.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "cached".data(using: .utf8)!.write(to: caches.appendingPathComponent("sub/a.dat"))

        let prefs = home.appendingPathComponent("Library/Preferences/com.vendor.demo.plist")
        try fm.createDirectory(
            at: prefs.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try """
        <?xml version="1.0"?><plist version="1.0"><dict>
        <key>Owner</key><string>com.vendor.demo</string></dict></plist>
        """.data(using: .utf8)!.write(to: prefs)

        // launchd 登记
        let agents = home.appendingPathComponent("Library/LaunchAgents")
        try fm.createDirectory(at: agents, withIntermediateDirectories: true)
        try """
        <?xml version="1.0"?><plist version="1.0"><dict>
        <key>Label</key><string>com.vendor.demo.helper</string>
        <key>ProgramArguments</key><array><string>/Applications/Demo.app/Contents/MacOS/Demo</string></array>
        </dict></plist>
        """.data(using: .utf8)!.write(to: agents.appendingPathComponent("com.vendor.demo.helper.plist"))

        // 其他应用（C12 冲突源）
        let otherRecord = AppRecord(
            bundleId: "com.other.app", bundlePath: home.path + "/Applications/Other.app",
            displayName: "OtherApp"
        )

        return (home, target, [otherRecord])
    }

    @Test("完整扫描：本体 + 模板 + Spotlight + launchd + 内容升精确 + 去重")
    func fullScan() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }

        let spotlight = FakeSpotlight()
        spotlight.bundleIdResults = [
            fixture.home.path + "/Applications/Demo.app",                    // 本体（去重）
            fixture.home.path + "/Library/Application Support/com.vendor.demo",  // 模板外的 Application Support
        ]
        let launchdEntry = LaunchdParser.parse(
            plistPath: fixture.home.path + "/Library/LaunchAgents/com.vendor.demo.helper.plist",
            domain: "gui/501", isSystem: false
        )!

        let scanner = ResidueScanner(
            templates: makeTemplates(home: fixture.home.path),
            spotlight: spotlight,
            logger: Logger(category: .uninstall, buffer: LogBuffer(capacity: 20)),
            home: fixture.home.path
        )
        let plan = await scanner.scan(
            target: fixture.target, allApps: [fixture.target] + fixture.others,
            launchdEntries: [launchdEntry]
        )

        let paths = Set(plan.items.map(\.path))

        // L1 本体
        #expect(paths.contains(fixture.target.bundlePath))
        // 模板命中（probable）→ plist 内容校验升 exact
        let prefItem = plan.items.first { $0.path.hasSuffix("com.vendor.demo.plist") }
        #expect(prefItem?.confidence == .exact)
        // 缓存目录（目录内无 bundleId 文本 → 保持 probable）
        let cacheItem = plan.items.first { $0.path.hasSuffix("Caches/com.vendor.demo") }
        #expect(cacheItem?.confidence == .probable)
        // Spotlight 注入的 Application Support（不在模板中也有）
        #expect(paths.contains(fixture.home.path + "/Library/Application Support/com.vendor.demo"))
        // launchd L4
        #expect(plan.items.contains { $0.layer == .l4State && $0.path.hasSuffix(".plist") })
        // 无 C12 冲突（fixture 无其他应用残留）
        #expect(plan.skippedConflicts.isEmpty)
        // 无保护名单命中
        #expect(plan.skippedProtected.isEmpty)
    }

    @Test("C12：其他应用残留路径被剔除（腾讯套件零误伤语义）")
    func conflictExclusion() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }

        let spotlight = FakeSpotlight()
        spotlight.bundleIdResults = [
            fixture.home.path + "/Library/Containers/com.other.app",   // 其他应用资产
        ]
        let scanner = ResidueScanner(
            templates: makeTemplates(home: fixture.home.path),
            spotlight: spotlight,
            logger: Logger(category: .uninstall, buffer: LogBuffer(capacity: 20)),
            home: fixture.home.path
        )
        let plan = await scanner.scan(
            target: fixture.target, allApps: [fixture.target] + fixture.others
        )
        // 冲突路径被剔除并透明展示
        #expect(!plan.items.contains { $0.path.contains("com.other.app") })
        #expect(plan.skippedConflicts.contains { $0.owner == "OtherApp" })
    }

    @Test("保护名单：com.apple 前缀路径拦截并记 skippedProtected")
    func protectedSkipped() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }

        let spotlight = FakeSpotlight()
        spotlight.bundleIdResults = [
            fixture.home.path + "/Library/Caches/com.apple.Safari",   // 受保护路径
        ]
        let scanner = ResidueScanner(
            templates: makeTemplates(home: fixture.home.path),
            spotlight: spotlight,
            logger: Logger(category: .uninstall, buffer: LogBuffer(capacity: 20)),
            home: fixture.home.path
        )
        let plan = await scanner.scan(
            target: fixture.target, allApps: [fixture.target] + fixture.others
        )
        #expect(!plan.items.contains { $0.path.contains("com.apple.Safari") })
        #expect(plan.skippedProtected.contains { $0.contains("com.apple.Safari") })
    }

    @Test("默认勾选：exact 勾、possible 不勾、high 永不勾（基线 C4）")
    func defaultSelection() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }

        let scanner = ResidueScanner(
            templates: makeTemplates(home: fixture.home.path),
            spotlight: FakeSpotlight(),
            logger: Logger(category: .uninstall, buffer: LogBuffer(capacity: 20)),
            home: fixture.home.path
        )
        let plan = await scanner.scan(target: fixture.target, allApps: [fixture.target])

        let selected = Set(plan.defaultSelected.map(\.path))
        // 本体（exact + medium）默认勾
        #expect(selected.contains(fixture.target.bundlePath))
        // plist（exact）默认勾
        #expect(plan.items.first { $0.path.hasSuffix("com.vendor.demo.plist") }.map { selected.contains($0.path) } == true)
        // 全部 high 项不在默认勾选集
        #expect(plan.items.filter { $0.risk == .high }.allSatisfy { !selected.contains($0.path) })
    }

    @Test("去重：同路径取最高置信度（本体 probable+exact → exact）")
    func dedupe() throws {
        let scanner = ResidueScanner(
            templates: [], spotlight: FakeSpotlight(),
            logger: Logger(category: .uninstall, buffer: LogBuffer(capacity: 10))
        )
        let items = [
            ResidueItem(path: "/x", layer: .l2User, confidence: .probable, risk: .low, reason: "a"),
            ResidueItem(path: "/x", layer: .l2User, confidence: .exact, risk: .medium, reason: "b"),
            ResidueItem(path: "/y", layer: .l4State, confidence: .possible, risk: .medium, reason: "c"),
        ]
        let deduped = ResidueScanner.dedupe(items)
        let x = try #require(deduped.first { $0.path == "/x" })
        #expect(x.confidence == .exact)
        #expect(x.risk == .medium)   // 取更高风险
    }
}