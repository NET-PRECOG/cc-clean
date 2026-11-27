import Testing
import Foundation
import Darwin
import CcCleanCore
@testable import CcCleanFS

@Suite("SizeCache")
struct SizeCacheTests {

    func makeCache() throws -> SizeCache {
        try SizeCache(
            database: FSTestFixture.indexDBURL(),
            logger: Logger(category: .scan, buffer: LogBuffer(capacity: 20))
        )
    }

    @Test("体积计算：与现场遍历一致（du 等价性）")
    func computeMatchesLive() async throws {
        let layout = try FSTestFixture.makeTree()
        defer { FSTestFixture.remove(layout.root) }
        let cache = try makeCache()

        let updates = await drain(cache.computeSizes(appPaths: [layout.fakeAppBundle.path]))
        #expect(updates.count == 1)
        let update = try #require(updates.first)
        #expect(!update.fromCache)
        #expect(update.sizeBytes == FSIndex.liveSize(of: layout.fakeAppBundle.path))
        #expect(update.sizeBytes >= 600)   // Demo(200B) + Info.plist(>400B)
    }

    @Test("mtime 未变：第二次读缓存（fromCache=true）")
    func cacheHit() async throws {
        let layout = try FSTestFixture.makeTree()
        defer { FSTestFixture.remove(layout.root) }
        let cache = try makeCache()

        let first = await drain(cache.computeSizes(appPaths: [layout.fakeAppBundle.path]))
        let second = await drain(cache.computeSizes(appPaths: [layout.fakeAppBundle.path]))
        #expect(first.first?.fromCache == false)
        #expect(second.first?.fromCache == true)
        #expect(first.first?.sizeBytes == second.first?.sizeBytes)
    }

    @Test("顶层 mtime 变化：缓存失效重算")
    func cacheInvalidation() async throws {
        let layout = try FSTestFixture.makeTree()
        defer { FSTestFixture.remove(layout.root) }
        let cache = try makeCache()

        _ = await drain(cache.computeSizes(appPaths: [layout.fakeAppBundle.path]))

        // 在 bundle 内新建文件（改变顶层目录 mtime）
        try Data(repeating: 0x46, count: 4096).write(
            to: layout.fakeAppBundle.appendingPathComponent("Contents/newfile.bin")
        )
        // 显式回拨 1 小时，确保与首次计算的 mtime 差异超过 1ms 容差
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3600)],
            ofItemAtPath: layout.fakeAppBundle.path
        )

        let second = await drain(cache.computeSizes(appPaths: [layout.fakeAppBundle.path]))
        #expect(second.first?.fromCache == false)
        // 原 2 块（Demo + Info.plist）+ 新增 1 块
        #expect(second.first!.sizeBytes >= 3 * 4096)   // 新增 ≥ 1 块
    }

    @Test("AsyncStream 推送数量与并发统计一致")
    func streamCompletes() async throws {
        let layout = try FSTestFixture.makeTree()
        defer { FSTestFixture.remove(layout.root) }
        let cache = try makeCache()

        let paths = [
            layout.fileA.path,
            layout.dirCJK.path,
            layout.dirEmoji.path,
            layout.fakeAppBundle.path,
            layout.nestedDir.path,
        ]
        let updates = await drain(cache.computeSizes(appPaths: paths))
        #expect(updates.count == 5)
        // 全部成功（无 denied/缺失路径）
        #expect(updates.allSatisfy { $0.sizeBytes >= 0 })
    }

    /// 收集 AsyncStream 全部事件。
    func drain(_ stream: AsyncStream<SizeUpdate>) async -> [SizeUpdate] {
        var collected: [SizeUpdate] = []
        for await update in stream {
            collected.append(update)
        }
        return collected
    }
}

/// S1-7 POC-T10：大卷索引稳定性（基线 16 章 T10）。
/// 折衷规模：2 万文件（100 目录 × 200 文件），验证吞吐与内存约束；
/// 500GB 全量验证在真机回归执行。
@Suite("POC-T10 大卷索引稳定性")
struct LargeVolumeTests {

    static func currentFootprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            task_info(
                mach_task_self_,
                task_flavor_t(TASK_VM_INFO),
                UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: integer_t.self),
                &count
            )
        }
        return kr == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }

    /// 生成 100 目录 × 200 文件的目录树。
    func makeLargeTree(directoryCount: Int = 100, filesPerDir: Int = 200) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cclean-large-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let chunk = Data(repeating: 0x47, count: 256)
        for d in 0..<directoryCount {
            let dir = root.appendingPathComponent("dir-\(d)")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for f in 0..<filesPerDir {
                try chunk.write(to: dir.appendingPathComponent("file-\(f).dat"))
            }
        }
        return root
    }

    @Test("2 万文件索引：吞吐 ≥ 3000 条/秒，内存增长 < 100MB")
    func largeVolumeIndex() async throws {
        let root = try makeLargeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let index = try FSIndex(
            database: FSTestFixture.indexDBURL(),
            logger: Logger(category: .scan, buffer: LogBuffer(capacity: 10))
        )

        let before = Self.currentFootprint()
        let stats = await index.index(roots: [root.path], policy: IndexPolicy())
        let after = Self.currentFootprint()

        let expectedEntries = 100 * 200 + 100 + 1   // 文件 + 目录 + root
        #expect(stats.scannedEntries == expectedEntries)

        // 吞吐（秒级换算）
        let seconds = Double(stats.elapsed.components.seconds)
            + Double(stats.elapsed.components.attoseconds) / 1e18
        #expect(seconds > 0)
        let throughput = Double(stats.scannedEntries) / seconds
        #expect(throughput >= 3000)

        // 内存（POC 门：峰值 ≤ 350MB；此处用增长量近似）
        let growth = after - before
        #expect(growth < 100 * 1024 * 1024)

        print("POC-T10: entries=\(stats.scannedEntries) elapsed=\(stats.elapsed) throughput=\(Int(throughput))/s memoryDelta=\(growth / 1024 / 1024)MB")

        // 增量二次索引 < 8s 门槛的比例验证（2 万条目应 < 2s）
        let second = await index.index(roots: [root.path], policy: IndexPolicy())
        let secondSeconds = Double(second.elapsed.components.seconds)
            + Double(second.elapsed.components.attoseconds) / 1e18
        #expect(second.skippedSubtrees == 100)
        #expect(secondSeconds < 8)
    }
}