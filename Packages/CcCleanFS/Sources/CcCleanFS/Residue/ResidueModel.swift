import Foundation
import CcCleanCore

/// bundleId/名称精确匹配器（基线 7.3 关键类 BundleIdMatcher）：
/// 精确 bundleId 匹配 + 名称全词匹配，禁前缀删除（C1/C12/D2/F3/G5 复用）。
public struct BundleIdMatcher: Sendable {

    public init() {}

    /// 路径文本是否含目标 bundleId（精确词边界：`.bundleId.` / `/bundleId/` / 结尾）。
    public func pathContains(bundleId: String, path: String) -> Bool {
        guard !bundleId.isEmpty else { return false }
        let lowered = path.lowercased()
        let id = bundleId.lowercased()
        // 词边界：出现于分隔符（/ . 空格）之间
        let separators: Set<Character> = ["/", ".", " ", "\t", "-", "_"]
        var searchRange = lowered.range(of: id)
        while let range = searchRange {
            let beforeOK = range.lowerBound == lowered.startIndex
                || separators.contains(lowered[lowered.index(before: range.lowerBound)])
            let afterOK = range.upperBound == lowered.endIndex
                || separators.contains(lowered[range.upperBound])
            if beforeOK && afterOK { return true }
            let next = lowered.range(of: id, range: range.upperBound..<lowered.endIndex)
            searchRange = next
        }
        return false
    }

    /// 路径文本是否含应用显示名的**全词**（禁前缀：QQ 不能命中 QQMusic）。
    public func pathContainsWholeWord(name: String, path: String) -> Bool {
        guard !name.isEmpty else { return false }
        // 显示名做简单归一（去空格差异按原词匹配）
        let lowered = path.lowercased()
        let word = name.lowercased()
        let separators: Set<Character> = ["/", ".", " ", "\t", "-", "_", "(", ")"]
        var searchRange = lowered.range(of: word)
        while let range = searchRange {
            let beforeOK = range.lowerBound == lowered.startIndex
                || separators.contains(lowered[lowered.index(before: range.lowerBound)])
            let afterOK = range.upperBound == lowered.endIndex
                || separators.contains(lowered[range.upperBound])
            if beforeOK && afterOK { return true }
            let next = lowered.range(of: word, range: range.upperBound..<lowered.endIndex)
            searchRange = next
        }
        return false
    }

    /// 路径是否属于其他应用的资产（C12 判定核心）：
    /// 路径名含其他应用的 bundleId（精确词边界）或精确显示名（全词）。
    public func belongsToOtherApp(
        path: String, target: AppRecord, allApps: [AppRecord]
    ) -> AppRecord? {
        for other in allApps where other.bundleId != target.bundleId {
            if pathContains(bundleId: other.bundleId, path: path) {
                return other
            }
            if pathContainsWholeWord(name: other.displayName, path: path) {
                return other
            }
            if let bundleName = other.bundleName, pathContainsWholeWord(name: bundleName, path: path) {
                return other
            }
        }
        return nil
    }
}

/// 残留项置信度（基线 7.3 算法 4）。
public enum ResidueConfidence: String, Codable, Sendable, Comparable {
    case exact      // 内容校验命中（默认勾选）
    case probable   // 路径模板命中
    case possible   // 仅名称模糊命中（默认不勾）

    private var rank: Int {
        switch self {
        case .exact: return 3
        case .probable: return 2
        case .possible: return 1
        }
    }

    public static func < (lhs: ResidueConfidence, rhs: ResidueConfidence) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// 四层清理模型（基线 7.3 算法 1）。
public enum ResidueLayer: String, Codable, Sendable {
    case l1Body         // L1 应用本体（可撤销）
    case l2User         // L2 用户级残留（可撤销）
    case l3System       // L3 系统级残留（root，不可撤销）
    case l4State        // L4 关联状态（部分可撤销）
}

/// 单条残留项。
public struct ResidueItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String { path }
    public let path: String
    public let layer: ResidueLayer
    public var confidence: ResidueConfidence
    public var risk: RiskLevel
    /// 判定理由（UI 逐项展示「为什么」，基线 C4）
    public var reason: String
    public let requiresRoot: Bool
    /// 可撤销（L1/L2 trash 可恢复；L3 明确不可撤销）
    public let undoable: Bool
    /// 体积（字节，文件/目录）
    public var bytes: Int64
    /// C12：命中了哪个其他应用的路径（剔除原因展示）
    public var conflictsWith: String?

    public init(
        path: String, layer: ResidueLayer, confidence: ResidueConfidence,
        risk: RiskLevel, reason: String, requiresRoot: Bool = false,
        undoable: Bool = true, bytes: Int64 = 0, conflictsWith: String? = nil
    ) {
        self.path = path
        self.layer = layer
        self.confidence = confidence
        self.risk = risk
        self.reason = reason
        self.requiresRoot = requiresRoot
        self.undoable = undoable
        self.bytes = bytes
        self.conflictsWith = conflictsWith
    }
}

/// C12 剔除项（可 Codable 落库）。
public struct SkippedConflict: Codable, Sendable, Equatable {
    public let path: String
    public let owner: String

    public init(path: String, owner: String) {
        self.path = path
        self.owner = owner
    }
}

/// 卸载计划（基线 7.3 算法 8：生成时不写盘，天然支撑 C15 dry-run）。
public struct UninstallPlan: Codable, Sendable {
    public var planID: UUID
    public var app: AppRecord
    public var items: [ResidueItem]
    /// C12 剔除清单（透明展示：可能被 N 个同厂应用共用）
    public var skippedConflicts: [SkippedConflict]
    /// 保护名单拦截项（skippedProtected 审计展示）
    public var skippedProtected: [String]

    public init(
        planID: UUID = UUID(), app: AppRecord,
        items: [ResidueItem] = [],
        skippedConflicts: [SkippedConflict] = [],
        skippedProtected: [String] = []
    ) {
        self.planID = planID
        self.app = app
        self.items = items
        self.skippedConflicts = skippedConflicts
        self.skippedProtected = skippedProtected
    }

    /// 默认勾选集（基线 C4：exact 默认勾、probable 视风险、possible 不勾；high 永不默认勾）
    public var defaultSelected: [ResidueItem] {
        items.filter { item in
            if item.risk == .high { return false }
            switch item.confidence {
            case .exact: return true
            case .probable: return item.risk != .high
            case .possible: return false
            }
        }
    }

    /// 风险汇总（底部实时更新，基线 C4）。
    public func riskSummary(selected: [ResidueItem]) -> (total: Int, bytes: Int64, highRisk: Int, systemLevel: Int) {
        (
            selected.count,
            selected.reduce(0) { $0 + $1.bytes },
            selected.filter { $0.risk == .high }.count,
            selected.filter { $0.layer == .l3System }.count
        )
    }
}