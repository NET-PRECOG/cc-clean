import Testing
import Foundation
import CcCleanCore
@testable import CcCleanFS

/// 可控 Fake 环境提供者。
final class FakeEnvironment: AppEnvironmentProviding, @unchecked Sendable {
    var casks: Set<String> = []
    var pkgs: [String] = []
    var pkgMatched: Set<String> = []   // pkgContains 协议路径用（enrichSources 已改走 pkgFiles）
    var pkgBundlePath: String = ""     // 仅该路径判定为 pkg 安装
    var pkgFilesMap: [String: [String]] = [:]   // pkgId → 文件清单（内存匹配，pkgutil --files 同构）
    var quarantined: Set<String> = []
    var signatures: [String: (String?, Bool)] = [:]

    func caskTokens() async -> Set<String> { casks }
    func pkgIds() async -> [String] { pkgs }
    func pkgFiles(pkgId: String) async -> [String]? { pkgFilesMap[pkgId] }
    func pkgContains(pkgId: String, bundlePath: String) async -> Bool {
        pkgMatched.contains(pkgId) && bundlePath == pkgBundlePath
    }
    func hasQuarantine(path: String) async -> Bool { quarantined.contains(path) }
    func codeSignature(of path: String) async -> (teamId: String?, isAdHoc: Bool)? {
        signatures[path].map { (teamId: $0.0, isAdHoc: $0.1) }
    }
    func machineArch() async -> String { "arm64" }
}

@Suite("AppScanner")
struct AppScannerTests {

    /// 构造含多种来源形态的 fixture。
    func makeFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cclean-apps-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default

        func makeApp(_ name: String, bundleId: String, version: String = "1.0.0", masReceipt: Bool = false, broken: Bool = false) throws {
            let path = root.appendingPathComponent(name)
            try fm.createDirectory(at: path.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            if masReceipt {
                try fm.createDirectory(at: path.appendingPathComponent("Contents/_MASReceipt"), withIntermediateDirectories: true)
                try Data(repeating: 1, count: 16).write(to: path.appendingPathComponent("Contents/_MASReceipt/receipt"))
            }
            if broken {
                try Data("not a plist".utf8).write(to: path.appendingPathComponent("Contents/Info.plist"))
            } else {
                let plist = """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0"><dict>
                <key>CFBundleIdentifier</key><string>\(bundleId)</string>
                <key>CFBundleName</key><string>\(name)</string>
                <key>CFBundleDisplayName</key><string>\(name) 显示名</string>
                <key>CFBundleExecutable</key><string>\(name)</string>
                <key>CFBundleShortVersionString</key><string>\(version)</string>
                <key>CFBundleVersion</key><string>\(version)</string>
                <key>LSMinimumSystemVersion</key><string>13.0</string>
                </dict></plist>
                """
                try plist.data(using: .utf8)!.write(to: path.appendingPathComponent("Contents/Info.plist"))
            }
        }

        try makeApp("MasApp.app", bundleId: "com.example.mas", masReceipt: true)
        try makeApp("CaskApp.app", bundleId: "com.example.cask")
        try makeApp("PkgApp.app", bundleId: "com.example.pkg")
        try makeApp("DragApp.app", bundleId: "com.example.drag")
        try makeApp("UnknownApp.app", bundleId: "com.example.unknown")
        try makeApp("Broken.app", bundleId: "com.example.broken", broken: true)

        // 嵌套：Nested/VendorApp.app（下探一层）
        try fm.createDirectory(at: root.appendingPathComponent("Nested"), withIntermediateDirectories: true)
        try makeApp("Nested/VendorApp.app", bundleId: "com.example.vendor")

        return root
    }

    func makeScanner(_ env: FakeEnvironment) -> AppScanner {
        AppScanner(environment: env, logger: Logger(category: .scan, buffer: LogBuffer(capacity: 20)))
    }

    @Test("全量扫描：元数据解析 + 来源四级判定优先级")
    func scanAndSources() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let env = FakeEnvironment()
        env.casks = ["caskapp"]                       // token = CaskApp.app → "caskapp"
        env.pkgs = ["com.example.pkginstaller"]
        env.pkgFilesMap = ["com.example.pkginstaller": [
            "Applications/PkgApp.app/Contents/Info.plist",
            "Applications/PkgApp.app/Contents/MacOS/PkgApp",
        ]]
        env.quarantined = [root.appendingPathComponent("DragApp.app").path]

