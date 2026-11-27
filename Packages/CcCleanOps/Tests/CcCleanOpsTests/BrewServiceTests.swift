import Testing
import Foundation
import CcCleanCore
import CcCleanFS
@testable import CcCleanOps

/// brew 命令执行 Fake（基线 13.1：不依赖真实 brew 安装）。
final class FakeBrewRunner: BrewCommandRunning, @unchecked Sendable {
    /// 路由键：args 以空格连接（数组不可作字典键）
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

/// Spotlight Fake（本地版本，供 D2 复检联动）。
final class FakeSpotlightForBrew: SpotlightProviding, @unchecked Sendable {
    var bundleIdResults: [String] = []
    var nameResults: [String] = []
    func findByBundleId(_ bundleId: String) async -> [String] { bundleIdResults }
    func findByName(_ name: String) async -> [String] { nameResults }
}

@Suite("BrewService (S8-2 D 组)")
struct BrewServiceTests {

    func makeService(_ runner: BrewCommandRunning) -> BrewService {
        BrewService(
            runner: runner,
            brewPath: "/opt/homebrew/bin/brew",
            logger: Logger(category: .scan, buffer: LogBuffer(capacity: 10))
        )
    }

    // MARK: - D1 解码容错

    @Test("v2 JSON 解码：formulae 完整字段 + outdated/pinned")
    func decodeFormulae() throws {
        let json = """
        {"formulae":[{
            "name":"wget","full_name":"wget","current":"1.24.5",
            "installed":[{"version":"1.24.3"}],
            "outdated":true,"pinned":false
        }]}
        """
        let formulae = BrewService.decodeFormulae(from: Data(json.utf8))
        #expect(formulae.count == 1)
        let wget = try #require(formulae.first)
        #expect(wget.name == "wget")
        #expect(wget.installedVersion == "1.24.3")
        #expect(wget.latestVersion == "1.24.5")
        #expect(wget.outdated == true)
    }

    @Test("v2 JSON 容错：可选字段缺失/类型不符不崩溃（基线 D1 验收）")
    func decodeTolerant() throws {
        // ① formulae 数组缺失
        #expect(BrewService.decodeFormulae(from: Data("{}".utf8)) == [])
        // ② 非法 JSON
        #expect(BrewService.decodeFormulae(from: Data("not-json".utf8)) == [])
        // ③ 条目缺 name → 跳过
        let json = """
        {"formulae":[{"full_name":"x"},{"name":"y","installed":[]}]}
        """
        let formulae = BrewService.decodeFormulae(from: Data(json.utf8))
        #expect(formulae.count == 1)
        #expect(formulae[0].name == "y")
        #expect(formulae[0].installedVersion == nil)
        #expect(formulae[0].outdated == false)   // 缺省 false
    }

    @Test("v2 JSON 解码：casks + hasZap 标记")
    func decodeCasks() throws {
        let json = """
        {"casks":[
            {"token":"example","installed":"1.0","version":"2.0","outdated":true,
             "zap":[{"trash":"~/Library/Caches/example"}]},
            {"token":"minimal","installed":"1.0","version":"1.0"}
        ]}
        """
        let casks = BrewService.decodeCasks(from: Data(json.utf8))
        #expect(casks.count == 2)
        #expect(casks[0].hasZap == true)
        #expect(casks[0].outdated == true)
        #expect(casks[1].hasZap == false)   // 无 zap 段
    }

    @Test("D1 listFormulae/listCasks：命令路由 + 解码")
    func listViaFake() async throws {
        let fake = FakeBrewRunner()
        fake.routes["info --json=v2 --installed"] = Data("""
        {"formulae":[{"name":"wget","installed":[{"version":"1.0"}],"outdated":false}]}
        """.utf8)
        fake.routes["info --json=v2 --cask --installed"] = Data("""
        {"casks":[{"token":"example","installed":"1.0","version":"2.0","outdated":true,"zap":[]}]}
        """.utf8)
        let service = makeService(fake)

        let formulae = try await service.listFormulae()
        #expect(formulae.count == 1)
        #expect(formulae[0].name == "wget")

        let casks = try await service.listCasks()
        #expect(casks.count == 1)
        #expect(casks[0].token == "example")
        #expect(casks[0].outdated == true)
    }

