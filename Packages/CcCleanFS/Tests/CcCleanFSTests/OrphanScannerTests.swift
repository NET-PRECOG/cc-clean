import Testing
import Foundation
@testable import CcCleanFS

@Suite("OrphanScanner (C11 孤儿文件)")
struct OrphanScannerTests {

    @Test("bundleId 提取：reverse-DNS ≥2 段；com.apple.* 系统项排除；非法名拒绝")
    func bundleIdExtraction() {
        #expect(OrphanScanner.bundleIdCandidate(from: "com.dead.app") == "com.dead.app")
        #expect(OrphanScanner.bundleIdCandidate(from: "com.dead.app.plist") == "com.dead.app")
        #expect(OrphanScanner.bundleIdCandidate(from: "cn.foo.bar-baz") == "cn.foo.bar-baz")
        #expect(OrphanScanner.bundleIdCandidate(from: "com.apple.Safari") == nil)
        #expect(OrphanScanner.bundleIdCandidate(from: "com.apple.helper-quit") == nil)
        #expect(OrphanScanner.bundleIdCandidate(from: "nosuffix") == nil)          // 单段
        #expect(OrphanScanner.bundleIdCandidate(from: ".hidden") == nil)           // 空段
        #expect(OrphanScanner.bundleIdCandidate(from: "some random name") == nil)  // 含空格
        #expect(OrphanScanner.bundleIdCandidate(from: "com.apple") == nil)         // 裸 apple 域
    }

    @Test("扫描：未装应用的残留 → 孤儿候选；已装/系统项不报；confidence 分层")
    func scanFindings() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("orphan-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("Home").path

        func touch(_ rel: String, isDir: Bool) throws {
            let p = root.appendingPathComponent("Home/\(rel)")
            if isDir {
                try FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
                try "data".data(using: .utf8)!.write(to: p.appendingPathComponent("f"))
            } else {
                try FileManager.default.createDirectory(
                    at: p.deletingLastPathComponent(), withIntermediateDirectories: true)
                try "cfg".data(using: .utf8)!.write(to: p)
            }
        }

        // 孤儿：应用已卸载
        try touch("Library/Caches/com.dead.cache", isDir: true)
        try touch("Library/Application Support/com.dead.support", isDir: true)
        try touch("Library/Preferences/com.dead.support.plist", isDir: false)
        // 已装应用残留 → 不报
        try touch("Library/Caches/com.live.app", isDir: true)
        // 系统项 → 永不报
        try touch("Library/Containers/com.apple.mail", isDir: true)
        // 非 bundleId 名 → 不报
        try touch("Library/Caches/just-a-folder", isDir: true)

        let scanner = OrphanScanner()
        let findings = scanner.scan(
            home: home, installedBundleIds: ["com.live.app"])

        let paths = findings.map(\.path)
        #expect(paths.contains { $0.contains("Library/Caches/com.dead.cache") })
        #expect(paths.contains { $0.contains("Library/Application Support/com.dead.support") })
        #expect(paths.contains { $0.contains("Library/Preferences/com.dead.support.plist") })
        // 已装 / 系统 / 非 bundleId 不在结果
        #expect(!paths.contains { $0.contains("com.live.app") })
        #expect(!paths.contains { $0.contains("com.apple.mail") })
        #expect(!paths.contains { $0.contains("just-a-folder") })
        // confidence 分层：目录层 probable、Preferences possible
        let cache = findings.first { $0.path.contains("Caches/com.dead.cache") }!
        let pref = findings.first { $0.path.contains("Preferences/com.dead.support.plist") }!
        #expect(cache.confidence == "probable")
        #expect(pref.confidence == "possible")
        // 体积非空（fixture 有内容）
        #expect((cache.sizeBytes ?? 0) > 0)
    }

    @Test("空已装集合：全部候选报孤儿；无残留目录 → 空结果")
    func edgeCases() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("orphan-e-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("Home").path

        let scanner = OrphanScanner()
        // 无任何 Library 目录 → 空
        #expect(scanner.scan(home: home, installedBundleIds: []).isEmpty)

        // 有残留 + 空已装集合 → 全报
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Home/Library/Caches/com.ghost.app"),
            withIntermediateDirectories: true)
        let findings = scanner.scan(home: home, installedBundleIds: [])
        #expect(findings.count == 1)
        #expect(findings[0].bundleIdCandidate == "com.ghost.app")
    }
}