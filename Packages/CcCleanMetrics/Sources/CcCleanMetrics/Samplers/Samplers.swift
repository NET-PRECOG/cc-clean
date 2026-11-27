import Foundation
import Darwin
import CcCleanCore

/// CPU 与内存采样器（host_processor_info / host_statistics64，与活动监视器偏差 < 3% 目标）。
/// 差分状态实例持有（NSLock 保护；MetricsService actor 串行调用，锁为双保险）。
public final class CPUMemorySampler: MetricSampling, @unchecked Sendable {

    private let lock = NSLock()
    private var lastTicks: (cpu: [Int64], user: Int64, system: Int64, idle: Int64, nice: Int64)?

    public init() {}

    public func sample() async -> MetricBatch {
        // 同步方法内持锁（async 上下文禁 NSLock，Swift 6）
        sampleSync()
    }

    func sampleSync() -> MetricBatch {
        lock.lock(); defer { lock.unlock() }
        var samples: [MetricSampleValue] = []

        // CPU（总 + 逐核差分）
        if let cpu = Self.cpuUsage(current: lastTicks) {
            lastTicks = cpu.ticks
            samples.append(MetricSampleValue(kind: .cpuUsage, value: cpu.total))
            if let cores = cpu.perCore {
                let detail = (try? JSONEncoder().encode(cores))
                    .flatMap { String(data: $0, encoding: .utf8) }
                samples.append(MetricSampleValue(kind: .cpuPerCore, value: cpu.total, detail: detail))
            }
        }
        // 内存
        if let mem = Self.memoryStats() {
            samples.append(MetricSampleValue(kind: .memoryUsed, value: mem.usedBytes))
            samples.append(MetricSampleValue(kind: .memoryPressure, value: mem.pressureLevel))
            samples.append(MetricSampleValue(kind: .swapUsed, value: mem.swapBytes))
        }
        return MetricBatch(timestamp: Date(), samples: samples)
    }

    struct CPUResult {
        let total: Double          // 0~100
        let perCore: [Double]?
        let ticks: (cpu: [Int64], user: Int64, system: Int64, idle: Int64, nice: Int64)
    }

    /// host_processor_info 差分（与活动监视器同源）。
    static func cpuUsage(current last: (cpu: [Int64], user: Int64, system: Int64, idle: Int64, nice: Int64)?) -> CPUResult? {
        var processorCount: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var cpuInfoCount: mach_msg_type_number_t = 0
        guard host_processor_info(
            mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
            &processorCount, &cpuInfo, &cpuInfoCount
        ) == KERN_SUCCESS, let info = cpuInfo else { return nil }
        defer {
            let size = vm_size_t(cpuInfoCount) * vm_size_t(MemoryLayout<integer_t>.size)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), size)
        }

        var perCore: [Double] = []
        var ticks: [Int64] = []
        var totalSystem: Int64 = 0, totalUser: Int64 = 0, totalIdle: Int64 = 0, totalNice: Int64 = 0

        for core in 0..<Int(processorCount) {
            let offset = Int(CPU_STATE_MAX) * core
            let user = Int64(info[offset + Int(CPU_STATE_USER)])
            let system = Int64(info[offset + Int(CPU_STATE_SYSTEM)])
            let idle = Int64(info[offset + Int(CPU_STATE_IDLE)])
            let nice = Int64(info[offset + Int(CPU_STATE_NICE)])
            ticks += [user, system, idle, nice]
            totalUser += user; totalSystem += system; totalIdle += idle; totalNice += nice

            if let last, core * 4 + 3 < last.cpu.count {
                let dUser = user - last.cpu[core * 4]
                let dSystem = system - last.cpu[core * 4 + 1]
                let dIdle = idle - last.cpu[core * 4 + 2]
                let dNice = nice - last.cpu[core * 4 + 3]
                let delta = dUser + dSystem + dIdle + dNice
                perCore.append(delta > 0
                    ? min(max(Double(dUser + dSystem + dNice) / Double(delta) * 100, 0), 100)
                    : 0)
            } else {
                perCore.append(0)   // 首次采样无差分基线
            }
        }

        let dTotal = Double(totalUser + totalSystem + totalIdle + totalNice
            - (last.map { $0.user + $0.system + $0.idle + $0.nice } ?? 0))
        var usage: Double
        if let last, dTotal > 0 {
            let dUser = Double(totalUser - last.user)
            let dSystem = Double(totalSystem - last.system)
            let dNice = Double(totalNice - last.nice)
            usage = (dUser + dSystem + dNice) / dTotal * 100
        } else if last == nil {
            usage = Double(totalUser + totalSystem + totalNice)
                / Double(max(totalUser + totalSystem + totalIdle + totalNice, 1)) * 100
        } else {
            usage = 0
        }

        return CPUResult(
            total: min(max(usage, 0), 100),
            perCore: perCore,
            ticks: (cpu: ticks, user: totalUser, system: totalSystem, idle: totalIdle, nice: totalNice)
        )
    }

    // MARK: - 内存

    struct MemoryStats {
        let usedBytes: Double
        let pressureLevel: Double   // 1=normal 2=warning 3=critical
        let swapBytes: Double
    }

    static func memoryStats() -> MemoryStats? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<natural_t>.size)
        let host = mach_host_self()
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            host_statistics64(host, HOST_VM_INFO64,
                UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: integer_t.self), &count)
        }
        mach_port_deallocate(mach_task_self_, host)
        guard kr == KERN_SUCCESS else { return nil }

        let pageSize = UInt64(getpagesize())
        let used = (UInt64(stats.active_count) + UInt64(stats.wire_count)
            + UInt64(stats.compressor_page_count)) * pageSize

        // 内存压力近似：free 占比（POC-T4 真机校准 phys_memory_pressure 口径）
        let total = UInt64(stats.active_count + stats.free_count + stats.wire_count
            + stats.speculative_count + stats.purgeable_count + stats.external_page_count)
        let freeRatio = Double(stats.free_count) / Double(max(total, 1))
        let pressureLevel: Double = freeRatio < 0.05 ? 3 : (freeRatio < 0.15 ? 2 : 1)

        return MemoryStats(
            usedBytes: Double(used),
            pressureLevel: pressureLevel,
            swapBytes: swapUsageBytes() ?? 0
        )
    }

    /// E4：swap 实际使用量（sysctl vm.swapusage；解析失败 → nil 优雅降级）。
    static func swapUsageBytes() -> Double? {
        var size = 0
        sysctlbyname("vm.swapusage", nil, &size, nil, 0)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("vm.swapusage", &buffer, &size, nil, 0) == 0 else { return nil }
        return parseSwapUsage(String(cString: buffer))
    }

    /// 解析 "Swap usage: total = 2048.0M used = 512.0M free = 1536.0M (encrypted)"。
    static func parseSwapUsage(_ text: String) -> Double? {
        guard let usedRange = text.range(of: "used = ") else { return nil }
        let rest = text[usedRange.upperBound...]
        let token = rest.prefix(while: { !$0.isWhitespace })
        guard let value = Double(token.prefix(while: { $0.isNumber || $0 == "." })),
              value >= 0, !token.isEmpty else { return nil }
        let unit = token.drop(while: { $0.isNumber || $0 == "." }).first
        switch unit {
        case "G": return value * 1024 * 1024 * 1024
        case "K": return value * 1024
        case "T": return value * 1024 * 1024 * 1024 * 1024
        default: return value * 1024 * 1024
        }
    }
}