    // MARK: - D2 --zap 联动

    @Test("D2 zapCask：命令记账（runWhitelistedCommand）+ 复检联动")
    func zapWithResidueCheck() async throws {
        let fake = FakeBrewRunner()
        fake.routes["uninstall --zap --cask example"] = Data("".utf8)
        let service = makeService(fake)

        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("brew-db-\(UUID().uuidString).sqlite")
        let store = try DatabaseStore.open(
            at: dbURL, logger: Logger(category: .uninstall, buffer: LogBuffer(capacity: 10)))
        defer { try? FileManager.default.removeItem(at: dbURL) }
        // journal 注入同一 Fake：zap 命令走 fake 路由而非真实 brew
        let journal = OperationJournal(
            store: store, logger: Logger(category: .uninstall, buffer: LogBuffer(capacity: 10)),
            userCommandRunner: fake)

        let residueScanner = ResidueScanner(
            templates: [
                ResidueTemplate(
                    id: "l2.caches", path: "~/Library/Caches/{{bundleId}}",
                    layer: "L2", risk: "low", confidence: "probable"
                ),
            ],
            spotlight: FakeSpotlightForBrew(),
            logger: Logger(category: .uninstall, buffer: LogBuffer(capacity: 10)),
            home: FileManager.default.temporaryDirectory.path
        )
        let target = AppRecord(
            bundleId: "com.example.app", bundlePath: "/Applications/Example.app", displayName: "Example"
        )

        let (zapOK, residue, failed) = await service.zapCask(
            token: "example", journal: journal,
            residueScanner: residueScanner, target: target, allApps: [target]
        )
        #expect(zapOK)
        #expect(failed.isEmpty)
        // zap 后复检已执行（返回残留列表——空目录无残留）
        #expect(residue.isEmpty)
        // 命令已发起（zap --cask example）
        #expect(fake.callArgs.contains { $0 == ["uninstall", "--zap", "--cask", "example"] })
    }

    @Test("zapCask：brew 未安装 → 明确失败")
    func zapNoBrew() async throws {
        let service = BrewService(
            runner: FakeBrewRunner(), brewPath: nil,
            logger: Logger(category: .scan, buffer: LogBuffer(capacity: 10))
        )
        // brewPath nil → resolve() 依赖本机安装；显式置空模拟未安装
        await service.setBrewPath(nil)

        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("brew-db-\(UUID().uuidString).sqlite")
        let store = try DatabaseStore.open(
            at: dbURL, logger: Logger(category: .uninstall, buffer: LogBuffer(capacity: 10)))
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let journal = OperationJournal(
            store: store, logger: Logger(category: .uninstall, buffer: LogBuffer(capacity: 10)))

        let residueScanner = ResidueScanner(
            templates: [], spotlight: FakeSpotlightForBrew(),
            logger: Logger(category: .uninstall, buffer: LogBuffer(capacity: 10)))
        let target = AppRecord(bundleId: "com.x", bundlePath: "/X.app", displayName: "X")

        let (zapOK, _, failed) = await service.zapCask(
            token: "x", journal: journal,
            residueScanner: residueScanner, target: target, allApps: [target]
        )
        #expect(!zapOK)
        #expect(failed["brew"]?.contains("未找到") == true)
    }

    @Test("runWhitelistedCommand 用户级直跑降级（无 Helper，D2 依赖路径）")
    func userLevelCommandFallback() async throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("usercmd-db-\(UUID().uuidString).sqlite")
        let store = try DatabaseStore.open(
            at: dbURL, logger: Logger(category: .uninstall, buffer: LogBuffer(capacity: 10)))
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let journal = OperationJournal(
            store: store, logger: Logger(category: .uninstall, buffer: LogBuffer(capacity: 10)))

        let id = await journal.begin("用户级命令")
        try await journal.append(
            .runWhitelistedCommand(executable: "/bin/echo", args: ["user-level-ok"]),
            to: id
        )
        let result = await journal.commit(id)
        // 无 Helper → ProcessRunner 直跑成功（用户级）
        #expect(result.succeededCount == 1)
        #expect(result.failedCount == 0)
    }
}
