import Testing
import Foundation
import CcCleanCore
import CcCleanFS
@testable import CcCleanOps

/// AppEnvironment Fake（I1 签名判定注入）。
final class FakeSecurityEnvironment: AppEnvironmentProviding, @unchecked Sendable {
    var signatures: [String: (teamId: String?, isAdHoc: Bool)] = [:]
    var casks: Set<String> = []
    var pkgs: [String] = []
    var quarantined: Set<String> = []

    func caskTokens() async -> Set<String> { casks }
    func pkgIds() async -> [String] { pkgs }
    func pkgFiles(pkgId: String) async -> [String]? { nil }
    func pkgContains(pkgId: String, bundlePath: String) async -> Bool { false }
    func hasQuarantine(path: String) async -> Bool { quarantined.contains(path) }
    func codeSignature(of path: String) async -> (teamId: String?, isAdHoc: Bool)? {
        signatures[path]
    }
    func machineArch() async -> String { "arm64" }
}

@Suite("SecuritySuite (I1/I3/I7/I2)")
struct SecuritySuiteTests {

    func makeSuite(_ env: AppEnvironmentProviding) -> SecuritySuite {
        SecuritySuite(appEnvironment: env, logger: Logger(category: .uninstall, buffer: LogBuffer(capacity: 10)))
    }

    // MARK: - I1 可疑签名（零高危误报语义）

    @Test("I1 签名扫描：ad-hoc/未签名报 medium，正常签名不进列表（零高危误报）")
    func suspiciousSignature() async {
        let env = FakeSecurityEnvironment()
        env.signatures = [
            "/Applications/AdHoc.app": (nil, true),           // ad-hoc → medium
            "/Applications/Unsigned.app": (nil, false),       // 未签名 → medium
            "/Applications/Normal.app": ("TEAM123", false),   // 正常签名 → 不进列表
        ]
        let records = ["AdHoc", "Unsigned", "Normal"].map {
            AppRecord(bundleId: "com.\($0.lowercased())", bundlePath: "/Applications/\($0).app", displayName: $0)
        }
        let suite = makeSuite(env)
        let findings = await suite.scanSuspiciousApps(
            records: records,
            signatures: env.signatures)
        #expect(findings.count == 2)   // Normal 不进列表（零高危误报）
        #expect(findings.allSatisfy { $0.risk == .medium })
    }

    @Test("I1 launchd 指向临时目录：高危（恶意驻留特征）")
    func suspiciousLaunchd() async {
        let suite = makeSuite(FakeSecurityEnvironment())
        let entry = LaunchdEntry(
            label: "com.evil.persist", plistPath: "/x.plist", domain: "gui/501",
            program: "/tmp/evil", args: [],
            runAtLoad: true, keepAlive: nil, startInterval: nil,
            ownerBundle: nil, isSystem: false
        )
        let findings = await suite.scanSuspiciousLaunchd(entries: [entry])
        #expect(findings.count == 1)
        #expect(findings[0].risk == .high)
        #expect(findings[0].reasons[0].contains("/tmp/"))
    }

    // MARK: - I3 TCC

    @Test("I3 TCC 重置：走 Helper resetTCC 逐服务（代码级禁 reset All 由 Helper 校验）")
    func resetTCC() async {
        final class FakeHelper: HelperClientProtocol, @unchecked Sendable {
            var receivedServices: [String] = []
            func removeItems(_ paths: [String], journalID: String) async -> (succeeded: [String], failed: [String: String]) { ([], [:]) }
            func forgetReceipts(_ pkgIDs: [String], journalID: String) async -> (succeeded: [String], failed: [String: String]) { ([], [:]) }
            func resetTCC(bundleID: String, services: [String], journalID: String) async -> (succeeded: [String], failed: [String: String]) {
                receivedServices = services
                return (services, [:])
            }
            func bootout(label: String, plistPath: String, journalID: String) async -> (succeeded: [String], failed: [String: String]) { ([], [:]) }
            func runWhitelisted(_ executable: String, args: [String], journalID: String) async -> (succeeded: [String], failed: [String: String]) { ([], [:]) }
        }
        let helper = FakeHelper()
        let suite = makeSuite(FakeSecurityEnvironment())
        let (succeeded, failed) = await suite.resetTCC(
            bundleID: "com.example.app",
            services: ["kTCCServiceCamera", "kTCCServiceMicrophone"],
            helper: helper)
        #expect(failed.isEmpty)
        #expect(succeeded.count == 2)
        #expect(helper.receivedServices == ["kTCCServiceCamera", "kTCCServiceMicrophone"])
    }

