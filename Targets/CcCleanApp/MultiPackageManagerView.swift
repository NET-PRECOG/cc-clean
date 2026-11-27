import SwiftUI
import CcCleanCore
import CcCleanOps

/// 多包管理器页（D11，基线：npm/pnpm/uv/conda/cargo 五类全局包枚举；
/// 缺失的管理器隐藏、单类失败不影响其他）。
@Observable
@MainActor
final class MultiPackageManagerViewModel {
    private let service = MultiPackageManager(logger: Logger(category: .general))

    private(set) var packages: [GlobalPackage] = []
    private(set) var isRefreshing = false
    private(set) var message: String?

    var searchText = ""

    var grouped: [(manager: String, items: [GlobalPackage])] {
        let filtered = searchText.isEmpty ? packages : packages.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
        let dict = Dictionary(grouping: filtered, by: \.manager)
        return dict.map { (manager: $0.key, items: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.manager < $1.manager }
    }

    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        packages = await service.listAll()
        message = packages.isEmpty
            ? "未发现任何全局包（五类管理器均缺失或无包）" : nil
    }
}

struct MultiPackageManagerView: View {
    @State private var model = MultiPackageManagerViewModel()

    var body: some View {
        List {
            if let message = model.message {
                Text(message).foregroundStyle(.secondary)
            }
            ForEach(model.grouped, id: \.manager) { group in
                Section("\(group.manager)（\(group.items.count)）") {
                    ForEach(Array(group.items.enumerated()), id: \.offset) { _, pkg in
                        HStack {
                            Text(pkg.name).font(.headline)
                            Spacer()
                            Text(pkg.version ?? "--")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("多包管理器")
        .overlay(LoadingOverlay(
            isLoading: model.isRefreshing,
            title: "正在枚举全局包…",
            systemImage: "shippingbox.fill",
            accent: .packages))
        .searchable(text: $model.searchText, prompt: "搜索包名")
        .task { await model.refresh() }
        .refreshable { await model.refresh() }
    }
}