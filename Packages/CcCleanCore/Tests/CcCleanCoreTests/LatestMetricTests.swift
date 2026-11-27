import Testing
import Foundation
import GRDB
@testable import CcCleanCore

/// E14 Widget 数据源：latestMetricValue（最新一条 + 无记录降级）。
@Suite("latestMetricValue (E14 数据源)")
struct LatestMetricTests {

    @Test("最新一条：同 kind 多条返回 sampled_at 最新；无记录 → nil")
    func latestValue() async throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("latest-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let store = try DatabaseStore.open(
            at: dbURL, logger: Logger(category: .general, buffer: LogBuffer(capacity: 10)))

        // 落两条 cpuUsage（旧 55、新 80）+ 一条其他 kind
        try await store.pool.write { db in
            try db.execute(
                sql: "INSERT INTO metric_sample (kind, value, detail, sampled_at) VALUES (?, ?, NULL, ?)",
                arguments: ["cpuUsage", 55.0, Date().addingTimeInterval(-60).timeIntervalSince1970])
            try db.execute(
                sql: "INSERT INTO metric_sample (kind, value, detail, sampled_at) VALUES (?, ?, NULL, ?)",
                arguments: ["cpuUsage", 80.0, Date().timeIntervalSince1970])
            try db.execute(
                sql: "INSERT INTO metric_sample (kind, value, detail, sampled_at) VALUES (?, ?, NULL, ?)",
                arguments: ["memoryUsed", 8e9, Date().timeIntervalSince1970])
        }

        let cpu = await store.latestMetricValue(kind: "cpuUsage")
        #expect(cpu == 80.0)   // 最新时间戳优先
        let memory = await store.latestMetricValue(kind: "memoryUsed")
        #expect(memory != nil && memory! > 0)
        let missing = await store.latestMetricValue(kind: "nonexistent")
        #expect(missing == nil)
    }
}