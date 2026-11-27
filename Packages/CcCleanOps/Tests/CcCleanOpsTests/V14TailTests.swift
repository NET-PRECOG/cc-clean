import Testing
import Foundation
import CcCleanCore
import CcCleanFS
@testable import CcCleanOps

/// 包管理器命令执行 Fake（D11，基线 13.1）。
final class FakePMRunner: PackageManagerRunning, @unchecked Sendable {
    var routes: [String: Data] = [:]
    var callArgs: [[String]] = []

    func run(executable: String, args: [String], timeout: Duration) async throws -> ProcessResult {
        callArgs.append(args)
        guard let data = routes[executable] else {
            return ProcessResult(exitCode: 1, stdout: "", stderr: "no route")
        }
        return ProcessResult(exitCode: 0, stdout: String(decoding: data, as: UTF8.self), stderr: "")
    }
}

@Suite("MultiPackageManager (D11)")
struct MultiPackageManagerTests {

    @Test("D11 五类解析：npm JSON/pnpm 复用/uv 行解析/conda JSON/cargo 行解析")
    func allParsers() async throws {
        let fake = FakePMRunner()
        fake.routes["npm"] = Data("""
        {"dependencies":{"wget":{"version":"1.0.0"},"axios":{"version":"0.27.0"}}}
        """.utf8)
        fake.routes["pnpm"] = Data("""
        {"dependencies":{"turborepo":{"version":"1.10"}}}
        """.utf8)
        fake.routes["conda"] = Data("""
        [{"name":"numpy","version":"1.26"},{"name":"pandas","version":"2.1"}]
        """.utf8)
        fake.routes["cargo"] = Data("""
        ripgrep 14.0.0:
        fd-find 9.0.0:
        """.utf8)

        let service = MultiPackageManager(
            runner: fake, logger: Logger(category: .scan, buffer: LogBuffer(capacity: 10)))
        // 注入 fixture specs（不依赖真实系统 npm 路径）
        // checkPath 用真实存在路径（存在性探测与 fake 路由解耦：executable 是 fake 的路由 key）
        let fixtures = [
            MultiPackageManager.ManagerSpec(
                kind: "npm", executable: "npm", checkPath: "/usr/bin/true",
                args: ["ls", "-g", "--json"],
                parse: MultiPackageManager.parseNpm),
            MultiPackageManager.ManagerSpec(
                kind: "pnpm", executable: "pnpm", checkPath: "/usr/bin/true",
                args: ["ls", "-g", "--json"],
                parse: MultiPackageManager.parsePnpm),
            MultiPackageManager.ManagerSpec(
                kind: "conda", executable: "conda", checkPath: "/usr/bin/true",
                args: ["list", "--json"],
                parse: MultiPackageManager.parseConda),
            MultiPackageManager.ManagerSpec(
                kind: "cargo", executable: "cargo", checkPath: "/usr/bin/true",
                args: ["install", "--list"],
                parse: MultiPackageManager.parseCargo),
        ]
        let packages = await service.listAll(specs: fixtures)

        let managers = Set(packages.map(\.manager))
        #expect(managers.contains("npm"))
        #expect(managers.contains("pnpm"))
        #expect(managers.contains("conda"))
        #expect(managers.contains("cargo"))
        #expect(packages.count >= 6)   // npm 2 + pnpm 1 + conda 2 + cargo 2

        let npmPackages = packages.filter { $0.manager == "npm" }
        #expect(npmPackages.contains { $0.name == "wget" && $0.version == "1.0.0" })
        let condaPackages = packages.filter { $0.manager == "conda" }
        #expect(condaPackages.contains { $0.name == "numpy" && $0.version == "1.26" })
    }

    @Test("D11 单类失败不影响其他（基线 D11 验收：no route → 跳过该类）")
    func partialFailure() async throws {
        let fake = FakePMRunner()
        // 只配置 npm（其他类 no route → 跳过）
        fake.routes["npm"] = Data("""
        {"dependencies":{"survivor":{"version":"1.0"}}}
        """.utf8)
        let service = MultiPackageManager(
            runner: fake, logger: Logger(category: .scan, buffer: LogBuffer(capacity: 10)))
        let packages = await service.listAll()
        #expect(packages.map(\.manager).allSatisfy { $0 == "npm" })
    }

    @Test("D11 缺失的包管理器隐藏（checkPath 不存在 → 跳过）")
    func missingManagerHidden() async {
        // 全部 checkPath 探测：本机可能没有 pnpm/conda——specs 按存在性过滤
        // 验证 listAll 不崩溃且返回合法列表
        let service = MultiPackageManager(
            runner: FakePMRunner(), logger: Logger(category: .scan, buffer: LogBuffer(capacity: 10)))
        let packages = await service.listAll()
        #expect(packages.allSatisfy { !$0.name.isEmpty })
    }
}


