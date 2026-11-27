import Foundation
import AppKit

/// 权限能力项（基线 6.4）。
public enum Capability: String, CaseIterable, Sendable, Codable {
    case fullDiskAccess       // 读 /Library、~/.Trash、其他用户目录、TCC.db 等
    case privilegedHelper     // root 操作
    case automation           // Apple Events 优雅退出
    case accessibility        // 进程窗口/能耗细节
    case notification         // 告警通知
    case networkExtension     // I5 分应用连接监控
}

/// 能力状态。
public enum CapabilityStatus: Sendable, Equatable {
    case granted
    case denied(reason: String)
    case notDetermined
    case unsupported(reason: String)   // 如 Intel Mac 无某传感器、无相关硬件
}

/// 降级策略（基线 6.4 降级映射表一一对应）。
public struct Degradation: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case full
        case partial(String)
        case unavailable(String)
    }
    public let kind: Kind

    public static let full = Degradation(kind: .full)
    public static func partial(_ desc: String) -> Degradation { .init(kind: .partial(desc)) }
    public static func unavailable(_ desc: String) -> Degradation { .init(kind: .unavailable(desc)) }
}

public struct CapabilityResolution: Sendable, Equatable {
    public let status: CapabilityStatus
    public let degradation: Degradation
    /// 系统设置直达 URL（如全盘访问页）。
    public let guideURL: URL?
}

public struct CapabilitySnapshot: Sendable, Equatable {
    public let statuses: [Capability: CapabilityStatus]
    public let probedAt: Date
    public var missing: [Capability] {
        // 按 allCases 固定顺序输出，保证 UI 展示与断言稳定
        Capability.allCases.filter { capability in
            guard let status = statuses[capability] else { return false }
            switch status {
            case .granted, .unsupported: return false
            case .denied, .notDetermined: return true
            }
        }
    }
}

/// 能力探测器协议：真实实现走系统 API，单测注入 Fake（基线 13.1 FS 层测试策略同源）。
public protocol CapabilityProbing: Sendable {
    func probe(_ capability: Capability) async -> CapabilityStatus
}

/// 探测结果缓存条目。
private struct CacheEntry: Sendable {
    let snapshot: CapabilitySnapshot
    let probedAt: Date
}

/// L1 权限能力矩阵与优雅降级（基线 6.4）。
/// 探测结果缓存 60s；可在设置页强制重探（forceRefresh）。
public actor CapabilityGate {

    private let prober: CapabilityProbing
    private let logger: Logger
    private var cache: CacheEntry?
    private let cacheTTL: Duration

    public init(prober: CapabilityProbing, logger: Logger, cacheTTL: Duration = .seconds(60)) {
        self.prober = prober
        self.logger = logger
        self.cacheTTL = cacheTTL
    }

    /// 探测全部能力。
    public func snapshot(forceRefresh: Bool = false) async -> CapabilitySnapshot {
        if !forceRefresh, let cache,
           Duration.seconds(Date().timeIntervalSince(cache.probedAt)) < cacheTTL {
            return cache.snapshot
        }
        var statuses: [Capability: CapabilityStatus] = [:]
        for capability in Capability.allCases {
            statuses[capability] = await prober.probe(capability)
        }
        let snapshot = CapabilitySnapshot(statuses: statuses, probedAt: Date())
        cache = CacheEntry(snapshot: snapshot, probedAt: snapshot.probedAt)
        if !snapshot.missing.isEmpty {
            logger.info("capability missing: \(snapshot.missing.map(\.rawValue).joined(separator: ","))")
        }
        return snapshot
    }

    /// 某能力可用性 + 对应降级策略（降级映射表见基线 6.4）。
    public func resolve(_ capability: Capability) async -> CapabilityResolution {
        let status = await prober.probe(capability)
        return CapabilityResolution(
            status: status,
            degradation: Self.degradation(for: capability, status: status),
            guideURL: Self.guideURL(for: capability)
        )
    }

    /// 求编辑后的可用范围：过滤掉需要某能力但该能力缺失的项。
    public func filter<T>(_ items: [T], capability: Capability, requires: (T) -> Bool) async -> [T] {
        let snapshot = await snapshot()
        switch snapshot.statuses[capability] {
        case .granted, nil:
            return items
        case .unsupported:
            return items.filter { !requires($0) }
        case .denied, .notDetermined:
            return items.filter { !requires($0) }
        }
    }

    /// 请求/引导（仅引导，不做越权 API 调用，基线 6.4 要点 4）。
    public func request(_ capability: Capability) async -> CapabilityStatus {
        // 打开系统设置对应面板（全盘访问）或返回当前状态；不做越权调用。
        if let url = Self.guideURL(for: capability) {
            NSWorkspace.shared.open(url)
        }
        return await prober.probe(capability)
    }

    // MARK: - 降级映射（与基线 6.4 表格一一对应）

    public static func degradation(for capability: Capability, status: CapabilityStatus) -> Degradation {
        if case .granted = status {
            switch capability {
            case .fullDiskAccess, .privilegedHelper, .automation,
                 .accessibility, .notification, .networkExtension:
                return .full
            }
        }
        if case .unsupported(let reason) = status {
            return .unavailable(reason)
        }
        switch capability {
        case .fullDiskAccess:
            return .partial("只扫 /Applications 与用户可读目录；/Library 相关项需授权后可见；部分清理规则灰显")
        case .privilegedHelper:
            return .partial("系统级残留清理、快照删除、TCC 重置、系统 launchd 操作灰显，需安装辅助程序")
        case .automation:
            return .partial("结束进程降级为 SIGTERM（跳过优雅退出）")
        case .accessibility:
            return .partial("隐藏进程窗口/能耗细节列，其余不变")
        case .notification:
            return .partial("阈值告警降级为应用内横幅")
        case .networkExtension:
            return .unavailable("分应用连接监控不可用，需系统扩展授权")
        }
    }

    public static func guideURL(for capability: Capability) -> URL? {
        switch capability {
        case .fullDiskAccess:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        case .accessibility:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        case .notification:
            URL(string: "x-apple.systempreferences:com.apple.preference.notifications")
        case .privilegedHelper:
            URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
        case .automation, .networkExtension:
            nil
        }
    }
}