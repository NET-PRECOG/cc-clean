import Foundation

/// 诊断上下文：由 App 层在导出时装配（模块版本、能力状态、规则版本）。
public struct DiagnosticContext: Codable, Sendable {
    public var appVersion: String
    public var moduleVersions: [String: String]
    public var capabilityStates: [String: String]
    public var ruleVersion: String
    public var systemVersion: String

    public init(
        appVersion: String,
        moduleVersions: [String: String],
        capabilityStates: [String: String],
        ruleVersion: String,
        systemVersion: String = ProcessInfo.processInfo.operatingSystemVersionString
    ) {
        self.appVersion = appVersion
        self.moduleVersions = moduleVersions
        self.capabilityStates = capabilityStates
        self.ruleVersion = ruleVersion
        self.systemVersion = systemVersion
    }
}

/// 诊断报告（基线 14.5：日志 + 版本 + 能力状态 + 规则版本，路径脱敏；不含文件内容）。
public struct DiagnosticReport: Codable, Sendable {
    public var generatedAt: Date
    public var context: DiagnosticContext
    public var logs: [LogEntry]
}

public enum DiagnosticExportError: Error, Equatable {
    case emptyLogs
}

/// 诊断包一键导出。
public struct DiagnosticExporter: Sendable {

    let buffer: LogBuffer

    public init(buffer: LogBuffer = .shared) {
        self.buffer = buffer
    }

    /// 生成报告结构（可先行预览——用户发送前可见内容）。
    public func buildReport(context: DiagnosticContext, minLevel: LogLevel = .info) -> DiagnosticReport {
        DiagnosticReport(
            generatedAt: Date(),
            context: context,
            logs: buffer.snapshot(minLevel: minLevel).map { entry in
                LogEntry(
                    timestamp: entry.timestamp,
                    category: entry.category,
                    level: entry.level,
                    message: Logger.sanitize(entry.message)
                )
            }
        )
    }

    /// 写出 JSON 文件。`.atomic` 原子写（基线 6.3 要点 6）。
    public func export(to url: URL, context: DiagnosticContext, minLevel: LogLevel = .info) throws {
        let report = buildReport(context: context, minLevel: minLevel)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        try data.write(to: url, options: .atomic)
    }
}