import SwiftUI
import CcCleanCore
import CcCleanFS

/// 空间分析 ViewModel（F1 Treemap/F2 大文件/F3 重复文件，基线 11.3 ③）。
@Observable
@MainActor
final class SpaceViewModel {

    private var index: FSIndex?
    private let largeFileScanner = LargeFileScanner()
    private let duplicateDetector = DuplicateFileDetector(
        logger: Logger(category: .scan, buffer: LogBuffer(capacity: 10)))

    private(set) var isIndexing = false
    private(set) var indexingProgress: (scanned: Int, path: String)?
    private(set) var largeFiles: [LargeFileEntry] = []
    private(set) var categorySummary: [(category: LargeFileCategory, bytes: Int64, count: Int)] = []
    private(set) var duplicateGroups: [DuplicateGroup] = []
    /// F1 Treemap 顶层节点（aggregate depth=1 降序前 12 + 其他合计）
    private(set) var treemapNodes: [(name: String, bytes: Int64)] = []
    private(set) var totalUsedBytes: Int64 = 0
    private(set) var lastScanAt: Date?

    var searchText = ""

    /// 索引根（用户主目录；全盘扫描需全盘访问权限，基线 6.4）
    private var scanRoot: String { NSHomeDirectory() }

    // MARK: - 扫描

    func refresh() async {
        guard !isIndexing else { return }
        isIndexing = true
        defer { isIndexing = false }

        // FSIndex 初始化（复用索引库）
        if index == nil {
            index = try? FSIndex(
                database: Paths.indexDatabase,
                logger: Logger(category: .scan, buffer: LogBuffer(capacity: 10))
            )
        }
        guard let index else { return }

        // 增量索引（性能基线：首次 < 90s / 增量 < 8s，基线 6.1）
        let stats = await index.index(roots: [scanRoot], policy: IndexPolicy()) { scanned, path in
            Task { @MainActor in
                self.indexingProgress = (scanned, path)
            }
        }
        totalUsedBytes = await index.allocatedSize(of: scanRoot)

        // F1 Treemap 顶层节点（depth=1 降序前 12 + 其他合计）
        let aggregated = await index.aggregate(under: scanRoot, depth: 1)
        let sorted = aggregated
            .filter { $0.key != scanRoot }
            .map { (name: ($0.key as NSString).lastPathComponent, bytes: $0.value) }
            .sorted { $0.bytes > $1.bytes }
        if sorted.count > 12 {
            let others = sorted.dropFirst(12).reduce(Int64(0)) { $0 + $1.bytes }
            treemapNodes = Array(sorted.prefix(12)) + [("其他", others)]
        } else {
            treemapNodes = sorted
        }

        // F2 大文件
        largeFiles = await largeFileScanner.scan(index: index, roots: [scanRoot])
        categorySummary = LargeFileScanner.summarize(largeFiles)

        // F3 重复文件（候选：缓存与下载目录的文件，控制规模）
        let candidateQuery = FSQuery(roots: [
            scanRoot + "/Downloads",
            scanRoot + "/Library/Caches",
        ])
        let candidates = await index.query(candidateQuery)
            .filter { !$0.isDirectory && $0.allocatedSize > 1024 * 1024 }
            .map(\.path)
        duplicateGroups = await duplicateDetector.detect(candidates: candidates)

        lastScanAt = Date()
        _ = stats
        indexingProgress = nil
    }

    /// 大文件按分类过滤 + 搜索。
    var filteredLargeFiles: [LargeFileEntry] {
        guard !searchText.isEmpty else { return largeFiles }
        return largeFiles.filter { $0.path.lowercased().contains(searchText.lowercased()) }
    }
}

// MARK: - F1 Treemap 布局（slice-and-dice 简化：水平/垂直交替按比例分割）

struct TreemapRect: Identifiable {
    let id: String
    let name: String
    let bytes: Int64
    let rect: CGRect
}

enum TreemapLayout {
    /// 交替分割布局（数据端简化实现；F1 验收：下钻 5 层不卡由按需下钻承担）。
    static func layout(
        entries: [(name: String, bytes: Int64)], in rect: CGRect
    ) -> [TreemapRect] {
        let total = entries.reduce(Int64(0)) { $0 + $1.bytes }
        guard total > 0, !entries.isEmpty else { return [] }

        var results: [TreemapRect] = []
        var remaining = rect
        var remainingBytes = total
        var horizontal = rect.width >= rect.height

        for (i, entry) in entries.enumerated() {
            let isLast = i == entries.count - 1
            let fraction = isLast
                ? 1.0
                : CGFloat(entry.bytes) / CGFloat(remainingBytes)
            let slice: CGRect
            if horizontal {
                let w = remaining.width * fraction
                slice = CGRect(x: remaining.minX, y: remaining.minY, width: w, height: remaining.height)
                remaining = CGRect(
                    x: remaining.minX + w, y: remaining.minY,
                    width: remaining.width - w, height: remaining.height)
            } else {
                let h = remaining.height * fraction
                slice = CGRect(x: remaining.minX, y: remaining.minY, width: remaining.width, height: h)
                remaining = CGRect(
                    x: remaining.minX, y: remaining.minY + h,
                    width: remaining.width, height: remaining.height - h)
            }
            results.append(TreemapRect(
                id: entry.name, name: entry.name, bytes: entry.bytes, rect: slice))
            remainingBytes -= entry.bytes
            horizontal.toggle()
        }
        return results
    }
}

