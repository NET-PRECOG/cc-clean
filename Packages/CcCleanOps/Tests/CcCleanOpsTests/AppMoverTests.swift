import Testing
import Foundation
import CcCleanCore
@testable import CcCleanOps

@Suite("AppMover (C14 应用搬家)")
struct AppMoverTests {

    func makeJournal() throws -> (OperationJournal, URL) {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("move-db-\(UUID().uuidString).sqlite")
        let store = try DatabaseStore.open(
            at: dbURL, logger: Logger(category: .uninstall, buffer: LogBuffer(capacity: 10)))
        let journal = OperationJournal(
            store: store, logger: Logger(category: .uninstall, buffer: LogBuffer(capacity: 10)))
        return (journal, dbURL)
    }

    func makeApp(content: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("move-src-\(UUID().uuidString)", isDirectory: true)
        let app = dir.appendingPathComponent("Demo.app")
        try FileManager.default.createDirectory(
            at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try content.data(using: .utf8)!.write(to: app.appendingPathComponent("Contents/MacOS/Bin"))
        return app
    }

    @Test("同卷搬家：moveItem 原子完成，源消失、目标在")
    func sameVolumeMove() async throws {
        let (journal, dbURL) = try makeJournal()
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let app = try makeApp(content: "v1")
        defer { try? FileManager.default.removeItem(at: app) }
        let destDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("move-dest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destDir) }

        let mover = AppMover(logger: Logger(category: .uninstall, buffer: LogBuffer(capacity: 10)))
        let outcome = await mover.move(
            bundlePath: app.path, toDirectory: destDir.path, journal: journal)
        #expect(outcome.newPath == (destDir.path as NSString).appendingPathComponent(app.lastPathComponent))
        #expect(!outcome.rolledBack)
        #expect(!FileManager.default.fileExists(atPath: app.path))
        #expect(FileManager.default.fileExists(atPath: outcome.newPath!))
    }

    @Test("预检失败：源缺失/目标缺失/同名冲突 → 无副作用（不伪造成功）")
    func precheckFailures() async throws {
        let (journal, dbURL) = try makeJournal()
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let mover = AppMover(logger: Logger(category: .uninstall, buffer: LogBuffer(capacity: 10)))
        let destDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("move-pc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destDir) }

        // 源缺失
        let missing = await mover.move(
            bundlePath: "/nonexistent/X.app", toDirectory: destDir.path, journal: journal)
        #expect(missing.newPath == nil && missing.message.contains("源应用不存在"))
        // 目标目录缺失
        let app = try makeApp(content: "v1")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let noDest = await mover.move(
            bundlePath: app.path, toDirectory: "/nonexistent/dir", journal: journal)
        #expect(noDest.message.contains("目标目录不存在"))
        // 同名冲突：两个同名 Demo.app（不同目录）先后搬入同一目标
        let second = try makeApp(content: "v2")
        defer { try? FileManager.default.removeItem(at: second.deletingLastPathComponent()) }
        let first = await mover.move(bundlePath: app.path, toDirectory: destDir.path, journal: journal)
        #expect(first.newPath != nil)
        let conflict = await mover.move(bundlePath: second.path, toDirectory: destDir.path, journal: journal)
        #expect(conflict.newPath == nil && conflict.message.contains("同名"))
        #expect(FileManager.default.fileExists(atPath: second.path))   // 原位置未动
    }

    @Test("contentsConsistent：复制后一致；篡改后不一致")
    func consistencyCheck() throws {
        let dirA = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-a-\(UUID().uuidString)", isDirectory: true)
        let dirB = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-b-\(UUID().uuidString)", isDirectory: true)
        for dir in [dirA, dirB] {
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: dirA) }
        defer { try? FileManager.default.removeItem(at: dirB) }
        try "hello".data(using: .utf8)!.write(to: dirA.appendingPathComponent("f1"))
        try "hello".data(using: .utf8)!.write(to: dirA.appendingPathComponent("sub/f2"))
        try "hello".data(using: .utf8)!.write(to: dirB.appendingPathComponent("f1"))
        try "hello".data(using: .utf8)!.write(to: dirB.appendingPathComponent("sub/f2"))

        #expect(AppMover.contentsConsistent(from: dirA.path, to: dirB.path))
        // 篡改 → 不一致
        try "changed!".data(using: .utf8)!.write(to: dirB.appendingPathComponent("sub/f2"))
        #expect(!AppMover.contentsConsistent(from: dirA.path, to: dirB.path))
    }
}