import Foundation
import IOKit
import IOKit.ps
import CcCleanCore

/// 网络接口详情（E7，基线 7.8）。
public struct NetworkInterfaceInfo: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let address: String?
    public let isUp: Bool
}

/// 电池健康（E9，基线 7.8：IOPowerSources 循环次数不可读，用 CycleCount 近似不可得——
/// macOS 公开 API 无循环次数，提供电量/电源状态/充电中；循环数需私有 API，声明边界）。
public struct BatteryHealthInfo: Sendable, Equatable {
    public let percent: Double          // 0~100
    public let isCharging: Bool
    public let usingAC: Bool
    /// 电池时间估算（秒；AC 供电时 nil）
    public let timeToEmptySeconds: Int?
}

/// 硬件信息面板（E11，基线 7.8：sysctl 公开数据）。
public struct HardwarePanelInfo: Sendable, Equatable {
    public let machineModel: String      // hw.model
    public let cpuBrand: String          // machdep.cpu.brand_string
    public let cpuCoreCount: Int         // hw.ncpu
    public let physicalMemory: UInt64    // hw.memsize
    public let osVersion: String
}

/// 系统信息服务（E7/E9/E11/E15，基线 7.8：全部公开 API，无私有框架）。
public actor SystemInfoService {

    private let runner = ProcessRunner()
    private let logger: Logger

    public init(logger: Logger) {
        self.logger = logger
    }

    // MARK: - E7 网络详情

    /// 网络接口枚举（getifaddrs；IPv4 地址 + 状态）。
    public func networkInterfaces() -> [NetworkInterfaceInfo] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        var results: [NetworkInterfaceInfo] = []
        var seen = Set<String>()
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let ifa = current.pointee
            if let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                var addr = sockaddr_in()
                memcpy(&addr, sa, MemoryLayout<sockaddr_in>.size)
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let name = String(cString: ifa.ifa_name)
                if getnameinfo(
                    sa, socklen_t(sa.pointee.sa_len), &hostname, socklen_t(hostname.count),
                    nil, 0, NI_NUMERICHOST) == 0 {
                    let address = String(cString: hostname)
                    let isUp = (ifa.ifa_flags & UInt32(IFF_UP)) != 0
                    if seen.insert(name).inserted {
                        results.append(NetworkInterfaceInfo(
                            name: name, address: address, isUp: isUp))
                    }
                }
            }
            cursor = ifa.ifa_next
        }
        return results
    }

    // MARK: - E9 电池健康

    /// 电池信息（IOPSCopyPowerSourcesInfo；台式机返回空数组）。
    public func batteryHealth() -> BatteryHealthInfo? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            // Get 语义：描述字典是 snapshot 内部引用，调用方不拥有（takeRetainedValue 会过度释放，
            // 全量并发回归时 CFArrayReleaseValues 段错误——崩溃报告定位）
            guard let desc = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            guard let percent = desc[kIOPSCurrentCapacityKey] as? Double,
                  let maxCapacity = desc[kIOPSMaxCapacityKey] as? Double,
                  maxCapacity > 0 else { continue }
            let charging = (desc[kIOPSIsChargingKey] as? Bool) ?? false
            let powerSource = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue
            let timeToEmpty = (desc[kIOPSTimeToEmptyKey] as? Int)

            return BatteryHealthInfo(
                percent: percent / maxCapacity * 100,
                isCharging: charging,
                usingAC: !powerSource,
                timeToEmptySeconds: charging ? nil : timeToEmpty)
        }
        return nil
    }

    // MARK: - E11 硬件面板

    /// 硬件信息（sysctl 公开数据）。
    public func hardwarePanel() -> HardwarePanelInfo {
        func sysctlString(_ name: String) -> String {
            var size = 0
            sysctlbyname(name, nil, &size, nil, 0)
            guard size > 0 else { return "unknown" }
            var buffer = [CChar](repeating: 0, count: size)
            sysctlbyname(name, &buffer, &size, nil, 0)
            return String(cString: buffer)
        }

        var memsize: UInt64 = 0
        var len = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &memsize, &len, nil, 0)
        var ncpu: Int32 = 0
        var nlen = MemoryLayout<Int32>.size
        sysctlbyname("hw.ncpu", &ncpu, &nlen, nil, 0)

        return HardwarePanelInfo(
            machineModel: sysctlString("hw.model"),
            cpuBrand: sysctlString("machdep.cpu.brand_string"),
            cpuCoreCount: Int(ncpu),
            physicalMemory: memsize,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString)
    }

    // MARK: - E15 网络测速

    /// 网络测速（下载已知 URL 计时估算带宽；不依赖第三方服务，用可配置 URL）。
    /// - Parameter url: 测试下载地址（默认 Cloudflare speed test 100MB 文件的前 10MB range）
    public func speedTest(url: URL = URL(string: "https://speed.cloudflare.com/__down?bytes=10000000")!) async -> (mbps: Double, bytesDownloaded: Int64)? {
        let start = Date()
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("bytes=0-9999999", forHTTPHeaderField: "Range")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            let elapsed = Date().timeIntervalSince(start)
            guard elapsed > 0.1 else { return nil }
            let mbps = Double(data.count) * 8 / elapsed / 1_000_000
            return (mbps: mbps, bytesDownloaded: Int64(data.count))
        } catch {
            logger.error("speed test failed: \((error as NSError).localizedDescription)")
            return nil
        }
    }
}