/// 网络与磁盘采样器（getifaddrs 差分；磁盘 IO 差分依赖 IOKit，POC-T5 后接入）。
public final class NetworkDiskSampler: MetricSampling, @unchecked Sendable {

    struct NetSnapshot: Equatable {
        let rxBytes: Int64
        let txBytes: Int64
        let at: Date
    }
    struct DiskSnapshot: Equatable {
        let readBytes: Int64
        let writeBytes: Int64
        let at: Date
    }

    private let lock = NSLock()
    private var lastNet: NetSnapshot?
    private var lastDisk: DiskSnapshot?

    public init() {}

    public func sample() async -> MetricBatch {
        // 同步方法内持锁（async 上下文禁 NSLock，Swift 6）
        sampleSync()
    }

    func sampleSync() -> MetricBatch {
        lock.lock(); defer { lock.unlock() }
        var samples: [MetricSampleValue] = []

        if let net = Self.networkRates(previous: lastNet) {
            lastNet = net.snapshot
            samples.append(MetricSampleValue(kind: .networkRx, value: net.rx))
            samples.append(MetricSampleValue(kind: .networkTx, value: net.tx))
        }
        if let disk = Self.diskRates(previous: lastDisk) {
            lastDisk = disk.snapshot
            samples.append(MetricSampleValue(kind: .diskRead, value: disk.read))
            samples.append(MetricSampleValue(kind: .diskWrite, value: disk.write))
        }
        return MetricBatch(timestamp: Date(), samples: samples)
    }

    /// getifaddrs 差分（排除 loopback）。
    static func networkRates(previous: NetSnapshot?) -> (rx: Double, tx: Double, snapshot: NetSnapshot)? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var rxTotal: Int64 = 0, txTotal: Int64 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let ifa = current.pointee
            if let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_LINK),
               String(cString: ifa.ifa_name) != "lo0",
               let dataPtr = ifa.ifa_data {
                let data = dataPtr.assumingMemoryBound(to: if_data.self)
                rxTotal += Int64(data.pointee.ifi_ibytes)
                txTotal += Int64(data.pointee.ifi_obytes)
            }
            cursor = ifa.ifa_next
        }
        let snapshot = NetSnapshot(rxBytes: rxTotal, txBytes: txTotal, at: Date())

        guard let previous else { return (0, 0, snapshot) }
        let elapsed = snapshot.at.timeIntervalSince(previous.at)
        guard elapsed > 0.1 else { return (0, 0, snapshot) }
        let rx = Double(max(rxTotal - previous.rxBytes, 0)) / elapsed
        let tx = Double(max(txTotal - previous.txBytes, 0)) / elapsed
        return (rx, tx, snapshot)
    }

    /// 磁盘 IO 差分：依赖 IOKit DLDiskStatistics（POC-T5 真机校准后接入），
    /// 当前返回 nil（E6 未启用时 UI 显示「本机型不支持」而非伪造数据，基线 6.4）。
    static func diskRates(previous: DiskSnapshot?) -> (read: Double, write: Double, snapshot: DiskSnapshot)? {
        nil
    }
}