import Testing
import Foundation
@testable import CcCleanCore

@Suite("Logger / DiagnosticExporter")
struct LoggerTests {

    @Test("脱敏：家目录与用户名替换为 <user>，幂等")
    func sanitize() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let user = NSUserName()
        let message = "failed to scan \(home)/Library/Caches owned by \(user)"
        let sanitized = Logger.sanitize(message)
        #expect(!sanitized.contains(home))
        #expect(!sanitized.contains(user))
        #expect(sanitized.contains("/Users/<user>/Library/Caches owned by <user>"))
        // 幂等
        #expect(Logger.sanitize(sanitized) == sanitized)
        // 短用户名（<3 字符）不替换，避免误伤
        #expect(Logger.sanitize("ab") == "ab")
    }

    @Test("Logger 写入环形缓冲，级别过滤生效")
    func logToBuffer() {
        let buffer = LogBuffer(capacity: 100)
        let logger = Logger(category: .scan, buffer: buffer)
        logger.debug("debug message /Users/x")
        logger.info("info message")
        logger.error("error message")

        let all = buffer.snapshot()
        #expect(all.count == 3)
        let errors = buffer.snapshot(minLevel: .error)
        #expect(errors.count == 1)
        #expect(errors.first?.level == "error")
        #expect(errors.first?.category == "scan")
    }

    @Test("环形缓冲容量淘汰：超过 capacity 丢弃最旧")
    func ringCapacity() {
        let buffer = LogBuffer(capacity: 10)
        for i in 0..<25 {
            buffer.append(LogEntry(category: "scan", level: "info", message: "msg-\(i)"))
        }
        let entries = buffer.snapshot()
        #expect(entries.count == 10)
        #expect(entries.first?.message == "msg-15")
        #expect(entries.last?.message == "msg-24")
    }

    @Test("诊断导出：JSON 往返解码，内容脱敏且含上下文")
    func diagnosticExport() throws {
        let buffer = LogBuffer(capacity: 50)
        let logger = Logger(category: .uninstall, buffer: buffer)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        logger.info("uninstall plan for \(home)/Applications/Demo.app")

        let exporter = DiagnosticExporter(buffer: buffer)
        let context = DiagnosticContext(
            appVersion: "1.0.0",
            moduleVersions: ["core": "0.1.0"],
            capabilityStates: ["fullDiskAccess": "granted"],
            ruleVersion: "2026.11.1"
        )
        let report = exporter.buildReport(context: context)

        #expect(report.logs.count >= 1)
        #expect(!report.logs.contains { $0.message.contains(home) })
        #expect(report.context.ruleVersion == "2026.11.0" ? false : true)
        #expect(report.context.capabilityStates["fullDiskAccess"] == "granted")

        // JSON 往返
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DiagnosticReport.self, from: data)
        #expect(decoded.logs.count == report.logs.count)
        #expect(decoded.context.appVersion == "1.0.0")

        // 文件导出（原子写）
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cclean-diag-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try exporter.export(to: url, context: context)
        let fileData = try Data(contentsOf: url)
        #expect(!fileData.isEmpty)
    }
}