import Foundation
import CcCleanCore

/// 更新前快照服务（B5，基线 7.2 算法 7）：
/// ditto 级复制到 Snapshots/<bundleId>/<version>-<timestamp>/，保留最近 2 份；
/// 还原 = trash 现版本 + 快照回位（全部走 OperationJournal 可撤销）。
public actor SnapshotService {

    private let snapshotsRoot: URL

    public init(root: URL? = nil) {
        self.snapshotsRoot = root ?? Paths.snapshotsDirectory
        try? FileManager.default.createDirectory(
            at: self.snapshotsRoot, withIntermediateDirectories: true
        )
    }

    /// 对应用本体做快照。返回快照目录。
    public func snapshot(appPath: String, bundleId: String, version: String?) async throws -> URL {
        let fm = FileManager.default
        let source = URL(fileURLWithPath: appPath)
        guard fm.fileExists(atPath: appPath) else {
            throw SnapshotError.sourceMissing(appPath)
        }
        let appDir = snapshotsRoot.appendingPathComponent(bundleId, isDirectory: true)
        try fm.createDirectory(at: appDir, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        let name = "\(version ?? "unknown")-\(stamp)"
        let destination = appDir.appendingPathComponent(name, isDirectory: true)
        try fm.copyItem(at: source, to: destination)
        return destination
    }

    /// 列出某应用的全部快照（按 mtime 升序；快照目录名含版本-时间戳，mtime 即创建时刻）。
    public func listSnapshots(bundleId: String) -> [URL] {
        let appDir = snapshotsRoot.appendingPathComponent(bundleId, isDirectory: true)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: appDir, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return contents
            .filter { $0.hasDirectoryPath }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return l < r
            }
    }

    /// 清理旧快照：保留最近 keep 份，多余的走 OperationJournal trash（可撤销）。
    public func prune(bundleId: String, keep: Int, journal: OperationJournal) async {
        let snapshots = listSnapshots(bundleId: bundleId)
        let stale = snapshots.dropFirst(max(keep, 0)).map(\.path)
        guard !stale.isEmpty else { return }
        let id = await journal.begin("清理旧快照 \(bundleId)")
        try? await journal.append(.trash(paths: Array(stale)), to: id)
        _ = await journal.commit(id)
    }

    /// 还原快照到目标位置（走 OperationJournal：trash 现版本 → 快照回位）。
    public func restore(
        snapshotURL: URL, targetPath: String, journal: OperationJournal
    ) async -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: snapshotURL.path) else { return false }

        let id = await journal.begin("还原快照 → \(targetPath)")
        // ① 现版本移入废纸篓（可撤销）
        if fm.fileExists(atPath: targetPath) {
            try? await journal.append(.trash(paths: [targetPath]), to: id)
        }
        let result = await journal.commit(id)
        let trashOK = result.results.first { $0.succeeded.contains(targetPath) } != nil
            || !fm.fileExists(atPath: targetPath)

        // ② 快照回位（copy 而非 move：保留快照本体）
        guard trashOK else { return false }
        do {
            try fm.copyItem(at: snapshotURL, to: URL(fileURLWithPath: targetPath))
            return true
        } catch {
            logger.log(.error, "snapshot restore failed: \(TrashServiceError.describe(error))")
            return false
        }
    }

    private let logger = Logger(category: .uninstall)
}

public enum SnapshotError: Error, Equatable {
    case sourceMissing(String)
}

/// TrashService 错误描述复用（避免跨类型耦合）。
enum TrashServiceError {
    static func describe(_ error: Error) -> String {
        (error as NSError).localizedDescription
    }
}

/// 更新分派计划（B3，基线 7.2 算法 6：按来源分派动作）。
public struct UpdateDispatchPlan: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        /// 打开 Mac App Store 页面（macappstore://）
        case openMacAppStore(url: String)
        /// brew upgrade --cask（S14 BrewService 接入）
        case brewUpgrade(token: String)
        /// 打开应用内更新（目标 App 自带 updater）
        case openAppInUpdater(path: String)
        /// 打开下载页（国产源 / 未知 Sparkle）
        case openDownloadPage(url: String)
        /// 禁用（unknown 来源）
        case unavailable(reason: String)
    }

    public let bundleId: String
    public let action: Action

    /// 按检测结果生成分派计划。
    public static func plan(for result: VersionCheckResult, probe: VersionProbe) -> UpdateDispatchPlan {
        switch (result.source, result.confidence, result.downloadUrl ?? result.notesUrl) {
        case (.appStore, .exact, let url?), (.appStore, .probable, let url?):
            // macappstore:// 直达（trackViewUrl 转换）
            if let id = url.components(separatedBy: "/id").last, id.first?.isNumber == true {
                let idPart = id.components(separatedBy: "?")[0]
                return .init(
                    bundleId: result.bundleId,
                    action: .openMacAppStore(url: "macappstore://apps.apple.com/app/id\(idPart)")
                )
            }
            return .init(bundleId: result.bundleId, action: .openDownloadPage(url: url))
        case (.homebrewCask, _, _):
            let token = ((probe.bundlePath as NSString).lastPathComponent as NSString)
                .deletingPathExtension.lowercased()
            return .init(bundleId: result.bundleId, action: .brewUpgrade(token: token))
        case (.sparkle, _, _):
            return .init(bundleId: result.bundleId, action: .openAppInUpdater(path: probe.bundlePath))
        case (.domesticFeed, _, let url?):
            return .init(bundleId: result.bundleId, action: .openDownloadPage(url: url))
        case (_, .unknown, _), (.none, _, _):
            return .init(
                bundleId: result.bundleId,
                action: .unavailable(reason: "来源未知，不提供更新动作")
            )
        default:
            return .init(bundleId: result.bundleId, action: .unavailable(reason: "来源无法确定"))
        }
    }
}

