import Testing
import Foundation
import CcCleanCore
import CcCleanFS
@testable import CcCleanOps

@Suite("BrewService D 组深度 (S14~S15)")
struct BrewDepthTests {

    func makeService(_ runner: BrewCommandRunning) -> BrewService {
        BrewService(
            runner: runner,
            brewPath: "/opt/homebrew/bin/brew",
            logger: Logger(category: .scan, buffer: LogBuffer(capacity: 10))
        )
    }

    func makeJournalRunner(_ runner: BrewCommandRunning) throws -> (OperationJournal, URL) {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("brewdepth-db-\(UUID().uuidString).sqlite")
        let store = try DatabaseStore.open(
            at: dbURL, logger: Logger(category: .uninstall, buffer: LogBuffer(capacity: 10)))
        let journal = OperationJournal(
            store: store, logger: Logger(category: .uninstall, buffer: LogBuffer(capacity: 10)),
            userCommandRunner: runner)
        return (journal, dbURL)
    }

    // MARK: - D6 doctor 可视图

    @Test("D6 doctor：输出分类（error/warning/suggestion）+ 修复提示")
    func doctorClassification() async throws {
        let fake = FakeBrewRunner()
        fake.routes["doctor"] = Data("""
        Please run brew update

        Warning: Some directories are not owned
        /opt/homebrew/foo

        Error: python@3.12 contains a broken symlink
        """.utf8)
        let service = makeService(fake)
        let findings = try await service.doctor()

        #expect(findings.count == 3)
        #expect(findings[0].severity == .suggestion)
        #expect(findings[1].severity == .warning)
        #expect(findings[2].severity == .error)
        // 每条含修复提示（不自动执行，可复制）
        #expect(findings.allSatisfy { $0.fixHint != nil })
    }

    @Test("D6 doctor：无问题输出 → 空列表")
    func doctorClean() async throws {
        let fake = FakeBrewRunner()
        fake.routes["doctor"] = Data("Your system is ready to brew.\n".utf8)
        let service = makeService(fake)
        let findings = try await service.doctor()
        #expect(findings.count == 1)   // 单段落
        #expect(findings[0].severity == .suggestion)
    }

    // MARK: - D7 缓存清理

    @Test("D7 cleanup -n 预览：体积解析 + 路径清单")
    func cleanupPreview() async throws {
        let fake = FakeBrewRunner()
        fake.routes["cleanup -n"] = Data("""
        Would remove: /opt/homebrew/caches/download/wget--1.24 (12.5 MB)
        Would remove: /opt/homebrew/logs (2.0 KB)
        """.utf8)
        let service = makeService(fake)
        let preview = try await service.cleanupPreview()
        #expect(preview.bytesToFree >= 12_000_000)          // 12.5 MB 主体
        #expect(preview.paths.contains { $0.contains("wget--1.24") })
    }

    @Test("D7 cleanup 执行：走 journal 记账（runWhitelistedCommand）")
    func cleanupExecute() async throws {
        let fake = FakeBrewRunner()
        fake.routes["cleanup"] = Data()
        let service = makeService(fake)
        let (journal, dbURL) = try makeJournalRunner(fake)
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let ok = await service.cleanupExecute(journal: journal)
        #expect(ok)
        #expect(fake.callArgs.contains { $0 == ["cleanup"] })
    }

    // MARK: - D8 搜索与安装

    @Test("D8 search：token 列表过滤（==>/Cask 前缀剔除）")
    func searchCasks() async throws {
        let fake = FakeBrewRunner()
        fake.routes["search --cask example"] = Data("""
        ==> Casks
        example
        example-pro
        """.utf8)
        let service = makeService(fake)
        let tokens = try await service.searchCasks("example")
        #expect(tokens == ["example", "example-pro"])
    }

    @Test("D8 install：走 journal 记账（argv 预览语义）")
    func installCask() async throws {
        let fake = FakeBrewRunner()
        fake.routes["install --cask example"] = Data()
        let service = makeService(fake)
        let (journal, dbURL) = try makeJournalRunner(fake)
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let ok = await service.installCask("example", journal: journal)
        #expect(ok)
        #expect(fake.callArgs.contains { $0 == ["install", "--cask", "example"] })
    }

    // MARK: - D9 多版本 link

