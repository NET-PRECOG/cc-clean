import Foundation
import CcCleanCore
import CcCleanFS

/// 开发环境缓存盘点项（M2/M5）。
public struct DevCacheItem: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public let path: String
    public let ruleId: String
    public let title: String
    public let bytes: Int64
    public let reason: String

    public init(path: String, ruleId: String, title: String, bytes: Int64, reason: String) {
        self.path = path
        self.ruleId = ruleId
        self.title = title
        self.bytes = bytes
        self.reason = reason
    }
}

/// 开发环境专项服务（M2 七类包管理器缓存 + M5 Xcode 缓存，基线 7.5）：
/// 盘点 = RuleEngine devenv 规则评估（只读，体积与 du 误差 < 2%）；
/// 清理 = 选中项 trash（走 OperationJournal 可撤销）。
public actor DevEnvService {

    private let ruleEngine: RuleEngine
    private let logger: Logger

    public init(ruleEngine: RuleEngine, logger: Logger) {
        self.ruleEngine = ruleEngine
        self.logger = logger
    }

    /// 便捷构造：加载内置 devenv 规则（Shared/Resources/rules/devenv/devenv-cache.json）。
    public static func makeDefault(logger: Logger) -> DevEnvService {
        let rulesRoot = Paths.sharedResources.appendingPathComponent("rules", isDirectory: true)
        var rules: [RuleFile] = []
        let cacheFile = rulesRoot
            .appendingPathComponent("devenv", isDirectory: true)
            .appendingPathComponent("devenv-cache.json")
        if let data = FileManager.default.contents(atPath: cacheFile.path),
           case .success(let pack) = RuleValidator.validateJSON(data) {
            rules = pack.rules
        }
        let engine = RuleEngine(protected: .builtin, logger: logger)
        Task {
            try? await engine.load(rules)
        }
        return DevEnvService(ruleEngine: engine, logger: logger)
    }

    /// 盘点（只读，不写盘）。
    public func inventory() async -> [DevCacheItem] {
        let hits = await ruleEngine.evaluate(RuleContext(scope: .devenv, budget: .seconds(15)))
        return hits.flatMap { hit in
            hit.paths.map { path in
                DevCacheItem(
                    path: path, ruleId: hit.rule.id, title: hit.rule.title,
                    bytes: hit.totalBytes,
                    reason: hit.rule.explain
                )
            }
        }
    }

    /// 清理选中项（trash 可撤销；清理后可重建——基线 M2 验收）。
    public func clean(
        _ selected: [DevCacheItem], journal: OperationJournal
    ) async -> (succeeded: [String], failed: [String: String]) {
        let paths = selected.map(\.path)
        guard !paths.isEmpty else { return ([], [:]) }
        let id = await journal.begin("开发环境缓存清理（\(selected.count) 项）")
        try? await journal.append(.trash(paths: paths), to: id)
        let result = await journal.commit(id)
        let ok = result.results.first?.succeeded ?? []
        let failed = result.results.first?.failed ?? [:]
        logger.info("devenv clean: ok=\(ok.count) failed=\(failed.count)")
        return (ok, failed)
    }
}