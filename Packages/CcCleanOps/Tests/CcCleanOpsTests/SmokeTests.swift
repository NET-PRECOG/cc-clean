import Testing
@testable import CcCleanOps

/// S4 起由真实测试替换（OperationJournal / TrashService 单测）。
@Suite("CcCleanOps Smoke")
struct SmokeTests {
    @Test("包骨架可链接")
    func links() {
        #expect(CcCleanOpsInfo.moduleName == "CcCleanOps")
    }
}