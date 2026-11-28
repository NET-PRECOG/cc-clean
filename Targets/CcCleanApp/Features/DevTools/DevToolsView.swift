import SwiftUI
import CcCleanCore
import CcCleanFS
import CcCleanOps

/// 开发环境页（M 组，基线 7.5）：M2 开发缓存 / M3 JDK 切换 / M5 PATH 冲突。
@Observable
@MainActor
final class DevToolsViewModel {
    private let jdkService = JDKService(logger: Logger(category: .general))
    private let pathDetector = PathConflictDetector()
    private let devEnvService = DevEnvService(
        ruleEngine: RuleEngine(protected: .builtin, logger: Logger(category: .scan)),
        logger: Logger(category: .general))

    private(set) var jdks: [JDKEntry] = []
    private(set) var currentJavaHome: String?
    private(set) var pathConflicts: [PATHConflict] = []
    private(set) var cacheItems: [DevCacheItem] = []
    private(set) var message: String?

    var selectedCaches: Set<String> = []

    func refresh(store: DatabaseStore) async {
        jdks = await jdkService.list()
        currentJavaHome = await jdkService.currentJavaHome()
        let exports = await pathDetector.parseProfiles(home: NSHomeDirectory())
        pathConflicts = pathDetector.detect(exports: exports)
        cacheItems = await devEnvService.inventory()
        selectedCaches = []
    }

    /// M3：切换 JAVA_HOME（托管区块写入 ~/.zshrc，走 journal 可撤销）。
    func switchJdk(_ entry: JDKEntry, store: DatabaseStore) async {
        let profile = NSHomeDirectory() + "/.zshrc"
        let ok = await jdkService.switchTo(entry, profilePath: profile)
        message = ok ? "已切换 JAVA_HOME → \(entry.version)（重启终端生效）"
                     : "切换失败（homePath 不存在或写入失败）"
        if ok {
            jdks = await jdkService.list()
            currentJavaHome = await jdkService.currentJavaHome()
        }
    }

    /// M2：清理勾选缓存（trash 可撤销）。
    func cleanSelected(store: DatabaseStore) async {
        let selected = cacheItems.filter { selectedCaches.contains($0.id) }
        let journal = OperationJournalHolder.shared(store: store)
        let result = await devEnvService.clean(selected, journal: journal)
        message = "缓存清理：成功 \(result.succeeded.count) 项，失败 \(result.failed.count) 项"
        await refresh(store: store)
    }
}

/// 开发环境页（M2/M3/M5）。
struct DevToolsView: View {
    @State private var model = DevToolsViewModel()
    @State private var isRefreshing = false

    var body: some View {
        List {
            if let message = model.message {
                Text(message).font(.footnote).foregroundStyle(.orange)
            }

            Section("JDK（M3）") {
                if model.jdks.isEmpty {
                    Text("未发现 JDK（三处枚举均无）").foregroundStyle(.secondary)
                }
                ForEach(model.jdks) { jdk in
                    HStack {
                        VStack(alignment: .leading) {
                            Text("\(jdk.vendor) \(jdk.version)").font(.headline)
                            Text("\(jdk.source) · \(jdk.homePath)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if jdk.isCurrent {
                            Text("当前").font(.caption).foregroundStyle(.green)
                        } else {
                            Button("切换") {
                                Task { await model.switchJdk(jdk, store: DatabaseStoreHolder.shared) }
                            }
                        }
                    }
                }
                if let home = model.currentJavaHome {
                    Text("生效 JAVA_HOME：\(home)").font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("PATH 冲突（M5）") {
                if model.pathConflicts.isEmpty {
                    Text("无冲突").foregroundStyle(.secondary)
                }
                ForEach(Array(model.pathConflicts.enumerated()), id: \.offset) { _, conflict in
                    VStack(alignment: .leading) {
                        Text("\(conflict.kind.rawValue)：\(conflict.directory)").font(.headline)
                        Text("发现来源：\(conflict.source)\(conflict.shadowedBy.map { " · 被 \($0) 覆盖" } ?? "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section("开发缓存（M2）") {
                if model.cacheItems.isEmpty {
                    Text("无缓存项").foregroundStyle(.secondary)
                }
                ForEach(model.cacheItems) { item in
                    HStack {
                        Toggle("", isOn: Binding(
                            get: { model.selectedCaches.contains(item.id) },
                            set: { on in
                                if on { model.selectedCaches.insert(item.id) }
                                else { model.selectedCaches.remove(item.id) }
                            }))
                        .labelsHidden()
                        VStack(alignment: .leading) {
                            Text(item.title).font(.headline)
                            Text("\(item.path) · \(CCleanTheme.formatBytes(item.bytes))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Button("清理勾选（可撤销）") {
                    Task { await model.cleanSelected(store: DatabaseStoreHolder.shared) }
                }
                .disabled(model.selectedCaches.isEmpty)
            }
        }
        .overlay(LoadingOverlay(
            isLoading: isRefreshing,
            title: "正在加载开发环境…",
            systemImage: "hammer.fill",
            accent: .devTools))
        .navigationTitle("开发环境")
        .task {
            isRefreshing = true
            await model.refresh(store: DatabaseStoreHolder.shared)
            isRefreshing = false
        }
    }
}