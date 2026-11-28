import SwiftUI
import CcCleanCore
import CcCleanFS
import CcCleanOps

/// 大文件 ViewModel（独立功能页：FSIndex + LargeFileScanner，分类筛选 + 搜索 + 移入废纸篓）。
@Observable
@MainActor
final class LargeFilesViewModel {

    private var index: FSIndex?
    private let scanner = LargeFileScanner()
    /// 废纸篓唯一出口（代码红线：写盘通道收敛在 TrashService）。
    private let trashService = TrashService()

    private(set) var isScanning = false
    private(set) var scanningProgress: (scanned: Int, path: String)?
    private(set) var largeFiles: [LargeFileEntry] = []
    private(set) var categorySummary: [(category: LargeFileCategory, bytes: Int64, count: Int)] = []
    private(set) var lastScanAt: Date?
    /// 已移入废纸篓的路径（列表即时移除，可从废纸篓恢复）。
    private(set) var trashedPaths: Set<String> = []

    var searchText = ""
    /// 选中的分类过滤（nil = 全部）。
    var selectedCategory: LargeFileCategory?

    /// 扫描根（用户主目录；全盘扫描需全盘访问权限）。
    private var scanRoot: String { NSHomeDirectory() }

    var totalBytes: Int64 {
        largeFiles.reduce(Int64(0)) { $0 + $1.bytes }
    }

    // MARK: - 扫描

    func refresh() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        if index == nil {
            index = FSIndexFactory.make()
        }
        guard let index else { return }

        let stats = await index.index(roots: [scanRoot], policy: IndexPolicy()) { scanned, path in
            Task { @MainActor in
                self.scanningProgress = (scanned, path)
            }
        }
        _ = stats

        largeFiles = await scanner.scan(index: index, roots: [scanRoot])
        categorySummary = LargeFileScanner.summarize(largeFiles)
        lastScanAt = Date()
        scanningProgress = nil
    }

    // MARK: - 过滤

    /// 分类 + 搜索双重过滤后的列表。
    var filteredFiles: [LargeFileEntry] {
        largeFiles
            .filter { trashedPaths.contains($0.path) == false }
            .filter { selectedCategory == nil || $0.category == selectedCategory }
            .filter { searchText.isEmpty || $0.path.lowercased().contains(searchText.lowercased()) }
    }

    // MARK: - 操作

    /// 移入废纸篓（可撤销；成功后从列表即时隐藏）。
    func trash(_ entry: LargeFileEntry) async {
        let result = await trashService.trash(paths: [entry.path])
        if result.succeeded[entry.path] != nil {
            trashedPaths.insert(entry.path)
        }
        // 失败保持列表不变（不伪造成功）
    }
}

/// 大文件页（独立功能：分类胶囊筛选 + 路径搜索 + 单文件移入废纸篓）。
struct LargeFilesView: View {
    @State private var model = LargeFilesViewModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            categoryBar
            fileList
        }
        .overlay(LoadingOverlay(
            isLoading: model.isScanning,
            title: "正在扫描大文件…",
            detail: model.scanningProgress.map { "已扫描 \($0.scanned) 项 · \($0.path)" },
            systemImage: "doc.text.fill",
            accent: .largeFile))
        .navigationTitle("大文件")
        .task { await model.refresh() }
    }

    private var header: some View {
        PageHeader(
            caption: "大文件占用",
            title: CCleanTheme.formatBytes(model.totalBytes),
            lastScanAt: model.lastScanAt
        ) {
            Button("刷新") { Task { await model.refresh() } }
        }
    }

    /// 分类胶囊（点击切换筛选；再点同胶囊取消回到全部）。
    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                categoryChip(title: "全部", isSelected: model.selectedCategory == nil) {
                    model.selectedCategory = nil
                }
                ForEach(model.categorySummary, id: \.category) { item in
                    categoryChip(
                        title: "\(item.category.rawValue) × \(item.count)（\(CCleanTheme.formatBytes(item.bytes))）",
                        isSelected: model.selectedCategory == item.category
                    ) {
                        model.selectedCategory = model.selectedCategory == item.category ? nil : item.category
                    }
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 8)
    }

    private func categoryChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(isSelected ? Color.orange.opacity(0.25) : Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }

    private var fileList: some View {
        List(model.filteredFiles) { entry in
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.path).font(.system(.caption, design: .monospaced)).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(entry.category.rawValue).font(.caption2)
                            .padding(2).background(.orange.opacity(0.12), in: Capsule())
                        Text(entry.modifiedAt.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(CCleanTheme.formatBytes(entry.bytes))
                    .font(.caption).monospacedDigit()
                Button {
                    Task { await model.trash(entry) }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("移入废纸篓（可恢复）")
            }
            .padding(.vertical, 2)
        }
        .listStyle(.inset)
        .searchable(text: $model.searchText, prompt: "搜索路径")
        .overlay {
            if !model.isScanning && model.filteredFiles.isEmpty {
                ContentUnavailableView("未找到大文件", systemImage: "doc.text")
            }
        }
    }
}