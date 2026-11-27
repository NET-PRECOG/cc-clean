import Testing
import Foundation
import CcCleanCore
@testable import CcCleanPrivileged

/// Helper 侧路径校验恶意用例（基线 S9-2 验收：20 例全拒，覆盖率 ≥ 85%）。
@Suite("HelperPathValidator 恶意路径防御")
struct HelperPathValidatorTests {

    let validator = HelperPathValidator()

    // MARK: - 批量删除路径（六道关）

    @Test("20 例恶意路径全拒")
    func maliciousPathsRejected() {
        let home = NSHomeDirectory()
        let malicious: [String] = [
            // ① 非绝对路径
            "relative/path",
            "~/Library/Trash",
            // ② 含 ..
            "/Users/x/../y",
            "/Applications/../../etc",
            "/tmp/a..b/c",                      // 含 .. 字面量（规则从严）
            // ③ 通配符
            "/Applications/*.app",
            "/tmp/da?mon",
            "/Library/Ext[en]sions",
            // ④ 保护路径（系统卷）
            "/System/Library/CoreServices",
            "/usr/bin/true",
            "/bin/ls",
            "/sbin/mount",
            "/private/var/folders/x/T/f",
            "/Library/Extensions/kext.kext",
            // ⑤ 保护路径（bundleId 前缀段）
            "/Users/x/Library/Caches/com.apple.Safari",
            "/Users/x/Library/Containers/system.cached",
            // ⑥ 保护路径（exact，home 与 validator 一致）
            "\(home)/Library/Keychains",
            // ⑦ ~ 展开 + .. 组合（符号链接逃逸的 realpath 复核由 symlinkEscape 专测覆盖）
            "~/Library/../Library/Keychains",
        ]
        var rejected = 0
        for path in malicious {
            let errors = validator.validatePath(path)
            if errors.isEmpty {
                print("DEBUG leak: \(path)")
            } else {
                rejected += 1
            }
            #expect(!errors.isEmpty, "恶意路径未被拒: \(path) → \(errors)")
        }
        #expect(rejected == malicious.count)
    }

    @Test("合法路径放行：用户级残留目标")
    func legitPathsAllowed() {
        let home = NSHomeDirectory()
        let legit = [
            "/Applications/Demo.app",
            "\(home)/Library/Caches/com.vendor.demo",
            "/Library/Application Support/VendorApp",
            "/Library/LaunchDaemons/com.vendor.helper.plist",
        ]
        for path in legit {
            let errors = validator.validatePath(path)
            #expect(errors.isEmpty, "合法路径被误拒: \(path) → \(errors)")
        }
    }

    @Test("符号链接逃逸：realpath 复核拦截")
    func symlinkEscape() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hlpv-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try "x".data(using: .utf8)!.write(to: target.appendingPathComponent("file"))

        let errors = validator.validatePath(link.path + "/file")
        #expect(errors.contains { $0 == .realpathMismatch(link.path + "/file") })
    }

    @Test("批量限制：空列表 / 超 500 条")
    func batchLimits() {
        #expect(validator.validateBatch([]).contains(.emptyPaths))
        let tooMany = Array(repeating: "/Applications/X.app", count: HelperConstants.maxBatchPaths + 1)
        #expect(validator.validateBatch(tooMany).contains { $0 == .batchTooLarge(count: tooMany.count) })
        #expect(validator.validateBatch(Array(repeating: "/Applications/X.app", count: 10)).isEmpty)
    }

    // MARK: - 命令白名单

    @Test("非白名单可执行文件拒绝")
    func commandWhitelist() {
        #expect(!validator.validateCommand(executable: "/bin/rm", args: []).isEmpty)
        #expect(!validator.validateCommand(executable: "/usr/bin/curl", args: ["evil.com"]).isEmpty)
        #expect(validator.validateCommand(executable: "/usr/sbin/pkgutil", args: ["--forget", "x"]).isEmpty)
        #expect(validator.validateCommand(executable: "/bin/launchctl", args: ["bootout", "system/x"]).isEmpty)
    }

    @Test("tccutil reset All 硬禁（代码级，基线 10.4）")
    func tccResetAllForbidden() {
        #expect(validator.validateCommand(
            executable: "/usr/bin/tccutil", args: ["reset", "All"]
        ).contains(.forbiddenResetAll))
        #expect(validator.validateCommand(
            executable: "/usr/bin/tccutil", args: ["reset", "kTCCServiceCamera"]
        ).isEmpty)
        // resetTCC 请求路径同样硬禁
        #expect(validator.validateTCC(bundleID: "com.x", services: ["All"]).contains(.forbiddenResetAll))
        #expect(validator.validateTCC(bundleID: "com.x", services: ["kTCCServiceCamera"]).isEmpty)
    }

    // MARK: - 完整请求校验

    @Test("完整请求分派校验")
    func requestValidation() {
        let bad = HelperRequest(
            journalID: "j1", action: .removeItems,
            paths: ["../escape"]
        )
        #expect(!validator.validate(bad).isEmpty)

        let good = HelperRequest(
            journalID: "j1", action: .removeItems,
            paths: ["/Applications/Demo.app", "/Library/Application Support/Demo"]
        )
        #expect(validator.validate(good).isEmpty)

        let receipt = HelperRequest(journalID: "j1", action: .forgetReceipts, pkgIDs: [])
        #expect(validator.validate(receipt).contains(.emptyPaths))
    }
}