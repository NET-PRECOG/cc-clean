import Foundation
import CcCleanCore

/// launchd 守护项记录（基线 8.2 launchd_entry 表的内存形态）。
public struct LaunchdEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: String { label }
    public let label: String
    public let plistPath: String
    /// system / gui/<uid>
    public let domain: String
    public let program: String?
    public let args: [String]
    public let runAtLoad: Bool?
    public let keepAlive: Bool?
    public let startInterval: Int?
    /// 归属应用 bundleId，nil = 未识别（基线 7.8 算法 2）
    public let ownerBundle: String?
    /// 系统组件（/System/Library 下）只读展示
    public let isSystem: Bool
    /// 0 = 僵尸/启动失败（program 不存在或 exit 非 0）
    public var healthy: Bool
    public let lastExit: Int?
    public let scannedAt: Date

    public init(
        label: String, plistPath: String, domain: String, program: String?,
        args: [String], runAtLoad: Bool?, keepAlive: Bool?, startInterval: Int?,
        ownerBundle: String?, isSystem: Bool, healthy: Bool = true,
        lastExit: Int? = nil, scannedAt: Date = Date()
    ) {
        self.label = label
        self.plistPath = plistPath
        self.domain = domain
        self.program = program
        self.args = args
        self.runAtLoad = runAtLoad
        self.keepAlive = keepAlive
        self.startInterval = startInterval
        self.ownerBundle = ownerBundle
        self.isSystem = isSystem
        self.healthy = healthy
        self.lastExit = lastExit
        self.scannedAt = scannedAt
    }
}

/// launchd plist 解析与归属映射（H2/C2/C10 支撑，基线 7.8 关键算法 2）。
/// 归属四级回退：Program 路径所属 .app → Label 前缀匹配 bundleId →
/// ProgramArguments[0] 路径反查 → 未识别。
public enum LaunchdParser {

    /// 可写目录（系统目录只读展示）
    public static func writableRoots(home: String) -> [String] {
        [
            "/Library/LaunchDaemons",
            "/Library/LaunchAgents",
            home + "/Library/LaunchAgents",
        ]
    }

    /// 全部扫描根（含系统只读目录）。
    public static func allRoots(home: String) -> [(path: String, isSystem: Bool)] {
        [
            ("/Library/LaunchDaemons", false),
            ("/Library/LaunchAgents", false),
            (home + "/Library/LaunchAgents", false),
            ("/System/Library/LaunchDaemons", true),
            ("/System/Library/LaunchAgents", true),
        ]
    }

    /// 解析单个 plist。
    public static func parse(plistPath: String, domain: String, isSystem: Bool) -> LaunchdEntry? {
        guard let data = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil) as? [String: Any]
        else { return nil }

        guard let label = plist["Label"] as? String else { return nil }
        let program = plist["Program"] as? String
        let args = (plist["ProgramArguments"] as? [Any])?.compactMap { $0 as? String } ?? []
        let runAtLoad = plist["RunAtLoad"] as? Bool
        let keepAliveRaw = plist["KeepAlive"]
        let keepAlive: Bool?
        switch keepAliveRaw {
        case let b as Bool: keepAlive = b
        case let d as [String: Any]: keepAlive = !d.isEmpty   // 字典形式（条件保活）视为 true
        case nil: keepAlive = nil
        default: keepAlive = true
        }
        let startInterval = plist["StartInterval"] as? Int

        // 可执行路径：Program 优先，回退 ProgramArguments[0]
        let executable = program ?? args.first

