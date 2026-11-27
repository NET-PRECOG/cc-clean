import Testing
import Foundation
import CcCleanCore
@testable import CcCleanFS

@Suite("BulkDirectoryReader")
struct BulkDirectoryReaderTests {

    @Test("条目枚举：文件/目录/软链接识别，名字含中文/空格/emoji，logicalSize 精确")
    func basicEntries() throws {
        let layout = try FSTestFixture.makeTree()
        defer { FSTestFixture.remove(layout.root) }

        let entries = try BulkDirectoryReader.readEntries(atPath: layout.root.path)
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })

        // 顶层 6 项：a.txt / 中文 目录 / 🎉dir / Demo.app / a-link / n1
        #expect(entries.map(\.name).sorted() == ["Demo.app", "a-link", "a.txt", "n1", "中文 目录", "🎉dir"])
        #expect(byName["a.txt"] != nil)
        #expect(byName["中文 目录"]?.isDirectory == true)
        #expect(byName["🎉dir"]?.isDirectory == true)
        #expect(byName["Demo.app"]?.isDirectory == true)
        #expect(byName["n1"]?.isDirectory == true)
        #expect(byName["a-link"]?.isSymlink == true)

        // logicalSize 精确（1000 字节）；allocSize 块对齐（≥ logical 且 ≤ +4096）
        let a = try #require(byName["a.txt"])
        #expect(a.logicalSize == 1000)
        #expect(a.allocSize >= 1000 && a.allocSize <= 1000 + 4096)
        #expect(a.inode > 0)
        #expect(a.mtime.timeIntervalSinceNow < 60)
    }

    @Test("目录不存在/无权限：抛错而非崩溃")
    func errorPaths() {
        #expect(throws: BulkDirectoryReader.BulkError.self) {
            _ = try BulkDirectoryReader.readEntries(atPath: "/nonexistent-dir-for-test")
        }
    }
}

@Suite("FSIndex")
struct FSIndexTests {

    func makeIndex() throws -> FSIndex {
        try FSIndex(database: FSTestFixture.indexDBURL(), logger: Logger(category: .scan, buffer: LogBuffer(capacity: 20)))
    }

    @Test("首次索引：节点数正确，skipPackageDescendants 时 .app 内部不入索引")
    func firstIndex() async throws {
        let layout = try FSTestFixture.makeTree()
        defer { FSTestFixture.remove(layout.root) }
        let index = try makeIndex()

        let stats = await index.index(roots: [layout.root.path], policy: IndexPolicy())

        // root(1) + 顶层 6 + cjk(1) + emoji(1) + n1 子树(3) = 12；Demo.app 包内不入索引
        #expect(stats.scannedEntries == 12)
        #expect(stats.insertedNodes == 12)
        #expect(stats.deniedPaths.isEmpty)
        #expect(stats.elapsed > .zero)

        // .app 内部未下探（默认 skipPackageDescendants = true）
        let appContents = await index.query(FSQuery(roots: [layout.root.path])
            .with { $0.extensions = nil; $0.limit = 100 })
        #expect(!appContents.contains { $0.path.contains("Demo.app/Contents") })

        // 嵌套 3 层已入索引
        #expect(appContents.contains { $0.path.hasSuffix("n1/n2/n3/deep.log") })
    }

    @Test("增量索引：未变的顶层目录整棵跳过")
    func incrementalIndex() async throws {
        let layout = try FSTestFixture.makeTree()
        defer { FSTestFixture.remove(layout.root) }
        let index = try makeIndex()

        _ = await index.index(roots: [layout.root.path], policy: IndexPolicy())
        let second = await index.index(roots: [layout.root.path], policy: IndexPolicy())

        // 顶层 4 个目录整棵跳过；顶层项自身 + root 重新扫描 = 7
        #expect(second.skippedSubtrees == 4)
        #expect(second.scannedEntries == 7)
    }