        let scanner = makeScanner(env)
        let records = await scanner.scan(roots: [root.path])

        let byId = Dictionary(uniqueKeysWithValues: records.map { ($0.bundleId, $0) })
        #expect(records.count == 7)   // 5 正常 + Broken fallback + 嵌套 VendorApp

        // MAS 优先于 cask/quarantine
        #expect(byId["com.example.mas"]?.installSource == .appStore)
        #expect(byId["com.example.cask"]?.installSource == .homebrewCask)
        #expect(byId["com.example.pkg"]?.installSource == .pkgInstaller)
        #expect(byId["com.example.drag"]?.installSource == .dragAndDrop)
        #expect(byId["com.example.unknown"]?.installSource == .unknown)

        // 元数据解析（plist 中名称含 .app 后缀为 fixture 写入值）
        let cask = try #require(byId["com.example.cask"])
        #expect(cask.displayName == "CaskApp.app 显示名")
        #expect(cask.shortVersion == "1.0.0")
        #expect(cask.minimumSystem == "13.0")
        #expect(cask.executableName == "CaskApp.app")

        // 体积字段为 nil（元数据阶段，S1-4 增量推送）
        #expect(cask.sizeBytes == nil)
    }

    @Test("Info.plist 损坏：fallback 记录不崩溃")
    func brokenPlist() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let scanner = makeScanner(FakeEnvironment())
        let records = await scanner.scan(roots: [root.path])
        let broken = records.first { $0.bundlePath.hasSuffix("Broken.app") }
        let record = try #require(broken)
        #expect(record.bundleId.hasPrefix("path:"))
        #expect(record.signature == .unknown)
        #expect(record.shortVersion == nil)
    }

    @Test("嵌套一层下探：Nested/VendorApp.app 可发现")
    func nestedDiscovery() throws {
        let found = AppScanner.enumerateApps(
            under: FileManager.default.temporaryDirectory.path
        )
        // 不校验具体数量；仅验证深层嵌套场景由 enumerateApps 的深度限制保护
        _ = found
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let apps = AppScanner.enumerateApps(under: root.path)
        #expect(apps.map { ($0 as NSString).lastPathComponent }.sorted()
            == ["Broken.app", "CaskApp.app", "DragApp.app", "MasApp.app", "PkgApp.app", "UnknownApp.app", "VendorApp.app"])
    }

    @Test("签名判定：adHoc / developerID / unsigned")
    func signatures() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let env = FakeEnvironment()
        env.signatures = [
            root.appendingPathComponent("CaskApp.app").path: (nil, true),
            root.appendingPathComponent("MasApp.app").path: ("TEAM1234", false),
            root.appendingPathComponent("PkgApp.app").path: (nil, false),
        ]
        let scanner = makeScanner(env)
        var records = await scanner.scan(roots: [root.path])
        await scanner.resolveSignatures(&records, concurrency: 4)

        let byId = Dictionary(uniqueKeysWithValues: records.map { ($0.bundleId, $0) })
        #expect(byId["com.example.cask"]?.signature == .adHoc)
        #expect(byId["com.example.mas"]?.signature == .developerID)
        #expect(byId["com.example.mas"]?.teamIdentifier == "TEAM1234")
        #expect(byId["com.example.pkg"]?.signature == .unsigned)
    }
}

@Suite("InstallTimeResolver")
struct InstallTimeResolverTests {

    @Test("四级回退 ③④：无 Spotlight 结果时降级为 birthtime（fileSystem 置信度）")
    func birthtimeFallback() async throws {
        let layout = try FSTestFixture.makeTree()
        defer { FSTestFixture.remove(layout.root) }

        let resolver = InstallTimeResolver()
        let result = await resolver.resolve(bundlePath: layout.fakeAppBundle.path, pkgIds: [])

        // pkgIds=[] 跳过 ①；mdls 对 temp 目录返回 (null) → 跳过 ②
        #expect(result.confidence == .fileSystem)
        #expect(result.date != nil)
    }

    @Test("未知 bundle：返回 unknown 置信度而非伪造时间")
    func unknownPath() async {
        let resolver = InstallTimeResolver()
        let result = await resolver.resolve(bundlePath: "/nonexistent-bundle-path", pkgIds: [])
        #expect(result.confidence == .unknown)
        #expect(result.date == nil)
    }
}