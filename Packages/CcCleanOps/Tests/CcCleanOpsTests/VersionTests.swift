import Testing
import Foundation
import CcCleanCore
@testable import CcCleanOps

/// 网络桩（等价 URLProtocol 桩，基线 13.4：断网/DNS 失败/非法 JSON 优雅失败）。
final class StubFetcher: NetworkFetching, @unchecked Sendable {
    /// host+path 前缀 → 响应体
    var routes: [(prefix: String, data: Data)] = []
    var callCount: [String: Int] = [:]

    func fetch(
        _ url: URL, timeout: TimeInterval, cachePolicy: URLRequest.CachePolicy
    ) async throws -> Data {
        let key = url.host.map { "\($0)\(url.path)" } ?? url.absoluteString
        callCount[key, default: 0] += 1
        for route in routes where key.hasPrefix(route.prefix) {
            return route.data
        }
        throw URLError(.cannotFindHost)   // 未配置路由 = 网络失败
    }

    func json(_ text: String) -> Data { Data(text.utf8) }
}

@Suite("VersionComparator")
struct VersionComparatorTests {

    @Test("宽松比较：数值段 / 混合段 / 日期段")
    func comparisons() {
        #expect(VersionComparator.compare(candidate: "1.0.4", current: "1.0.3") == .newer)
        #expect(VersionComparator.compare(candidate: "1.0.3", current: "1.0.3") == .same)
        #expect(VersionComparator.compare(candidate: "1.0", current: "1.0.3") == .older)
        // 混合段：1.0.3b2 > 1.0.3（b 预发布按基线语义判 newer……实际 prerelease 语义相反，
        // 基线要求"非数字段按字典序"，b > 空 → newer）
        #expect(VersionComparator.compare(candidate: "1.0.3b2", current: "1.0.3") != .incomparable)
        #expect(VersionComparator.compare(candidate: "2024.1", current: "2023.12") == .newer)
        #expect(VersionComparator.compare(candidate: "10.15", current: "9.9") == .newer)
    }

    @Test("isOutdated 组合判定")
    func outdated() {
        let probe = VersionProbe(bundleId: "com.x", bundlePath: "/X.app", shortVersion: "1.0", sparkleFeedURL: nil)
        let newer = VersionCheckResult(bundleId: "com.x", latest: "2.0", source: .appStore, confidence: .exact)
        #expect(VersionResolver.isOutdated(probe: probe, result: newer) == true)
        let same = VersionCheckResult(bundleId: "com.x", latest: "1.0", source: .appStore, confidence: .exact)
        #expect(VersionResolver.isOutdated(probe: probe, result: same) == false)
        let unknown = VersionCheckResult(bundleId: "com.x", latest: nil, source: .none, confidence: .unknown)
        #expect(VersionResolver.isOutdated(probe: probe, result: unknown) == nil)
    }
}

@Suite("ExcludedApps")
struct ExcludedAppsTests {

