import Foundation
import AppKit
import CcCleanCore

/// 三级强制结束进程（C6，基线 7.3 算法 8）：
/// terminate()（优雅，需 Automation）→ 3s → SIGTERM → 2s → SIGKILL；
/// 无 Automation 权限降级为 SIGTERM（基线 6.4 降级映射）；结束失败进报告。
public actor ProcessTerminator {

    public enum Capability: Sendable {
        case full           // 有 Automation：terminate() → SIGTERM → SIGKILL
        case noAutomation   // 无 Automation：直接 SIGTERM → SIGKILL
    }

    private let capability: Capability

    public init(capability: Capability = .full) {
        self.capability = capability
    }

    /// 结束某 bundlePath 下全部进程。返回 [路径: 错误]（空 = 全部成功）。
    public func terminate(bundlePath: String) async -> [String: String] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: bundlePath) else {
            return [bundlePath: "应用路径不存在"]
        }
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            app.bundleURL?.path.hasPrefix(bundlePath) == true
                || app.executableURL?.path.hasPrefix(bundlePath) == true
        }
        var failures: [String: String] = [:]
        if apps.isEmpty { return failures }

        // 第一级：优雅退出（Apple Event，需 Automation 权限）
        if capability == .full {
            for app in apps where !app.isTerminated && app.processIdentifier > 0 {
                app.terminate()
            }
            if await waitForExit(apps, timeout: 3) { return failures }
        }

        // 第二级：SIGTERM（3s 或无 Automation 后）
        for app in apps where !app.isTerminated && app.processIdentifier > 0 {
            kill(app.processIdentifier, SIGTERM)
        }
        if await waitForExit(apps, timeout: 2) { return failures }

        // 第三级：SIGKILL（2s 后仍存活）
        for app in apps where !app.isTerminated && app.processIdentifier > 0 {
            kill(app.processIdentifier, SIGKILL)
        }
        if await waitForExit(apps, timeout: 2) { return failures }

        for app in apps where !app.isTerminated && app.processIdentifier > 0 {
            failures[app.bundleURL?.path ?? bundlePath] = "进程 \(app.processIdentifier) 结束失败（可能被 launchd 自动重启，需先 bootout）"
        }
        return failures
    }

    /// 等待全部进程退出。
    private func waitForExit(_ apps: [NSRunningApplication], timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if apps.allSatisfy({ !$0.isTerminated && $0.processIdentifier > 0 }) {
                // 再确认一轮（isTerminating 可能滞后）
                try? await Task.sleep(for: .milliseconds(200))
                return apps.allSatisfy { !$0.isTerminated && $0.processIdentifier > 0 }
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return apps.allSatisfy { !$0.isTerminated && $0.processIdentifier > 0 }
    }
}