import Testing
@testable import CcCleanMetrics

/// S12 起由真实测试替换（采样器与降采样单测）。
@Suite("CcCleanMetrics Smoke")
struct SmokeTests {
    @Test("包骨架可链接")
    func links() {
        #expect(CcCleanMetricsInfo.moduleName == "CcCleanMetrics")
    }
}