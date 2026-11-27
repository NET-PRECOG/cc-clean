import SwiftUI
import CcCleanCore
import CcCleanFS
import CcCleanOps

/// 启动项 ViewModel（基线 11.3 ⑤：三分区 + 开关确认 + 健康列红点 + 虚拟滚动）。
@Observable
@MainActor
final class StartupItemsViewModel {

    private let store: DatabaseStore
    private var launchdStore: LaunchdStore?

    private(set) var entries: [LaunchdEntry] = []
    private(set) var isRefreshing = false
    private(set) var lastRefreshAt: Date?
    /// 开关操作进行中的 label（防重复点击）
    private(set) var pendingLabels: Set<String> = []
    /// 操作反馈（label → 消息）
    private(set) var messages: [String: String] = [:]

    var searchText = ""

    init(store: DatabaseStore = DatabaseStoreHolder.shared) {
        self.store = store
    }

    /// 三分区（基线 11.3 ⑤）：用户登录项 / 守护项 / 系统组件（只读）。
    var userEntries: [LaunchdEntry] {
        filtered(entries.filter { !$0.isSystem && $0.domain.hasPrefix("gui/") })
    }
    var systemEntries: [LaunchdEntry] {
        filtered(entries.filter { !$0.isSystem && !$0.domain.hasPrefix("gui/") })
    }
    var readOnlyEntries: [LaunchdEntry] {
        filtered(entries.filter { $0.isSystem })
    }

    var unhealthyCount: Int {
        entries.filter { !$0.healthy }.count
    }

    private func filtered(_ items: [LaunchdEntry]) -> [LaunchdEntry] {
        guard !searchText.isEmpty else { return items }
        let q = searchText.lowercased()
        return items.filter {
            $0.label.lowercased().contains(q)
                || ($0.ownerBundle?.lowercased().contains(q) ?? false)
                || $0.plistPath.lowercased().contains(q)
        }
    }

    func load() async {
        let ldStore = LaunchdStore(store: store, logger: Logger(category: .uninstall))
        launchdStore = ldStore
        entries = await ldStore.entries()
        if entries.isEmpty {
            await refresh()
        }
    }

    /// H2 全量刷新（扫描 + 归属 + 落库；launchctl print 注入自 S10 真机接入）。
    func refresh() async {
        guard !isRefreshing, let launchdStore else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        entries = await launchdStore.refresh(
            home: NSHomeDirectory(),
            knownBundles: []   // 归属映射由 AppInventoryRepository 台账补充（首次扫描空表可用）
        )
        lastRefreshAt = Date()
    }

    /// H1 开关（系统组件 UI 层拒绝；journal 走共享 Holder）。
    func toggle(_ entry: LaunchdEntry) async {
        guard let launchdStore, !pendingLabels.contains(entry.label) else { return }
        pendingLabels.insert(entry.label)
        defer { pendingLabels.remove(entry.label) }
        let journal = OperationJournalHolder.shared(store: store)
        let (ok, message) = await launchdStore.setEnabled(
            entry, enabled: false, journal: journal, undoJournalID: nil
        )
        messages[entry.label] = message
        if ok { await refresh() }
        _ = ok
    }

    /// H5 诊断建议。
    func suggestions(for entry: LaunchdEntry) async -> [String] {
        guard let launchdStore else { return [] }
        return await launchdStore.diagnoseSuggestions(entry)
    }
}

/// 启动项页（基线 11.3 ⑤：登录项开关 / 守护项列表归属 / 系统组件只读 + 健康列红点；
/// > 30 项 List 惰性渲染）。
struct StartupItemsView: View {
    @State private var model = StartupItemsViewModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .navigationTitle("启动项与守护项")
        .task { await model.load() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            TextField("搜索 Label / bundleId / 路径", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
            Spacer()
            if model.unhealthyCount > 0 {
                Text("\(model.unhealthyCount) 项异常")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if model.isRefreshing {
                ProgressView().controlSize(.small)
            }
            Button("刷新") { Task { await model.refresh() } }
        }
        .padding(12)
        .background(.bar)
    }

    @ViewBuilder
    private var content: some View {
        List {
            section("用户登录项（可开关）", model.userEntries)
            section("守护项（可开关）", model.systemEntries)
            section("系统组件（只读展示）", model.readOnlyEntries)
        }
        .listStyle(.inset)
        .overlay(LoadingOverlay(
            isLoading: model.isRefreshing,
            title: "正在刷新启动项…",
            systemImage: "paperplane.fill",
            accent: .loginItem))
    }

    private func section(_ title: String, _ items: [LaunchdEntry]) -> some View {
        Section("\(title) · \(items.count)") {
            if items.isEmpty {
                Text("无").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(items) { entry in
                entryRow(entry)
            }
        }
    }

    private func entryRow(_ entry: LaunchdEntry) -> some View {
        HStack(spacing: 10) {
            // 健康列红点（基线 11.3 ⑤）
            Circle()
                .fill(entry.healthy ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.label).font(.system(.body, design: .monospaced)).lineLimit(1)
                    if let owner = entry.ownerBundle {
                        Text("归属 \(owner)").font(.caption2)
                            .padding(2).background(.blue.opacity(0.12), in: Capsule())
                    }
                }
                Text(entry.plistPath).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                if let message = model.messages[entry.label] {
                    Text(message).font(.caption2).foregroundStyle(.orange)
                }
            }
            Spacer()
            if entry.isSystem {
                Text("系统").font(.caption2).padding(3)
                    .background(.gray.opacity(0.15), in: Capsule())
            } else {
                Button("停用") {
                    Task { await model.toggle(entry) }
                }
                .controlSize(.small)
                .disabled(model.pendingLabels.contains(entry.label))
            }
        }
        .padding(.vertical, 2)
    }
}