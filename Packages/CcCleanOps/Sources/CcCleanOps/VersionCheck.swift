import Foundation
import CcCleanCore

/// 版本来源（基线 8.2 version_cache.source 口径）。
public enum VersionSource: String, Codable, Sendable {
    case appStore
    case sparkle
    case homebrewCask
    case domesticFeed
    case none
}

/// 置信度分级（基线 B1 验收：UI 只显示「可更新至 x（来源）」不定性表述）。
public enum VersionConfidence: String, Codable, Sendable {
    case exact      // 权威源（MAS / cask 唯一命中）
    case probable   // 私有 appcast / 宽松比较
    case unknown    // 全部未命中或命中排除表
}

/// 版本检测结果（version_cache 表内存形态）。
public struct VersionCheckResult: Codable, Sendable, Equatable {
    public var bundleId: String
    public var latest: String?
    public var source: VersionSource
    public var confidence: VersionConfidence
    public var downloadUrl: String?
    public var notesUrl: String?
    public var checkedAt: Date

    public init(
        bundleId: String, latest: String?, source: VersionSource,
        confidence: VersionConfidence, downloadUrl: String? = nil,
        notesUrl: String? = nil, checkedAt: Date = Date()
    ) {
        self.bundleId = bundleId
        self.latest = latest
        self.source = source
        self.confidence = confidence
        self.downloadUrl = downloadUrl
        self.notesUrl = notesUrl
        self.checkedAt = checkedAt
    }

    /// 缓存 TTL（基线 B1：24h）
    public var isStale: Bool {
        Date().timeIntervalSince(checkedAt) > 24 * 3600
    }
}

/// 版本检测输入（从 AppRecord 提取的最小信息）。
public struct VersionProbe: Sendable {
    public let bundleId: String
    public let bundlePath: String
    public let shortVersion: String?
    /// 目标应用 Info.plist 的 SUFeedURL（Sparkle 检测用）
    public let sparkleFeedURL: String?

    public init(bundleId: String, bundlePath: String, shortVersion: String?, sparkleFeedURL: String?) {
        self.bundleId = bundleId
        self.bundlePath = bundlePath
        self.shortVersion = shortVersion
        self.sparkleFeedURL = sparkleFeedURL
    }
}

// MARK: - 宽松版本比较器

/// 宽松版本比较（基线 7.2 边界表：`1.0.3b2` vs `1.0.3`，非数字段按字典序）。
public enum VersionComparator {

    public enum Order: Sendable, Equatable {
        case older, same, newer, incomparable
    }

    /// 判断 candidate 是否比 current 更新。
    /// 无法比较时返回 incomparable（调用方降级 confidence = probable）。
    public static func compare(candidate: String, current: String) -> Order {
        let left = tokenize(candidate)
        let right = tokenize(current)
        guard !left.isEmpty, !right.isEmpty else { return .incomparable }

        let count = max(left.count, right.count)
        for i in 0..<count {
            let l = i < left.count ? left[i] : "0"
            let r = i < right.count ? right[i] : "0"
            if l == r { continue }

            // 双方均为纯数字 → 数值比较
            if let li = Int(l), let ri = Int(r) {
                return li > ri ? .newer : (li < ri ? .older : .same)
            }
            // 混合段：纯数字大于数字开头的混合段（"1.0.3" 的 "0" vs "1.0.3b2" 的 "0b2"——
            // "0" 与 "0b2" 数字前缀相同则比较后缀字典序）
            let lDigits = l.prefix { $0.isNumber }
            let rDigits = r.prefix { $0.isNumber }
            if lDigits == rDigits, !lDigits.isEmpty {
                let lSuffix = String(l.dropFirst(lDigits.count))
                let rSuffix = String(r.dropFirst(rDigits.count))
                if lSuffix.isEmpty { return .older }      // "0" < "0b2"？——3 < 3b2 → current 旧
                if rSuffix.isEmpty { return .newer }
                return lSuffix > rSuffix ? .newer : .older
            }
            // 字典序兜底
            return l > r ? .newer : .older
        }
        return .same
    }

    /// 切分版本号：按 `.` 与数字/非数字边界。
    static func tokenize(_ version: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var lastWasDigit: Bool?
        for ch in version.lowercased() {
            let isDigit = ch.isNumber
            if let last = lastWasDigit, isDigit != last {
                tokens.append(current)
                current = ""
            }
            if ch == "." || ch == "-" || ch == "_" {
                if !current.isEmpty { tokens.append(current); current = "" }
                lastWasDigit = nil
                continue
            }
            current.append(ch)
            lastWasDigit = isDigit
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens.filter { !$0.isEmpty }
    }
}

// MARK: - 排除表（excluded-apps.plist）

/// 版本检测排除表（B1）：命中 bundleId 直接返回 unknown（UI 显示「未知来源」）。
public struct ExcludedApps: Sendable {

    public struct Entry: Sendable, Equatable {
        public let bundleId: String
        public let reason: String
    }

    public let entries: [Entry]

    public static let empty = ExcludedApps(entries: [])

    /// 从 plist 加载（Shared/Resources/excluded-apps.plist）。
    public static func load(from url: URL) -> ExcludedApps {
        guard let data = FileManager.default.contents(atPath: url.path),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                as? [String: Any],
              let raw = plist["entries"] as? [[String: Any]] else {
            return .empty
        }
        let entries = raw.compactMap { item -> Entry? in
            guard let bundleId = item["bundleId"] as? String,
                  let reason = item["reason"] as? String else { return nil }
            return Entry(bundleId: bundleId, reason: reason)
        }
        return ExcludedApps(entries: entries)
    }

    public func isExcluded(_ bundleId: String) -> Bool {
        entries.contains { $0.bundleId == bundleId }
    }
}