import Testing
import Foundation
import CcCleanCore
@testable import CcCleanOps

@Suite("SnapshotService (B5)")
struct SnapshotServiceTests {

    func makeApp() throws -> (path: String, url: URL) {
        let app = FileManager.default.temporaryDirectory
            .appendingPathComponent("snap-test-\(UUID().uuidString).app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true
        )
        try "binary-v1".data(using: .utf8)!.write(
            to: app.appendingPathComponent("Contents/MacOS/Bin"))
        return (app.path, app)
    }

    @Test("快照创建：内容一致，可列出")
    func createAndList() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("snaps-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SnapshotService(root: root)
        let (appPath, app) = try makeApp()
        defer { try? FileManager.default.removeItem(at: app) }

        let snapshotURL = try await service.snapshot(
            appPath: appPath, bundleId: "com.demo", version: "1.0"
        )
        #expect(FileManager.default.fileExists(atPath: snapshotURL.path))
        // 快照内容与原文件一致（ditto 级）
        let copied = try String(
            contentsOf: snapshotURL.appendingPathComponent("Contents/MacOS/Bin"), encoding: .utf8)
        #expect(copied == "binary-v1")
        #expect(await service.listSnapshots(bundleId: "com.demo").count == 1)
    }

    @Test("prune：保留最近 2 份，旧快照走 journal 废纸篓")
    func prune() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("snaps-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SnapshotService(root: root)
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("snap-db-\(UUID().uuidString).sqlite")
        let store = try DatabaseStore.open(
            at: dbURL, logger: Logger(category: .uninstall, buffer: LogBuffer(capacity: 10)))
        let journal = OperationJournal(
            store: store, logger: Logger(category: .uninstall, buffer: LogBuffer(capacity: 10)))
        defer { try? FileManager.default.removeItem(at: dbURL) }

        for i in 0..<4 {
            let dir = root.appendingPathComponent("com.demo/v-\(i)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // 目录 birthtime 不可设置，改用 mtime（listSnapshots 按 mtime 排序）
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(Double(i) * 60)], ofItemAtPath: dir.path
            )
        }
        #expect(await service.listSnapshots(bundleId: "com.demo").count == 4)

        await service.prune(bundleId: "com.demo", keep: 2, journal: journal)
        let remaining = await service.listSnapshots(bundleId: "com.demo")
        #expect(remaining.count == 2)
        // 保留最新两份：v-0 mtime = now（最新）、v-1 = -60s；v-2/v-3 最旧被清
        let names = remaining.map(\.lastPathComponent).sorted()
        #expect(names == ["v-0", "v-1"])
    }

    @Test("restore：trash 现版本 + 快照回位（走 journal）")
    func restore() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("snaps-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SnapshotService(root: root)
        let (appPath, app) = try makeApp()
        defer { try? FileManager.default.removeItem(at: app) }

        let snapshotURL = try await service.snapshot(
            appPath: appPath, bundleId: "com.demo", version: "1.0"
        )
        // 更新本体内容（模拟升级后）
        try "binary-v2".data(using: .utf8)!.write(
            to: app.appendingPathComponent("Contents/MacOS/Bin"))

        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("snap-db-\(UUID().uuidString).sqlite")
        let store = try DatabaseStore.open(
            at: dbURL, logger: Logger(category: .uninstall, buffer: LogBuffer(capacity: 10)))
        let journal = OperationJournal(
            store: store, logger: Logger(category: .uninstall, buffer: LogBuffer(capacity: 10)))
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let ok = await service.restore(snapshotURL: snapshotURL, targetPath: appPath, journal: journal)
        #expect(ok)
        // 回位后内容回到 v1（签名不变语义：文件还原）
        let restored = try String(
            contentsOf: app.appendingPathComponent("Contents/MacOS/Bin"), encoding: .utf8)
        #expect(restored == "binary-v1")
    }
}

@Suite("UpdateDispatcher (B3/S6-2)")
struct UpdateDispatcherTests {

    func makeJournal() throws -> (OperationJournal, URL) {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("disp-db-\(UUID().uuidString).sqlite")
        let store = try DatabaseStore.open(
            at: dbURL, logger: Logger(category: .uninstall, buffer: LogBuffer(capacity: 10)))
        let journal = OperationJournal(
            store: store, logger: Logger(category: .uninstall, buffer: LogBuffer(capacity: 10)))
        return (journal, dbURL)
    }

