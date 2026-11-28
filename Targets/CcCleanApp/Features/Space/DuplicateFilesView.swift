import SwiftUI
import CcCleanCore
import CcCleanFS

/// 重复文件 ViewModel（独立功能页：候选目录扫描 → 三级查重 → 勾选移入废纸篓）。
@Observable
@MainActor
final class DuplicateFilesViewModel {

    private var index: FSIndex?
    private let detector = DuplicateFileDetector(
        logger: Logger(category: .scan, buffer: LogBuffer(capacity: 10)))

    private(set) var isScanning = false
    private(set) var scanningProgress: (scanned: Int, path: String)?
    private(set) var groups: [DuplicateGroup] = []
    private(set) var lastScanAt: Date?
    /// 已移入废纸篓的路径（分组内即时隐藏；可从废纸篓恢复）。
    private(set) var trashedPaths: Set<String> = []
    /// 每组勾选待删除的副本路径（默认排除保留项）。
    private(set) var selected: Set<String> = []
    /// 路径 → 单份大小（勾选合计可释放空间用）。
    private var bytesByPath: [String: Int64] = [:]

    /// 扫描候选根（下载与缓存目录，控制规模）。
    private var candidateRoots: [String] {
        [NSHomeDirectory() + "/Downloads", NSHomeDirectory() + "/Library/Caches"]
    }

    /// 组内剔除已删除路径后仍 ≥ 2 份的分组。
    var visibleGroups: [DuplicateGroup] {
        groups.filter { survivingPaths(in: $0).count >= 2 }
    }

    /// 组内未删除的路径（keepPath 为剩余最早一份）。
    func survivingPaths(in group: DuplicateGroup) -> [String] {
        group.paths.filter { trashedPaths.contains($0) == false }
    }

    /// 勾选项合计可释放空间。
    var selectedBytes: Int64 {
        selected.reduce(Int64(0)) { $0 + (bytesByPath[$1] ?? 0) }
    }

    var selectedCount: Int { selected.count }

    /// 单份文件大小（组内每份同大小）。
    func bytes(for path: String) -> Int64 { bytesByPath[path] ?? 0 }

    // MARK: - 扫描

    func refresh() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        if index == nil {
            index = try? FSIndex(
                database: Paths.indexDatabase,
                logger: Logger(category: .scan, buffer: LogBuffer(capacity: 10))
            )
        }
        guard let index else { return }

        let candidates = await index.query(FSQuery(roots: candidateRoots))
            .filter { !$0.isDirectory && $0.allocatedSize > 1024 * 1024 }
            .map(\.path)
        groups = await detector.detect(candidates: candidates)
        bytesByPath = Dictionary(
            uniqueKeysWithValues: groups.flatMap { group in
                group.paths.map { ($0, group.bytesPerFile) }
            })
        selected = Set(groups.flatMap { group in
            group.paths.filter { $0 != group.keepPath }
        })
        lastScanAt = Date()
        scanningProgress = nil
    }

    // MARK: - 操作

    func toggle(_ path: String) {
        if selected.contains(path) {
            selected.remove(path)
        } else {
            selected.insert(path)
        }
    }

    /// 勾选副本移入废纸篓（可撤销；成功后从分组即时隐藏）。
    func trashSelected() {
        for path in selected where trashedPaths.contains(path) == false {
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                trashedPaths.insert(path)
            } catch {
                // 单个失败跳过（保留勾选，不伪造成功）
            }
        }
        selected.subtract(trashedPaths)
    }
}

/// 重复文件页（独立功能：分组列表 + 勾选副本 + 批量移入废纸篓）。
struct DuplicateFilesView: View {
    @State private var model = DuplicateFilesViewModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            groupList
        }
        .overlay(LoadingOverlay(
            isLoading: model.isScanning,
            title: "正在检测重复文件…",
            detail: model.scanningProgress.map { "已扫描 \($0.scanned) 项 · \($0.path)" },
            systemImage: "doc.on.doc.fill",
            accent: .duplicate))
        .navigationTitle("重复文件")
        .task { await model.refresh() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("重复组").font(.caption).foregroundStyle(.secondary)
                Text("\(model.visibleGroups.count) 组")
                    .font(.title2.bold())
            }
            Spacer()
            if let last = model.lastScanAt {
                Text("扫描 \(last.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("刷新") { Task { await model.refresh() } }
            Button("删除勾选（可恢复）") { model.trashSelected() }
                .disabled(model.selectedCount == 0)
        }
        .padding(12)
        .background(.bar)
    }

    private var groupList: some View {
        List {
            if model.visibleGroups.isEmpty {
                Text("未发现重复文件").foregroundStyle(.secondary)
            }
            ForEach(model.visibleGroups, id: \.keepPath) { group in
                let paths = model.survivingPaths(in: group)
                Section("每组 \(paths.count) 份 × \(CCleanTheme.formatBytes(group.bytesPerFile))\(group.hasHardlinks ? "（含硬链接）" : "")") {
                    ForEach(paths, id: \.self) { path in
                        row(path: path, keepPath: group.keepPath)
                    }
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if !model.isScanning && model.visibleGroups.isEmpty {
                ContentUnavailableView("未发现重复文件", systemImage: "doc.on.doc")
            }
        }
    }

    private func row(path: String, keepPath: String) -> some View {
        let isKeep = path == keepPath
        return HStack(spacing: 10) {
            if isKeep {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Image(systemName: model.selected.contains(path) ? "checkmark.square" : "square")
                    .foregroundStyle(model.selected.contains(path) ? Color.accentColor : Color.secondary)
                    .onTapGesture { model.toggle(path) }
            }
            Text(path).font(.system(.caption2, design: .monospaced)).lineLimit(1)
            Spacer()
            if isKeep {
                Text("保留").font(.caption2).foregroundStyle(.green)
            } else {
                Text(CCleanTheme.formatBytes(model.bytes(for: path)))
                    .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}