        return LaunchdEntry(
            label: label, plistPath: plistPath, domain: domain,
            program: program, args: args,
            runAtLoad: runAtLoad, keepAlive: keepAlive, startInterval: startInterval,
            ownerBundle: nil, isSystem: isSystem,
            healthy: executable == nil ? false : FileManager.default.fileExists(atPath: executable!)
        )
    }

    /// 扫描目录并做归属映射。roots 缺省扫全部（含系统只读目录）；
    /// 测试与限定扫描可传入自定义根。
    public static func scan(
        home: String,
        knownBundles: [AppRecord],
        roots: [(path: String, isSystem: Bool)]? = nil
    ) -> [LaunchdEntry] {
        var entries: [LaunchdEntry] = []
        for (root, isSystem) in roots ?? allRoots(home: home) {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
            for file in files where file.hasSuffix(".plist") {
                let path = root + "/" + file
                if var entry = parse(plistPath: path, domain: domainOf(root, home: home), isSystem: isSystem) {
                    entry = Self.attributeOwner(entry: entry, knownBundles: knownBundles)
                    entries.append(entry)
                }
            }
        }
        return entries
    }

    static func domainOf(_ root: String, home: String) -> String {
        if root.hasPrefix("/System/") { return "system" }
        if root == "/Library/LaunchDaemons" || root == "/Library/LaunchAgents" { return "system" }
        if root.hasPrefix(home) { return "gui/\(getuid())" }
        return "system"
    }

    /// 归属映射四级回退（基线 7.8 算法 2）。
    public static func attributeOwner(entry: LaunchdEntry, knownBundles: [AppRecord]) -> LaunchdEntry {
        let candidates = [entry.program] + entry.args

        // ① Program（或 args[0]）路径落在某 .app bundle 内 → 该应用
        for candidate in candidates.compactMap({ $0 }) {
            var url = URL(fileURLWithPath: candidate)
            while url.pathComponents.count > 1 {
                if url.pathExtension == "app",
                   let record = knownBundles.first(where: {
                       $0.bundlePath == url.path
                           || $0.bundlePath.lowercased() == url.path.lowercased()
                   }) {

                    return LaunchdEntry(
                        label: entry.label, plistPath: entry.plistPath, domain: entry.domain,
                        program: entry.program, args: entry.args,
                        runAtLoad: entry.runAtLoad, keepAlive: entry.keepAlive,
                        startInterval: entry.startInterval,
                        ownerBundle: record.bundleId, isSystem: entry.isSystem,
                        healthy: entry.healthy, lastExit: entry.lastExit, scannedAt: entry.scannedAt
                    )
                }
                url.deleteLastPathComponent()
            }
        }

        // ② Label 前缀匹配 bundleId（如 com.apple.pkg → com.apple.*）
        for record in knownBundles {
            if entry.label == record.bundleId
                || entry.label.hasPrefix(record.bundleId + ".")
                || record.bundleId.hasPrefix(entry.label + ".") {
                return LaunchdEntry(
                    label: entry.label, plistPath: entry.plistPath, domain: entry.domain,
                    program: entry.program, args: entry.args,
                    runAtLoad: entry.runAtLoad, keepAlive: entry.keepAlive,
                    startInterval: entry.startInterval,
                    ownerBundle: record.bundleId, isSystem: entry.isSystem,
                    healthy: entry.healthy, lastExit: entry.lastExit, scannedAt: entry.scannedAt
                )
            }
        }

        // ③ ProgramArguments[0] 路径反查：可执行名匹配 bundle executable_name
        if let exec = entry.args.first {
            let execName = (exec as NSString).lastPathComponent
            if let record = knownBundles.first(where: {
                $0.executableName == execName || $0.bundleName == execName
            }) {
                return LaunchdEntry(
                    label: entry.label, plistPath: entry.plistPath, domain: entry.domain,
                    program: entry.program, args: entry.args,
                    runAtLoad: entry.runAtLoad, keepAlive: entry.keepAlive,
                    startInterval: entry.startInterval,
                    ownerBundle: record.bundleId, isSystem: entry.isSystem,
                    healthy: entry.healthy, lastExit: entry.lastExit, scannedAt: entry.scannedAt
                )
            }
        }

        // ④ 未识别
        return entry
    }

    /// 僵尸/异常判定（C10/H5，基线 7.8 算法 3）：
    /// program 路径不存在，或 launchctl print 的 last exit code 非 0。
    public static func diagnose(_ entry: LaunchdEntry) -> LaunchdEntry {
        var result = entry
        let executable = entry.program ?? entry.args.first
        if let executable, !FileManager.default.fileExists(atPath: executable) {
            result.healthy = false
        }
        if let exit = entry.lastExit, exit != 0 {
            result.healthy = false
        }
        return result
    }
}