/// E6 磁盘读写速率 + E8 蓝牙电量（独立类型封装——iostat/system_profiler 命令调用
/// 无 actor 隔离需求；基线 E6：POC-T5 降级口径）。
public enum DiskBluetoothService {

    /// 磁盘读写速率（`iostat -d -w 1 -c 2` 两次采样差分 → KB/s；iostat 不可用返回 nil）。
    public static func diskRates(runner: (String, [String], Duration) async throws -> ProcessResult) async -> (readKbs: Double, writeKbs: Double)? {
        let result = try? await runner("/usr/sbin/iostat", ["-d", "-w", "1", "-c", "2"], .seconds(15))
        guard let result, result.succeeded else { return nil }
        let dataLines = result.stdout.components(separatedBy: "\n")
            .filter { $0.contains("disk") && !$0.contains("KB/t") && !$0.contains("MB/s") }
        guard dataLines.count >= 2 else { return nil }
        let rows = dataLines.suffix(2).map { $0.split(separator: " ").map(String.init) }
        guard rows.count == 2, rows[0].count >= 3, rows[1].count >= 3,
              let readNow = Double(rows[1][1]), let writeNow = Double(rows[1][2]) else { return nil }
        return (readKbs: readNow, writeKbs: writeNow)
    }

    public struct BluetoothDevice: Sendable, Equatable, Identifiable {
        public var id: String { name }
        public let name: String
        public let batteryPercent: Int?

        public init(name: String, batteryPercent: Int?) {
            self.name = name
            self.batteryPercent = batteryPercent
        }
    }

    /// 蓝牙设备电量（system_profiler SPBluetoothDataType -json；无蓝牙设备返回空）。
    public static func bluetoothDevices(runner: (String, [String], Duration) async throws -> ProcessResult) async -> [BluetoothDevice] {
        let result = try? await runner("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"], .seconds(30))
        guard let result, result.succeeded,
              let json = try? JSONSerialization.jsonObject(with: result.stdout.data(using: .utf8) ?? Data())
                as? [String: Any],
              let bt = json["SPBluetoothDataType"] as? [String: Any] else { return [] }

        var devices: [BluetoothDevice] = []
        for containerKey in ["device_connected", "device_paired"] {
            guard let containers = bt[containerKey] as? [[String: Any]] else { continue }
            for container in containers {
                for (name, value) in container {
                    guard let info = value as? [String: Any] else { continue }
                    let level = (info["battery Level"] as? String)
                        ?? (info["battery_percent"] as? String)
                    var percent: Int?
                    if let level, let pct = Int(level.replacingOccurrences(of: "%", with: "")) {
                        percent = pct
                    }
                    devices.append(BluetoothDevice(name: name, batteryPercent: percent))
                }
            }
        }
        return devices
    }
}
// MARK: - 状态栏面板采集（GPU 核数 / 风扇 SMC / 电池循环健康，全部用户态公开通道）

/// 风扇读数（转速 RPM + SMC 名称，如 Left side/Right side）。
public struct FanReading: Sendable, Equatable {
    public let index: Int
    public let rpm: Double
    public let name: String?
}

/// 状态栏面板专用系统采集（独立 extension：SMC 用户态 + IORegistry，无特权要求）。
extension SystemInfoService {

    // MARK: GPU 核数

    /// GPU 核数（Apple Silicon AGXAccelerator 的 gpu-core-count；Intel/不可得 → nil）。
    public static func gpuCoreCount() -> Int? {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        // IORegistryEntryCreateCFProperty 返回 IUO——键不存在时为 nil，
        // 直接挂 takeRetainedValue 会在 nil 上强解包断言崩溃（EXC_BREAKPOINT，状态栏退出根因）
        guard let unmanaged = IORegistryEntryCreateCFProperty(
            entry, "gpu-core-count" as CFString, kCFAllocatorDefault, 0
        ), let raw = unmanaged.takeRetainedValue() as? Int else { return nil }
        return raw > 0 ? raw : nil
    }

