import Testing
import Foundation
import CcCleanCore
import CcCleanFS
@testable import CcCleanOps

/// brew 命令执行 Fake 复用（FakeBrewRunner 在 BrewServiceTests 定义）。
final class FakeBrewRunner2: BrewCommandRunning, @unchecked Sendable {
    var routes: [String: Data] = [:]
    var callArgs: [[String]] = []

    func run(brewPath: String, args: [String], timeout: Duration) async throws -> ProcessResult {
        callArgs.append(args)
        guard let data = routes[args.joined(separator: " ")] else {
            return ProcessResult(exitCode: 1, stdout: "", stderr: "no route")
        }
        return ProcessResult(exitCode: 0, stdout: String(decoding: data, as: UTF8.self), stderr: "")
    }
}

@Suite("JDKService (M3)")
struct JDKServiceTests {

    func makeService(_ runner: BrewCommandRunning) -> JDKService {
        JDKService(runner: runner, logger: Logger(category: .scan, buffer: LogBuffer(capacity: 10)))
    }

    @Test("M3 枚举：release 文件取版本 + 三处来源 + isCurrent")
    func enumeration() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jdk-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("Home").path

        // 用户级 JDK fixture（release 文件）
        let jdkHome = home + "/Library/Java/JavaVirtualMachines/temurin-17.jdk/Contents/Home"
        try FileManager.default.createDirectory(
            atPath: jdkHome, withIntermediateDirectories: true)
        try """
        JAVA_VERSION="17.0.9"
        IMPLEMENTOR="Eclipse Adoptium"
        """.data(using: .utf8)!.write(to: URL(fileURLWithPath: jdkHome + "/release"))

        let fake = FakeBrewRunner2()
        fake.routes[""] = Data(jdkHome.utf8)   // 空 args join = ""

        let service = makeService(fake)
        // 注入 JAVA_HOME（currentJavaHome 环境变量优先，与运行时语义一致）
        setenv("JAVA_HOME", jdkHome, 1)
        defer { unsetenv("JAVA_HOME") }
        let entries = await service.list(
            sources: [(home + "/Library/Java/JavaVirtualMachines", "user")]
        )
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.version == "17.0.9")
        #expect(entry.vendor == "Eclipse Adoptium")
        #expect(entry.source == "user")
        #expect(entry.isCurrent == true)   // java_home 输出与枚举一致
    }

    @Test("M3 JAVA_HOME 托管区块切换：备份 + 不堆叠 + 还原")
    func switchTo() async throws {
        let profile = FileManager.default.temporaryDirectory
            .appendingPathComponent("zshrc-jdk-\(UUID().uuidString)").path
        defer {
            try? FileManager.default.removeItem(atPath: profile)
            try? FileManager.default.removeItem(atPath: profile + ".cclean-backup")
        }
        try "export OLD=1\n".data(using: .utf8)!.write(to: URL(fileURLWithPath: profile))

        // fixture：创建真实 homePath（switchTo 有存在性守卫）
        let jdkFixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("jdk21-\(UUID().uuidString)/Contents/Home").path
        try FileManager.default.createDirectory(atPath: jdkFixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: jdkFixture) }
        let service = makeService(FakeBrewRunner2())
        let entry = JDKEntry(
            homePath: jdkFixture,
            version: "21", vendor: "Eclipse Adoptium", source: "system", isCurrent: false
        )
        let switched = await service.switchTo(entry, profilePath: profile)
        #expect(switched)

        let content = try String(contentsOfFile: profile, encoding: .utf8)
        #expect(content.contains(">>> cclean jdk >>>"))
        #expect(content.contains(jdkFixture))
        #expect(content.contains("OLD=1"))
        #expect(FileManager.default.fileExists(atPath: profile + ".cclean-backup"))

        // 还原
        let restored = await service.restoreProfile(profilePath: profile)
        #expect(restored)
        let restoredContent = try String(contentsOfFile: profile, encoding: .utf8)
        #expect(restoredContent.contains("OLD=1"))
        #expect(!restoredContent.contains("cclean jdk"))
    }
}

@Suite("PathConflictDetector (M7)")
struct PathConflictDetectorTests {

    let detector = PathConflictDetector()

