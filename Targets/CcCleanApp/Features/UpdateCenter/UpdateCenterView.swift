import SwiftUI
import CcCleanCore
import CcCleanFS
import CcCleanOps
import CcCleanPrivileged

/// 更新中心 ViewModel（基线 5.4 数据流②：从台账取应用 → 检测 → 缓存 → 分派）。
@Observable
@MainActor
final class UpdateCenterViewModel {

    private var resolver: VersionResolver?
    private var dispatcher: UpdateDispatcher?
    private var snapshotService: SnapshotService?
    private let store: DatabaseStore

    private(set) var results: [VersionCheckResult] = []
    private(set) var isChecking = false
    private(set) var queueOutcomes: [UpdateDispatcher.ItemOutcome] = []
    private(set) var lastCheckedAt: Date?

    init(store: DatabaseStore = DatabaseStoreHolder.shared) {
        self.store = store
    }

    var outdatedItems: [(probe: VersionProbe, result: VersionCheckResult)] {
        results.compactMap { result in
            let probe = probes.first { $0.bundleId == result.bundleId }
            guard let probe else { return nil }
            guard VersionResolver.isOutdated(probe: probe, result: result) == true else { return nil }
            return (probe, result)
        }
    }

    private var probes: [VersionProbe] = []

    /// 初始化 Provider 链（排除表 + 国产源从 Shared/Resources 加载）。
    func setup() {
        let domestic = DomesticFeedProvider.load(
            from: Paths.sharedResources.appendingPathComponent("domestic-feeds.json")
        )
        resolver = VersionResolver(
            providers: VersionResolver.defaultProviders(domesticFeeds: domestic),
            excluded: ExcludedApps.load(
                from: Paths.sharedResources.appendingPathComponent("excluded-apps.plist")
            ),
            store: store,
            logger: Logger(category: .network)
        )
        snapshotService = SnapshotService()
        dispatcher = UpdateDispatcher(snapshots: snapshotService ?? SnapshotService())
    }

    /// 全量检测（元数据从台账取）。
    func checkAll() async {
        guard !isChecking, let resolver else { return }
        isChecking = true
        defer { isChecking = false }

        let repo = AppInventoryRepository(
            store: store, scanner: AppScanner(logger: Logger(category: .scan))
        )
        let records = (await repo.loadCached()).filter { !$0.isProtected }
        probes = records.map { record in
            VersionProbe(
                bundleId: record.bundleId,
                bundlePath: record.bundlePath,
                shortVersion: record.shortVersion,
                sparkleFeedURL: Self.readSparkleFeed(bundlePath: record.bundlePath)
            )
        }
        results = await resolver.checkAll(probes) { [weak self] _ in
            // 增量回调：主界面无需逐条刷新，最终统一更新
            _ = self
        }
        lastCheckedAt = Date()
    }

    /// 读目标应用 Info.plist 的 SUFeedURL（Sparkle 检测入口）。
    private static func readSparkleFeed(bundlePath: String) -> String? {
        let infoPath = bundlePath + "/Contents/Info.plist"
        guard let data = FileManager.default.contents(atPath: infoPath),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil) as? [String: Any]
        else { return nil }
        return plist["SUFeedURL"] as? String ?? plist["SUFeedURLForFinalUserRelease"] as? String
    }

    /// 执行批量更新队列（B3/B5：快照先行 + 分派 + 失败不中断）。
    func runUpdateQueue() async {
        guard let dispatcher, let journal = journal else { return }
        queueOutcomes = await dispatcher.runQueue(outdatedItems, journal: journal)
    }

    private var journal: OperationJournal? {
        OperationJournalHolder.shared(store: store)
    }

    func execute(_ outcome: UpdateDispatcher.ItemOutcome) {
        // 打开类动作由 UI 层执行（NSWorkspace.open）
        switch outcome.action {
        case .openMacAppStore(let url), .openDownloadPage(let url):
            if let nsURL = URL(string: url) {
                NSWorkspace.shared.open(nsURL)
            }
        case .openAppInUpdater(let path):
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        default:
            break
        }
    }
}

/// OperationJournal 单例（App 生命周期共享；注入 XPCHelperClient 打通系统级通路，S10）。
@MainActor
enum OperationJournalHolder {
    static var cached: OperationJournal?
    static func shared(store: DatabaseStore) -> OperationJournal {
        if let cached { return cached }
        // S10：注入 Helper 客户端——removeSystem/forgetReceipts/resetTCC/bootout
        // 走 Helper XPC（Helper 未注册时 OperationJournal 内部降级为明确失败原因，UI 灰显）
        let journal = OperationJournal(
            store: store,
            helper: XPCHelperClient(),
            logger: Logger(category: .uninstall)
        )
        cached = journal
        return journal
    }
}

/// 更新中心页（基线 11.3 ② 流程：列表 → 勾选 → 检测 → 执行队列 → 结果汇总）。
struct UpdateCenterView: View {
    @State private var model = UpdateCenterViewModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            content
            footer
        }
        .navigationTitle("更新中心")
        .task {
            model.setup()
            await model.checkAll()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("可更新应用").font(.caption).foregroundStyle(.secondary)
                Text("\(model.outdatedItems.count) 项")
                    .font(.title2.bold())
            }
            Spacer()
            if model.isChecking {
                ProgressView().controlSize(.small)
                Text("检测中…（并发 6，缓存 24h）").font(.caption).foregroundStyle(.secondary)
            }
            Button("重新检测") { Task { await model.checkAll() } }
            Button("批量更新") {
                Task {
                    await model.runUpdateQueue()
                }
            }
            .disabled(model.outdatedItems.isEmpty || model.isChecking)
        }
        .padding(12)
        .background(.bar)
    }

    @ViewBuilder
    private var content: some View {
        if !model.queueOutcomes.isEmpty {
            // 队列结果汇总（单项失败标红可重试）
            List(model.queueOutcomes, id: \.bundleId) { outcome in
                HStack {
                    Image(systemName: outcome.succeeded ? "checkmark.circle" : "xmark.circle")
                        .foregroundStyle(outcome.succeeded ? .green : .red)
                    Text(outcome.bundleId)
                    Spacer()
                    Text(outcome.message).font(.caption).foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)
        } else {
            List(model.results, id: \.bundleId) { result in
                let outdated = model.outdatedItems.contains { $0.result.bundleId == result.bundleId }
                HStack(spacing: 12) {
                    Text(result.bundleId)
                        .lineLimit(1)
                    Spacer()
                    if outdated {
                        Text("可更新")
                            .font(.caption2).padding(3)
                            .background(.green.opacity(0.15), in: Capsule())
                    }
                    // 不定性表述（基线 B1 验收：只显示「可更新至 x（来源）」）
                    Text(result.latest.map { "可更新至 \($0)（\(result.source.rawValue)）" } ?? "未知来源")
                        .font(.caption).foregroundStyle(.secondary)
                    if result.confidence == .unknown {
                        Text("未知").font(.caption2)
                            .padding(3).background(.gray.opacity(0.15), in: Capsule())
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private var footer: some View {
        HStack {
            if let last = model.lastCheckedAt {
                Text("检测时间 \(last.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("brew 升级自 S14 接入；快照先行（B5）")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(8)
        .background(.bar)
    }
}