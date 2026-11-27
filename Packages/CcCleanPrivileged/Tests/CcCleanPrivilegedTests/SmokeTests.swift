import Testing
@testable import CcCleanPrivileged

/// S9 起由真实测试替换（恶意路径 20 例：../通配符/保护路径/符号链接）。
@Suite("CcCleanPrivileged Smoke")
struct SmokeTests {
    @Test("包骨架可链接")
    func links() {
        #expect(CcCleanPrivilegedInfo.moduleName == "CcCleanPrivileged")
    }
}