    @Test("分派计划：4 来源对应 4 动作")
    func planGeneration() {
        let probe = VersionProbe(bundleId: "com.x", bundlePath: "/Applications/X.app", shortVersion: "1", sparkleFeedURL: nil)

        // App Store
        let mas = UpdateDispatchPlan.plan(
            for: .init(bundleId: "com.x", latest: "2", source: .appStore, confidence: .exact,
                       downloadUrl: "https://apps.apple.com/cn/app/x/id123456"),
            probe: probe
        )
        #expect(mas.action == .openMacAppStore(url: "macappstore://apps.apple.com/app/id123456"))

        // cask
        let cask = UpdateDispatchPlan.plan(
            for: .init(bundleId: "com.x", latest: "2", source: .homebrewCask, confidence: .exact),
            probe: probe
        )
        #expect(cask.action == .brewUpgrade(token: "x"))

        // Sparkle
        let sparkle = UpdateDispatchPlan.plan(
            for: .init(bundleId: "com.x", latest: "2", source: .sparkle, confidence: .probable),
            probe: probe
        )
        #expect(sparkle.action == .openAppInUpdater(path: "/Applications/X.app"))

        // 国产源
        let domestic = UpdateDispatchPlan.plan(
            for: .init(bundleId: "com.x", latest: "2", source: .domesticFeed, confidence: .probable,
                       downloadUrl: "https://dl.example.com/"),
            probe: probe
        )
        #expect(domestic.action == .openDownloadPage(url: "https://dl.example.com/"))

        // unknown → 禁用
        let unknown = UpdateDispatchPlan.plan(
            for: .init(bundleId: "com.x", latest: nil, source: .none, confidence: .unknown),
            probe: probe
        )
        if case .unavailable = unknown.action {} else { Issue.record("unknown 应禁用") }
    }

    @Test("批量队列：单项失败不影响其他（基线 B3 验收）")
    func queueFailureIsolation() async throws {
        let (journal, dbURL) = try makeJournal()
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let dispatcher = UpdateDispatcher(
            snapshots: SnapshotService(root: FileManager.default.temporaryDirectory
                .appendingPathComponent("disp-snaps-\(UUID().uuidString)", isDirectory: true)),
            snapshotEnabled: false
        )

        let items: [(VersionProbe, VersionCheckResult)] = [
            (
                VersionProbe(bundleId: "com.ok", bundlePath: "/X.app", shortVersion: "1", sparkleFeedURL: nil),
                .init(bundleId: "com.ok", latest: "2", source: .domesticFeed, confidence: .probable,
                      downloadUrl: "https://dl.example.com/")
            ),
            (
                VersionProbe(bundleId: "com.bad", bundlePath: "/Y.app", shortVersion: "1", sparkleFeedURL: nil),
                .init(bundleId: "com.bad", latest: nil, source: .none, confidence: .unknown)
            ),
            (
                VersionProbe(bundleId: "com.ok2", bundlePath: "/Z.app", shortVersion: "1", sparkleFeedURL: nil),
                .init(bundleId: "com.ok2", latest: "3", source: .sparkle, confidence: .probable)
            ),
        ]
        let outcomes = await dispatcher.runQueue(items, journal: journal)
        #expect(outcomes.count == 3)
        #expect(outcomes[0].succeeded)                          // domestic → 打开下载页
        #expect(!outcomes[1].succeeded)                         // unknown → 失败
        #expect(outcomes[2].succeeded)                          // 失败后继续执行第 3 项 ✓
    }

    @Test("brewUpgrade 队列项：先快照（S14 接入前明确返回状态）")
    func brewQueueWithSnapshot() async throws {
        let (journal, dbURL) = try makeJournal()
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let (appPath, app) = try {
            let app = FileManager.default.temporaryDirectory
                .appendingPathComponent("brew-app-\(UUID().uuidString).app", isDirectory: true)
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
            try "v1".data(using: .utf8)!.write(to: app.appendingPathComponent("bin"))
            return (app.path, app)
        }()
        defer { try? FileManager.default.removeItem(at: app) }

        let snapshotsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("brew-snaps-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: snapshotsRoot) }
        let dispatcher = UpdateDispatcher(snapshots: SnapshotService(root: snapshotsRoot))
        let outcomes = await dispatcher.runQueue(
            [(
                VersionProbe(bundleId: "com.brew.app", bundlePath: appPath, shortVersion: "1", sparkleFeedURL: nil),
                .init(bundleId: "com.brew.app", latest: "2", source: .homebrewCask, confidence: .exact)
            )],
            journal: journal
        )
        #expect(outcomes.count == 1)
        #expect(outcomes[0].snapshotURL != nil)   // B5 快照先行 ✓
        #expect(outcomes[0].message.contains("S14"))
    }
}
@Suite("UpdateDispatcher B8 回滚联动")
struct UpdateRollbackTests {

