import Testing
import Foundation
import CcCleanCore
@testable import CcCleanFS

@Suite("ArchInspector (A5)")
struct ArchInspectorTests {

    /// 写临时 Mach-O 文件。
    func writeMachO(_ bytes: [UInt8]) throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("macho-\(UUID().uuidString)").path
        try Data(bytes).write(to: URL(fileURLWithPath: path))
        return path
    }

    @Test("thin arm64：本机 arm64 不需 Rosetta")
    func thinArm64() throws {
        var bytes: [UInt8] = [0xcf, 0xfa, 0xed, 0xfe]   // MH_MAGIC_64 (LE)
        bytes += [0x0c, 0x00, 0x00, 0x01]                // cputype = 0x0100000c arm64 (LE)
        bytes += Array(repeating: 0, count: 64)
        let path = try writeMachO(bytes)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let info = ArchInspector.inspect(executablePath: path, machineArch: "arm64")
        #expect(info.architecture == "arm64")
        #expect(info.needsRosetta == false)
    }

    @Test("thin x86_64：本机 arm64 需 Rosetta")
    func thinX86_64() throws {
        var bytes: [UInt8] = [0xcf, 0xfa, 0xed, 0xfe]
        bytes += [0x07, 0x00, 0x00, 0x00]                // cputype = 0x7 x86_64
        bytes += Array(repeating: 0, count: 64)
        let path = try writeMachO(bytes)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let info = ArchInspector.inspect(executablePath: path, machineArch: "arm64")
        #expect(info.architecture == "x86_64")
        #expect(info.needsRosetta == true)
    }

    @Test("fat header（双架构）：universal")
    func universalBinary() throws {
        var bytes: [UInt8] = [0xca, 0xfe, 0xba, 0xbe]   // FAT_MAGIC (BE)
        bytes += [0x00, 0x00, 0x00, 0x02]                // nfat_arch = 2 (BE)
        // fat_arch[0]: cputype(arm64, BE)
        bytes += [0x01, 0x00, 0x00, 0x0c] + Array(repeating: 0, count: 16)
        // fat_arch[1]: cputype(x86_64, BE)
        bytes += [0x00, 0x00, 0x00, 0x07] + Array(repeating: 0, count: 16)
        let path = try writeMachO(bytes)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let info = ArchInspector.inspect(executablePath: path, machineArch: "arm64")
        #expect(info.architecture == "universal")
        #expect(info.needsRosetta == false)
    }

    @Test("可执行文件缺失：unknown 不崩溃")
    func missingBinary() {
        let info = ArchInspector.inspect(
            executablePath: "/nonexistent-binary-\(UUID().uuidString)", machineArch: "arm64"
        )
        #expect(info.architecture == "unknown")
        #expect(info.needsRosetta == false)
    }

    @Test("真实系统二进制：/bin/echo 判定为 arm64（Apple Silicon 本机）")
    func realBinary() {
        guard FileManager.default.fileExists(atPath: "/bin/echo") else { return }
        let info = ArchInspector.inspect(executablePath: "/bin/echo", machineArch: "arm64")
        #expect(info.architecture == "arm64" || info.architecture == "universal")
    }
}

@Suite("DuplicateAppDetector (A4)")
struct DuplicateAppDetectorTests {

    func record(_ bundleId: String, path: String, version: String?) -> AppRecord {
        AppRecord(bundleId: bundleId, bundlePath: path, displayName: "Demo", shortVersion: version)
    }

    @Test("同 bundleId 多路径分组；/Applications 优先为主副本")
    func grouping() {
        let records = [
            record("com.demo", path: "/Users/u/Applications/Demo.app", version: "1.0"),
            record("com.demo", path: "/Applications/Demo.app", version: "2.0"),
            record("com.other", path: "/Applications/Other.app", version: "1.0"),
        ]
        let groups = DuplicateAppDetector().detect(records)
        #expect(groups.count == 1)
        let group = groups[0]
        #expect(group.copies.count == 2)
        #expect(group.primary?.bundlePath == "/Applications/Demo.app")
        #expect(group.hasVersionConflict == true)
    }

    @Test("单副本与 fallback path: id 不产生误报")
    func noFalsePositives() {
        let records = [
            record("com.solo", path: "/Applications/Solo.app", version: "1.0"),
            record("path:abc", path: "/Users/u/Broken.app", version: nil),
            record("path:def", path: "/Users/u/Other.app", version: nil),
        ]
        #expect(DuplicateAppDetector().detect(records).isEmpty)
    }
}

@Suite("AssetReportExporter (A9)")
struct AssetReportExporterTests {

    @Test("CSV：UTF-8 BOM、行数、逗号转义")
    func csvExport() {
        let records = [
            AppRecord(bundleId: "com.a", bundlePath: "/A.app", displayName: "应用,含逗号", shortVersion: "1.0"),
            AppRecord(bundleId: "com.b", bundlePath: "/B.app", displayName: "引号\"测试", installSource: .appStore),
        ]
        let csv = AssetReportExporter().exportCSV(records)
        #expect(csv.hasPrefix("\u{FEFF}"))                      // Excel 无乱码
        #expect(csv.components(separatedBy: "\n").count == 3)   // header + 2 行
        #expect(csv.contains("\"应用,含逗号\""))
        #expect(csv.contains("\"引号\"\"测试\""))
        #expect(csv.contains("appStore"))
    }

    @Test("Markdown：含统计汇总与来源分布")
    func markdownExport() {
        let records = [
            AppRecord(bundleId: "com.a", bundlePath: "/A.app", displayName: "A", installSource: .appStore, sizeBytes: 4096),
            AppRecord(bundleId: "com.b", bundlePath: "/B.app", displayName: "B", installSource: .homebrewCask, sizeBytes: 8192),
        ]
        let md = AssetReportExporter().exportMarkdown(records)
        #expect(md.contains("应用总数：2"))
        #expect(md.contains("appStore × 1"))
        #expect(md.contains("| A | `com.a` |"))
        #expect(md.contains("12 KB"))
    }

    @Test("原子写文件")
    func writeFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("report-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        try AssetReportExporter().write("# test", to: url)
        let content = try String(contentsOf: url, encoding: .utf8)
        #expect(content == "# test")
    }
}