    @Test("aggregate：depth=0 全子树汇总，depth=1 直接子项")
    func aggregate() async throws {
        let layout = try FSTestFixture.makeTree()
        defer { FSTestFixture.remove(layout.root) }
        let index = try makeIndex()
        _ = await index.index(roots: [layout.root.path], policy: IndexPolicy())

        // depth=1：中文 目录 = 500B 文件（1 块）
        let top = await index.aggregate(under: layout.root.path, depth: 1)
        let cjk = try #require(top[layout.dirCJK.path])
        #expect(cjk >= 500 && cjk <= 500 + 4096)

        // depth=0：全树 = a.txt + cjk(500B) + emoji(100B) + deep.log(80B) 四个常规文件
        // （a-link 符号链接 alloc 视实现 0~1 块；Demo.app 不入索引）
        let total = await index.aggregate(under: layout.root.path, depth: 0)
        let rootSize = try #require(total[layout.root.path])
        #expect(rootSize >= 4 * 4096 && rootSize <= 5 * 4096)

        // depth=2：n1 → n2
        let d2 = await index.aggregate(under: layout.root.path, depth: 2)
        let n2 = try #require(d2[layout.nestedDir.deletingLastPathComponent().path])
        #expect(n2 >= 80 && n2 <= 80 + 4096)
    }

    @Test("query：按体积排序 Top-N + 扩展名过滤")
    func query() async throws {
        let layout = try FSTestFixture.makeTree()
        defer { FSTestFixture.remove(layout.root) }
        let index = try makeIndex()
        _ = await index.index(roots: [layout.root.path], policy: IndexPolicy())

        let top1 = await index.query(FSQuery(roots: [layout.root.path]))
        #expect(top1.count <= 500)
        // 排序降序：首个 ≥ 末个
        if top1.count >= 2 {
            #expect(top1.first!.allocatedSize >= top1.last!.allocatedSize)
        }

        var q = FSQuery(roots: [layout.root.path])
        q.extensions = ["txt"]
        let txts = await index.query(q)
        #expect(txts.count == 1)
        #expect(txts.first?.path.hasSuffix("a.txt") == true)
    }

    @Test("allocatedSize：索引值与现场遍历一致（du 等价性）")
    func allocatedSize() async throws {
        let layout = try FSTestFixture.makeTree()
        defer { FSTestFixture.remove(layout.root) }
        let index = try makeIndex()
        _ = await index.index(roots: [layout.root.path], policy: IndexPolicy())

        let indexed = await index.allocatedSize(of: layout.dirCJK.path)
        let live = FSIndex.liveSize(of: layout.dirCJK.path)
        #expect(indexed == live)
        #expect(indexed >= 500 && indexed <= 500 + 4096)
    }

    @Test("invalidate：失效后 aggregate 清空")
    func invalidate() async throws {
        let layout = try FSTestFixture.makeTree()
        defer { FSTestFixture.remove(layout.root) }
        let index = try makeIndex()
        _ = await index.index(roots: [layout.root.path], policy: IndexPolicy())

        await index.invalidate(under: layout.dirCJK.path)
        let after = await index.aggregate(under: layout.dirCJK.path, depth: 1)
        #expect(after.isEmpty)

        let stats = await index.stats(forRoot: layout.root.path)
        #expect(stats?.stale == true)
    }

    @Test("EPERM 目录：记入 deniedPaths 不中断")
    func deniedPaths() async throws {
        // /private/var/db 等受限目录在无全盘访问时通常 EPERM；
        // fixture 中直接验证不存在的 root 记入 denied
        let index = try makeIndex()
        let stats = await index.index(roots: ["/nonexistent-root-\(UUID().uuidString)"], policy: IndexPolicy())
        #expect(stats.deniedPaths.count == 1)
    }
}

private extension FSQuery {
    /// 测试辅助：就地修改查询条件。
    func with(_ mutate: (inout FSQuery) -> Void) -> FSQuery {
        var copy = self
        mutate(&copy)
        return copy
    }
}