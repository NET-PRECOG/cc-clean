import Testing
import Foundation
@testable import CcCleanCore

/// 可控 Fake 探测器。
final class FakeProber: CapabilityProbing, @unchecked Sendable {
    var states: [Capability: CapabilityStatus]
    var probeCount = 0

    init(states: [Capability: CapabilityStatus] = [:]) {
        self.states = states
    }

    func probe(_ capability: Capability) async -> CapabilityStatus {
        probeCount += 1
        return states[capability] ?? .notDetermined
    }
}

@Suite("CapabilityGate")
struct CapabilityGateTests {

    func makeLogger() -> Logger {
        Logger(category: .general, buffer: LogBuffer(capacity: 20))
    }

    @Test("snapshot：全部 granted 时 missing 为空")
    func snapshotAllGranted() async {
        var states: [Capability: CapabilityStatus] = [:]
        for c in Capability.allCases { states[c] = .granted }
        let gate = CapabilityGate(prober: FakeProber(states: states), logger: makeLogger())
        let snapshot = await gate.snapshot()
        #expect(snapshot.missing.isEmpty)
        #expect(snapshot.statuses.count == Capability.allCases.count)
    }

    @Test("snapshot：denied 与 notDetermined 计入 missing，unsupported 不计入")
    func snapshotMissing() async {
        let states: [Capability: CapabilityStatus] = [
            .fullDiskAccess: .denied(reason: "未授权"),
            .privilegedHelper: .notDetermined,
            .automation: .granted,
            .accessibility: .unsupported(reason: "无可选细节"),
            .notification: .granted,
            .networkExtension: .granted,
        ]
        let gate = CapabilityGate(prober: FakeProber(states: states), logger: makeLogger())
        let snapshot = await gate.snapshot()
        #expect(snapshot.missing == [.fullDiskAccess, .privilegedHelper])
    }

    @Test("缓存：60s TTL 内复用，forceRefresh 重探")
    func caching() async {
        let prober = FakeProber(states: [:])
        let gate = CapabilityGate(prober: prober, logger: makeLogger())
        _ = await gate.snapshot()
        _ = await gate.snapshot()
        _ = await gate.snapshot()
        #expect(prober.probeCount == Capability.allCases.count)  // 命中缓存，仅探一轮

        _ = await gate.snapshot(forceRefresh: true)
        #expect(prober.probeCount == Capability.allCases.count * 2)
    }

    @Test("降级映射：与基线 6.4 表格一一对应")
    func degradationMapping() {
        let kind = { (c: Capability) in
            CapabilityGate.degradation(for: c, status: .denied(reason: "x")).kind
        }
        if case .partial = kind(.fullDiskAccess) {} else { Issue.record("fullDiskAccess 应为 partial") }
        if case .partial = kind(.privilegedHelper) {} else { Issue.record("privilegedHelper 应为 partial") }
        if case .partial = kind(.automation) {} else { Issue.record("automation 应为 partial") }
        if case .partial = kind(.accessibility) {} else { Issue.record("accessibility 应为 partial") }
        if case .partial = kind(.notification) {} else { Issue.record("notification 应为 partial") }
        if case .unavailable = kind(.networkExtension) {} else { Issue.record("networkExtension 应为 unavailable") }

        // granted 时全部 full
        for c in Capability.allCases {
            if case .full = CapabilityGate.degradation(for: c, status: .granted).kind {} else {
                Issue.record("granted 应为 full: \(c)")
            }
        }
        // unsupported 透传原因
        if case .unavailable = CapabilityGate.degradation(
            for: .accessibility, status: .unsupported(reason: "无传感器")).kind {} else {
            Issue.record("unsupported 应透传")
        }
    }

    @Test("filter：缺能力时剔除需要该能力的项")
    func filtering() async {
        let states: [Capability: CapabilityStatus] = [
            .privilegedHelper: .denied(reason: "helper 未安装")
        ]
        let gate = CapabilityGate(prober: FakeProber(states: states), logger: makeLogger())

        struct Item: Sendable { let name: String; let needsHelper: Bool }
        let items = [
            Item(name: "user-level", needsHelper: false),
            Item(name: "system-level", needsHelper: true),
        ]
        let filtered = await gate.filter(items, capability: .privilegedHelper) { $0.needsHelper }
        #expect(filtered.map(\.name) == ["user-level"])
    }

    @Test("guideURL：全盘访问直达系统设置")
    func guideURL() {
        let url = CapabilityGate.guideURL(for: .fullDiskAccess)
        #expect(url?.absoluteString.contains("Privacy_AllFiles") == true)
        #expect(CapabilityGate.guideURL(for: .automation) == nil)
    }
}