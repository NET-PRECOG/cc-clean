import Foundation
import os

/// 日志分类（基线 14.5：os_log 分 category）。
public enum LogCategory: String, CaseIterable, Sendable {
    case scan, uninstall, helper, network, metrics, general
}

/// 日志级别。
public enum LogLevel: String, Codable, Sendable, Comparable {
    case debug, info, warning, error, fault

    private var rank: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warning: return 2
        case .error: return 3
        case .fault: return 4
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// 单条日志记录。
public struct LogEntry: Codable, Sendable, Equatable {
    public let timestamp: Date
    public let category: String
    public let level: String
    public let message: String

    public init(timestamp: Date = Date(), category: String, level: String, message: String) {
        self.timestamp = timestamp
        self.category = category
        self.level = level
        self.message = message
    }
}

/// 内存环形日志缓冲：诊断包导出数据源（os_log 无法程序化读取）。
public final class LogBuffer: @unchecked Sendable {

    public static let shared = LogBuffer()

    private let lock = NSLock()
    private var entries: [LogEntry] = []
    private let capacity: Int

    public init(capacity: Int = 500) {
        self.capacity = max(capacity, 10)
    }

    public func append(_ entry: LogEntry) {
        lock.lock(); defer { lock.unlock() }
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    public func snapshot(minLevel: LogLevel = .debug) -> [LogEntry] {
        lock.lock(); defer { lock.unlock() }
        return entries.filter { LogLevel(rawValue: $0.level) ?? .debug >= minLevel }
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
    }
}

/// 统一日志出口：os_log（分类）+ 内存环形缓冲（诊断导出）。
/// 所有消息先经脱敏（用户名/家目录 → `<user>`），绝不记录文件内容、密钥、聊天正文（基线 14.5）。
public struct Logger: Sendable {

    private static let subsystem = "com.cclean.app"

    public let category: LogCategory
    private let osLog: OSLog
    private let buffer: LogBuffer
    private let minBufferLevel: LogLevel

    public init(category: LogCategory, buffer: LogBuffer = .shared, minBufferLevel: LogLevel = .debug) {
        self.category = category
        self.osLog = OSLog(subsystem: Self.subsystem, category: category.rawValue)
        self.buffer = buffer
        self.minBufferLevel = minBufferLevel
    }

    public func debug(_ message: String)   { log(.debug, message) }
    public func info(_ message: String)    { log(.info, message) }
    public func warning(_ message: String) { log(.warning, message) }
    public func error(_ message: String)   { log(.error, message) }
    public func fault(_ message: String)   { log(.fault, message) }

    public func log(_ level: LogLevel, _ message: String) {
        let sanitized = Self.sanitize(message)
        let entry = LogEntry(
            timestamp: Date(),
            category: category.rawValue,
            level: level.rawValue,
            message: sanitized
        )
        if level >= minBufferLevel {
            buffer.append(entry)
        }
        let type: OSLogType
        switch level {
        case .debug: type = .debug
        case .info: type = .info
        case .warning: type = .default
        case .error: type = .error
        case .fault: type = .fault
        }
        os_log("%{public}@", log: osLog, type: type, sanitized)
    }

    // MARK: - 脱敏

    /// 路径脱敏：家目录与用户名替换为 `<user>`。幂等。
    public static func sanitize(_ message: String) -> String {
        var result = message
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if !home.isEmpty, result.contains(home) {
            result = result.replacingOccurrences(of: home, with: "/Users/<user>")
        }
        let user = NSUserName()
        if !user.isEmpty, user.count >= 3, result.contains(user) {
            result = result.replacingOccurrences(of: user, with: "<user>")
        }
        return result
    }
}