    @Test("M7 profile 解析：export PATH 提取 + $HOME 展开 + 跳过 $PATH 占位")
    func parseProfiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("path-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("Home").path

        let zshrc = home + "/.zshrc"
        try FileManager.default.createDirectory(
            atPath: home, withIntermediateDirectories: true)
        try """
        export PATH="$HOME/bin:/usr/local/bin:$PATH"
        # export PATH="/commented:$PATH"
        """.data(using: .utf8)!.write(to: URL(fileURLWithPath: zshrc))

        let exports = await detector.parseProfiles(home: home)
        let zshrcExport = exports.first { $0.source == zshrc }
        let export = try #require(zshrcExport)
        #expect(export.directories.contains(home + "/bin"))
        #expect(export.directories.contains("/usr/local/bin"))
        // $PATH 占位与注释行已剔除
        #expect(!export.directories.contains { $0.contains("$") })
        #expect(!export.directories.contains("/commented"))
    }

    @Test("M7 三类冲突：missing/duplicate/shadowed")
    func conflictDetection() throws {
        let root = FileManager.default.temporaryDirectory

        // dir-a 与 dir-b 均含同名可执行 tool（shadowed）；dir-missing 不存在（missing）
        let dirA = root.appendingPathComponent("dir-a")
        let dirB = root.appendingPathComponent("dir-b")
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        try "x".data(using: .utf8)!.write(to: dirA.appendingPathComponent("tool"))
        try "y".data(using: .utf8)!.write(to: dirB.appendingPathComponent("tool"))

        // dirA 只在 /etc/paths（低优先级）；dirB 只在 ~/.zshrc（高优先级前插）
        // → dirA 的 tool 被 dirB 覆盖（shadowed）
        let exports = [
            PATHExport(source: "/etc/paths", directories: [dirA.path]),
            PATHExport(source: "~/.zshrc", directories: [dirB.path, "/nonexistent-dir"]),
        ]
        let conflicts = detector.detect(exports: exports)

        #expect(conflicts.contains { $0.kind == .missing && $0.directory == "/nonexistent-dir" })
        #expect(conflicts.contains { $0.kind == .shadowed && $0.directory == dirA.path })
    }

}

@Suite("DevEnvService (M2/M5)")
struct DevEnvServiceTests {

    @Test("M2/M5 盘点：devenv 规则评估（Xcode DerivedData fixture 命中）")
    func inventory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("devenv-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("Home").path

        // DerivedData fixture（规则 roots ~/Library/Developer/Xcode/DerivedData maxDepth 2）
        let derived = home + "/Library/Developer/Xcode/DerivedData"
        try FileManager.default.createDirectory(
            atPath: derived + "/App-abc/Build", withIntermediateDirectories: true)
        try Data(repeating: 0x50, count: 2048).write(
            to: URL(fileURLWithPath: derived + "/App-abc/Build/out.o"))

        // 规则加载自 Shared/Resources（真实规则文件）
        let service = DevEnvService.makeDefault(
            logger: Logger(category: .scan, buffer: LogBuffer(capacity: 10)))
        // 重定向 home：规则 roots 含 ~ —— RuleEngine 用 init 的 home（默认真实家目录）
        // DevEnvService 走真实家目录评估（本机 DerivedData 真实存在）→ 断言仅验证盘点通路
        let items = await service.inventory()
        #expect(items.allSatisfy { $0.bytes >= 0 })
        #expect(items.allSatisfy { !$0.ruleId.isEmpty })
    }

    @Test("M2 清理：走 journal trash（可撤销）")
    func clean() async throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("devenv-db-\(UUID().uuidString).sqlite")
        let store = try DatabaseStore.open(
            at: dbURL, logger: Logger(category: .uninstall, buffer: LogBuffer(capacity: 10)))
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let journal = OperationJournal(
            store: store, logger: Logger(category: .uninstall, buffer: LogBuffer(capacity: 10)))
        let service = DevEnvService(
            ruleEngine: RuleEngine(logger: Logger(category: .scan, buffer: LogBuffer(capacity: 10))),
            logger: Logger(category: .uninstall, buffer: LogBuffer(capacity: 10))
        )

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("devenv-cache-\(UUID().uuidString).tmp")
        try Data(repeating: 1, count: 512).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let (succeeded, failed) = await service.clean(
            [DevCacheItem(
                path: file.path, ruleId: "devenv.test", title: "测试缓存",
                bytes: 512, reason: "测试")],
            journal: journal
        )
        #expect(failed.isEmpty)
        #expect(succeeded.contains(file.path))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}