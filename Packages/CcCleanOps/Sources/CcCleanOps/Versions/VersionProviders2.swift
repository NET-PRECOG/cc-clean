import Foundation
import GRDB
import CcCleanCore

/// Sparkle appcast 解析（基线 7.2 关键算法 3：读 SUFeedURL → 解析第一个 item；
/// SPUUserDriver 方案自 POC-T6 决策后接入）。
public struct SparkleVersionProvider: VersionProviding {

    public let source: VersionSource = .sparkle

    let network: NetworkFetching

    public init(network: NetworkFetching = HTTPNetworkFetcher()) {
        self.network = network
    }

    public func check(_ probe: VersionProbe) async -> VersionCheckResult? {
        guard let feedURLString = probe.sparkleFeedURL,
              !feedURLString.isEmpty,
              let url = URL(string: feedURLString) else { return nil }
        guard let data = try? await network.fetch(url, timeout: 20) else { return nil }

        // 解析第一个 item 的 sparkle:shortVersionString（自解析 XML，兼容老版本 updater）
        let text = String(decoding: data, as: UTF8.self)
        guard let itemRange = text.range(of: "<item>") else { return nil }
        let itemText = String(text[itemRange.lowerBound...])
        guard let endRange = itemText.range(of: "</item>") else { return nil }
        let item = String(itemText[..<endRange.upperBound])

        // 优先 shortVersionString，回退 sparkle:version
        let shortVersion = Self.extractAttribute(from: item, tag: "sparkle:shortVersionString")
            ?? Self.extractAttribute(from: item, tag: "sparkle:version")
        guard let version = shortVersion, !version.isEmpty else { return nil }

        let enclosureURL = Self.extractAttribute(from: item, tag: "url", inTag: "enclosure")
        // B6：变更日志链接（appcast 的 sparkle:releaseNotesLink，UI 展示更新说明）
        let releaseNotes = Self.extractAttribute(from: item, tag: "sparkle:releaseNotesLink")
        return VersionCheckResult(
            bundleId: probe.bundleId, latest: version, source: .sparkle,
            confidence: .probable,   // 私有 appcast → probable（基线 7.2 边界表）
            downloadUrl: enclosureURL,
            notesUrl: releaseNotes
        )
    }

    /// 提取 <tag>value</tag> 或 <tag attr="value">。
    static func extractAttribute(from text: String, tag: String, inTag: String? = nil) -> String? {
        // 1) 元素文本形式
        if let open = text.range(of: "<\(tag)>"),
           let close = text.range(of: "</\(tag)>"), open.upperBound <= close.lowerBound {
            return String(text[open.upperBound..<close.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 2) 属性形式（在指定容器 tag 内）
        if let container = inTag,
           let cOpen = text.range(of: "<\(container)"),
           let cClose = text.range(of: ">", range: cOpen.upperBound..<text.endIndex) {
            let tagText = String(text[cOpen.lowerBound..<cClose.upperBound])
            let attrPattern = "\(tag)=\"([^\"]*)\""
            if let regex = try? NSRegularExpression(pattern: attrPattern),
               let match = regex.firstMatch(in: tagText, range: NSRange(tagText.startIndex..., in: tagText)),
               match.numberOfRanges > 1,
               let r = Range(match.range(at: 1), in: tagText) {
                return String(tagText[r])
            }
        }
        return nil
    }
}

/// Homebrew cask Provider（基线 7.2 关键算法 4：拉取 cask.json → 裁剪 → token 唯一命中才采纳）。
public actor HomebrewCaskProvider: VersionProviding {

    public let source: VersionSource = .homebrewCask

    public struct TrimmedCask: Codable, Sendable {
        public var token: String
        public var version: String
    }

    private let network: NetworkFetching
    private let cacheURL: URL
    private var index: [String: String] = [:]        // token → version
    private var indexLoadedAt: Date?
    /// 索引内存 TTL（基线 T7：1 小时）
    private let indexTTL: TimeInterval = 3600

    public init(network: NetworkFetching = HTTPNetworkFetcher(), cacheURL: URL? = nil) {
        self.network = network
        self.cacheURL = cacheURL
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("cclean-cask-index.json")
    }

    public func check(_ probe: VersionProbe) async -> VersionCheckResult? {
        await ensureIndex()
        guard !index.isEmpty else { return nil }

        // token = 应用名去 .app 小写归一（基线 7.2 算法 4）
        let token = ((probe.bundlePath as NSString).lastPathComponent as NSString)
            .deletingPathExtension.lowercased()
        guard let version = index[token] else { return nil }

        return VersionCheckResult(
            bundleId: probe.bundleId, latest: version, source: .homebrewCask,
            confidence: .exact,   // cask 索引权威源
            downloadUrl: "https://formulae.brew.sh/cask/\(token)"
        )
    }

    /// 加载索引：内存 TTL → 落盘缓存 → 远端拉取裁剪（19MB → ~1.5MB）。
    private func ensureIndex() async {
        if let loadedAt = indexLoadedAt,
           Date().timeIntervalSince(loadedAt) < indexTTL, !index.isEmpty {
            return
        }
        // 落盘缓存未过期则直接用
        if let data = try? Data(contentsOf: cacheURL),
           let trimmed = try? JSONDecoder().decode([TrimmedCask].self, from: data), !trimmed.isEmpty {
            index = Dictionary(uniqueKeysWithValues: trimmed.map { ($0.token, $0.version) })
            indexLoadedAt = Date()
            return
        }
        // 远端拉取（T7：3 次成功、单次 < 8s）
        guard let url = URL(string: "https://formulae.brew.sh/api/cask.json"),
              let data = try? await network.fetch(url, timeout: 30) else {
            indexLoadedAt = Date()
            return   // 失败：该来源全部 unknown（基线 7.2 边界表）
        }
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return
        }
        let trimmed: [TrimmedCask] = array.compactMap { item in
            guard let token = item["token"] as? String,
                  let version = item["version"] as? String else { return nil }
            return TrimmedCask(token: token, version: version)
        }
        index = Dictionary(uniqueKeysWithValues: trimmed.map { ($0.token, $0.version) })
        indexLoadedAt = Date()
        // 落盘裁剪缓存
        if let out = try? JSONEncoder().encode(trimmed) {
            try? out.write(to: cacheURL, options: .atomic)
        }

    }
}