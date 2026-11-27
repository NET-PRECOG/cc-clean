import Testing
import Foundation
import CcCleanCore
@testable import CcCleanFS

@Suite("LargeFileScanner (F2)")
struct LargeFileScannerTests {

    @Test("F2 分类：视频/镜像/归档/开发者/其他")
    func classification() {
        #expect(LargeFileCategory.classify(path: "/a/movie.mp4") == .video)
        #expect(LargeFileCategory.classify(path: "/a/setup.dmg") == .diskImage)
        #expect(LargeFileCategory.classify(path: "/a/backup.zip") == .archive)
        #expect(LargeFileCategory.classify(path: "/a/App.xcarchive") == .developer)
        #expect(LargeFileCategory.classify(path: "/a/unknown.xyz") == .other)
    }

    @Test("F2 扫描：FSIndex 阈值查询 + 分类汇总（fixture）")
    func scanWithIndex() async throws {
        // fixture：创建 > 1KB（测试阈值）的文件
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("large-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 0x51, count: 2048).write(to: root.appendingPathComponent("video.mp4"))
        try Data(repeating: 0x52, count: 1024).write(to: root.appendingPathComponent("disk.dmg"))

        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("large-idx-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let index = try FSIndex(database: dbURL, logger: Logger(category: .scan, buffer: LogBuffer(capacity: 10)))
        _ = await index.index(roots: [root.path], policy: IndexPolicy())

        let scanner = LargeFileScanner(thresholdBytes: 1000)
        let entries = await scanner.scan(index: index, roots: [root.path])
        #expect(entries.count == 2)   // 两个文件均 > 1000B

        let summary = LargeFileScanner.summarize(entries)
        #expect(summary.contains { $0.category == .video })
        #expect(summary.contains { $0.category == .diskImage })
        // 体积降序：video（2048）在前
        let videoBytes = summary.first { $0.category == .video }?.bytes ?? 0
        let imageBytes = summary.first { $0.category == .diskImage }?.bytes ?? 0
        #expect(videoBytes >= imageBytes)
    }
}

@Suite("DuplicateFileDetector (F3)")
struct DuplicateFileDetectorTests {

    let detector = DuplicateFileDetector(logger: Logger(category: .scan, buffer: LogBuffer(capacity: 10)))

    @Test("F3 三级策略：同内容分组 + mtime 升序保留最早 + 可回收体积")
    func threeStageDetection() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // 同内容 3 份（不同 mtime）
        let content = Data(repeating: 0x53, count: 4096)
        for (i, name) in ["copy-c", "copy-a", "copy-b"].enumerated() {
            let path = root.appendingPathComponent(name)
            try content.write(to: path)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-Double(100 - i * 10))],
                ofItemAtPath: path.path)
        }
        // 不同内容（不进组）
        try Data(repeating: 0x54, count: 4096).write(to: root.appendingPathComponent("unique"))

        let groups = await detector.detect(candidates: [
            root.appendingPathComponent("copy-a").path,
            root.appendingPathComponent("copy-b").path,
            root.appendingPathComponent("copy-c").path,
            root.appendingPathComponent("unique").path,
        ])
        #expect(groups.count == 1)
        let group = try #require(groups.first)
        #expect(group.paths.count == 3)
        // 保留最早（copy-c mtime -100s 最早 → mtime 升序首位…… -100 vs -90 vs -80：-100 最早）
        #expect(group.keepPath.hasSuffix("copy-c"))
        #expect(group.removablePaths.count == 2)
        #expect(group.reclaimableBytes == 2 * 4096)
        #expect(!group.hasHardlinks)
    }

    @Test("F3 硬链接：同 inode 不重复计费（基线 F3 验收）")
    func hardlinkDedup() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hardlink-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let original = root.appendingPathComponent("orig")
        try Data(repeating: 0x55, count: 4096).write(to: original)
        let link = root.appendingPathComponent("hard")
        try FileManager.default.linkItem(at: original, to: link)

        let groups = await detector.detect(candidates: [original.path, link.path])
        // 同 inode → 不进重复组（或标注 hasHardlinks 无清理候选）
        if let group = groups.first {
            #expect(group.hasHardlinks)
            #expect(group.removablePaths.isEmpty)
        } else {
            #expect(groups.isEmpty)   // 完全跳过也是正确语义
        }
    }

    @Test("F3 粗筛：首尾块不同直接排除（不全量哈希）")
    func coarseFilter() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("coarse-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // 同尺寸不同内容（首块不同）
        try Data(repeating: 0x56, count: 4096).write(to: root.appendingPathComponent("f1"))
        try Data(repeating: 0x57, count: 4096).write(to: root.appendingPathComponent("f2"))

        let groups = await detector.detect(candidates: [
            root.appendingPathComponent("f1").path,
            root.appendingPathComponent("f2").path,
        ])
        #expect(groups.isEmpty)   // 内容不同 → 无重复组
    }
}
