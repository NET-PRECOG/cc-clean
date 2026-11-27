import Foundation
import CcCleanCore

/// 架构检测（A5）：读 Mach-O header 判定 arm64 / x86_64 / Universal；
/// 仅 x86_64 且本机 arm64 → 需 Rosetta。
public enum ArchInspector {

    public struct Info: Sendable, Equatable {
        /// "arm64" / "x86_64" / "universal" / "unknown"
        public let architecture: String
        /// 本机为 arm64 而应用仅 x86_64
        public let needsRosetta: Bool
    }

    // Mach-O magic
    private static let mhMagic64: UInt32 = 0xfeedfacf       // MH_MAGIC_64 (little-endian 读取)
    private static let fatMagic: UInt32 = 0xcafebabe        // Universal（big-endian）
    private static let cpuArm64: UInt32 = 0x0100000c
    private static let cpuX86_64: UInt32 = 0x00000007

    /// 解析应用的可执行文件架构。executablePath 为解析后的可执行文件路径。
    public static func inspect(executablePath: String, machineArch: String) -> Info {
        guard let cpus = readCpuTypes(executablePath) else {
            return Info(architecture: "unknown", needsRosetta: false)
        }
        guard !cpus.isEmpty else {
            return Info(architecture: "unknown", needsRosetta: false)
        }

        let arch: String
        if cpus.count > 1 {
            arch = "universal"
        } else if cpus[0] == cpuArm64 {
            arch = "arm64"
        } else if cpus[0] == cpuX86_64 {
            arch = "x86_64"
        } else {
            arch = "unknown"
        }

        let needsRosetta = arch == "x86_64" && machineArch == "arm64"
        return Info(architecture: arch, needsRosetta: needsRosetta)
    }

    /// 读 cputype 列表（支持 thin 与 fat header）。
    static func readCpuTypes(_ path: String) -> [UInt32]? {
        guard let file = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? file.close() }
        let header = file.readData(ofLength: 4096)
        guard header.count >= 8 else { return nil }

        let le32 = header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
        if le32 == mhMagic64 {
            return [header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }]
        }
        // fat header：magic 与字段均为 big-endian
        let be32 = { (offset: Int) in
            header.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
        }
        if be32(0) == fatMagic {
            let nfat = Int(be32(4))
            var cpus: [UInt32] = []
            for i in 0..<min(nfat, 16) {
                cpus.append(be32(8 + i * 20))   // fat_arch: cputype @0, cpusubtype @4, offset @8 ...
            }
            return cpus
        }
        return nil
    }

    /// bundlePath → 可执行文件路径（CFBundleExecutable 或目录名）。
    public static func executablePath(of bundlePath: String, executableName: String?) -> String {
        let name = executableName
            ?? ((bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension
        return bundlePath + "/Contents/MacOS/" + name
    }
}

/// 重复应用检测（A4）：同 bundleId 多路径/多版本共存。
public struct DuplicateAppDetector: Sendable {

    public struct Group: Sendable, Equatable {
        public let bundleId: String
        /// 全部副本（按路径排序；/Applications 优先为主副本）
        public let copies: [AppRecord]

        /// 主副本（默认 /Applications 下优先）
        public var primary: AppRecord? {
            copies.first { $0.bundlePath.hasPrefix("/Applications/") } ?? copies.first
        }

        /// 版本是否不一致
        public var hasVersionConflict: Bool {
            let versions = Set(copies.compactMap(\.shortVersion))
            return versions.count > 1
        }
    }

    public init() {}

    /// 按 bundleId 分组，返回存在多副本的组（path: 前缀的 fallback id 同样参与分组）。
    public func detect(_ records: [AppRecord]) -> [Group] {
        let byId = Dictionary(grouping: records, by: \.bundleId)
        return byId.values
            .filter { $0.count > 1 }
            .map { copies in
                Group(
                    bundleId: copies[0].bundleId,
                    copies: copies.sorted { ($0.bundlePath.hasPrefix("/Applications/") ? 0 : 1, $0.bundlePath)
                        < ($1.bundlePath.hasPrefix("/Applications/") ? 0 : 1, $1.bundlePath)
                    }
                )
            }
            .sorted { $0.bundleId < $1.bundleId }
    }
}

/// 资产报表导出（A9）：CSV + Markdown，含扫描时间与统计汇总。
public struct AssetReportExporter: Sendable {

    public init() {}

    /// CSV（UTF-8 BOM 保证 Excel 无乱码，基线 A9 验收）。
    public func exportCSV(_ records: [AppRecord]) -> String {
        var lines: [String] = []
        lines.append("名称,bundleId,版本,来源,签名,架构,体积(字节),安装时间,保护,扫描时间")
        let formatter = ISO8601DateFormatter()
        for r in records {
            lines.append([
                csvEscape(r.displayName),
                csvEscape(r.bundleId),
                csvEscape(r.shortVersion ?? ""),
                csvEscape(r.installSource.rawValue),
                csvEscape(r.signature.rawValue),
                csvEscape(r.architecture ?? ""),
                r.sizeBytes.map(String.init) ?? "",
                r.installDate.map(formatter.string(from:)) ?? "",
                r.isProtected ? "是" : "否",
                formatter.string(from: r.scannedAt),
            ].joined(separator: ","))
        }
        return "\u{FEFF}" + lines.joined(separator: "\n")
    }

    /// Markdown 台账（含统计汇总）。
    public func exportMarkdown(_ records: [AppRecord]) -> String {
        let totalSize = records.compactMap(\.sizeBytes).reduce(0, +)
        let bySource = Dictionary(grouping: records, by: \.installSource.rawValue)
        let formatter = ISO8601DateFormatter()

        var md = "# CcClean 应用资产报表\n\n"
        md += "- 扫描时间：\(formatter.string(from: Date()))\n"
        md += "- 应用总数：\(records.count)\n"
        md += "- 已统计体积合计：\(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file))\n"
        md += "- 来源分布：\(bySource.map { "\($0.key) × \($0.value.count)" }.sorted().joined(separator: "，"))\n\n"
        md += "| 名称 | bundleId | 版本 | 来源 | 架构 | 保护 |\n|---|---|---|---|---|---|\n"
        for r in records.sorted(by: { $0.displayName < $1.displayName }) {
            md += "| \(r.displayName) | `\(r.bundleId)` | \(r.shortVersion ?? "—") | \(r.installSource.rawValue) | \(r.architecture ?? "—") | \(r.isProtected ? "是" : "否") |\n"
        }
        return md
    }

    /// 写文件（.atomic 原子写，基线 6.3 要点 6）。
    public func write(_ content: String, to url: URL) throws {
        try content.data(using: .utf8)!.write(to: url, options: .atomic)
    }

    private func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }
}