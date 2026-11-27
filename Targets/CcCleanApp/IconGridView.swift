import SwiftUI
import AppKit
import CcCleanCore
import CcCleanFS

/// 图标墙（A10，基线 11.4：Grid 图标缓存 ≤ 200，300 应用流畅滚动）。
@Observable
@MainActor
final class IconGridViewModel {
    private let scanner = AppScanner(logger: Logger(category: .scan))
    /// 图标缓存（NSCache 线程安全；上限 200，基线 A10 DoD）
    private let iconCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 200
        return cache
    }()

    private(set) var apps: [AppRecord] = []
    private(set) var isScanning = false

    var searchText = ""

    var filtered: [AppRecord] {
        searchText.isEmpty ? apps : apps.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText)
        }
    }

    func refresh() async {
        isScanning = true
        defer { isScanning = false }
        apps = await scanner.scan()
    }

    /// 图标获取（NSWorkspace 系统图标 + NSCache 限 200）。
    func icon(for path: String) -> NSImage {
        if let cached = iconCache.object(forKey: path as NSString) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        iconCache.setObject(icon, forKey: path as NSString)
        return icon
    }
}

/// 图标墙页（A10）。
struct IconGridView: View {
    @State private var model = IconGridViewModel()

    private let columns = [
        GridItem(.adaptive(minimum: 96), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(model.filtered) { app in
                    VStack(spacing: 4) {
                        Image(nsImage: model.icon(for: app.bundlePath))
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 48, height: 48)
                        Text(app.displayName)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if let size = app.sizeBytes {
                            Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(6)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    .help(app.bundlePath)
                }
            }
            .padding()
        }
        .navigationTitle("图标墙")
        .searchable(text: $model.searchText, prompt: "搜索应用")
        .task { await model.refresh() }
        .refreshable { await model.refresh() }
        .overlay {
            LoadingOverlay(
                isLoading: model.isScanning,
                title: "正在扫描应用…",
                systemImage: "square.grid.2x2.fill",
                accent: .iconWall
            )
        }
    }
}