/// 磁盘空间页（基线 11.3 ③：Treemap + 大文件 + 重复文件）。
struct SpaceView: View {
    @State private var model = SpaceViewModel()
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("", selection: $selectedTab) {
                Text("空间构成").tag(0)
                Text("大文件").tag(1)
                Text("重复文件").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)

            if model.isIndexing {
                LoadingOverlay(
                    isLoading: true,
                    title: "正在扫描磁盘…",
                    detail: model.indexingProgress.map { "已扫描 \($0.scanned) 项 · \($0.path)" },
                    systemImage: "externaldrive.fill",
                    accent: .disk
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch selectedTab {
                case 0: treemapTab
                case 1: largeFilesTab
                default: duplicatesTab
                }
            }
        }
        .navigationTitle("磁盘空间")
        .task { await model.refresh() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("已用空间").font(.caption).foregroundStyle(.secondary)
                Text(ByteCountFormatter.string(fromByteCount: model.totalUsedBytes, countStyle: .file))
                    .font(.title2.bold())
            }
            Spacer()
            if let last = model.lastScanAt {
                Text("扫描 \(last.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("刷新") { Task { await model.refresh() } }
        }
        .padding(12)
        .background(.bar)
    }

    // MARK: - F1 Treemap

    private var treemapTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if model.treemapNodes.isEmpty {
                    Text("暂无数据，请刷新").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    Canvas { context, size in
                        let rects = TreemapLayout.layout(
                            entries: model.treemapNodes,
                            in: CGRect(origin: .zero, size: size))
                        for treemapRect in rects {
                            let path = Path(treemapRect.rect)
                            context.fill(path, with: .color(.blue.opacity(0.15)))
                            context.stroke(path, with: .color(.white), lineWidth: 2)
                            if treemapRect.rect.width > 60, treemapRect.rect.height > 24 {
                                context.draw(
                                    Text(treemapRect.name).font(.caption2),
                                    in: treemapRect.rect.insetBy(dx: 4, dy: 4))
                            }
                        }
                    }
                    .frame(height: 220)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))

                    ForEach(model.treemapNodes, id: \.name) { node in
                        HStack {
                            Text(node.name).lineLimit(1)
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: node.bytes, countStyle: .file))
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
            }
            .padding(12)
        }
    }

    // MARK: - F2 大文件

    private var largeFilesTab: some View {
        VStack(spacing: 0) {
            if !model.categorySummary.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.categorySummary, id: \.category) { item in
                            Text("\(item.category.rawValue) × \(item.count)（\(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file))）")
                                .font(.caption).padding(6)
                                .background(.blue.opacity(0.1), in: Capsule())
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .padding(.vertical, 6)
            }
            List(model.filteredLargeFiles) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.path).font(.system(.caption, design: .monospaced)).lineLimit(1)
                    HStack {
                        Text(entry.category.rawValue).font(.caption2)
                            .padding(2).background(.blue.opacity(0.1), in: Capsule())
                        Spacer()
                        Text(entry.modifiedAt.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption2).foregroundStyle(.secondary)
                        Text(ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file))
                            .font(.caption).monospacedDigit()
                    }
                }
                .padding(.vertical, 2)
            }
            .listStyle(.inset)
            .searchable(text: $model.searchText, prompt: "搜索路径")
        }
    }

    // MARK: - F3 重复文件

    private var duplicatesTab: some View {
        List {
            if model.duplicateGroups.isEmpty {
                Text("未发现重复文件").foregroundStyle(.secondary)
            }
            ForEach(model.duplicateGroups, id: \.keepPath) { group in
                Section("每组 \(group.paths.count) 份 × \(ByteCountFormatter.string(fromByteCount: group.bytesPerFile, countStyle: .file))\(group.hasHardlinks ? "（含硬链接）" : "")") {
                    ForEach(group.paths, id: \.self) { path in
                        HStack {
                            Image(systemName: path == group.keepPath ? "checkmark.circle" : "circle")
                                .foregroundStyle(path == group.keepPath ? .green : .secondary)
                            Text(path).font(.system(.caption2, design: .monospaced)).lineLimit(1)
                            if path == group.keepPath {
                                Text("保留").font(.caption2).foregroundStyle(.green)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
    }
}