/// pkgutil Fake（batchIsolation 测试避免真实 pkgutil 全量扫描耗时）。
final class FakePkgUtilForBatch: PkgUtilProviding, @unchecked Sendable {
    func pkgIds() async -> [String] { [] }
    func files(ofPkg pkgId: String) async -> [String] { [] }
}

@Suite("BatchUninstallService (C7/C8)")
struct BatchUninstallServiceTests {

    @Test("C7 批量卸载：单项失败不影响其他（基线 C7 验收）")
    func batchIsolation() async throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("batch-db-\(UUID().uuidString).sqlite")
        let store = try DatabaseStore.open(
            at: dbURL, logger: Logger(category: .uninstall, buffer: LogBuffer(capacity: 10)))
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let journal = OperationJournal(
            store: store, logger: Logger(category: .uninstall, buffer: LogBuffer(capacity: 10)))
        let snapshots = SnapshotService()
        let engine = UninstallEngine(
            residueScanner: ResidueScanner(
                templates: [], spotlight: FakeSpotlightForBrew(),
                logger: Logger(category: .uninstall, buffer: LogBuffer(capacity: 10))),
            receiptScanner: ReceiptScanner(
                pkgUtil: FakePkgUtilForBatch(),
                logger: Logger(category: .uninstall, buffer: LogBuffer(capacity: 10))),
            store: store,
            logger: Logger(category: .uninstall, buffer: LogBuffer(capacity: 10)))
        let service = BatchUninstallService(
            snapshots: snapshots, backupRoot: FileManager.default.temporaryDirectory
                .appendingPathComponent("batch-bk-\(UUID().uuidString)", isDirectory: true),
            logger: Logger(category: .uninstall, buffer: LogBuffer(capacity: 10)))

        // 目标 1：真实 fixture 应用（卸载成功）；目标 2：不存在路径（残留扫描空 → plan 无项）
        let appDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("batch-app-\(UUID().uuidString).app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: appDir.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try "bin".data(using: .utf8)!.write(to: appDir.appendingPathComponent("Contents/MacOS/Bin"))
        defer { try? FileManager.default.removeItem(at: appDir) }

        let targets = [
            AppRecord(bundleId: "com.batch.good", bundlePath: appDir.path, displayName: "Good"),
            AppRecord(bundleId: "com.batch.missing", bundlePath: "/nonexistent-app", displayName: "Missing"),
        ]
        let outcomes = await service.runBatch(
            targets: targets, allApps: targets, engine: engine, journal: journal)
        #expect(outcomes.count == 2)   // 单项失败不中断 ✓
    }

    @Test("C8 备份：ditto 级复制 + 内容一致")
    func backupBeforeUninstall() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("c8-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshots = SnapshotService()
        let service = BatchUninstallService(
            snapshots: snapshots, backupRoot: root,
            logger: Logger(category: .uninstall, buffer: LogBuffer(capacity: 10)))

        let app = root.appendingPathComponent("Backup.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try "payload".data(using: .utf8)!.write(to: app.appendingPathComponent("Bin"))

        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("c8-db-\(UUID().uuidString).sqlite")
        let store = try DatabaseStore.open(
            at: dbURL, logger: Logger(category: .uninstall, buffer: LogBuffer(capacity: 10)))
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let journal = OperationJournal(
            store: store, logger: Logger(category: .uninstall, buffer: LogBuffer(capacity: 10)))

        let backupURL = await service.backupBeforeUninstall(
            appPath: root.appendingPathComponent("Backup.app").path,
            bundleId: "com.c8", journal: journal)
        let url = try #require(backupURL)
        let copied = try String(
            contentsOf: url.appendingPathComponent("Contents/MacOS/Bin"), encoding: .utf8)
        #expect(copied == "payload")
    }
}

@Suite("ScheduledUpdateChecker (B4/B7)")
struct ScheduledUpdateCheckerTests {

    @Test("B4 忽略版本：忽略后不再提示，清除后恢复")
    func ignoreVersion() async {
        let checker = ScheduledUpdateChecker(logger: Logger(category: .network, buffer: LogBuffer(capacity: 10)))
        await checker.ignoreVersion(bundleId: "com.x", version: "2.0")
        #expect(await checker.isIgnored(bundleId: "com.x", version: "2.0"))
        #expect(await !checker.isIgnored(bundleId: "com.x", version: "3.0"))
        await checker.clearIgnored(bundleId: "com.x")
        #expect(await !checker.isIgnored(bundleId: "com.x", version: "2.0"))
    }

    @Test("B7 启停：enable 后 isEnabled，disable 后 false")
    func enableDisable() async {
        let checker = ScheduledUpdateChecker(logger: Logger(category: .network, buffer: LogBuffer(capacity: 10)))
        await checker.enable { [] }
        #expect(await checker.isEnabled)
        await checker.disable()
        #expect(await checker.isEnabled == false)
    }
}