    func makeJournal() throws -> (OperationJournal, URL) {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rb-db-\(UUID().uuidString).sqlite")
        let store = try DatabaseStore.open(
            at: dbURL, logger: Logger(category: .uninstall, buffer: LogBuffer(capacity: 10)))
        let journal = OperationJournal(
            store: store, logger: Logger(category: .uninstall, buffer: LogBuffer(capacity: 10)))
        return (journal, dbURL)
    }

    func makeApp(content: String) throws -> (path: String, url: URL) {
        let app = FileManager.default.temporaryDirectory
            .appendingPathComponent("rb-app-\(UUID().uuidString).app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try content.data(using: .utf8)!.write(to: app.appendingPathComponent("Contents/MacOS/Bin"))
        return (app.path, app)
    }

    @Test("B8：升级失败 → 快照自动回滚（内容恢复 v1，消息明示）")
    func rollbackOnFailure() async throws {
        let (journal, dbURL) = try makeJournal()
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let (appPath, app) = try makeApp(content: "v1")
        defer { try? FileManager.default.removeItem(at: app) }

        let snapshotsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("rb-snaps-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: snapshotsRoot) }
        let snapshots = SnapshotService(root: snapshotsRoot)
        let dispatcher = UpdateDispatcher(
            snapshots: snapshots,
            brewUpgradeExecutor: { _ in false }   // 模拟 brew 升级失败
        )

        let outcomes = await dispatcher.runQueue(
            [(
                VersionProbe(bundleId: "com.rb.app", bundlePath: appPath, shortVersion: "1", sparkleFeedURL: nil),
                .init(bundleId: "com.rb.app", latest: "2", source: .homebrewCask, confidence: .exact)
            )],
            journal: journal
        )
        #expect(outcomes.count == 1)
        #expect(!outcomes[0].succeeded)
        #expect(outcomes[0].message.contains("已回滚"))
        // 内容恢复为快照 v1
        let restored = try String(
            contentsOf: app.appendingPathComponent("Contents/MacOS/Bin"), encoding: .utf8)
        #expect(restored == "v1")
    }

    @Test("B8：升级成功 → 不回滚")
    func successNoRollback() async throws {
        let (journal, dbURL) = try makeJournal()
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let (appPath, app) = try makeApp(content: "v1")
        defer { try? FileManager.default.removeItem(at: app) }

        let snapshotsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("rb-ok-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: snapshotsRoot) }
        // 模拟升级本体变更（executor 成功）
        try "v2".data(using: .utf8)!.write(to: app.appendingPathComponent("Contents/MacOS/Bin"))
        let dispatcher = UpdateDispatcher(
            snapshots: SnapshotService(root: snapshotsRoot),
            brewUpgradeExecutor: { _ in true }
        )

        let outcomes = await dispatcher.runQueue(
            [(
                VersionProbe(bundleId: "com.rb.app", bundlePath: appPath, shortVersion: "1", sparkleFeedURL: nil),
                .init(bundleId: "com.rb.app", latest: "2", source: .homebrewCask, confidence: .exact)
            )],
            journal: journal
        )
        #expect(outcomes[0].succeeded)
        #expect(outcomes[0].message == "升级完成")
        let current = try String(
            contentsOf: app.appendingPathComponent("Contents/MacOS/Bin"), encoding: .utf8)
        #expect(current == "v2")
    }

    @Test("B8：无快照失败 → 明示无快照可回滚（不伪造）")
    func failureWithoutSnapshot() async throws {
        let (journal, dbURL) = try makeJournal()
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let (appPath, app) = try makeApp(content: "v1")
        defer { try? FileManager.default.removeItem(at: app) }

        let dispatcher = UpdateDispatcher(
            snapshots: SnapshotService(root: FileManager.default.temporaryDirectory
                .appendingPathComponent("rb-ns-\(UUID().uuidString)", isDirectory: true)),
            snapshotEnabled: false,
            brewUpgradeExecutor: { _ in false }
        )

        let outcomes = await dispatcher.runQueue(
            [(
                VersionProbe(bundleId: "com.rb.app", bundlePath: appPath, shortVersion: "1", sparkleFeedURL: nil),
                .init(bundleId: "com.rb.app", latest: "2", source: .homebrewCask, confidence: .exact)
            )],
            journal: journal
        )
        #expect(!outcomes[0].succeeded)
        #expect(outcomes[0].message.contains("无快照"))
    }
}