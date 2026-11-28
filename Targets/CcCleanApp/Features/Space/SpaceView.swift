import SwiftUI
import CcCleanCore
import CcCleanFS

/// 磁盘空间 ViewModel（F1 Treemap 空间构成；大文件/重复文件已拆分为独立功能页）。
@Observable
@MainActor
final class SpaceViewModel {

    private var index: FSIndex?

    private(set) var isIndexing = false
    private(set) var indexingProgress: (scanned: Int, path: String)?
    /// F1 Treemap 顶层节点（aggregate depth=1 降序前 12 + 其他合计）
    private(set) var treemapNodes: [(name: String, bytes: Int64)] = []
    private(set) var totalUsedBytes: Int64 = 0
    private(set) var lastScanAt: Date?

    /// 索引根（用户主目录；全盘扫描需全盘访问权限，基线 6.4）
    private var scanRoot: String { NSHomeDirectory() }

    // MARK: - 扫描

    func refresh() async {
        guard !isIndexing else { return }
        isIndexing = true
        defer { isIndexing = false }

        // FSIndex 初始化（复用索引库；构造参数统一走 FSIndexFactory）
        if index == nil {
            index = FSIndexFactory.make()
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

        lastScanAt = Date()
        _ = stats
        indexingProgress = nil
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

/// 磁盘空间页（空间构成 Treemap；大文件/重复文件见 LargeFilesView / DuplicateFilesView）。
struct SpaceView: View {
    @State private var model = SpaceViewModel()

    var body: some View {
        VStack(spacing: 0) {
            header
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
                treemapTab
            }
        }
        .navigationTitle("磁盘空间")
        .task { await model.refresh() }
    }

    private var header: some View {
        PageHeader(
            caption: "已用空间",
            title: CCleanTheme.formatBytes(model.totalUsedBytes),
            lastScanAt: model.lastScanAt
        ) {
            Button("刷新") { Task { await model.refresh() } }
        }
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
                            Text(CCleanTheme.formatBytes(node.bytes))
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
            }
            .padding(12)
        }
    }
}