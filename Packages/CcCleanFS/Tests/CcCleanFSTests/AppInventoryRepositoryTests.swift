import Testing
import Foundation
import CcCleanCore
@testable import CcCleanFS

@Suite("AppInventoryRepository (A1)")
struct AppInventoryRepositoryTests {

    func makeRepository() throws -> (AppInventoryRepository, URL) {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cclean-main-\(UUID().uuidString).sqlite")
        let store = try DatabaseStore.open(
            at: dbURL, logger: Logger(category: .scan, buffer: LogBuffer(capacity: 10))
        )
        let scanner = AppScanner(
            environment: FakeEnvironment(),
            logger: Logger(category: .scan, buffer: LogBuffer(capacity: 10))
        )
        return (AppInventoryRepository(store: store, scanner: scanner), dbURL)
    }

    @Test("refresh → loadCached 往返一致（字段完整率 100%）")
    func refreshAndCache() async throws {
        let (repo, dbURL) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let scanned = await repo.refresh()
        #expect(!scanned.isEmpty)

        let cached = await repo.loadCached()
        #expect(cached.count == scanned.count)

        let cachedById = Dictionary(uniqueKeysWithValues: cached.map { ($0.bundleId, $0) })
        for original in scanned {
            let restored = try #require(cachedById[original.bundleId])
            #expect(restored.bundlePath == original.bundlePath)
            #expect(restored.displayName == original.displayName)
            #expect(restored.shortVersion == original.shortVersion)
            #expect(restored.installSource == original.installSource)
            #expect(restored.signature == original.signature)
            #expect(restored.isProtected == original.isProtected)
            #expect(restored.installConfidence == original.installConfidence)
        }
    }

    @Test("二次启动读缓存：独立实例打开同一库可读")
    func secondLaunchReadsCache() async throws {
        let (repo, dbURL) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: dbURL) }
        _ = await repo.refresh()

        // 模拟二次启动：新开实例读同一库
        let store2 = try DatabaseStore.open(
            at: dbURL, logger: Logger(category: .scan, buffer: LogBuffer(capacity: 10))
        )
        let repo2 = AppInventoryRepository(
            store: store2,
            scanner: AppScanner(
                environment: FakeEnvironment(),
                logger: Logger(category: .scan, buffer: LogBuffer(capacity: 10))
            )
        )
        let start = Date()
        let cached = await repo2.loadCached()
        let elapsed = Date().timeIntervalSince(start)
        #expect(!cached.isEmpty)
        #expect(elapsed < 1.5)   // 基线：二次启动读缓存 < 1.5s
    }

    @Test("updateSize：体积增量落库")
    func updateSize() async throws {
        let (repo, dbURL) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let scanned = await repo.refresh()
        let target = try #require(scanned.first)

        await repo.updateSize(bundlePath: target.bundlePath, sizeBytes: 4096)
        let cached = await repo.loadCached()
        let updated = try #require(cached.first { $0.bundleId == target.bundleId })
        #expect(updated.sizeBytes == 4096)
    }
}