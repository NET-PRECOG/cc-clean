import Testing
import Foundation
import CcCleanCore
@testable import CcCleanMetrics

/// 临时诊断：状态栏面板数据源真机实测（跑完即删）。
@Suite("Panel Diagnostics")
struct PanelDiagnosticsTests {

    @Test("① SMC 风扇实测")
    func fans() {
        let fans = SystemInfoService.fanReadings()
        print("FAN_DIAG: \(fans.count) 个风扇")
        for fan in fans {
            print("FAN_DIAG: idx=\(fan.index) rpm=\(fan.rpm) name=\(fan.name ?? "nil")")
        }
        if fans.isEmpty { print("FAN_DIAG: 空数组（SMC 读取失败）") }
    }

    @Test("② 电池循环/健康度实测")
    func battery() {
        guard let d = SystemInfoService.batteryDetail() else {
            print("BATT_DIAG: nil（AppleSmartBattery 读取失败）")
            return
        }
        print("BATT_DIAG: cycles=\(d.cycles) health=\(d.healthPercent)%")
    }

    @Test("③ GPU 核数实测")
    func gpu() {
        let g = SystemInfoService.gpuCoreCount()
        print("GPU_DIAG: \(g.map(String.init) ?? "nil")")
    }

    @Test("④ CPU/内存采样器实测（两次差分）")
    func cpuMem() async throws {
        let sampler = CPUMemorySampler()
        let first = await sampler.sample()
        try await Task.sleep(for: .seconds(1))
        let second = await sampler.sample()
        let cpu = second.samples.first { $0.kind == .cpuUsage }?.value ?? -1
        let mem = second.samples.first { $0.kind == .memoryUsed }?.value ?? -1
        print("CPU_DIAG: 首帧=\(first.samples.first { $0.kind == .cpuUsage }?.value ?? -1)% 二帧=\(cpu)%")
        print("MEM_DIAG: used=\(mem / 1_000_000_000)GB")
    }

    @Test("⑤ 网络采样器实测（两次差分）")
    func net() async throws {
        let sampler = NetworkDiskSampler()
        _ = await sampler.sample()
        try await Task.sleep(for: .seconds(2))
        let second = await sampler.sample()
        let rx = second.samples.first { $0.kind == .networkRx }?.value ?? -1
        let tx = second.samples.first { $0.kind == .networkTx }?.value ?? -1
        print("NET_DIAG: rx=\(rx)B/s tx=\(tx)B/s")
    }

    static func fanLabel(_ i: Int) -> String { String(i) }
}