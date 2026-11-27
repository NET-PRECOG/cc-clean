import Foundation

/// 目录常量表（基线 5.2 CcCleanCore 职责）。
/// 所有路径统一走 URL，禁止 shell 字符串拼接。
public enum Paths {

    public static let home: URL = FileManager.default.homeDirectoryForCurrentUser

    /// ~/Library/Application Support/CcClean/
    public static var appSupport: URL {
        home.appendingPathComponent("Library/Application Support/CcClean", isDirectory: true)
    }

    /// ~/Library/Application Support/CcClean/index.sqlite
    public static var indexDatabase: URL {
        appSupport.appendingPathComponent("index.sqlite")
    }

    /// ~/Library/Application Support/CcClean/cclean.sqlite
    public static var mainDatabase: URL {
        appSupport.appendingPathComponent("cclean.sqlite")
    }

    /// Helper 侧独立审计库
    public static var helperDatabase: URL {
        appSupport.appendingPathComponent("helper.sqlite")
    }

    /// ~/Library/Application Support/CcClean/journal/
    public static var journalDirectory: URL {
        appSupport.appendingPathComponent("journal", isDirectory: true)
    }

    /// ~/Library/Application Support/CcClean/Snapshots/
    public static var snapshotsDirectory: URL {
        appSupport.appendingPathComponent("Snapshots", isDirectory: true)
    }

    /// 随包签名资源根（Shared/Resources 在 Xcode 工程中以 bundle resource 提供；
    /// SPM/CLI 场景下回退到仓库内路径）。
    public static var sharedResources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Sources/CcCleanCore
            .deletingLastPathComponent()  // Sources
            .deletingLastPathComponent()  // Packages/CcCleanCore
            .deletingLastPathComponent()  // Packages
            .appendingPathComponent("Shared/Resources", isDirectory: true)
    }

    /// 确保数据目录存在（幂等）。
    public static func ensureDataDirectories() throws {
        for url in [appSupport, journalDirectory, snapshotsDirectory] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}