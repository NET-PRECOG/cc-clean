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
    /// - Returns: cycles = 循环次数；healthPercent = NominalChargeCapacity/DesignCapacity × 100
    ///   （新版 macOS 顶层 MaxCapacity 已改为百分比，容量明细移入 BatteryData 字典）。
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
        guard let cycles = property("CycleCount") else { return nil }
        // 优先 BatteryData 字典（NominalChargeCapacity/DesignCapacity，与系统报告口径一致）
        var healthPercent: Double?
        if let unmanaged = IORegistryEntryCreateCFProperty(
            entry, "BatteryData" as CFString, kCFAllocatorDefault, 0),
           let dict = unmanaged.takeRetainedValue() as? [String: Any],
           let nominal = dict["NominalChargeCapacity"] as? Int, nominal > 0,
           let design = dict["DesignCapacity"] as? Int, design > 0 {
            healthPercent = Double(nominal) / Double(design) * 100
        }
        // 降级：顶层 MaxCapacity（新版为 0~100 百分比）
        if healthPercent == nil, let maxPct = property("MaxCapacity"), maxPct > 0, maxPct <= 100 {
            healthPercent = Double(maxPct)
        }
        guard let healthPercent else { return nil }
        return (cycles, healthPercent)
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

        // 风扇数量（FNum，ui8/ui16）
        guard let numData = smcReadKey("FNum", connect: connect), let rawCount = numData.first,
              rawCount > 0, rawCount <= 4 else { return [] }
        let fanCount = Int(rawCount)

        var readings: [FanReading] = []
        for index in 0..<fanCount {
            let key = String(format: "F%dAc", index)
            if let full = smcReadFull(key, connect: connect) {
                // 转速按 dataType 解析：'flt '（M 系新固件 4 字节 IEEE float 小端）/
                // fpe2（老固件定点 /4）/ ui16 / ui8
                let type = smcTypeString(full.dataType)
                let b = full.bytes
                let raw16 = b.count >= 2 ? UInt16(b[0]) << 8 | UInt16(b[1]) : 0
                let rpm: Double
                switch type {
                case "flt " where b.count >= 4:
                    let bits = UInt32(b[0]) | UInt32(b[1]) << 8
                        | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
                    rpm = Double(Float(bitPattern: bits))
                case "fpe2" where b.count >= 2:
                    rpm = Double(raw16) / 4.0
                case "ui16" where b.count >= 2:
                    rpm = Double(raw16)
                case "ui8" where b.count >= 1:
                    rpm = Double(b[0])
                default:
                    continue   // 未知类型不伪造（基线 6.4）
                }
                guard rpm >= 0, rpm.isFinite else { continue }
                // 风扇名（F*nID，32 字节 ASCII，去零与空白；部分机型无此键）
                var name: String?
                if let idData = smcReadKey(String(format: "F%dID", index), connect: connect) {
                    let bytes = idData.prefix(while: { $0 != 0 }).filter { $0 != 0 }
                    let text = String(bytes: bytes, encoding: .ascii)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if let text, !text.isEmpty { name = text }
                }
                readings.append(FanReading(index: index, rpm: rpm, name: name))
            }
        }
        return readings
    }

    // MARK: SMC 底层（用户态 AppleSMC 连接；布局逐字节对齐 osx-cpu-temp 的 SMCKeyData_t
    // （C 布局 sizeof=80）——Swift 自动布局曾产出 76B/偏移漂移，故手动按 C 偏移构造缓冲）

    /// SMC user client 调用（统一 selector 2；op=9 READ_KEYINFO / op=5 READ_BYTES）。
    /// C 偏移（已验证）：key@0-3、keyInfo.dataSize@28、dataType@32、result@40、status@41、op@42、data@48-79。
    /// 字段均为小端（ARM64/x64）；key 以 UInt32 小端写入（大端逐字节写会读到反序键名 → keyinfo not found）。
    private static func smcCall(
        key: UInt32, op: UInt8, dataSize: UInt32, connect: io_connect_t
    ) -> (result: UInt8, dataSize: UInt32, dataType: UInt32, bytes: [UInt8])? {
        var input = [UInt8](repeating: 0, count: 80)
        withUnsafeBytes(of: key.littleEndian) {                 // key @0-3（小端）
            for (i, b) in $0.prefix(4).enumerated() { input[i] = b }
        }
        withUnsafeBytes(of: dataSize.littleEndian) {            // keyInfo.dataSize @28（小端）
            for (i, b) in $0.prefix(4).enumerated() { input[28 + i] = b }
        }
        input[42] = op                                          // data8 命令字 @42
        var output = [UInt8](repeating: 0, count: 80)
        let inSize = 80
        var outSize = 80
        let kr = input.withUnsafeMutableBufferPointer { inPtr in
            output.withUnsafeMutableBufferPointer { outPtr in
                IOConnectCallStructMethod(
                    connect, 2, inPtr.baseAddress!, inSize,
                    outPtr.baseAddress!, &outSize)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        func leU32(_ offset: Int) -> UInt32 {
            UInt32(output[offset]) | UInt32(output[offset + 1]) << 8
                | UInt32(output[offset + 2]) << 16 | UInt32(output[offset + 3]) << 24
        }
        return (output[40], leU32(28), leU32(32), Array(output[48...79]))
    }

    /// 读取 SMC 键（两步：op=9 获取真实 dataSize → op=5 按真实大小读）。
    private static func smcReadFull(
        _ key: String, connect: io_connect_t
    ) -> (dataSize: UInt32, dataType: UInt32, bytes: [UInt8])? {
        let chars = Array(key.utf8.prefix(4))
        guard chars.count == 4 else { return nil }
        let keyUint = (UInt32(chars[0]) << 24) | (UInt32(chars[1]) << 16)
            | (UInt32(chars[2]) << 8) | UInt32(chars[3])
        // ① keyinfo（op=9）
        let info = smcCall(key: keyUint, op: 9, dataSize: 0, connect: connect)
        guard let info, info.result == 0 else { return nil }   // result≠0：键不存在等，优雅降级
        let dataSize = min(info.dataSize, 32)
        guard dataSize > 0 else { return nil }
        // ② read（op=5，按真实 dataSize）
        let read = smcCall(key: keyUint, op: 5, dataSize: dataSize, connect: connect)
        guard let read, read.result == 0 else { return nil }
        // dataType 取 keyinfo 阶段输出（op=5 输出不含 dataType）
        return (dataSize, info.dataType, Array(read.bytes.prefix(Int(dataSize))))
    }

    /// SMC 类型码 → ASCII（如 'fpe2'/'ui16'/'sp78'）。
    private static func smcTypeString(_ type: UInt32) -> String {
        let chars = [UInt8(type >> 24 & 0xFF), UInt8(type >> 16 & 0xFF),
                     UInt8(type >> 8 & 0xFF), UInt8(type & 0xFF)].filter { $0 != 0 }
        return String(bytes: chars, encoding: .ascii) ?? ""
    }

    /// SMC 诊断（@testable 实测各键 keyinfo/read 原始结果）。
    static func smcDiagnostic(
        _ keys: [String]
    ) -> [(key: String, dataSize: UInt32, dataType: String, bytes: [UInt8])] {

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return [] }
        defer { IOObjectRelease(service) }
        var connect: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connect) == KERN_SUCCESS else { return [] }
        defer { IOServiceClose(connect) }
        return keys.map { key in
            guard let full = smcReadFull(key, connect: connect) else {
                return (key, 0, "", [])
            }
            let type = smcTypeString(full.dataType)
            print("SMC_STEP \(key): size=\(full.dataSize) type='\(type)' bytes=\(full.bytes)")
            return (key, full.dataSize, type, full.bytes)
        }
    }

    /// 读取 SMC 键原始字节（两步协议封装，失败 nil 优雅降级）。
    private static func smcReadKey(_ key: String, connect: io_connect_t) -> [UInt8]? {
        smcReadFull(key, connect: connect)?.bytes
    }
}