/// 批量更新队列（S6-2）：逐项执行、单项失败不影响其他、结果可重试。
public struct UpdateDispatcher: Sendable {

    public struct ItemOutcome: Sendable, Equatable {
        public let bundleId: String
        public let action: UpdateDispatchPlan.Action
        public let snapshotURL: URL?
        public let succeeded: Bool
        public let message: String
    }

    /// B8：brew 升级执行器注入（token → 成功与否；nil = S6 待接入现状）。
    public typealias BrewUpgradeExecuting = @Sendable (String) async -> Bool

    private let snapshots: SnapshotService
    private let snapshotEnabled: Bool
    private let brewUpgradeExecutor: BrewUpgradeExecuting?

    public init(
        snapshots: SnapshotService, snapshotEnabled: Bool = true,
        brewUpgradeExecutor: BrewUpgradeExecuting? = nil
    ) {
        self.snapshots = snapshots
        self.snapshotEnabled = snapshotEnabled
        self.brewUpgradeExecutor = brewUpgradeExecutor
    }

    /// 执行批量更新（预检 → 快照 → 分派动作；brewUpgrade 由 S14 BrewService 提供，
    /// S6 阶段返回「待接入」状态；单项失败不中断队列）。
    public func runQueue(
        _ items: [(probe: VersionProbe, result: VersionCheckResult)],
        journal: OperationJournal
    ) async -> [ItemOutcome] {
        var outcomes: [ItemOutcome] = []
        for (probe, result) in items {
            let plan = UpdateDispatchPlan.plan(for: result, probe: probe)
            let outcome = await runOne(probe: probe, plan: plan, journal: journal)
            outcomes.append(outcome)   // 失败不中断后续（基线 B3 验收）
        }
        return outcomes
    }

    private func runOne(
        probe: VersionProbe, plan: UpdateDispatchPlan, journal: OperationJournal
    ) async -> ItemOutcome {
        // 预检：unknown 直接失败
        if case .unavailable(let reason) = plan.action {
            return .init(bundleId: probe.bundleId, action: plan.action,
                         snapshotURL: nil, succeeded: false, message: reason)
        }

        // B5 更新前快照
        var snapshotURL: URL?
        if snapshotEnabled, case .brewUpgrade = plan.action {
            // 仅自动更新类来源需要快照；打开页面类由用户手动下载安装
            do {
                snapshotURL = try await snapshots.snapshot(
                    appPath: probe.bundlePath, bundleId: probe.bundleId, version: probe.shortVersion
                )
                // 保留最近 2 份
                await snapshots.prune(bundleId: probe.bundleId, keep: 2, journal: journal)
            } catch {
                return .init(bundleId: probe.bundleId, action: plan.action,
                             snapshotURL: nil, succeeded: false,
                             message: "快照失败：\(String(describing: error))")
            }
        }

        switch plan.action {
        case .openMacAppStore, .openDownloadPage, .openAppInUpdater:
            // 打开类动作由 UI 层执行 NSWorkspace.open（L2 层不做 UI 调用）
            return .init(bundleId: probe.bundleId, action: plan.action,
                         snapshotURL: snapshotURL, succeeded: true, message: "待用户执行")
        case .brewUpgrade(let token):
            guard let executor = brewUpgradeExecutor else {
                return .init(bundleId: probe.bundleId, action: plan.action,
                             snapshotURL: snapshotURL, succeeded: false,
                             message: "brew 升级由 S14 BrewService 提供（已快照）")
            }
            let ok = await executor(token)
            if ok {
                return .init(bundleId: probe.bundleId, action: plan.action,
                             snapshotURL: snapshotURL, succeeded: true, message: "升级完成")
            }
            // B8：升级失败 → 自动回滚到快照版本（回滚失败保留快照并明示）
            if let url = snapshotURL {
                let restored = await snapshots.restore(
                    snapshotURL: url, targetPath: probe.bundlePath, journal: journal)
                return .init(
                    bundleId: probe.bundleId, action: plan.action,
                    snapshotURL: snapshotURL, succeeded: false,
                    message: restored
                        ? "升级失败，已回滚到更新前版本"
                        : "升级失败且回滚失败，快照保留：\(url.lastPathComponent)")
            }
            return .init(bundleId: probe.bundleId, action: plan.action,
                         snapshotURL: nil, succeeded: false, message: "升级失败（无快照可回滚）")
        case .unavailable:
            return .init(bundleId: probe.bundleId, action: plan.action,
                         snapshotURL: nil, succeeded: false, message: "不可用")
        }
    }
}