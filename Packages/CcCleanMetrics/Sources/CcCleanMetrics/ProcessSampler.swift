import Foundation
import Darwin
import CcCleanCore

/// 进程条目（E10 进程管理器数据源）。
public struct ProcessEntry: Sendable, Equatable, Identifiable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let name: String
    public let path: String?
    public let cpuPercent: Double      // 差分（0~100 单核口径，多核可 >100 归一）
    public let rssBytes: Int64         // 物理内存驻留
    /// 父进程 pid（树状视图；0 = 根）
    public let parentPid: Int32
    /// Apple 系统进程（结束需二次确认且仍拒绝，基线 E10 边界）
    public let isAppleSystem: Bool

    public init(
        pid: Int32, name: String, path: String?, cpuPercent: Double,
        rssBytes: Int64, parentPid: Int32, isAppleSystem: Bool
    ) {
        self.pid = pid
        self.name = name
        self.path = path
        self.cpuPercent = cpuPercent
        self.rssBytes = rssBytes
        self.parentPid = parentPid
        self.isAppleSystem = isAppleSystem
    }
}

/// 进程采样器（E10/E1 Top 5 数据源，libproc 枚举 + CPU 时间差分）。
/// 差分状态实例持有（NSLock 保护；与 CPUMemorySampler 同模式）。
public final class ProcessSampler: @unchecked Sendable {

    struct ProcTick {
        let userTime: Int64
        let systemTime: Int64
        let at: Date
    }

    private let lock = NSLock()
    private var lastTicks: [Int32: ProcTick] = [:]

    /// 单核归一系数（总 CPU% = Δtime/Δwalltime × 100；多核进程可 >100，展示时按核数归一可选）
    private let coreCount: Int

    public init() {
        self.coreCount = max(1, ProcessInfo.processInfo.activeProcessorCount)
    }

    /// 枚举全部进程并计算 CPU 差分。
    public func sample() -> [ProcessEntry] {
        lock.lock(); defer { lock.unlock() }

        let pids = listPids()
        var entries: [ProcessEntry] = []
        var currentTicks: [Int32: ProcTick] = [:]
        let now = Date()

        for pid in pids {
            guard let (name, path, rss, userTime, systemTime, ppid) = Self.procInfo(pid) else { continue }
            currentTicks[pid] = ProcTick(userTime: userTime, systemTime: systemTime, at: now)

            var cpuPercent = 0.0
            if let last = lastTicks[pid] {
                let dUser = userTime - last.userTime
                let dSystem = systemTime - last.systemTime
                let elapsed = now.timeIntervalSince(last.at)
                if elapsed > 0.05, dUser + dSystem >= 0 {
                    // CPU% = ΔCPU 时间 / Δ墙钟时间（单核口径 × 100）
                    cpuPercent = Double(dUser + dSystem) / elapsed / 100.0
                }
            }
            // Apple 系统进程判定（路径前缀）
            let isApple = path?.hasPrefix("/System/") == true
                || path?.hasPrefix("/usr/libexec/") == true
                || path?.hasPrefix("/sbin/") == true

            entries.append(ProcessEntry(
                pid: pid, name: name, path: path,
                cpuPercent: min(max(cpuPercent, 0), 100),
                rssBytes: rss, parentPid: ppid, isAppleSystem: isApple
            ))
        }
        lastTicks = currentTicks
        // CPU 排序降序（E10：能耗/CPU 排序）
        return entries.sorted { $0.cpuPercent > $1.cpuPercent }
    }

    /// Top N 进程（E1 菜单栏弹出面板）。
    public func topProcesses(_ count: Int = 5) -> [ProcessEntry] {
        Array(sample().prefix(count))
    }

    // MARK: - libproc

    private func listPids() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 16)
        let actual = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard actual > 0 else { return [] }
        return Array(pids.prefix(Int(actual)).filter { $0 > 0 })
    }

    /// proc_pidinfo 提取进程信息（已退出的进程返回 nil）。
    static func procInfo(_ pid: Int32) -> (name: String, path: String?, rss: Int64, user: Int64, system: Int64, ppid: Int32)? {
        // 名称与路径
        var nameBuffer = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN))
        proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        let rawName = String(cString: nameBuffer, encoding: .utf8) ?? ""

        var pathBuffer = [CChar](repeating: 0, count: 4096)
        let pathLen = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        let path = pathLen > 0 ? String(cString: pathBuffer, encoding: .utf8) : nil

        // task info（CPU 时间 + RSS）
        var taskInfo = proc_taskinfo()
        let taskResult = proc_pidinfo(
            pid, PROC_PIDTASKINFO, 0, &taskInfo, Int32(MemoryLayout<proc_taskinfo>.size)
        )
        guard taskResult == Int32(MemoryLayout<proc_taskinfo>.size) else { return nil }

        // 父进程
        var ppidInfo = proc_bsdinfo()
        let ppidResult = proc_pidinfo(
            pid, PROC_PIDTBSDINFO, 0, &ppidInfo, Int32(MemoryLayout<proc_bsdinfo>.size)
        )
        let ppid = ppidResult == Int32(MemoryLayout<proc_bsdinfo>.size) ? Int32(bitPattern: UInt32(ppidInfo.pbi_ppid)) : 0

        let displayName = !rawName.isEmpty
            ? rawName
            : (path.map { ($0 as NSString).lastPathComponent } ?? "pid-\(pid)")

        return (
            name: displayName,
            path: path,
            rss: Int64(taskInfo.pti_resident_size),
            user: Int64(taskInfo.pti_total_user),
            system: Int64(taskInfo.pti_total_system),
            ppid: ppid
        )
    }
}