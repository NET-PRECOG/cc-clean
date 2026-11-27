import SwiftUI
import CcCleanCore
import CcCleanFS

/// 关联文件树（A8，基线 11.4：OutlineGroup 懒加载，>5000 节点截断保护；
/// 节点体积与 F1 同源——FSIndex.aggregate）。
struct FileTreeNode: Identifiable {
    let path: String
    let name: String
    let sizeBytes: Int64
    var children: [FileTreeNode]? = nil   // nil = 未展开；[] = 无子目录

    var id: String { path }
}

@Observable
@MainActor
final class FileTreeViewModel {
    private var index: FSIndex?

    private(set) var root: FileTreeNode?
    private(set) var isIndexing = false
    private(set) var truncatedPaths: Set<String> = []

    /// 单层节点上限（>5000 截断并标注，基线 A8 DoD）。
    private static let fanOutLimit = 5000

    func ensureIndex() {
        if index == nil {
            index = try? FSIndex(
                database: Paths.indexDatabase,
                logger: Logger(category: .scan, buffer: LogBuffer(capacity: 10)))
        }
    }

    /// 加载根节点（用户主目录；与 F1 同一索引）。
    func loadRoot() async {
        ensureIndex()
        guard let index, root == nil else { return }
        isIndexing = true
        defer { isIndexing = false }
        let home = NSHomeDirectory()
        let size = await index.allocatedSize(of: home)
        root = FileTreeNode(path: home, name: "主目录", sizeBytes: size, children: [])
        await loadChildren(of: root!)
    }

    /// 懒加载子目录（aggregate depth=1；与 F1 体积一致）。
    func loadChildren(of node: FileTreeNode) async {
        guard let index, node.children?.isEmpty == true else { return }
        let aggregated = await index.aggregate(under: node.path, depth: 1)
        var entries = aggregated
            .filter { $0.key != node.path }
            .map { (path: $0.key, bytes: $0.value) }
            .sorted { $0.bytes > $1.bytes }
        var truncated = false
        if entries.count > Self.fanOutLimit {
            entries = Array(entries[..<Self.fanOutLimit])
            truncated = true
        }
        let children = entries.map {
            FileTreeNode(
                path: $0.path, name: ($0.path as NSString).lastPathComponent,
                sizeBytes: $0.bytes, children: [])
        }
        if truncated { truncatedPaths.insert(node.path) }
        replaceChildren(of: node.path, with: children)
    }

    /// 树不可变更新（@Observable 触发刷新）。
    private func replaceChildren(of path: String, with children: [FileTreeNode]) {
        func update(_ node: FileTreeNode) -> FileTreeNode {
            var node = node
            if node.path == path {
                node.children = children
                return node
            }
            if let kids = node.children {
                node.children = kids.map(update)
            }
            return node
        }
        if let root { self.root = update(root) }
    }
}

/// 关联文件树页（A8）。
struct FileTreeView: View {
    @State private var model = FileTreeViewModel()

    var body: some View {
        Group {
            if let root = model.root {
                List {
                    TreeNodeRow(node: root) { node in
                        await model.loadChildren(of: node)
                    }
                }
            } else if model.isIndexing {
                LoadingOverlay(
                    isLoading: true,
                    title: "正在建立文件索引…",
                    systemImage: "folder.fill",
                    accent: .fileTree
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("索引不可用").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("关联文件树")
        .task { await model.loadRoot() }
    }
}

/// 单行：展开时懒加载（OutlineGroup 语义）。
private struct TreeNodeRow: View {
    let node: FileTreeNode
    let onExpand: (FileTreeNode) async -> Void
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if let children = node.children, !children.isEmpty {
                ForEach(children) { child in
                    TreeNodeRow(node: child, onExpand: onExpand)
                }
            }
        } label: {
            HStack {
                Image(systemName: node.children?.isEmpty == false
                    ? "folder.fill" : "folder")
                    .foregroundStyle(.blue)
                Text(node.name)
                Spacer()
                Text(ByteCountFormatter.string(
                    fromByteCount: node.sizeBytes, countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: isExpanded) { _, expanded in
            if expanded {
                Task { await onExpand(node) }
            }
        }
    }
}