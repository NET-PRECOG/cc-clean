import Foundation
import CcCleanCore

/// 残留候选目录模板（基线 9.1 residue-paths.json）。
public struct ResidueTemplate: Codable, Sendable {
    public var id: String
    public var path: String
    public var layer: String      // L2/L3/L4
    public var risk: String       // low/medium/high
    public var confidence: String // probable/possible
    public var requiresRoot: Bool

    public init(
        id: String, path: String, layer: String, risk: String,
        confidence: String, requiresRoot: Bool = false
    ) {
        self.id = id
        self.path = path
        self.layer = layer
        self.risk = risk
        self.confidence = confidence
        self.requiresRoot = requiresRoot
    }

    enum CodingKeys: String, CodingKey {
        case id, path, layer, risk, confidence, requiresRoot
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        path = try c.decode(String.self, forKey: .path)
        layer = try c.decode(String.self, forKey: .layer)
        risk = try c.decode(String.self, forKey: .risk)
        confidence = try c.decode(String.self, forKey: .confidence)
        requiresRoot = try c.decodeIfPresent(Bool.self, forKey: .requiresRoot) ?? false
    }
}

/// Spotlight 反查协议（mdfind 注入，基线 13.1：不依赖真实系统输出）。
public protocol SpotlightProviding: Sendable {
    /// kMDItemCFBundleIdentifier == '<id>' 的路径结果
    func findByBundleId(_ bundleId: String) async -> [String]
    /// displayName 全文检索结果
    func findByName(_ name: String) async -> [String]
}

/// mdfind 真实实现（缺全盘访问/无索引时返回空 → 优雅降级）。
public struct MdfindSpotlight: SpotlightProviding {
    let runner = ProcessRunner()

    public init() {}

