import Foundation
import CcCleanCore

/// 后台项来源（H3，基线 7.8：SMAppService / backgroundtaskmanagementagent / launchd 三源合并）。
public enum BackgroundItemSource: String, Codable, Sendable {
    case launchAgent      // ~/Library/LaunchAgents（launchd 型，可开关）
    case launchDaemon     // /Library/LaunchAgents|Daemons（launchd 型，系统级只读）
    case btm              // macOS 13+ backgroundtaskmanagementagent（BTM 数据库，存在性标注）
}

/// 后台项条目（H3：与 H1/H2 的 LaunchdEntry 合并去重，BTM 源标注）。
public struct BackgroundItemEntry: Sendable, Equatable, Identifiable {
    public var id: String { "\(source.rawValue)-\(label)" }
    public let label: String
    public let source: BackgroundItemSource
    public let plistPath: String?
    public let healthy: Bool
    /// BTM 源无 plist 路径可操作——仅展示（macOS 13+ 由系统管理开关）
    public let isUserToggleable: Bool

    public init(
        label: String, source: BackgroundItemSource, plistPath: String?,
        healthy: Bool, isUserToggleable: Bool
    ) {
        self.label = label
        self.source = source
        self.plistPath = plistPath
        self.healthy = healthy
        self.isUserToggleable = isUserToggleable
    }
}

/// 后台项管理服务（H3，基线 7.8：三源合并枚举；launchd 型复用 LaunchdParser；
/// BTM（backgroundtaskmanagementagent）数据库为二进制格式，公开 API 无法解析——
/// 降级为存在性标注 + 系统设置引导，基线 H3 边界）。
public enum BackgroundItemsService {

    /// BTM 数据库文件存在性（macOS 13+ 登录项/BTM 的真实存储；解析不可行）。
    public static func btmDatabasePath(home: String) -> String {
        home + "/Library/Application Support/com.apple.backgroundtaskmanagement/BackgroundItems-v8.btm"
    }

    /// BTM 数据库是否存在（存在 → UI 提示「macOS 管理的后台项请在系统设置查看」）。
    public static func btmExists(home: String) -> Bool {
        FileManager.default.fileExists(atPath: btmDatabasePath(home: home))
    }

    /// H3 三源合并枚举：launchd 型复用 LaunchdParser（可开关）+ BTM 存在性标注。
    /// - Parameters:
    ///   - launchdEntries: LaunchdStore.refresh 产出的条目（已含归属/健康）
    public static func merge(
        home: String, launchdEntries: [LaunchdEntry]
    ) -> [BackgroundItemEntry] {
        var items: [BackgroundItemEntry] = []
        for entry in launchdEntries {
            let source: BackgroundItemSource = entry.domain == "system"
                ? (entry.plistPath.contains("LaunchDaemons") ? .launchDaemon : .launchAgent)
                : .launchAgent
            items.append(BackgroundItemEntry(
                label: entry.label, source: source, plistPath: entry.plistPath,
                healthy: entry.healthy,
                isUserToggleable: !entry.isSystem))
        }
        if btmExists(home: home) {
            items.append(BackgroundItemEntry(
                label: "macOS 管理的后台项（BTM）", source: .btm,
                plistPath: btmDatabasePath(home: home),
                healthy: true, isUserToggleable: false))
        }
        return items.sorted { ($0.source.rawValue, $0.label) < ($1.source.rawValue, $1.label) }
    }
}