    // MARK: 电池循环与健康度

    /// 电池循环次数与健康度（AppleSmartBattery IORegistry；无电池设备 → nil）。
    /// - Returns: cycles = 循环次数；healthPercent = MaxCapacity/DesignCapacity × 100。
    public static func batteryDetail() -> (cycles: Int, healthPercent: Double)? {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        func property(_ key: String) -> Int? {
            // Create 返回 Unmanaged<CFTypeRef>?——键不存在时为 nil，guard let 解包后才能 takeRetainedValue
            guard let unmanaged = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0) else {
                return nil
            }
            return unmanaged.takeRetainedValue() as? Int
        }
        guard let cycles = property("CycleCount"),
              let maxCapacity = property("MaxCapacity"),
              let designCapacity = property("DesignCapacity"),
              designCapacity > 0 else { return nil }
        return (cycles, Double(maxCapacity) / Double(designCapacity) * 100)
    }

    // MARK: 风扇（SMC 用户态）

    /// 风扇转速（SMC #NUMFAN + F0Ac/F1Ac…；AppleSMC 不可用或无键 → 空数组）。
    public static func fanReadings() -> [FanReading] {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return [] }
        defer { IOObjectRelease(service) }
        var connect: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connect) == KERN_SUCCESS else { return [] }
        defer { IOServiceClose(connect) }

        // 风扇数量（#NUMFAN，ui16 大端）
        guard let numData = smcReadKey("#NUMFAN", connect: connect), numData.count >= 2 else { return [] }
        let fanCount = Int(numData[0]) << 8 | Int(numData[1])
        guard fanCount > 0, fanCount <= 4 else { return [] }

        var readings: [FanReading] = []
        for index in 0..<fanCount {
            let key = String(format: "F%dAc", index)
            if let rpmData = smcReadKey(key, connect: connect), rpmData.count >= 2 {
                let raw = UInt16(rpmData[0]) << 8 | UInt16(rpmData[1])
                // 风扇名（F*nID，ch8* 32 字节 ASCII，去零与空白）
                var name: String?
                if let idData = smcReadKey(String(format: "F%dID", index), connect: connect) {
                    let bytes = idData.prefix(while: { $0 != 0 }).filter { $0 != 0 }
                    let text = String(bytes: bytes, encoding: .ascii)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if let text, !text.isEmpty { name = text }
                }
                readings.append(FanReading(index: index, rpm: Double(raw), name: name))
            }
        }
        return readings
    }

    // MARK: SMC 底层（用户态 AppleSMC 连接；结构布局与 osx-cpu-temp 开源实现同源，
    // 总大小 80 字节——内核 user client 按 80 字节写 output，缓冲小于该值会越界写破坏堆
    // （症状：调用成功但后续 malloc 报 POINTER_BEING_FREED_WAS_NOT_ALLOCATED））

    private struct SMCVersionStruct {
        var major: UInt16 = 0
        var minor: UInt16 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }   // 8B

    private struct SMCKeyInfoDataStruct {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }   // 9B（stride 12，对齐 4）

    private struct SMCParamStruct {
        var key: UInt32 = 0                    // 4
        var vers = SMCVersionStruct()          // 8
        var limits = SMCVersionStruct()        // 8
        var dataInfo = SMCKeyInfoDataStruct()  // 12
        var result: UInt32 = 0                 // 4
        var status: UInt8 = 0                  // 1
        var data: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                   UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                   UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                   UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
             0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)   // 32
        var op: UInt8 = 0                      // 1
        var reserved: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8) = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0)   // 补齐至 80
    }

    /// 读取 SMC 键原始字节（op=5 READ_KEY；失败 nil 优雅降级）。
    private static func smcReadKey(_ key: String, connect: io_connect_t) -> [UInt8]? {
        let chars = Array(key.utf8.prefix(4))
        guard chars.count == 4 else { return nil }
        var input = SMCParamStruct()
        var output = SMCParamStruct()
        input.key = (UInt32(chars[0]) << 24) | (UInt32(chars[1]) << 16)
            | (UInt32(chars[2]) << 8) | UInt32(chars[3])
        input.dataInfo.dataSize = 32
        input.op = 5
        var inputSize = MemoryLayout<SMCParamStruct>.stride
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        let kr = IOConnectCallStructMethod(
            connect, 1, &input, inputSize, &output, &outputSize)
        guard kr == KERN_SUCCESS, output.result == 0 else { return nil }
        return withUnsafeBytes(of: output.data) { Array($0) }
    }
}
