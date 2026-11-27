import Foundation
import GRDB
import CcCleanCore

/// 单个应用的体积更新事件（AsyncStream 增量推送，基线 5.4 数据流①）。
public struct SizeUpdate: Sendable, Equatable {
    public let bundlePath: String
    public let sizeBytes: Int64
    public let fromCache: Bool
    public let duration: Duration
}

/// 体积缓存与并发统计（基线 7.1 关键算法 3 + S1-4）：
/// mtime 未变直接读缓存；变化则重新枚举（bundle 内部下探，符号链接不计入）；
/// 并发上限 = activeProcessorCount；AsyncStream 增量推送（ViewModel 侧 100ms 节流合并）。
public actor SizeCache {

    private let pool: DatabasePool
    private let logger: Logger

    public init(database: URL, logger: Logger) throws {
        try FileManager.default.createDirectory(
            at: database.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        self.pool = try DatabasePool(path: database.path)
        self.logger = logger
        try FSSchema.migrator().migrate(pool)
    }

    /// 并发计算全部应用体积，返回增量推送流（流结束 = 全部完成）。
    public func computeSizes(appPaths: [String]) -> AsyncStream<SizeUpdate> {
        let maxConcurrent = max(2, ProcessInfo.processInfo.activeProcessorCount)
        return AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: SizeUpdate?.self) { group in
                    var inFlight = 0
                    for path in appPaths {
                        group.addTask { await self.computeOne(path: path) }
                        inFlight += 1
                        if inFlight >= maxConcurrent {
                            if let done = await group.next(), let update = done {
                                continuation.yield(update)
                            }
                            inFlight -= 1
                        }
                    }
                    for await update in group {
                        if let update { continuation.yield(update) }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 单应用体积：mtime 未变走缓存，否则现场枚举并写缓存。
    func computeOne(path: String) async -> SizeUpdate? {
        let clock = ContinuousClock.now
        guard let currentMtime = Self.topLevelMtime(of: path) else { return nil }
        let normalized = (path as NSString).standardizingPath

        // 缓存命中（mtime 未变）
        if let cached = await cachedSize(bundlePath: normalized, mtime: currentMtime) {
            return SizeUpdate(
                bundlePath: normalized, sizeBytes: cached,
                fromCache: true, duration: clock.duration(to: .now)
            )
        }

        // 现场枚举（下探 bundle 内部，符号链接不计入 —— 基线 7.1 算法 3）
        let size = FSIndex.liveSize(of: normalized)
        await store(bundlePath: normalized, mtime: currentMtime, sizeBytes: size)
        return SizeUpdate(
            bundlePath: normalized, sizeBytes: size,
            fromCache: false, duration: clock.duration(to: .now)
        )
    }

    /// 直接查缓存（mtime 未变才命中）。
    public func cachedSize(of path: String) async -> Int64? {
        let normalized = (path as NSString).standardizingPath
        guard let mtime = Self.topLevelMtime(of: path) else { return nil }
        return await cachedSize(bundlePath: normalized, mtime: mtime)
    }

    private func cachedSize(bundlePath: String, mtime: Date) async -> Int64? {
        (try? await pool.read { db in
            try Int64.fetchOne(
                db,
                sql: "SELECT size_bytes FROM size_cache WHERE bundle_path = ? AND ABS(mtime - ?) < 0.001",
                arguments: [bundlePath, mtime.timeIntervalSince1970]
            )
        }) ?? nil
    }

    private func store(bundlePath: String, mtime: Date, sizeBytes: Int64) async {
        _ = try? await pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO size_cache (bundle_path, mtime, size_bytes, updated_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(bundle_path) DO UPDATE SET
                    mtime = excluded.mtime,
                    size_bytes = excluded.size_bytes,
                    updated_at = excluded.updated_at
                """,
                arguments: [bundlePath, mtime.timeIntervalSince1970, sizeBytes, Date().timeIntervalSince1970]
            )
        }
    }

    /// 清空缓存（重建索引入口）。
    public func clear() async {
        _ = try? await pool.write { db in
            try db.execute(sql: "DELETE FROM size_cache")
        }
    }

    // MARK: - 工具

    /// 顶层 mtime（缓存失效依据）。
    static func topLevelMtime(of path: String) -> Date? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec))
    }
}