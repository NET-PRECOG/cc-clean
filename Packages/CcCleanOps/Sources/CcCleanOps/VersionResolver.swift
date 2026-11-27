import Foundation
import GRDB
import CcCleanCore

/// 版本检测编排（B1，基线 5.4 数据流②）：
/// 并发 6、24h TTL 缓存（version_cache 表）、排除表、Provider 优先级首命中即停。
public actor VersionResolver {

    private let providers: [VersionProviding]
    private let excluded: ExcludedApps
    private let store: DatabaseStore
    private let logger: Logger
    private let concurrency: Int

    public init(
        providers: [VersionProviding],
        excluded: ExcludedApps = .empty,
        store: DatabaseStore,
        logger: Logger,
        concurrency: Int = 6
    ) {
        self.providers = providers
        self.excluded = excluded
        self.store = store
        self.logger = logger
        self.concurrency = concurrency
    }

    /// 默认 Provider 链（基线 7.2 算法 1：appStore → sparkle → homebrewCask → domesticFeed）。
    public static func defaultProviders(
        domesticFeeds: DomesticFeedProvider? = nil,
        caskProvider: HomebrewCaskProvider? = nil
    ) -> [any VersionProviding] {
        var list: [any VersionProviding] = [
            AppStoreVersionProvider(),
            SparkleVersionProvider(),
        ]
        list.append(caskProvider ?? HomebrewCaskProvider())
        if let domesticFeeds {
            list.append(domesticFeeds)
        }
        return list
    }

    /// 全量检测（并发 6 + 24h 缓存）。
    public func checkAll(
        _ probes: [VersionProbe], forceRefresh: Bool = false,
        progress: (@Sendable (VersionCheckResult) -> Void)? = nil
    ) async -> [VersionCheckResult] {
        var results: [VersionCheckResult] = []
        await withTaskGroup(of: VersionCheckResult.self) { group in
            var inFlight = 0
            for probe in probes {
                group.addTask { await self.check(probe, forceRefresh: forceRefresh) }
                inFlight += 1
                if inFlight >= concurrency {
                    if let done = await group.next() {
                        results.append(done)
                        progress?(done)
                    }
                    inFlight -= 1
                }
            }
            for await done in group {
                results.append(done)
                progress?(done)
            }
        }
        return results
    }

    /// 单应用检测（缓存 → 排除表 → Provider 链首命中即停）。
    public func check(_ probe: VersionProbe, forceRefresh: Bool = false) async -> VersionCheckResult {
        // 24h TTL 缓存（基线 B1）
        if !forceRefresh, let cached = await cached(bundleId: probe.bundleId), !cached.isStale {
            return cached
        }

        let result: VersionCheckResult
        if excluded.isExcluded(probe.bundleId) {
            // 排除表命中 → unknown（UI 显示「未知来源」不显示更新按钮）
            result = VersionCheckResult(
                bundleId: probe.bundleId, latest: nil, source: .none, confidence: .unknown
            )
        } else {
            var found: VersionCheckResult?
            for provider in providers {
                if let hit = await provider.check(probe) {
                    found = hit
                    break   // 首命中即返回（基线 7.2 算法 1）
                }
            }
            result = found ?? VersionCheckResult(
                bundleId: probe.bundleId, latest: nil, source: .none, confidence: .unknown
            )
        }

        await persist(result)
        return result
    }

    /// 更新判定：本地是否比检测到的最新版旧。
    public static func isOutdated(probe: VersionProbe, result: VersionCheckResult) -> Bool? {
        guard let local = probe.shortVersion, let latest = result.latest,
              result.confidence != .unknown else { return nil }
        switch VersionComparator.compare(candidate: latest, current: local) {
        case .newer: return true
        case .older, .same: return false
        case .incomparable: return nil
        }
    }

    // MARK: - version_cache 落库

    private func cached(bundleId: String) async -> VersionCheckResult? {
        do {
            return try await store.pool.read { db in
                try Row.fetchOne(
                    db,
                    sql: """
                    SELECT bundle_id, latest, source, confidence, download_url, notes_url, checked_at
                    FROM version_cache WHERE bundle_id = ?
                    """,
                    arguments: [bundleId]
                ).map { row in
                    VersionCheckResult(
                        bundleId: row["bundle_id"] ?? "",
                        latest: row["latest"],
                        source: VersionSource(rawValue: row["source"] ?? "") ?? .none,
                        confidence: VersionConfidence(rawValue: row["confidence"] ?? "") ?? .unknown,
                        downloadUrl: row["download_url"],
                        notesUrl: row["notes_url"],
                        checkedAt: Date(timeIntervalSince1970: row["checked_at"] ?? 0)
                    )
                }
            }
        } catch {
            return nil
        }
    }

    private func persist(_ result: VersionCheckResult) async {
        _ = try? await store.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO version_cache (
                    bundle_id, latest, source, confidence, download_url, notes_url, checked_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(bundle_id) DO UPDATE SET
                    latest = excluded.latest,
                    source = excluded.source,
                    confidence = excluded.confidence,
                    download_url = excluded.download_url,
                    notes_url = excluded.notes_url,
                    checked_at = excluded.checked_at
                """,
                arguments: [
                    result.bundleId, result.latest, result.source.rawValue,
                    result.confidence.rawValue, result.downloadUrl, result.notesUrl,
                    result.checkedAt.timeIntervalSince1970,
                ]
            )
        }
    }
}