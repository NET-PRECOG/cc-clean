import Testing
import Foundation
import CcCleanCore
@testable import CcCleanOps

/// OperationJournal 测试（基线 13.1：超时/取消/失败不吞/先计划后执行/撤销语义）。
@Suite("OperationJournal (S4)")
struct OperationJournalTests {

    func makeJournal() throws -> (OperationJournal, DatabaseStore, URL) {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cclean-ops-\(UUID().uuidString).sqlite")
        let store = try DatabaseStore.open(
            at: dbURL, logger: Logger(category: .uninstall, buffer: LogBuffer(capacity: 10))
        )
        let journal = OperationJournal(
            store: store,
            logger: Logger(category: .uninstall, buffer: LogBuffer(capacity: 20))
        )
        return (journal, store, dbURL)
    }

    func tempFile(content: String = "demo") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("journal-\(UUID().uuidString).txt")
        try content.data(using: .utf8)!.write(to: url)
        return url
    }

    // MARK: - 先计划后执行

    @Test("未 commit 的事务零副作用")
    func noCommitNoSideEffect() async throws {
        let (journal, _, dbURL) = try makeJournal()
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let file = try tempFile()

        let id = await journal.begin("测试事务")
        try await journal.append(.trash(paths: [file.path]), to: id)
        // 未 commit：文件仍在
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("trash commit → 文件入废纸篓 → undo 恢复原路径")
    func trashCommitAndUndo() async throws {
        let (journal, _, dbURL) = try makeJournal()
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let file = try tempFile(content: "undo-me")

        let id = await journal.begin("卸载测试应用")
        try await journal.append(.trash(paths: [file.path]), to: id)
        let result = await journal.commit(id)

        #expect(result.succeededCount == 1)
        #expect(result.failedCount == 0)
        #expect(result.undoable)
        #expect(!FileManager.default.fileExists(atPath: file.path))

        // 撤销
        let undo = await journal.undo(id)
        #expect(undo.passed)
        #expect(undo.restored.contains { $0 == file.path || $0.contains("撤销") })
        #expect(FileManager.default.fileExists(atPath: file.path))

        let content = try? String(contentsOf: file, encoding: .utf8)
        #expect(content == "undo-me")
    }

    @Test("editPlist：修改 + undo 回写旧值")
    func editPlistUndo() async throws {
        let (journal, _, dbURL) = try makeJournal()
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let plist = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).plist")
        let dict: [String: Any] = ["RunAtLoad": true, "KeepAlive": false]
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: plist)
        defer { try? FileManager.default.removeItem(at: plist) }

        let id = await journal.begin("修改服务自启")
        try await journal.append(.editPlist(
            path: plist.path,
            mutations: [PlistMutation(key: "RunAtLoad", oldValue: nil, newValue: .boolean(false))]
        ), to: id)
        let result = await journal.commit(id)
        #expect(result.succeededCount == 1)

        // 修改生效
        let after = try PropertyListSerialization.propertyList(
            from: FileManager.default.contents(atPath: plist.path)!, options: [], format: nil
        ) as? [String: Any]
        #expect(after?["RunAtLoad"] as? Bool == false)

        // 撤销回写旧值
        let undo = await journal.undo(id)
        #expect(undo.restored.contains(plist.path))
        let restored = try PropertyListSerialization.propertyList(
            from: FileManager.default.contents(atPath: plist.path)!, options: [], format: nil
        ) as? [String: Any]
        #expect(restored?["RunAtLoad"] as? Bool == true)
    }

    @Test("removeSystem 无 Helper：全部失败且原因明确（不可撤销标记）")
    func removeSystemNeedsHelper() async throws {
        let (journal, _, dbURL) = try makeJournal()
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let id = await journal.begin("系统级删除（无 Helper）")
        try await journal.append(.removeSystem(paths: ["/Library/SomeApp/daemon"]), to: id)
        let result = await journal.commit(id)

        #expect(result.failedCount == 1)
        #expect(!result.undoable)
        let opResult = try #require(result.results.first)
        #expect(opResult.failed["/Library/SomeApp/daemon"]?.contains("辅助程序") == true)
    }

    @Test("commit 永不抛错：未知 journalID 返回空结果")
    func unknownJournalNoThrow() async {
        let (journal, _, dbURL) = try! makeJournal()
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let result = await journal.commit(UUID())
        #expect(result.results.isEmpty)
    }

    @Test("多项操作：trash 与 removeSystem 混合，单项失败不影响其他")
    func mixedOperations() async throws {
        let (journal, _, dbURL) = try makeJournal()
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let fileA = try tempFile(content: "a")

        let id = await journal.begin("混合操作")
        try await journal.append(.trash(paths: [fileA.path]), to: id)
        try await journal.append(.removeSystem(paths: ["/Library/X/daemon"]), to: id)
        let result = await journal.commit(id)

        #expect(result.succeededCount == 1)
        #expect(result.failedCount == 1)
        #expect(!FileManager.default.fileExists(atPath: fileA.path))
        #expect(result.undoable)   // trash 项可撤销
    }

    // MARK: - 审计与历史

    @Test("审计文件生成 + history/journal 查询")
    func auditAndHistory() async throws {
        let (journal, store, dbURL) = try makeJournal()
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let file = try tempFile()

        let id = await journal.begin("审计测试")
        try await journal.append(.trash(paths: [file.path]), to: id)
        _ = await journal.commit(id)

        // 审计文件存在
        let auditURL = Paths.journalDirectory.appendingPathComponent("\(id.uuidString).json")
        defer { try? FileManager.default.removeItem(at: auditURL) }
        #expect(FileManager.default.fileExists(atPath: auditURL.path))

        // history 查询
        let history = await journal.history(limit: 10)
        #expect(history.contains { $0.journalID == id })
        #expect(history.first { $0.journalID == id }?.status == "committed")

        // journal 单条
        let record = await journal.journal(id)
        #expect(record?.title == "审计测试")
        #expect(record?.ops.count == 1)
    }

    // MARK: - Operation 编码往返

    @Test("Operation Codable 往返（10 种全部）")
    func operationCodable() throws {
        let ops: [CcCleanOps.Operation] = [
            .trash(paths: ["/a", "/b"]),
            .removeSystem(paths: ["/Library/X"]),
            .backupAndRemove(paths: ["/c"], backupRoot: "/backup"),
            .bootout(plist: "/Library/LaunchDaemons/com.x.plist"),
            .bootstrap(plist: "/Library/LaunchDaemons/com.x.plist"),
            .forgetReceipt(pkgID: "com.example.pkg"),
            .resetTCC(bundleID: "com.example.app", services: ["kTCCServiceCamera"]),
            .editPlist(path: "/p.plist", mutations: [
                PlistMutation(key: "RunAtLoad", oldValue: .boolean(true), newValue: .boolean(false)),
            ]),
            .runWhitelistedCommand(executable: "/usr/bin/tmutil", args: ["listlocalsnapshots", "/"]),
            .thinBinaries(paths: ["/App.app"], keepArch: "arm64"),
        ]
        let decoder = JSONDecoder()
        for op in ops {
            let data = try JSONEncoder().encode(op)
            let decoded = try decoder.decode(Operation.self, from: data)
            #expect(decoded == op)
            #expect(decoded.affectedPaths == op.affectedPaths)
            #expect(decoded.undoable == op.undoable)
        }
    }

    @Test("撤销语义分级：trash/editPlist 可撤销，系统级不可撤销")
    func undoableSemantics() {
        #expect(Operation.trash(paths: []).undoable)
        #expect(Operation.editPlist(path: "/p", mutations: []).undoable)
        #expect(Operation.bootout(plist: "/x.plist").undoable)
        #expect(!Operation.removeSystem(paths: []).undoable)
        #expect(!Operation.forgetReceipt(pkgID: "x").undoable)
        #expect(!Operation.resetTCC(bundleID: "x", services: []).undoable)
        #expect(!Operation.thinBinaries(paths: [], keepArch: "arm64").undoable)
    }

    @Test("trash 撤销：原路径被占用时加序号后缀不覆盖")
    func undoWithOccupiedPath() async throws {
        let (journal, _, dbURL) = try makeJournal()
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let file = try tempFile(content: "original-content")

        let id = await journal.begin("占用场景")
        try await journal.append(.trash(paths: [file.path]), to: id)
        _ = await journal.commit(id)
        #expect(!FileManager.default.fileExists(atPath: file.path))

        // 原路径放新文件（占用）
        try "occupied".data(using: .utf8)!.write(to: file)

        let undo = await journal.undo(id)
        // 恢复到了带序号后缀的新路径（不覆盖占用文件）
        #expect(!undo.restored.isEmpty)
        let restoredPath = try #require(undo.restored.first)
        #expect(restoredPath != file.path)
        #expect(FileManager.default.fileExists(atPath: restoredPath))
        let content = try? String(contentsOf: URL(fileURLWithPath: restoredPath), encoding: .utf8)
        #expect(content == "original-content")
        #expect((try? String(contentsOf: file, encoding: .utf8)) == "occupied")   // 占用文件未被覆盖
        // 清理撤销产物
        try? FileManager.default.removeItem(atPath: restoredPath)
    }
}