    // MARK: - I2 隐私痕迹

    @Test("I2 隐私清理：只清勾选类别（基线 I2 验收：不清除未选类别）")
    func privacyClean() async throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("privacy-db-\(UUID().uuidString).sqlite")
        let store = try DatabaseStore.open(
            at: dbURL, logger: Logger(category: .uninstall, buffer: LogBuffer(capacity: 10)))
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let journal = OperationJournal(
            store: store, logger: Logger(category: .uninstall, buffer: LogBuffer(capacity: 10)))
        let suite = makeSuite(FakeSecurityEnvironment())

        let targetA = FileManager.default.temporaryDirectory
            .appendingPathComponent("privacy-a-\(UUID().uuidString).db").path
        let targetB = FileManager.default.temporaryDirectory
            .appendingPathComponent("privacy-b-\(UUID().uuidString).db").path
        try "a".data(using: .utf8)!.write(to: URL(fileURLWithPath: targetA))
        try "b".data(using: .utf8)!.write(to: URL(fileURLWithPath: targetB))
        defer {
            try? FileManager.default.removeItem(atPath: targetA)
            try? FileManager.default.removeItem(atPath: targetB)
        }

        // 只勾选 targetA
        let (succeeded, failed) = await suite.cleanPrivacy(
            selectedPaths: [targetA], journal: journal)
        #expect(failed.isEmpty)
        #expect(succeeded.contains(targetA))
        #expect(!FileManager.default.fileExists(atPath: targetA))
        // targetB（未勾选）完好——不清除未选类别 ✓
        #expect(FileManager.default.fileExists(atPath: targetB))
    }

    // MARK: - I7 敏感文件扫描

    @Test("I7 敏感文件扫描：规则驱动（sensitive-file.json report 语义）")
    func sensitiveScan() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sensitive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // 敏感文件 fixture（id_rsa 命中规则 namePatterns）
        try "PRIVATE KEY MATERIAL".data(using: .utf8)!.write(
            to: root.appendingPathComponent("id_rsa"))

        let engine = RuleEngine(logger: Logger(category: .uninstall, buffer: LogBuffer(capacity: 10)))
        // 手工构造 I7 规则（roots 重定向到 fixture）
        let rule = RuleFile(
            id: "security.sensitive.private-key", module: "I7", scope: .security,
            title: "私钥文件",
            explain: "检测到私钥文件；仅报告路径不展示内容，绝不自动清理",
            risk: .high, defaultSelected: false, requiresRoot: false,
            action: .report,
            match: RuleMatch(
                roots: [root.path], maxDepth: 2,
                namePatterns: ["id_rsa"], pathRegex: nil, extensions: nil,
                minSize: nil, olderThanDays: nil,
                contentContains: nil, excludePatterns: nil),
            schemaVersion: 1)
        try await engine.load([rule])

        let suite = makeSuite(FakeSecurityEnvironment())
        let findings = await suite.scanSensitiveFiles(ruleEngine: engine)
        #expect(findings.count == 1)
        #expect(findings[0].path.hasSuffix("id_rsa"))
        // 只报路径与规则名，不展示内容（基线 I7 边界）
        #expect(!findings[0].reason.contains("PRIVATE KEY"))
        _ = root
    }
}