import Foundation
import CoreServices
import ApplicationServices
import ServiceManagement

/// Helper daemon 常量（Core 承载：CapabilityGate 探测与 Privileged 包共用）。
public enum HelperServiceInfo {
    /// SMAppService daemon 的 launchd plist 名（与 Helper target 注册一致）
    public static let daemonPlistName = "app.cclean.helper.plist"
    /// MachServiceName（与 Privileged 包 HelperConstants.machServiceName 一致）
    public static let machServiceName = "app.cclean.helper"
}

/// 全盘访问探测（基线 6.4 要点 1）：无官方 API，采用「读特定受保护路径」探测。
public struct FullDiskAccessProber: Sendable {

    public init() {}

    /// 候选探测路径：命中任一可读即视为已授权。
    static let probePaths = [
        "~/Library/Safari/History.db",
        "~/Library/Application Support/com.apple.TCC/TCC.db",
    ]

    public func isGranted() -> Bool {
        for template in Self.probePaths {
            let path = (template as NSString).expandingTildeInPath
            if FileManager.default.isReadableFile(atPath: path) {
                return true
            }
        }
        // 无网络沙盒限制的进程读不到以上文件也可能因为它们不存在；
        // 再用 /Library/Application Support 目录枚举能力兜底。
        return FileManager.default.isReadableFile(atPath: "/Library/Application Support")
    }
}

/// 真实探测器：全盘访问走受保护路径探测，其余能力走对应系统 API / 状态推断。
public struct SystemCapabilityProber: CapabilityProbing {

    let fullDiskAccessProber = FullDiskAccessProber()

    public init() {}

    public func probe(_ capability: Capability) async -> CapabilityStatus {
        switch capability {
        case .fullDiskAccess:
            return fullDiskAccessProber.isGranted()
                ? .granted
                : .denied(reason: "未授予全盘访问，/Library 与受保护目录不可读")

        case .privilegedHelper:
            // S10：SMAppService.daemon 真实探测（基线 6.4 privilegedHelper）
            let service = SMAppService.daemon(plistName: HelperServiceInfo.daemonPlistName)
            switch service.status {
            case .enabled:
                return .granted
            case .requiresApproval:
                return .denied(reason: "辅助程序待批准：请在系统设置的「登录项与扩展」中允许 CcClean Helper")
            case .notRegistered, .notFound:
                return .notDetermined
            @unknown default:
                return .notDetermined
            }

        case .automation:
            // 预检语义在 C6 调用目标处进行；此处返回未定（不主动弹窗，基线 6.4 要点 3）。
            return .notDetermined

        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .notDetermined

        case .notification:
            return .notDetermined   // UNUserNotificationCenter 状态由 App 层注入后替换

        case .networkExtension:
            return .notDetermined
        }
    }
}