import Testing
@testable import CcCleanFS

/// S1 起由真实测试替换（任务拆解 S1-6 fixture 体系）。
@Suite("CcCleanFS Smoke")
struct SmokeTests {
    @Test("包骨架可链接")
    func links() {
        #expect(CcCleanFSInfo.moduleName == "CcCleanFS")
    }
}