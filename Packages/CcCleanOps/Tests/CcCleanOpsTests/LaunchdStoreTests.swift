import Testing
import Foundation
import CcCleanCore
import CcCleanFS
@testable import CcCleanOps

@Suite("LaunchdStore (H1/H2/H5)")
struct LaunchdStoreTests {

    func makeStore() throws -> (LaunchdStore, DatabaseStore, URL) {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("launchd-store-\(UUID().uuidString).sqlite")
        let store = try DatabaseStore.open(
            at: dbURL, logger: Logger(category: .uninstall, buffer: LogBuffer(capacity: 10)))
        let launchdStore = LaunchdStore(
            store: store, logger: Logger(category: .uninstall, buffer: LogBuffer(capacity: 10)))
        return (launchdStore, store, dbURL)
    }

    func makeFixture() throws -> (home: String, knownApp: AppRecord) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("launchdstore-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("Home").path
        let fm = FileManager.default

        // 已知应用（归属映射数据源）
        let app = root.appendingPathComponent("Demo.app/Contents/MacOS")
        try fm.createDirectory(at: app, withIntermediateDirectories: true)
        try "bin".data(using: .utf8)!.write(to: app.appendingPathComponent("DemoBin"))
        let knownApp = AppRecord(
            bundleId: "com.vendor.demo", bundlePath: root.path + "/Demo.app",
            displayName: "Demo", executableName: "DemoBin"
        )

        // 用户 LaunchAgents：健康项 + 僵尸项
        let agents = URL(fileURLWithPath: home).appendingPathComponent("Library/LaunchAgents")
        try fm.createDirectory(at: agents, withIntermediateDirectories: true)
        for (name, program, label) in [
            ("com.vendor.demo.plist", knownApp.bundlePath + "/Contents/MacOS/DemoBin", "com.vendor.demo.agent"),
            ("com.dead.tool.plist", "/nonexistent/dead-tool", "com.dead.tool"),
        ] {
            let data = try PropertyListSerialization.data(
                fromPropertyList: ["Label": label, "Program": program] as [String: Any],
                format: .xml, options: 0)
            try data.write(to: agents.appendingPathComponent(name))
        }
        return (home, knownApp)
    }

    @Test("H2：扫描落库 + 健康过滤 + 归属（refresh → entries）")
    func refreshAndQuery() async throws {
        let (launchdStore, store, dbURL) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let fixture = try makeFixture()

        let entries = await launchdStore.refresh(
            home: fixture.home, knownBundles: [fixture.knownApp],
            roots: [
                (fixture.home + "/Library/LaunchAgents", false),
            ],
            lastExitOverrides: ["com.dead.tool": 127]
        )
        #expect(entries.count == 2)

        // 归属：com.vendor.demo.agent → com.vendor.demo（四级回退①）
        #expect(entries.first { $0.label == "com.vendor.demo.agent" }?.ownerBundle == "com.vendor.demo")
        // H5：僵尸标记（program 缺失 + exit 127）
        let dead = entries.first { $0.label == "com.dead.tool" }
        #expect(dead?.healthy == false)
        #expect(dead?.lastExit == 127)

        // 二次查询走 DB（含健康过滤）
        let unhealthy = await launchdStore.entries(onlyUnhealthy: true)
        #expect(unhealthy.count == 1)
        #expect(unhealthy.first?.label == "com.dead.tool")
        _ = store
    }

    @Test("H1 停用开关：plist trash（可撤销）+ 系统组件拒绝")
    func enableToggle() async throws {
        let (launchdStore, store, dbURL) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let fixture = try makeFixture()

        let entries = await launchdStore.refresh(
            home: fixture.home, knownBundles: [fixture.knownApp],
            roots: [(fixture.home + "/Library/LaunchAgents", false)]
        )
        let healthy = try #require(entries.first { $0.label == "com.vendor.demo.agent" })
        let dead = try #require(entries.first { $0.label == "com.dead.tool" })

        let dbForJournal = try DatabaseStore.open(
            at: FileManager.default.temporaryDirectory
                .appendingPathComponent("ls-journal-\(UUID().uuidString).sqlite"),
            logger: Logger(category: .uninstall, buffer: LogBuffer(capacity: 10)))
        defer { try? FileManager.default.removeItem(at: dbForJournal.fileURL) }
        let journal = OperationJournal(
            store: dbForJournal,
            logger: Logger(category: .uninstall, buffer: LogBuffer(capacity: 10)))

        // 系统组件拒绝（基线 H 边界）
        let systemEntry = LaunchdEntry(
            label: "com.apple.x", plistPath: "/System/Library/LaunchDaemons/x.plist",
            domain: "system", program: "/usr/bin/x", args: [],
            runAtLoad: nil, keepAlive: nil, startInterval: nil,
            ownerBundle: nil, isSystem: true
        )
        let rejected = await launchdStore.setEnabled(systemEntry, enabled: false, journal: journal, undoJournalID: nil)
        #expect(!rejected.succeeded)

        // 停用：plist 进废纸篓
        let (stopOK, _) = await launchdStore.setEnabled(healthy, enabled: false, journal: journal, undoJournalID: nil)
        #expect(stopOK)
        #expect(!FileManager.default.fileExists(atPath: healthy.plistPath))

        // 查询健康状态已更新
        let afterStop = await launchdStore.entries()
        #expect(afterStop.first { $0.label == healthy.label }?.healthy == false)
        _ = dead
    }

    @Test("H5 诊断建议：program 缺失 / exit 非 0 / 正常项")
    func diagnoseSuggestions() async throws {
        let (launchdStore, _, dbURL) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let dead = LaunchdEntry(
            label: "com.dead", plistPath: "/x.plist", domain: "system",
            program: "/nonexistent/tool", args: [],
            runAtLoad: nil, keepAlive: nil, startInterval: nil,
            ownerBundle: nil, isSystem: false, healthy: false, lastExit: 127
        )
        let suggestions = await launchdStore.diagnoseSuggestions(dead)
        #expect(suggestions.contains { $0.contains("不存在") })
        #expect(suggestions.contains { $0.contains("127") })

        let healthy = LaunchdEntry(
            label: "com.ok", plistPath: "/x.plist", domain: "system",
            program: "/bin/echo", args: [],
            runAtLoad: nil, keepAlive: nil, startInterval: nil,
            ownerBundle: nil, isSystem: false
        )
        let normal = await launchdStore.diagnoseSuggestions(healthy)
        #expect(normal == ["该项运行正常"])
    }
}