import Testing
import Foundation
import CcCleanCore
@testable import CcCleanFS

@Suite("LaunchdParser (S7-1)")
struct LaunchdParserTests {

    /// 写临时 launchd plist。
    func writePlist(_ dict: [String: Any], dir: URL, name: String) throws -> String {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent(name).path
        let data = try PropertyListSerialization.data(
            fromPropertyList: dict, format: .xml, options: 0
        )
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    func makeFakeApp(at root: URL, bundleId: String, name: String, exec: String) throws -> AppRecord {
        let app = root.appendingPathComponent("\(name).app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true
        )
        try "bin".data(using: .utf8)!.write(to: app.appendingPathComponent("Contents/MacOS/\(exec)"))
        return AppRecord(
            bundleId: bundleId, bundlePath: app.path, displayName: name,
            bundleName: name, executableName: exec
        )
    }

    @Test("plist 解析：Label/Program/ProgramArguments/RunAtLoad/KeepAlive 字典形式")
    func parseBasics() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("launchd-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = try writePlist(
            [
                "Label": "com.example.daemon",
                "ProgramArguments": ["/Applications/Demo.app/Contents/MacOS/Demo", "--flag"],
                "RunAtLoad": true,
                "KeepAlive": ["SuccessfulExit": false],   // 字典形式
                "StartInterval": 300,
            ],
            dir: dir, name: "com.example.daemon.plist"
        )
        let entry = try #require(LaunchdParser.parse(plistPath: path, domain: "system", isSystem: false))
        #expect(entry.label == "com.example.daemon")
        #expect(entry.program == nil)
        #expect(entry.args == ["/Applications/Demo.app/Contents/MacOS/Demo", "--flag"])
        #expect(entry.runAtLoad == true)
        #expect(entry.keepAlive == true)   // 字典形式视为条件保活
        #expect(entry.startInterval == 300)
        // args[0] 可执行存在（假 app 未建）→ healthy 由 diagnose 决定；此处路径不存在
        #expect(entry.healthy == false)    // parse 时 program 路径不存在 → 僵尸标记
    }

    @Test("归属映射四级回退：app 内路径 → Label 前缀 → 可执行名 → 未识别")
    func ownershipFallbacks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("owner-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let demo = try makeFakeApp(at: root, bundleId: "com.vendor.demo", name: "Demo", exec: "DemoBin")
        let wechat = try makeFakeApp(at: root, bundleId: "com.tencent.xinWeChat", name: "WeChat", exec: "WeChatBin")

        // ① 程序路径在 .app 内
        let inAppBundle = LaunchdEntry(
            label: "some.unknown.label", plistPath: "/x.plist", domain: "system",
            program: demo.bundlePath + "/Contents/MacOS/DemoBin", args: [],
            runAtLoad: nil, keepAlive: nil, startInterval: nil,
            ownerBundle: nil, isSystem: false
        )
        #expect(LaunchdParser.attributeOwner(entry: inAppBundle, knownBundles: [demo, wechat]).ownerBundle == "com.vendor.demo")

        // ② Label 前缀匹配 bundleId
        let labelMatch = LaunchdEntry(
            label: "com.tencent.xinWeChat.helper", plistPath: "/x.plist", domain: "system",
            program: "/usr/local/bin/something-else", args: [],
            runAtLoad: nil, keepAlive: nil, startInterval: nil,
            ownerBundle: nil, isSystem: false
        )
        #expect(LaunchdParser.attributeOwner(entry: labelMatch, knownBundles: [demo, wechat]).ownerBundle == "com.tencent.xinWeChat")

        // ③ ProgramArguments[0] 可执行名匹配
        let execMatch = LaunchdEntry(
            label: "another.unknown", plistPath: "/x.plist", domain: "system",
            program: nil, args: [demo.bundlePath + "/Contents/MacOS/DemoBin"],
            runAtLoad: nil, keepAlive: nil, startInterval: nil,
            ownerBundle: nil, isSystem: false
        )
        #expect(LaunchdParser.attributeOwner(entry: execMatch, knownBundles: [demo, wechat]).ownerBundle == "com.vendor.demo")

        // ④ 未识别
        let unknown = LaunchdEntry(
            label: "com.nohint.daemon", plistPath: "/x.plist", domain: "system",
            program: "/usr/sbin/nothing", args: [],
            runAtLoad: nil, keepAlive: nil, startInterval: nil,
            ownerBundle: nil, isSystem: false
        )
        #expect(LaunchdParser.attributeOwner(entry: unknown, knownBundles: [demo, wechat]).ownerBundle == nil)
    }

    @Test("僵尸诊断：program 不存在 / last exit 非 0")
    func zombieDiagnosis() throws {
        let dead = LaunchdEntry(
            label: "ai.openclaw.gateway", plistPath: "~/Library/LaunchAgents/x.plist", domain: "gui/501",
            program: "/nonexistent/gateway", args: [],
            runAtLoad: true, keepAlive: nil, startInterval: nil,
            ownerBundle: nil, isSystem: false, healthy: true, lastExit: 127
        )
        let diagnosed = LaunchdParser.diagnose(dead)
        #expect(diagnosed.healthy == false)   // OpenClaw 样本（exit 127 + program 缺失）

        let alive = LaunchdEntry(
            label: "com.ok.daemon", plistPath: "/x.plist", domain: "system",
            program: "/bin/echo", args: [],
            runAtLoad: nil, keepAlive: nil, startInterval: nil,
            ownerBundle: nil, isSystem: false, healthy: true, lastExit: 0
        )
        #expect(LaunchdParser.diagnose(alive).healthy == true)
    }

    @Test("scan：fixture 目录发现 + 归属（home 用户级 LaunchAgents）")
    func scanFixture() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("launchd-scan-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("Home").path

        // 用户级 LaunchAgents
        let userAgents = URL(fileURLWithPath: home).appendingPathComponent("Library/LaunchAgents")
        let knownApp = try makeFakeApp(at: root, bundleId: "com.vendor.demo", name: "Demo", exec: "DemoBin")
        try writePlist(
            [
                "Label": "com.vendor.demo.agent",
                "Program": knownApp.bundlePath + "/Contents/MacOS/DemoBin",
                "RunAtLoad": true,
            ],
            dir: userAgents, name: "com.vendor.demo.agent.plist"
        )

        let entries = LaunchdParser.scan(
            home: home, knownBundles: [knownApp],
            roots: [(userAgents.path, false)]   // 仅 fixture 目录（不含真实系统目录）
        )
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.domain.hasPrefix("gui/"))
        #expect(entry.ownerBundle == "com.vendor.demo")
        #expect(entry.healthy == true)   // 假 app 的 DemoBin 存在
        #expect(entry.isSystem == false)
    }
}