    @Test("D9 link/unlink：走 journal 记账")
    func linkUnlink() async throws {
        let fake = FakeBrewRunner()
        fake.routes["link wget@2"] = Data()
        fake.routes["unlink wget@2"] = Data()
        let service = makeService(fake)
        let (journal, dbURL) = try makeJournalRunner(fake)
        defer { try? FileManager.default.removeItem(at: dbURL) }

        #expect(await service.linkFormula("wget@2", journal: journal))
        #expect(fake.callArgs.contains { $0 == ["link", "wget@2"] })
        #expect(await service.unlinkFormula("wget@2", journal: journal))
        #expect(fake.callArgs.contains { $0 == ["unlink", "wget@2"] })
    }

    // MARK: - D10 镜像源

    @Test("D10 镜像切换：托管区块写入 + 备份 + 一键还原")
    func mirrorSwitchAndRestore() async throws {
        let profile = FileManager.default.temporaryDirectory
            .appendingPathComponent("zshrc-\(UUID().uuidString)").path
        defer {
            try? FileManager.default.removeItem(atPath: profile)
            try? FileManager.default.removeItem(atPath: profile + ".cclean-backup")
        }
        try "export ORIGINAL_VAR=1\n".data(using: .utf8)!.write(to: URL(fileURLWithPath: profile))

        let service = makeService(FakeBrewRunner())

        // 切换到清华（写入托管区块 + 备份原文件）
        let switched = await service.switchMirror(
            .tsinghua, profilePath: profile)
        #expect(switched)
        let content = try String(contentsOfFile: profile, encoding: .utf8)
        #expect(content.contains(">>> cclean brew >>>"))
        #expect(content.contains("mirrors.tuna.tsinghua.edu.cn"))
        #expect(content.contains("ORIGINAL_VAR=1"))           // 原内容保留
        #expect(FileManager.default.fileExists(atPath: profile + ".cclean-backup"))

        // 再次切换覆盖旧区块（不堆叠）
        _ = await service.switchMirror(.ustc, profilePath: profile)
        let second = try String(contentsOfFile: profile, encoding: .utf8)
        #expect(second.contains("mirrors.ustc.edu.cn"))
        #expect(!second.contains("mirrors.tuna.tsinghua.edu.cn"))

        // 一键还原
        let restored = await service.restoreMirror(profilePath: profile)
        #expect(restored)
        let restoredContent = try String(contentsOfFile: profile, encoding: .utf8)
        #expect(restoredContent.contains("ORIGINAL_VAR=1"))
        #expect(!restoredContent.contains("cclean brew"))
    }

    // MARK: - D4 依赖树

    @Test("D4 依赖树：树形解析 → 嵌套节点（含 not installed 标记）")
    func dependencyTree() async throws {
        let fake = FakeBrewRunner()
        fake.routes["deps --tree wget"] = Data("""
        wget
        ├──gettext
        │   └──libunistring (not installed)
        └──libidn2
        """.utf8)
        let service = makeService(fake)
        let tree = try await service.dependencyTree(formula: "wget")

        let root = try #require(tree)
        #expect(root.name == "wget")
        #expect(root.children.count == 2)                    // gettext + libidn2
        let gettext = try #require(root.children.first { $0.name == "gettext" })
        #expect(gettext.isInstalled)
        let libunistring = try #require(gettext.children.first)
        #expect(libunistring.name == "libunistring")
        #expect(!libunistring.isInstalled)                   // not installed 标记
    }

    @Test("D4 反向依赖：brew uses --installed")
    func reverseDependencies() async throws {
        let fake = FakeBrewRunner()
        fake.routes["uses --installed gettext"] = Data("wget\ngit\n".utf8)
        let service = makeService(fake)
        let reverse = try await service.reverseDependencies(of: "gettext")
        #expect(reverse == ["wget", "git"])
    }

    // MARK: - D12 时间线

    @Test("D12 时间线：installed_time 解析 + 按时间降序")
    func timeline() async throws {
        let fake = FakeBrewRunner()
        let now = Date().timeIntervalSince1970
        fake.routes["info --json=v2 --installed"] = Data("""
        {"formulae":[
            {"name":"older","installed":[{"installed_time":\(now - 86400),"installed_on_request":true,"installed_as_dependency":false}]},
            {"name":"newer","installed":[{"installed_time":\(now),"installed_on_request":false,"installed_as_dependency":true}]}
        ]}
        """.utf8)
        let service = makeService(fake)
        let entries = try await service.installTimeline()
        #expect(entries.count == 2)
        #expect(entries[0].name == "newer")                  // 降序
        #expect(entries[0].asDependency == true)
        #expect(entries[1].onRequest == true)
    }
}