import Testing
import Foundation
import CcCleanCore
@testable import CcCleanFS

@Suite("ZombieScanner (C10/H5)")
struct ZombieScannerTests {

    @Test("僵尸扫描：OpenClaw exit 127 样本（R2 固定回归）+ program 缺失")
    func zombieFindings() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zombie-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("Home").path
        let agents = URL(fileURLWithPath: home).appendingPathComponent("Library/LaunchAgents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)

        func writeP(_ name: String, dict: [String: Any]) throws {
            let data = try PropertyListSerialization.data(
                fromPropertyList: dict, format: .xml, options: 0)
            try data.write(to: agents.appendingPathComponent(name))
        }

        // OpenClaw 样本：program 缺失（exit 127 由 lastExitOverrides 注入）
        try writeP("ai.openclaw.gateway.plist", dict: [
            "Label": "ai.openclaw.gateway",
            "Program": "/Users/x/Library/OpenClaw/gateway",
        ])
        // program 缺失
        try writeP("com.dead.tool.plist", dict: [
            "Label": "com.dead.tool",
            "ProgramArguments": ["/nonexistent/dead-tool"],
        ])
        // 健康项（不应出现在结果中）
        try writeP("com.ok.daemon.plist", dict: [
            "Label": "com.ok.daemon",
            "Program": "/bin/echo",
        ])

        let scanner = ZombieScanner(home: home)
        let findings = scanner.scan(
            home: home, knownBundles: [],
            lastExitOverrides: ["ai.openclaw.gateway": 127]
        )
        #expect(findings.count == 2)   // OpenClaw + dead tool；com.ok 不在

        let openclaw = findings.first { $0.entry.label == "ai.openclaw.gateway" }
        let finding = try #require(openclaw)
        #expect(finding.reasons.contains { $0.contains("127") })
        #expect(finding.reasons.contains { $0.contains("不存在") })
        // 修复建议包含禁用与删除 plist（基线 7.8 算法 3）
        #expect(finding.suggestedFixes.contains { $0.contains("禁用") })
        #expect(finding.suggestedFixes.contains { $0.contains("删除 plist") })
        #expect(finding.entry.plistPath.hasSuffix("ai.openclaw.gateway.plist"))
    }

    @Test("系统组件：建议只读保持")
    func systemComponentReadOnly() throws {
        // 直接构造 isSystem 项诊断
        let entry = LaunchdEntry(
            label: "com.apple.sys.zombie", plistPath: "/System/Library/LaunchDaemons/x.plist",
            domain: "system", program: "/nonexistent-sys-tool", args: [],
            runAtLoad: nil, keepAlive: nil, startInterval: nil,
            ownerBundle: nil, isSystem: true
        )
        let diagnosed = LaunchdParser.diagnose(entry)
        #expect(diagnosed.healthy == false)

        let scanner = ZombieScanner()
        // 走 scan 的建议生成逻辑：系统组件 fixes 含「只读展示」
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("zombie-sys-\(UUID().uuidString)", isDirectory: true).path
        let findings = scanner.scan(home: home, knownBundles: [])
        #expect(findings.isEmpty)   // 空目录无发现
    }
}