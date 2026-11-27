import SwiftUI
import CcCleanCore

/// 能力总览视图模型：持有 CapabilityGate 快照，驱动设置页状态灯与全局 Banner。
@Observable
@MainActor
final class CapabilityViewModel {

    private let gate = CapabilityGate(prober: SystemCapabilityProber(), logger: Logger(category: .general))
    private var statuses: [Capability: CapabilityStatus] = [:]

    private(set) var isProbing = false
    private(set) var lastProbedAt: Date?

    var missingCount: Int {
        statuses.values.filter {
            if case .granted = $0 { return false }
            if case .unsupported = $0 { return false }
            return true
        }.count
    }

    func status(for capability: Capability) -> CapabilityStatus {
        statuses[capability] ?? .notDetermined
    }

    func degradationText(for capability: Capability) -> String {
        let d = CapabilityGate.degradation(for: capability, status: status(for: capability))
        switch d.kind {
        case .full: return "已授权"
        case .partial(let desc): return desc
        case .unavailable(let desc): return desc
        }
    }

    func refresh(force: Bool = false) async {
        isProbing = true
        defer { isProbing = false }
        let snapshot = await gate.snapshot(forceRefresh: force)
        statuses = snapshot.statuses
        lastProbedAt = snapshot.probedAt
    }

    func request(_ capability: Capability) async {
        _ = await gate.request(capability)
        await refresh(force: true)
    }

    func requestFirstMissing() async {
        let missing = Capability.allCases.first {
            if case .granted = status(for: $0) { return false }
            if case .unsupported = status(for: $0) { return false }
            return true
        }
        if let missing {
            await request(missing)
        }
    }
}