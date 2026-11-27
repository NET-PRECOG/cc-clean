import SwiftUI
import CcCleanCore
import CcCleanFS

/// 应用清单 ViewModel（基线 5.4 数据流①）：
/// 元数据首屏 < 300ms → SizeCache 增量推送 → 100ms 节流合并刷新。
@Observable
@MainActor
final class AppInventoryViewModel {

    private var repo: AppInventoryRepository?
    private var sizeCache: SizeCache?
    private let store: DatabaseStore

    private(set) var records: [AppRecord] = []
    private(set) var duplicates: [DuplicateAppDetector.Group] = []
    private(set) var isScanning = false
    private(set) var isSizing = false
    private(set) var lastScanAt: Date?
    private var sizeTask: Task<Void, Never>?
    private var pendingSizeUpdates: [String: Int64] = [:]

    // 筛选/排序（基线 11.2 列表骨架）
    var searchText = ""
    var sourceFilter: InstallSource?
    var sortAscendingBySize = false

    init(store: DatabaseStore) {
        self.store = store
    }

    /// 筛选 + 排序后的展示列表。
    var visibleRecords: [AppRecord] {
        var items = records
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            items = items.filter {
                $0.displayName.lowercased().contains(q)
                    || $0.bundleId.lowercased().contains(q)
            }
        }
        if let source = sourceFilter {
            items = items.filter { $0.installSource == source }
        }
        items.sort {
            let a = $0.sizeBytes ?? Int64.max
            let b = $1.sizeBytes ?? Int64.max
            return sortAscendingBySize ? a < b : a > b
        }
        return items
    }

    var totalSizedBytes: Int64 {
        records.compactMap(\.sizeBytes).reduce(0, +)
    }

    var duplicateBundleIds: Set<String> {
        Set(duplicates.flatMap { $0.copies.map(\.bundleId) })
    }

    /// 启动路径：先读缓存立即出列表，再触发全量扫描。
    func loadInitial() async {
        let repo = AppInventoryRepository(
            store: store,
            scanner: AppScanner(logger: Logger(category: .scan))
        )
        self.repo = repo
        self.sizeCache = try? SizeCache(
            database: Paths.indexDatabase,
            logger: Logger(category: .scan)
        )
        records = await repo.loadCached()
        duplicates = DuplicateAppDetector().detect(records)
        if records.isEmpty {
            await refresh()
        }
    }

    /// 全量扫描刷新。
    func refresh() async {
        guard !isScanning, let repo else { return }
        isScanning = true
        defer { isScanning = false }
        let scanned = await repo.refresh()
        records = scanned
        duplicates = DuplicateAppDetector().detect(scanned)
        lastScanAt = Date()
        startSizePush()
    }

    /// 体积增量推送（后台继续，ViewModel 节流 100ms 合并）。
    private func startSizePush() {
        sizeTask?.cancel()
        guard let sizeCache, !records.isEmpty else { return }
        let paths = records.map(\.bundlePath)
        isSizing = true
        sizeTask = Task { [weak self] in
            let stream = await sizeCache.computeSizes(appPaths: paths)
            for await update in stream {
                if Task.isCancelled { break }
                self?.pendingSizeUpdates[update.bundlePath] = update.sizeBytes
                try? await Task.sleep(for: .milliseconds(100))   // 节流合并
                self?.applyPendingSizes()
            }
            self?.applyPendingSizes()
            self?.isSizing = false
        }
    }

    private func applyPendingSizes() {
        guard !pendingSizeUpdates.isEmpty else { return }
        let updates = pendingSizeUpdates
        pendingSizeUpdates.removeAll()
        for (index, record) in records.enumerated() {
            if let size = updates[record.bundlePath] {
                records[index].sizeBytes = size
            }
        }
        Task { [repo] in
            for (path, size) in updates {
                await repo?.updateSize(bundlePath: path, sizeBytes: size)
            }
        }
    }
}

/// 数据库单例持有者（App 生命周期共享一个主库）。
@MainActor
enum DatabaseStoreHolder {
    static let shared: DatabaseStore = {
        do {
            return try DatabaseStore.open(
                at: Paths.mainDatabase,
                logger: Logger(category: .general)
            )
        } catch {
            fatalError("database open failed: \(error)")
        }
    }()
}

/// 应用清单页（基线 11.2 通用列表骨架：筛选/排序/搜索 + 主操作分离 + 底部汇总）。
struct AppInventoryView: View {
    @State private var model = AppInventoryViewModel(store: DatabaseStoreHolder.shared)

    var body: some View {
        NavigationSplitView {
            List {
                Section("来源筛选") {
                    ForEach([InstallSource.appStore, .homebrewCask, .pkgInstaller, .dragAndDrop, .unknown, .system], id: \.self) { source in
                        Button(source.rawValue) { model.sourceFilter = source }
                    }
                    if model.sourceFilter != nil {
                        Button("清除筛选") { model.sourceFilter = nil }
                    }
                }
            }
            .listStyle(.sidebar)
        } detail: {
            VStack(spacing: 0) {
                toolbar
                listView
                bottomBar
            }
            .overlay(LoadingOverlay(
                isLoading: model.isScanning,
                title: "正在扫描应用清单…",
                systemImage: "list.bullet.rectangle.fill",
                accent: .inventory))
            .task { await model.loadInitial() }
        }
        .navigationTitle("应用清单")
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            TextField("搜索名称 / bundleId", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
            Button(model.sortAscendingBySize ? "体积 ↑" : "体积 ↓") {
                model.sortAscendingBySize.toggle()
            }
            Spacer()
            if model.isScanning {
                ProgressView().controlSize(.small)
                Text("扫描中…").foregroundStyle(.secondary)
            } else if model.isSizing {
                Text("体积统计中…").foregroundStyle(.secondary).font(.caption)
            }
            Button("刷新") { Task { await model.refresh() } }
        }
        .padding(12)
    }

    private var listView: some View {
        List(model.visibleRecords, id: \.bundleId) { record in
            HStack(spacing: 12) {
                Text(record.displayName)
                    .fontWeight(.medium)
                if model.duplicateBundleIds.contains(record.bundleId) {
                    Text("重复").font(.caption2).padding(3)
                        .background(.orange.opacity(0.2), in: Capsule())
                }
                if record.isProtected {
                    Text("系统").font(.caption2).padding(3)
                        .background(.gray.opacity(0.2), in: Capsule())
                }
                Spacer()
                Text(record.shortVersion ?? "—").foregroundStyle(.secondary)
                Text(record.installSource.rawValue).foregroundStyle(.secondary)
                Text(record.sizeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…")
                    .monospacedDigit()
            }
        }
        .listStyle(.inset)
    }

    private var bottomBar: some View {
        HStack {
            Text("共 \(model.records.count) 项 · 已统计 \(ByteCountFormatter.string(fromByteCount: model.totalSizedBytes, countStyle: .file))")
                .foregroundStyle(.secondary)
            Spacer()
            if let last = model.lastScanAt {
                Text("上次扫描 \(last.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(.bar)
    }
}