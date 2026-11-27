import Foundation
import CcCleanCore

/// Provider 通用协议（基线 7.2：首命中即返回，不再询问后续）。
public protocol VersionProviding: Sendable {
    var source: VersionSource { get }
    /// 返回 nil = 该 provider 对此应用不适用（询问下一个）。
    func check(_ probe: VersionProbe) async -> VersionCheckResult?
}

// MARK: - App Store Provider

/// iTunes Lookup API（基线 7.2 关键算法 2）。
public struct AppStoreVersionProvider: VersionProviding {

    public let source: VersionSource = .appStore

    let network: NetworkFetching
    let country: String

    public init(network: NetworkFetching = HTTPNetworkFetcher(), country: String = "cn") {
        self.network = network
        self.country = country
    }

    public func check(_ probe: VersionProbe) async -> VersionCheckResult? {
        // 两级回退：desktopSoftware → macSoftware
        let base = "https://itunes.apple.com/lookup?bundleId=\(probe.bundleId)&country=\(country)"
        for entity in ["desktopSoftware", "macSoftware"] {
            guard let url = URL(string: "\(base)&entity=\(entity)&limit=1") else { continue }
            guard let data = try? await network.fetch(
                url, timeout: 30, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData
            ) else { continue }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["resultCount"] as? Int, results > 0,
                  let items = json["results"] as? [[String: Any]],
                  let item = items.first,
                  let version = item["version"] as? String else {
                continue   // 该 entity 未命中 → 回退
            }
            let trackUrl = (item["trackViewUrl"] as? String)
            let confidence: VersionConfidence = {
                // 与本地版本无法比较时降级 probable
                guard let local = probe.shortVersion else { return .exact }
                return VersionComparator.compare(candidate: version, current: local) == .incomparable
                    ? .probable : .exact
            }()
            return VersionCheckResult(
                bundleId: probe.bundleId, latest: version, source: .appStore,
                confidence: confidence, downloadUrl: trackUrl, notesUrl: trackUrl
            )
        }
        return nil
    }
}

// MARK: - 国产软件 Provider

/// domestic-feeds.json 驱动（基线 7.2 关键算法 5）：webPage + versionRegex / json + jsonPath。
public struct DomesticFeedProvider: VersionProviding {

    public let source: VersionSource = .domesticFeed

    public struct Feed: Codable, Sendable {
        public var bundleId: String
        public var name: String
        public var type: String        // webPage / json
        public var url: String
        public var versionRegex: String?
        public var downloadPage: String?
    }

    public struct FeedSet: Codable, Sendable {
        public var schemaVersion: Int
        public var feeds: [Feed]
    }

    let network: NetworkFetching
    let feeds: [Feed]

    public init(network: NetworkFetching = HTTPNetworkFetcher(), feeds: [Feed]) {
        self.network = network
        self.feeds = feeds
    }

    /// 从 domestic-feeds.json 加载。
    public static func load(from url: URL, network: NetworkFetching = HTTPNetworkFetcher()) -> DomesticFeedProvider? {
        guard let data = FileManager.default.contents(atPath: url.path),
              let set = try? JSONDecoder().decode(FeedSet.self, from: data) else {
            return nil
        }
        return DomesticFeedProvider(network: network, feeds: set.feeds)
    }

    public func check(_ probe: VersionProbe) async -> VersionCheckResult? {
        guard let feed = feeds.first(where: { $0.bundleId == probe.bundleId }) else { return nil }
        guard let url = URL(string: feed.url) else { return nil }
        guard let data = try? await network.fetch(url, timeout: 20) else {
            // 单源失败只影响该应用（基线 B2 验收）
            return nil
        }
        guard let regex = feed.versionRegex,
              let nsRegex = try? NSRegularExpression(pattern: regex) else { return nil }

        switch feed.type {
        case "webPage":
            // 正则从页面内容抓取版本
            let text = String(decoding: data, as: UTF8.self)
            let range = NSRange(text.startIndex..., in: text)
            guard let match = nsRegex.firstMatch(in: text, range: range),
                  match.numberOfRanges > 1,
                  let capture = Range(match.range(at: 1), in: text) else { return nil }
            let version = String(text[capture])
            return VersionCheckResult(
                bundleId: probe.bundleId, latest: version, source: .domesticFeed,
                confidence: .probable, downloadUrl: feed.downloadPage
            )
        case "json":
            guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
            // 简易 JSONPath 取首个字符串值（如 "version"）
            guard let version = Self.firstString(json, key: feed.versionRegex ?? "version") else {
                return nil
            }
            return VersionCheckResult(
                bundleId: probe.bundleId, latest: version, source: .domesticFeed,
                confidence: .probable, downloadUrl: feed.downloadPage
            )
        default:
            return nil
        }
    }

    static func firstString(_ json: Any, key: String) -> String? {
        if let dict = json as? [String: Any] {
            if let s = dict[key] as? String { return s }
            for value in dict.values {
                if let found = firstString(value, key: key) { return found }
            }
        } else if let array = json as? [Any] {
            for item in array {
                if let found = firstString(item, key: key) { return found }
            }
        }
        return nil
    }
}

// MARK: - 网络抽象（测试用 URLProtocol 桩注入，基线 13.4）

public protocol NetworkFetching: Sendable {
    func fetch(_ url: URL, timeout: TimeInterval, cachePolicy: URLRequest.CachePolicy) async throws -> Data
}

public extension NetworkFetching {
    /// 便捷重载：默认缓存策略。
    func fetch(_ url: URL, timeout: TimeInterval) async throws -> Data {
        try await fetch(url, timeout: timeout, cachePolicy: .useProtocolCachePolicy)
    }
}

/// URLSession 实现。
public struct HTTPNetworkFetcher: NetworkFetching {
    public init() {}

    public func fetch(
        _ url: URL, timeout: TimeInterval, cachePolicy: URLRequest.CachePolicy
    ) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: cachePolicy, timeoutInterval: timeout)
        request.setValue("CcClean/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}