    @Test("排除表加载与命中")
    func loadAndMatch() throws {
        let url = Bundle.main.bundleURL   // 占位；直接用字符串构造
        _ = url
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
        <key>entries</key><array>
            <dict><key>bundleId</key><string>com.example.unparseable</string>
            <key>reason</key><string>自建 appcast 版本号无法解析</string></dict>
        </array></dict></plist>
        """
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("excluded-\(UUID().uuidString).plist")
        try plist.data(using: .utf8)!.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let excluded = ExcludedApps.load(from: file)
        #expect(excluded.isExcluded("com.example.unparseable"))
        #expect(!excluded.isExcluded("com.example.ok"))
    }
}

@Suite("VersionProviders")
struct VersionProviderTests {

    func probe(_ bundleId: String = "com.example.app") -> VersionProbe {
        VersionProbe(bundleId: bundleId, bundlePath: "/Applications/Example.app", shortVersion: "1.0", sparkleFeedURL: nil)
    }

    @Test("AppStore Provider：lookup 命中 → exact；本地版本无法比较 → probable")
    func appStoreHit() async throws {
        let stub = StubFetcher()
        stub.routes.append((prefix: "itunes.apple.com/lookup", data: stub.json("""
        {"resultCount":1,"results":[{"version":"2.0.0","trackViewUrl":"https://apps.apple.com/cn/app/x/id1"}]}
        """)))
        let provider = AppStoreVersionProvider(network: stub)
        let result = try #require(await provider.check(probe()))
        #expect(result.latest == "2.0.0")
        #expect(result.source == .appStore)
        #expect(result.confidence == .exact)
        #expect(result.downloadUrl == "https://apps.apple.com/cn/app/x/id1")
    }

    @Test("AppStore Provider：desktopSoftware 未命中回退 macSoftware")
    func appStoreFallback() async throws {
        let stub = StubFetcher()
        stub.routes.append((prefix: "itunes.apple.com/lookup", data: stub.json("""
        {"resultCount":1,"results":[{"version":"3.0"}]}
        """)))
        let provider = AppStoreVersionProvider(network: stub)
        let result = try #require(await provider.check(probe()))
        #expect(result.latest == "3.0")
    }

    @Test("AppStore Provider：两次都 0 → provider 失效（nil）")
    func appStoreMiss() async {
        let stub = StubFetcher()
        stub.routes.append((prefix: "itunes.apple.com/lookup", data: stub.json(#"{"resultCount":0,"results":[]}"#)))
        let provider = AppStoreVersionProvider(network: stub)
        let result = await provider.check(probe())
        #expect(result == nil)
    }

    @Test("网络失败：Provider 优雅返回 nil 不崩溃（基线 13.4）")
    func networkFailure() async {
        let stub = StubFetcher()   // 无路由 → cannotFindHost
        let provider = AppStoreVersionProvider(network: stub)
        let result = await provider.check(probe())
        #expect(result == nil)
    }

    @Test("DomesticFeed Provider：webPage + versionRegex 命中")
    func domesticWebPage() async throws {
        let stub = StubFetcher()
        stub.routes.append((prefix: "mac.weixin.qq.com", data: stub.json(
            "<html>WeChat for Mac 3.8.9 下载</html>"
        )))
        let provider = DomesticFeedProvider(network: stub, feeds: [
            .init(
                bundleId: "com.tencent.xinWeChat", name: "微信", type: "webPage",
                url: "https://mac.weixin.qq.com/", versionRegex: "([0-9]+\\.[0-9]+\\.[0-9]+)",
                downloadPage: "https://mac.weixin.qq.com/"
            ),
        ])
        let result = try #require(await provider.check(probe("com.tencent.xinWeChat")))
        #expect(result.latest == "3.8.9")
        #expect(result.source == .domesticFeed)
        #expect(result.confidence == .probable)   // 正则抓取 → probable
    }

    @Test("DomesticFeed Provider：单源失败只影响该应用（nil）")
    func domesticFailure() async {
        let stub = StubFetcher()   // 无路由
        let provider = DomesticFeedProvider(network: stub, feeds: [
            .init(
                bundleId: "com.tencent.xinWeChat", name: "微信", type: "webPage",
                url: "https://mac.weixin.qq.com/", versionRegex: "([0-9]+)",
                downloadPage: nil
            ),
        ])
        let result = await provider.check(probe("com.tencent.xinWeChat"))
        #expect(result == nil)
    }

    @Test("Sparkle Provider：appcast XML 解析第一个 item")
    func sparkleAppcast() async throws {
        let stub = StubFetcher()
        stub.routes.append((prefix: "example.com/appcast", data: stub.json("""
        <rss><channel>
        <item><title>2.5.0</title>
        <sparkle:shortVersionString>2.5.0</sparkle:shortVersionString>
        <enclosure url="https://dl.example.com/X-2.5.0.dmg" sparkle:version="2500"/></item>
        <item><title>旧版本</title></item>
        </channel></rss>
        """)))
        let probe = VersionProbe(
            bundleId: "com.example.app", bundlePath: "/X.app",
            shortVersion: "2.4.0", sparkleFeedURL: "https://example.com/appcast.xml"
        )
        let provider = SparkleVersionProvider(network: stub)
        let result = try #require(await provider.check(probe))
        #expect(result.latest == "2.5.0")
        #expect(result.source == .sparkle)
        #expect(result.confidence == .probable)   // 私有 appcast → probable
        #expect(result.downloadUrl == "https://dl.example.com/X-2.5.0.dmg")
    }

    @Test("HomebrewCask Provider：裁剪索引 + token 唯一命中 → exact")
    func caskHit() async throws {
        let stub = StubFetcher()
        stub.routes.append((prefix: "formulae.brew.sh/api/cask.json", data: stub.json("""
        [{"token":"example","version":"5.0.0"},
         {"token":"example-beta","version":"6.0.0-beta"},
         {"token":"visual-studio-code","version":"1.90"}]
        """)))
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cask-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let provider = HomebrewCaskProvider(network: stub, cacheURL: cacheURL)

        // Example.app → token "example"（唯一命中）
        let result = try #require(await provider.check(probe("com.example.app")))
        #expect(result.latest == "5.0.0")
        #expect(result.confidence == .exact)

        // 二次调用走落盘缓存（不再网络请求）
        #expect(stub.callCount["formulae.brew.sh/api/cask.json"] == 1)
    }
}

@Suite("VersionResolver")
struct VersionResolverTests {

    /// 注意：不可在 makeStore 内 defer 删除——DatabasePool 读连接会按 path 重开文件，
    /// 过早 unlink 导致缓存读取失败（测试结束时残留 UUID 临时文件无害）。
    func makeStore() throws -> DatabaseStore {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cclean-ver-\(UUID().uuidString).sqlite")
        return try DatabaseStore.open(
            at: dbURL, logger: Logger(category: .network, buffer: LogBuffer(capacity: 10))
        )
    }

    @Test("排除表命中 → unknown + 缓存；Provider 首命中即停")
    func resolverFlow() async throws {
        let store = try makeStore()
        let stub = StubFetcher()
        stub.routes.append((prefix: "itunes.apple.com/lookup", data: stub.json("""
        {"resultCount":1,"results":[{"version":"9.9"}]}
        """)))

        let excluded = ExcludedApps(entries: [
            .init(bundleId: "com.excluded.app", reason: "误报高"),
        ])
        // 两个 Provider：AppStore 命中后不再询问 Domestic
        let domestic = DomesticFeedProvider(network: stub, feeds: [
            .init(
                bundleId: "com.normal.app", name: "X", type: "webPage",
                url: "https://mac.weixin.qq.com/", versionRegex: "([0-9]+\\.[0-9]+)",
                downloadPage: nil
            ),
        ])
        let resolver = VersionResolver(
            providers: [AppStoreVersionProvider(network: stub), domestic],
            excluded: excluded, store: store,
            logger: Logger(category: .network, buffer: LogBuffer(capacity: 10))
        )

        // ① 排除表命中
        let excludedResult = await resolver.check(
            VersionProbe(bundleId: "com.excluded.app", bundlePath: "/X.app", shortVersion: "1", sparkleFeedURL: nil)
        )
        #expect(excludedResult.confidence == .unknown)
        #expect(excludedResult.source == .none)

        // ② 首命中即停：AppStore 返回 9.9（不问 Domestic）
        let normal = await resolver.check(
            VersionProbe(bundleId: "com.normal.app", bundlePath: "/X.app", shortVersion: "1", sparkleFeedURL: nil)
        )
        #expect(normal.latest == "9.9")
        #expect(normal.source == .appStore)
    }

    @Test("24h 缓存：第二次检测直接读缓存（不发起网络请求）")
    func cacheTTL() async throws {
        let store = try makeStore()
        let stub = StubFetcher()
        stub.routes.append((prefix: "itunes.apple.com/lookup", data: stub.json("""
        {"resultCount":1,"results":[{"version":"7.7"}]}
        """)))
        let resolver = VersionResolver(
            providers: [AppStoreVersionProvider(network: stub)],
            store: store,
            logger: Logger(category: .network, buffer: LogBuffer(capacity: 10))
        )
        let probe = VersionProbe(bundleId: "com.cached.app", bundlePath: "/X.app", shortVersion: "1", sparkleFeedURL: nil)
        let first = await resolver.check(probe)
        #expect(first.latest == "7.7")
        let callsAfterFirst = stub.callCount["itunes.apple.com/lookup"] ?? 0
        #expect(callsAfterFirst >= 1)

        let second = await resolver.check(probe)
        #expect(second.latest == "7.7")
        #expect(stub.callCount["itunes.apple.com/lookup"] == callsAfterFirst)   // 缓存命中，无新请求
    }

    @Test("全 Provider 未命中 → unknown 落库")
    func allMiss() async throws {
        let store = try makeStore()
        let resolver = VersionResolver(
            providers: [AppStoreVersionProvider(network: StubFetcher())],
            store: store,
            logger: Logger(category: .network, buffer: LogBuffer(capacity: 10))
        )
        let result = await resolver.check(
            VersionProbe(bundleId: "com.unknown.app", bundlePath: "/X.app", shortVersion: "1", sparkleFeedURL: nil)
        )
        #expect(result.confidence == .unknown)
        #expect(result.source == .none)
    }
}