    public func findByBundleId(_ bundleId: String) async -> [String] {
        let result = try? await runner.run(.init(
            executablePath: "/usr/bin/mdfind",
            arguments: ["kMDItemCFBundleIdentifier == '\(bundleId)'"],
            timeout: .seconds(10)
        ))
        guard let result, result.succeeded else { return [] }
        return result.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public func findByName(_ name: String) async -> [String] {
        let result = try? await runner.run(.init(
            executablePath: "/usr/bin/mdfind",
            arguments: ["\(name)"],
            timeout: .seconds(10)
        ))
        guard let result, result.succeeded else { return [] }
        return result.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// 残留扫描器（C1/C2 核心，基线 7.3 关键算法 2~7）：
/// 本体 + 正向模板点名 + 反向定位 + 内容校验升精确 + 风险分级 + 保护名单 + C12 同厂剔除。
public actor ResidueScanner {

    private let templates: [ResidueTemplate]
    private let protected: ProtectedPaths
    private let matcher = BundleIdMatcher()
    private let spotlight: SpotlightProviding
    private let logger: Logger
    private let home: String

    public init(
        templates: [ResidueTemplate],
        protected: ProtectedPaths = .builtin,
        spotlight: SpotlightProviding = MdfindSpotlight(),
        logger: Logger,
        home: String? = nil
    ) {
        self.templates = templates
        self.protected = protected
        self.spotlight = spotlight
        self.logger = logger
        self.home = home ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// 从 residue-paths.json 加载模板。
    public static func loadTemplates(from url: URL) -> [ResidueTemplate] {
        guard let data = FileManager.default.contents(atPath: url.path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["templates"] as? [[String: Any]] else {
            return []
        }
        let decoder = JSONDecoder()
        return raw.compactMap { item in
            guard let obj = try? JSONSerialization.data(withJSONObject: item),
                  let template = try? decoder.decode(ResidueTemplate.self, from: obj) else {
                return nil
            }
            return template
        }
    }

    // MARK: - 完整扫描

    /// 扫描目标应用的残留并生成卸载计划（不写盘，支撑 C15 dry-run）。
    public func scan(
        target: AppRecord,
        allApps: [AppRecord],
        launchdEntries: [LaunchdEntry] = []
    ) async -> UninstallPlan {
        var plan = UninstallPlan(app: target)
        var items: [ResidueItem] = []

        // ① L1 本体（可撤销）
        items.append(contentsOf: scanBody(target))

        // ② 正向模板点名（probable/possible）
        items.append(contentsOf: await scanByTemplates(target))

        // ③ 反向定位：Spotlight + launchd
        items.append(contentsOf: await scanBySpotlight(target))
        items.append(contentsOf: scanByLaunchd(target: target, entries: launchdEntries))

        // ④ 内容校验升精确（probable → exact）
        items = await promoteToExact(items: items, target: target)

        // ⑤ 去重（同一 path 取最高置信度）
        items = Self.dedupe(items)

        // ⑥ C12 同厂剔除 + ⑦ 保护名单 + ⑧ 风险分级
        var skippedConflicts: [SkippedConflict] = []
        var finalItems: [ResidueItem] = []
        for var item in items {
            // C12：路径属于其他应用 → 剔除（基线 R4 腾讯套件零误伤）
            if let other = matcher.belongsToOtherApp(path: item.path, target: target, allApps: allApps) {
                skippedConflicts.append(SkippedConflict(path: item.path, owner: other.displayName))
                continue
            }
            // 共享 Group Container（teamId.*）→ high 且不默认勾（基线 7.3 算法 7）
            if item.path.contains("/Group Containers/"), item.risk != .high {
                item.risk = .high
                item.reason += "；共享 Group Container，可能被同厂应用共用"
            }
            // 保护名单前置：命中即移除记 skippedProtected（绝不静默丢弃）
            if protected.isProtected(path: item.path, home: home) {
                plan.skippedProtected.append(item.path)
                continue
            }
            finalItems.append(item)
        }

        plan.items = finalItems.sorted {
            ($0.layer.rawValue, $0.confidence, $0.path)
                < ($1.layer.rawValue, $1.confidence, $1.path)
        }
        plan.skippedConflicts = skippedConflicts

        logger.info(
            "residue scan \(target.bundleId): items=\(finalItems.count) conflicts=\(skippedConflicts.count) protected=\(plan.skippedProtected.count)"
        )
        return plan
    }

    // MARK: - L1 本体

    func scanBody(_ app: AppRecord) -> [ResidueItem] {
        var items: [ResidueItem] = []
        let fm = FileManager.default
        guard fm.fileExists(atPath: app.bundlePath) else { return items }

        items.append(ResidueItem(
            path: app.bundlePath, layer: .l1Body, confidence: .exact,
            risk: app.isProtected ? .high : .medium,
            reason: "应用本体",
            undoable: true,
            bytes: FSIndex.liveSize(of: app.bundlePath)
        ))
        // 同目录同名辅助脚本（基线 7.3 L1）
        let dir = (app.bundlePath as NSString).deletingLastPathComponent
        let baseName = ((app.bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension
        for ext in ["sh", "command", "tool"] {
            let helper = dir + "/" + baseName + "." + ext
            if fm.fileExists(atPath: helper) {
                items.append(ResidueItem(
                    path: helper, layer: .l1Body, confidence: .exact,
                    risk: .low, reason: "同目录同名辅助脚本"
                ))
            }
        }
        return items
    }

    // MARK: - ② 正向模板点名

    func scanByTemplates(_ app: AppRecord) async -> [ResidueItem] {
        var items: [ResidueItem] = []
        let fm = FileManager.default
        let placeholders: [String: String] = [
            "{{bundleId}}": app.bundleId,
            "{{displayName}}": app.displayName,
            "{{bundleName}}": app.bundleName ?? app.displayName,
            "{{executableName}}": app.executableName ?? app.displayName,
            "{{teamId}}": app.teamIdentifier ?? "",
        ]

        for template in templates {
            var expandedPaths: [String] = []
            var current = [template.path]
            for (key, value) in placeholders where !value.isEmpty {
                current = current.flatMap { segment -> [String] in
                    guard segment.contains(key) else { return [segment] }
                    return [segment.replacingOccurrences(of: key, with: value)]
                }
            }
            for raw in current {
                let expanded = raw.hasPrefix("~") ? home + raw.dropFirst() : raw
                guard !expanded.contains("..") else { continue }

                if expanded.contains("*") {
                    // glob：扫父目录取匹配项
                    let parent = (expanded as NSString).deletingLastPathComponent
                    let pattern = (expanded as NSString).lastPathComponent
                    let children = (try? fm.contentsOfDirectory(atPath: parent)) ?? []
                    for child in children where RuleGlob.match(child, pattern: pattern) {
                        expandedPaths.append(parent + "/" + child)
                    }
                } else if fm.fileExists(atPath: expanded) {
                    expandedPaths.append(expanded)
                }
            }

            let layer = ResidueLayer(rawValue: template.layer.lowercased()) ?? .l2User
            let risk = RiskLevel(rawValue: template.risk) ?? .medium
            let confidence = ResidueConfidence(rawValue: template.confidence) ?? .probable
            for path in expandedPaths {
                items.append(ResidueItem(
                    path: path, layer: layer, confidence: confidence,
                    risk: risk,
                    reason: "残留模板命中（\(template.id)）",
                    requiresRoot: template.requiresRoot,
                    undoable: layer == .l3System ? false : true,
                    bytes: Self.size(of: path)
                ))
            }
        }
        return items
    }

    // MARK: - ③ 反向定位

    func scanBySpotlight(_ app: AppRecord) async -> [ResidueItem] {
        var items: [ResidueItem] = []
        // 目录白名单（基线 7.3 算法 3：mdfind 结果按目录白名单过滤）
        let allowedPrefixes = [
            home + "/Library",
            "/Applications",
            "/Library",
        ]
        var candidates: [String] = []
        candidates.append(contentsOf: await spotlight.findByBundleId(app.bundleId))
        candidates.append(contentsOf: await spotlight.findByName(app.displayName))
        for path in candidates {
            guard allowedPrefixes.contains(where: { path.hasPrefix($0) }) else { continue }
            if path == app.bundlePath { continue }   // 本体已记录
            items.append(ResidueItem(
                path: path, layer: .l2User, confidence: .possible,
                risk: .medium, reason: "Spotlight 反向定位命中"
            ))
        }
        return items
    }

    func scanByLaunchd(target: AppRecord, entries: [LaunchdEntry]) -> [ResidueItem] {
        entries.compactMap { entry in
            let related = entry.ownerBundle == target.bundleId
                || matcher.pathContains(bundleId: target.bundleId, path: entry.plistPath)
                || (entry.args.first.map { matcher.pathContainsWholeWord(name: target.displayName, path: $0) } ?? false)
            guard related else { return nil }
            return ResidueItem(
                path: entry.plistPath, layer: .l4State, confidence: .probable,
                risk: entry.isSystem ? .high : .medium,
                reason: "launchd 登记（Label \(entry.label)）",
                requiresRoot: entry.domain == "system",
                undoable: true   // bootout 可恢复
            )
        }
    }

    // MARK: - ④ 内容校验升精确

    /// plist/文本内容含 bundleId（≤ 64KB）→ probable 升 exact（基线 7.3 算法 4）。
    func promoteToExact(items: [ResidueItem], target: AppRecord) async -> [ResidueItem] {
        var result: [ResidueItem] = []
        for var item in items {
            if item.confidence == .probable || item.confidence == .possible {
                if Self.contentContains(path: item.path, needle: target.bundleId) {
                    item.confidence = .exact
                    item.reason += "；内容校验含 bundleId"
                }
            }
            result.append(item)
        }
        return result
    }

    static func contentContains(path: String, needle: String) -> Bool {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        if isDir.boolValue {
            // 目录：检查其下 plist/文本（浅层）
            let children = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            return children.contains { child in
                contentContains(path: path + "/" + child, needle: needle)
            }
        }
        let ext = (path as NSString).pathExtension.lowercased()
        guard ext == "plist" || ext == "xml" || ext == "json" || ext == "txt" || ext == "log" || ext == "sh"
            || ext.isEmpty else { return false }
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let text = String(decoding: handle.readData(ofLength: 64 * 1024), as: UTF8.self)
        return text.contains(needle)
    }

    // MARK: - 工具

    static func size(of path: String) -> Int64 {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        if isDir.boolValue {
            return FSIndex.liveSize(of: path)
        }
        return (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// 去重：同一 path 保留最高置信度与更高风险。
    static func dedupe(_ items: [ResidueItem]) -> [ResidueItem] {
        var byPath: [String: ResidueItem] = [:]
        for item in items {
            if let existing = byPath[item.path] {
                let best = item.confidence > existing.confidence ? item : existing
                byPath[item.path] = ResidueItem(
                    path: item.path, layer: item.layer, confidence: best.confidence,
                    risk: maxRisk(item.risk, existing.risk),
                    reason: best.reason, requiresRoot: item.requiresRoot || existing.requiresRoot,
                    undoable: item.undoable && existing.undoable,
                    bytes: max(item.bytes, existing.bytes), conflictsWith: item.conflictsWith
                )
            } else {
                byPath[item.path] = item
            }
        }
        return Array(byPath.values)
    }

    private static func maxRisk(_ a: RiskLevel, _ b: RiskLevel) -> RiskLevel {
        switch (a, b) {
        case (.high, _), (_, .high): return .high
        case (.medium, _), (_, .medium): return .medium
        default: return .low
        }
    }
}