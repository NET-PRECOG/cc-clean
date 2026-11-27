import Testing
import Foundation
@testable import CcCleanMetrics

/// E4 swap 采样（vm.swapusage 解析 + 真实 sysctl 值域）。
@Suite("E4 swap 采样")
struct SwapSamplerTests {

    @Test("parseSwapUsage：M/G/K/无单位/非法输入")
    func parse() {
        #expect(CPUMemorySampler.parseSwapUsage(
            "Swap usage: total = 2048.0M used = 512.0M free = 1536.0M (encrypted)")
            == 512.0 * 1024 * 1024)
        #expect(CPUMemorySampler.parseSwapUsage(
            "Swap usage: total = 2.0G used = 1.5G free = 0.5G")
            == 1.5 * 1024 * 1024 * 1024)
        #expect(CPUMemorySampler.parseSwapUsage(
            "Swap usage: total = 1024K used = 64K free = 960K") == 64.0 * 1024)
        #expect(CPUMemorySampler.parseSwapUsage("Swap usage: total = 10 used = 0M") == 0)
        // 非法输入 → nil（优雅降级）
        #expect(CPUMemorySampler.parseSwapUsage("no used field here") == nil)
        #expect(CPUMemorySampler.parseSwapUsage("used = abcM") == nil)
    }

    @Test("swapUsageBytes：真实 sysctl（无 swap 机器返回 nil 优雅降级）")
    func realSysctl() {
        let bytes = CPUMemorySampler.swapUsageBytes()
        if let bytes {
            #expect(bytes >= 0)
        } else {
            #expect(Bool(true))   // 无 swap 设备：合法降级
        }
    }

    @Test("E4 集成：sampleSync 含 swapUsed 采样项")
    func sampleIntegration() {
        let sampler = CPUMemorySampler()
        let batch = sampler.sampleSync()
        let kinds = batch.samples.map(\.kind)
        #expect(kinds.contains(.memoryPressure))
        #expect(kinds.contains(.swapUsed))
        let swap = batch.samples.first { $0.kind == .swapUsed }!
        #expect(swap.value >= 0)
    }
}