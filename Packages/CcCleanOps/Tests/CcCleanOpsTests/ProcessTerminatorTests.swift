import Testing
import Foundation
import CcCleanCore
@testable import CcCleanOps

@Suite("ProcessTerminator (C6)")
struct ProcessTerminatorTests {

    @Test("应用路径不存在：返回失败原因")
    func missingPath() async {
        let terminator = ProcessTerminator()
        let failures = await terminator.terminate(bundlePath: "/nonexistent-app-\(UUID().uuidString)")
        #expect(failures.count == 1)
        #expect(failures.values.first?.contains("不存在") == true)
    }

    @Test("无运行进程：返回空 failures（成功）")
    func noRunningProcess() async throws {
        // 构造一个真实存在但未运行的 .app 路径
        let app = FileManager.default.temporaryDirectory
            .appendingPathComponent("term-test-\(UUID().uuidString).app/Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try "bin".data(using: .utf8)!.write(to: app.appendingPathComponent("Bin"))
        let bundlePath = (app.path as NSString).deletingLastPathComponent
        defer { try? FileManager.default.removeItem(atPath: bundlePath) }

        let terminator = ProcessTerminator()
        let failures = await terminator.terminate(bundlePath: bundlePath)
        #expect(failures.isEmpty)
    }

    @Test("三级顺序规格：noAutomation 跳过优雅退出直接 SIGTERM")
    func noAutomationPath() async throws {
        let app = FileManager.default.temporaryDirectory
            .appendingPathComponent("term-na-\(UUID().uuidString).app/Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let bundlePath = (app.path as NSString).deletingLastPathComponent
        defer { try? FileManager.default.removeItem(atPath: bundlePath) }

        let terminator = ProcessTerminator(capability: .noAutomation)
        let start = Date()
        let failures = await terminator.terminate(bundlePath: bundlePath)
        // 无运行进程 → 快速返回（无 3s 优雅等待）
        #expect(failures.isEmpty)
        #expect(Date().timeIntervalSince(start) < 2)
    }
}