import Testing
import Foundation
import CcCleanCore
@testable import CcCleanMetrics

@Suite("SystemInfoService (E7/E9/E11/E15)")
struct SystemInfoServiceTests {

    let service = SystemInfoService(logger: Logger(category: .metrics, buffer: LogBuffer(capacity: 10)))

    @Test("E7 网络详情：接口枚举含 lo0 且地址有效")
    func networkInterfaces() async {
        let interfaces = await service.networkInterfaces()
        #expect(!interfaces.isEmpty)
        #expect(interfaces.contains { $0.name == "lo0" })
        #expect(interfaces.allSatisfy { $0.address?.isEmpty == false })
    }

    @Test("E9 电池健康：笔记本返回数据或台式机返回 nil（不伪造）")
    func batteryHealth() async {
        let info = await service.batteryHealth()
        if let info {
            #expect(info.percent >= 0 && info.percent <= 100)
        }
        // 台式机/无电池环境 nil 为合法结果（基线 6.4 优雅降级）
    }

    @Test("E11 硬件面板：sysctl 数据完整")
    func hardwarePanel() async {
        let info = await service.hardwarePanel()
        #expect(info.machineModel != "unknown")
        #expect(info.cpuCoreCount > 0)
        #expect(info.physicalMemory > 1_000_000_000)
    }

    @Test("E15 网络测速：真实下载计时（网络可用时返回带宽）")
    func speedTest() async {
        let result = await service.speedTest()
        if let result {
            #expect(result.mbps > 0)
            #expect(result.bytesDownloaded > 0)
        }
        // 网络不可用 → nil 为合法降级（基线 6.4）
    }
}