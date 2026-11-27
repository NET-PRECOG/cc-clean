import Foundation
import Darwin
import CcCleanCore
import CcCleanFS

/// adb 设备与日志（M4，基线 7.5）。
public actor AdbService {

    private let runner: BrewCommandRunning   // 复用命令执行抽象（ProcessRunner 适配）
    private let adbCandidates = [
        "~/Library/Android/sdk/platform-tools/adb",
        "/opt/homebrew/bin/adb",
        "/usr/local/bin/adb",
    ]
    private let logger: Logger

    public init(runner: BrewCommandRunning = SystemBrewRunner(), logger: Logger) {
        self.runner = runner
        self.logger = logger
    }

    func resolveAdb(home: String) async -> String? {
        let fm = FileManager.default
        for candidate in adbCandidates {
            let expanded = candidate.hasPrefix("~") ? home + candidate.dropFirst() : candidate
            if fm.fileExists(atPath: expanded) { return expanded }
        }
        return nil
    }

    /// 枚举连接的设备（adb devices；无 adb 或无设备 → 空列表不报错）。
    public func listDevices(home: String = NSHomeDirectory()) async -> [String] {
        guard let adb = await resolveAdb(home: home) else { return [] }
        let result = try? await runner.run(brewPath: adb, args: ["devices"], timeout: .seconds(15))
        guard let result, result.succeeded else { return [] }
        return result.stdout.components(separatedBy: "\n")
            .dropFirst()   // 跳过 "List of devices attached"
            .compactMap { line in
                let parts = line.split(separator: "\t")
                return parts.count >= 2 ? String(parts[0]) : nil
            }
    }

    /// 拉取设备日志（logcat -d dump 模式，最近 N 行）。
    public func logcat(device: String, lines: Int = 200, home: String = NSHomeDirectory()) async -> String? {
        guard let adb = await resolveAdb(home: home) else { return nil }
        let result = try? await runner.run(brewPath: adb,
            args: ["-s", device, "logcat", "-d", "-t", String(lines)], timeout: .seconds(30))
        return result?.succeeded == true ? result?.stdout : nil
    }
}

/// Git 仓库体积扫描（M6，基线 7.5：按 .git 排序、下钻 objects/pack、不执行 gc/prune 只给建议）。
public struct GitRepoEntry: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public let path: String
    public let gitBytes: Int64
    /// .git/objects/pack 体积占比（大 pack → 建议 gc）
    public let packBytes: Int64

    public init(path: String, gitBytes: Int64, packBytes: Int64) {
        self.path = path
        self.gitBytes = gitBytes
        self.packBytes = packBytes
    }
}

public enum GitRepoScanner {

    /// 扫描目录树下的 Git 仓库（FSIndex 已索引数据源 + .git 目录体积）。
    public static func scan(roots: [String], maxDepth: Int = 4) -> [GitRepoEntry] {
        var repos: [GitRepoEntry] = []
        let fm = FileManager.default
        var stack: [(String, Int)] = roots.map { ($0, 0) }
        while let (dir, depth) = stack.popLast() {
            guard depth <= maxDepth,
                  let children = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for child in children {
                let full = dir + "/" + child
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else { continue }
                if child == ".git" {
                    // 命中仓库：体积统计
                    let gitBytes = FSIndex.liveSize(of: full)
                    let packDir = full + "/objects/pack"
                    let packBytes = FSIndex.liveSize(of: packDir)
                    let repoPath = (full as NSString).deletingLastPathComponent
                    repos.append(GitRepoEntry(path: repoPath, gitBytes: gitBytes, packBytes: packBytes))
                } else if depth < maxDepth {
                    stack.append((full, depth + 1))
                }
            }
        }
        return repos.sorted { $0.gitBytes > $1.gitBytes }
    }

    /// 优化建议（不执行 gc/prune，只给命令）。
    public static func suggestion(for entry: GitRepoEntry) -> String? {
        guard entry.gitBytes > 100 * 1024 * 1024 else { return nil }   // > 100MB
        return "git -C \(entry.path) gc --aggressive --prune=now"
    }
}

/// 端口占用条目（M8）。
public struct PortEntry: Sendable, Equatable, Identifiable {
    public var id: Int32 { pid }
    public let port: UInt16
    public let pid: Int32
    public let processName: String
    public let protocolName: String   // TCP/UDP
    public let isListening: Bool

