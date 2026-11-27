import Testing
import Foundation
import CcCleanCore
@testable import CcCleanOps

/// mas 行解析与降级测试（真实 mas 进程不进测试，红线）。
@Suite("MasService (B10)")
struct MasServiceTests {

    @Test("list 行解析：id name version / 缺版本 / 非法行")
    func parseListLines() {
        let ok = MasService.parseListLine("123456789  Xcode  15.2")
        #expect(ok?.id == 123456789)
        #expect(ok?.name == "Xcode")
        #expect(ok?.version == "15.2")

        // name 含空格：首段 id、末段版本、中间 name
        let spaced = MasService.parseListLine("498486188  Keynote  14.1")
        #expect(spaced?.name == "Keynote")

        let noVersion = MasService.parseListLine("123456789  WeirdApp")
        #expect(noVersion?.id == 123456789)
        #expect(noVersion?.version == "")

        #expect(MasService.parseListLine("") == nil)
        #expect(MasService.parseListLine("not-a-line") == nil)
        #expect(MasService.parseListLine("abc Name 1.0") == nil)   // id 非数字
    }

    @Test("outdated 行解析：(old -> new) → 版本取目标")
    func parseOutdatedLines() {
        let line = MasService.parseListLine("123456789  Keynote  (14.1 -> 14.2)")
        #expect(line?.id == 123456789)
        #expect(line?.name == "Keynote")
        #expect(line?.version == "14.2")

        let multi = MasService.parseListOutput("111  AppOne  1.0\n\n222  AppTwo  (1.1 -> 1.2)\nnoise line")
        #expect(multi.count == 2)
        #expect(multi[0].name == "AppOne")
        #expect(multi[1].version == "1.2")
    }

    @Test("未装 mas：listInstalled/outdated/upgrade 优雅降级（不报错）")
    func degradationWithoutMas() async {
        let logger = Logger(category: .uninstall, buffer: LogBuffer(capacity: 10))
        let service = MasService(logger: logger, masPath: "/nonexistent/mas")
        #expect(await service.resolveMas() == nil)
        #expect(await service.listInstalled().isEmpty)
        #expect(await service.outdated().isEmpty)
        let upgrade = await service.upgrade(ids: [1])
        #expect(!upgrade.succeeded)
        #expect(upgrade.summary.contains("mas"))
    }
}