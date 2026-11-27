import Testing
import Foundation
@testable import CcCleanFS

@Suite("BackgroundItems (H3 三源合并)")
struct BackgroundItemsTests {

    private func makeEntry(
        _ label: String, plistPath: String, domain: String,
        isSystem: Bool = false, healthy: Bool = true
    ) -> LaunchdEntry {
        LaunchdEntry(
            label: label, plistPath: plistPath, domain: domain,
            program: "/bin/echo", args: [], runAtLoad: nil,
            keepAlive: nil, startInterval: nil, ownerBundle: nil,
            isSystem: isSystem, healthy: healthy
        )
    }

    @Test("merge：launchAgent 可开关、launchDaemon 系统级只读、BTM 存在性标注")
    func mergeSources() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bgi-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("Home").path
        defer { try? FileManager.default.removeItem(at: root) }

        // BTM 数据库存在（macOS 13+）
        let btmPath = BackgroundItemsService.btmDatabasePath(home: home)
        try? FileManager.default.createDirectory(
            atPath: (btmPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: btmPath, contents: Data())

        let entries = BackgroundItemsService.merge(home: home, launchdEntries: [
            makeEntry("com.user.agent", plistPath: "\(home)/Library/LaunchAgents/com.user.agent.plist", domain: "gui/501"),
            makeEntry("com.sys.daemon", plistPath: "/Library/LaunchDaemons/com.sys.daemon.plist", domain: "system", isSystem: true),
            makeEntry("com.sys.agent", plistPath: "/Library/LaunchAgents/com.sys.agent.plist", domain: "system", isSystem: true),
            makeEntry("com.dead.agent", plistPath: "/Users/x/Library/LaunchAgents/com.dead.agent.plist", domain: "gui/501", healthy: false),
        ])

        #expect(entries.count == 5)
        // 来源映射
        let byLabel = { (label: String) in entries.first { $0.label == label }! }
        #expect(byLabel("com.user.agent").source == .launchAgent)
        #expect(byLabel("com.user.agent").isUserToggleable == true)
        #expect(byLabel("com.sys.daemon").source == .launchDaemon)
        #expect(byLabel("com.sys.daemon").isUserToggleable == false)
        // system 域但 LaunchAgents 路径 → launchAgent
        #expect(byLabel("com.sys.agent").source == .launchAgent)
        #expect(byLabel("com.sys.agent").isUserToggleable == false)
        // 健康标注透传
        #expect(byLabel("com.dead.agent").healthy == false)
        // BTM 条目：存在即标注，不可开关
        let btm = entries.first { $0.source == .btm }
        #expect(btm != nil)
        #expect(btm?.label == "macOS 管理的后台项（BTM）")
        #expect(btm?.plistPath == btmPath)
        #expect(btm?.isUserToggleable == false)
        // 排序：source.rawValue + label
        let raws = entries.map { $0.source.rawValue }
        #expect(raws == raws.sorted())
    }

    @Test("merge：BTM 不存在则无 BTM 条目")
    func noBtmEntry() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bgi-none-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("Home").path

        let entries = BackgroundItemsService.merge(home: home, launchdEntries: [])
        #expect(entries.isEmpty)
        #expect(BackgroundItemsService.btmExists(home: home) == false)
    }

    @Test("btmDatabasePath：路径符合真实存储位置")
    func btmPathFormat() {
        let path = BackgroundItemsService.btmDatabasePath(home: "/Users/t")
        #expect(path == "/Users/t/Library/Application Support/com.apple.backgroundtaskmanagement/BackgroundItems-v8.btm")
    }
}