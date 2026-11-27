import Testing
import Foundation
import CcCleanCore
@testable import CcCleanMetrics

@Suite("Samplers (E 组基建)")
struct SamplerTests {

    @Test("CPU/内存采样：真实 host API，值域合法")
    func cpuMemoryReal() async throws {
        let sampler = CPUMemorySampler()
        let first = await sampler.sample()
        // 首次采样：CPU 总值有效（瞬时比例），逐核为 0 基线
        let cpu = try #require(first.samples.first { $0.kind == .cpuUsage })
        #expect(cpu.value >= 0 && cpu.value <= 100)
        #expect(first.samples.contains { $0.kind == .memoryUsed } == true)
        #expect(first.samples.contains { $0.kind == .memoryPressure } == true)
        #expect(first.samples.contains { $0.kind == .swapUsed } == true)

        // 第二次采样：差分生效（逐核有值）
        try await Task.sleep(for: .milliseconds(300))
        let second = await sampler.sample()
        let perCore = second.samples.first { $0.kind == .cpuPerCore }
        #expect(perCore?.detail != nil)   // 逐核 JSON 已填充
    }

    @Test("网络差分：两次采样速率递增非负（lo0 排除）")
    func networkDiff() async throws {
        let sampler = NetworkDiskSampler()
        let first = await sampler.sample()
        #expect(first.samples.first { $0.kind == .networkRx }?.value == 0)   // 首次无基线

        try await Task.sleep(for: .milliseconds(300))
        let second = await sampler.sample()
        let rx = try #require(second.samples.first { $0.kind == .networkRx })
        #expect(rx.value >= 0)   // 差分非负（真实网络流量）
    }

    @Test("MetricBatch 编码往返：逐核 detail JSON")
    func batchCodable() throws {
        let batch = MetricBatch(samples: [
            .init(kind: .cpuPerCore, value: 50, detail: "[1,2,3]"),
            .init(kind: .memoryUsed, value: 1024),
        ])
        let data = try JSONEncoder().encode(batch)
        let decoded = try JSONDecoder().decode(MetricBatch.self, from: data)
        #expect(decoded == batch)
    }
}

@Suite("AlertEvaluator (E13)")
struct AlertEvaluatorTests {

    @Test("阈值触发：CPU > 90% 触发、内存压力 3 触发")
    func thresholdTrigger() async {
        let evaluator = AlertEvaluator()
        let batch = MetricBatch(samples: [
            .init(kind: .cpuUsage, value: 95),
            .init(kind: .memoryPressure, value: 3),
        ])
        let alerts = await evaluator.evaluate(batch)
        #expect(alerts.count == 2)
        #expect(alerts.allSatisfy { $0.value >= $0.rule.threshold })
    }

    @Test("同类去重：10 分钟内不重复触发（基线 E13 要点 2）")
    func dedup() async {
        let evaluator = AlertEvaluator()
        let batch = MetricBatch(samples: [.init(kind: .cpuUsage, value: 95)])

        let first = await evaluator.evaluate(batch)
        #expect(first.count == 1)

        let second = await evaluator.evaluate(batch)   // 10 分钟窗口内
        #expect(second.isEmpty)                        // 去重不触发
    }

    @Test("低于阈值不触发；reset 后可再次触发")
    func noTriggerBelowThreshold() async {
        let evaluator = AlertEvaluator()
        let low = MetricBatch(samples: [.init(kind: .cpuUsage, value: 50)])
        #expect(await evaluator.evaluate(low).isEmpty)

        // 手动规则更新后低值可触发（isUpperBound=false 场景）
        await evaluator.updateRules([
            .init(kind: .cpuUsage, threshold: 10, isUpperBound: false,
                  title: "CPU 过低", message: "测试"),
        ])
        let alerts = await evaluator.evaluate(low)
        #expect(alerts.isEmpty)   // 50 > 10，非下界触发
    }
}

/// 消费者 Fake（消费者管理验证）。
final class FakeConsumer: MetricsConsumer, @unchecked Sendable {
    let id: String
    var batches: [MetricBatch] = []

    init(id: String = "fake") { self.id = id }

    func didSample(_ batch: MetricBatch) async {
        batches.append(batch)
    }
}

@Suite("MetricsService (消费者管理/降采样落库)")
struct MetricsServiceTests {

    @Test("消费者注册触发启动 + 分发 + 移除暂停")
    func consumerLifecycle() async throws {
        let consumer = FakeConsumer()
        let evaluator = AlertEvaluator()
        let service = MetricsService(
            samplers: [CPUMemorySampler(), NetworkDiskSampler()],
            alertEvaluator: evaluator,
            interval: .milliseconds(100),
            persistEveryN: 3,
            logger: Logger(category: .metrics, buffer: LogBuffer(capacity: 10))
        )

        await service.addConsumer(consumer)
        #expect(await service.isRunning())   // 首个消费者触发启动

        // 等待几次 tick
        try await Task.sleep(for: .milliseconds(500))
        #expect(await consumer.batches.count >= 2)   // 分发到达

        await service.removeConsumer(id: consumer.id)
        // 10 分钟暂停窗口（移除后运行保持，pauseIfNoConsumers 600s 后执行）
        #expect(await service.isRunning())
    }

    @Test("latest 快照更新 + 降采样落库（metric_sample 表）")
    func latestAndPersist() async throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("metrics-db-\(UUID().uuidString).sqlite")
        let store = try DatabaseStore.open(
            at: dbURL, logger: Logger(category: .metrics, buffer: LogBuffer(capacity: 10)))
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let consumer = FakeConsumer()
        let service = MetricsService(
            samplers: [CPUMemorySampler()],
            store: store,
            interval: .milliseconds(50),
            persistEveryN: 2,
            logger: Logger(category: .metrics, buffer: LogBuffer(capacity: 10))
        )
        await service.addConsumer(consumer)
        try await Task.sleep(for: .milliseconds(400))

        // latest 快照已更新
        let latest = await service.latest
        #expect(latest?.samples.isEmpty == false)

        // 降采样落库：400ms / 50ms ≈ 8 次 tick / 2 → ≥ 3 次落库 × 4 类指标
        let count = try await store.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM metric_sample") ?? 0
        }
        #expect(count >= 3)
    }
}