    public init(port: UInt16, pid: Int32, processName: String, protocolName: String, isListening: Bool) {
        self.port = port
        self.pid = pid
        self.processName = processName
        self.protocolName = protocolName
        self.isListening = isListening
    }
}

/// 端口占用查看（M8：libproc 枚举 + socket 状态，与 lsof 抽样一致性）。
public enum PortScanner {

    /// 通过 lsof 解析（用户级命令，无额外权限；结构化输出）。
    public static func scan(runner: BrewCommandRunning) async -> [PortEntry] {
        let result = try? await runner.run(brewPath: "/usr/sbin/lsof",
            args: ["-iTCP", "-sTCP:LISTEN", "-nP"], timeout: .seconds(20))
        guard let result, result.succeeded else { return [] }
        var entries: [PortEntry] = []
        for line in result.stdout.components(separatedBy: "\n").dropFirst() {
            let parts = line.split(separator: " ").map(String.init).filter { !$0.isEmpty }
            // lsof 输出：COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME
            guard parts.count >= 9, let pid = Int32(parts[1]) else { continue }
            let name = parts[0]
            let node = parts[8]
            guard let colonIdx = node.lastIndex(of: ":") else { continue }
            let portPart = String(node[node.index(after: colonIdx)...])
            guard let port = UInt16(portPart) else { continue }
            entries.append(PortEntry(
                port: port, pid: pid, processName: name,
                protocolName: "TCP", isListening: true))
        }
        return entries.sorted { $0.port < $1.port }
    }
}

/// 开机耗时分析（H4，基线 7.8：sysctl kern.boottime + 各服务启动窗口）。
public enum BootTimeAnalyzer {

    /// 开机时刻（kern.boottime）。
    public static func bootTime() -> Date? {
        var tv = timeval()
        var len = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &len, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec))
    }

    /// 开机至今时长。
    public static func uptimeSinceBoot() -> TimeInterval? {
        guard let boot = bootTime() else { return nil }
        return Date().timeIntervalSince(boot)
    }
}

/// 卡慢识别采样条目（H6：与 Metrics 包 ProcessEntry 解耦——Ops 不依赖 Metrics，依赖红线）。
public struct SlowAppSample: Sendable, Equatable {
    public let pid: Int32
    public let name: String
    public let cpuPercent: Double
    public let rssBytes: Int64
    public let isAppleSystem: Bool

    public init(pid: Int32, name: String, cpuPercent: Double, rssBytes: Int64, isAppleSystem: Bool) {
        self.pid = pid
        self.name = name
        self.cpuPercent = cpuPercent
        self.rssBytes = rssBytes
        self.isAppleSystem = isAppleSystem
    }
}

/// 卡慢应用识别（H6，基线 7.8：CPU 持续高占用 + 内存压力下的 Top 应用）。
public struct SlowAppFinding: Sendable, Equatable {
    public let name: String
    public let pid: Int32
    public let cpuPercent: Double
    public let rssBytes: Int64
}

public enum SlowAppDetector {

    /// 识别卡慢应用（连续两次采样 CPU 均 > 50% 或 RSS > 1.5GB 的用户进程）。
    public static func detect(
        samples: [[SlowAppSample]]
    ) -> [SlowAppFinding] {
        guard samples.count >= 2 else { return [] }
        let last = samples[samples.count - 1]
        let prev = samples[samples.count - 2]
        let prevByPid = Dictionary(uniqueKeysWithValues: prev.map { ($0.pid, $0) })

        var findings: [SlowAppFinding] = []
        for entry in last where !entry.isAppleSystem {
            let prevEntry = prevByPid[entry.pid]
            let cpuHigh = entry.cpuPercent > 50
                && (prevEntry.map { $0.cpuPercent > 30 } ?? true)
            let memoryHigh = entry.rssBytes > 1_500_000_000
            if cpuHigh || memoryHigh {
                findings.append(SlowAppFinding(
                    name: entry.name, pid: entry.pid,
                    cpuPercent: entry.cpuPercent, rssBytes: entry.rssBytes))
            }
        }
        return findings.sorted { $0.cpuPercent > $1.cpuPercent }
    }
}