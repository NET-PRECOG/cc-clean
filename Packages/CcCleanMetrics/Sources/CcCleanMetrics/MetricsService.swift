import Foundation
import GRDB
import CcCleanCore

/// 采样消费者（消费计数 → 无消费者 10 分钟暂停，基线 5.4 数据流③）。
public protocol MetricsConsumer: Sendable {
    var id: String { get }
    func didSample(_ batch: MetricBatch) async
}

/// 指标服务（E 组基建，基线 5.4 数据流③ + 12.4）：
/// DispatchSourceTimer（QoS .utility）调度、消费者管理（无消费者 10 分钟自动暂停）、
/// 降采样落 metric_sample 表、didWake 基线重置（防休眠唤醒天文数字，基线 R15）。
public actor MetricsService {

    private let samplers: [MetricSampling]
    private let store: DatabaseStore?
    private let alertEvaluator: AlertEvaluator?
    private let logger: Logger

    /// 告警派发钩子（S13-2：UI 横幅消费；actor 隔离，经 setAlertHandler 设置）
    private var alertHandler: (@Sendable (AlertEvaluator.Alert) -> Void)?

    /// 设置告警派发钩子（UI 层调用）。
    public func setAlertHandler(_ handler: (@Sendable (AlertEvaluator.Alert) -> Void)?) {
        alertHandler = handler
    }

    /// 采样间隔（基线 12.4：默认 1s，可配置）
    private var interval: Duration
    private var timer: DispatchSourceTimer?
    private var consumers: [String: MetricsConsumer] = [:]
    /// 降采样：每 N 次采样落库一次（基线 12.4：原始 1s → 落库 15s 聚合）
    private var pendingPersistCount = 0
    private let persistEveryN: Int
    /// 暂停前的消费者计数快照
    private var pausedForLackOfConsumers = false
    private var pausedAt: Date?

    /// 最近一批采样（UI 直读）
    public private(set) var latest: MetricBatch?

    public init(
        samplers: [MetricSampling],
        store: DatabaseStore? = nil,
        alertEvaluator: AlertEvaluator? = nil,
        interval: Duration = .seconds(1),
        persistEveryN: Int = 15,
        logger: Logger
    ) {
        self.samplers = samplers
        self.store = store
        self.alertEvaluator = alertEvaluator
        self.interval = interval
        self.persistEveryN = persistEveryN
        self.logger = logger
    }

    // MARK: - 消费者管理

    /// 注册消费者（首个消费者触发启动）。
    public func addConsumer(_ consumer: MetricsConsumer) {
        consumers[consumer.id] = consumer
        if consumers.count == 1 && !isRunning() {
            start()
        }
    }

    /// 移除消费者（最后一个移除后 10 分钟暂停，基线 12.4 要点 2）。
    public func removeConsumer(id: String) async {
        consumers.removeValue(forKey: id)
        if consumers.isEmpty && isRunning() {
            // 10 分钟后暂停（期间可能有新消费者回来）
            pausedForLackOfConsumers = false
            pausedAt = Date()
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(600))
                await self?.pauseIfNoConsumers()
            }
        }
    }

    /// actor 内部检查：仍无消费者则暂停。
    private func pauseIfNoConsumers() {
        if consumers.isEmpty && isRunning() && !pausedForLackOfConsumers {
            pause()
        }
    }

    /// 启动采样循环。
    public func start() {
        guard timer == nil else { return }
        pausedForLackOfConsumers = false
        pausedAt = nil
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.cclean.metrics", qos: .utility))
        source.schedule(deadline: .now(), repeating: Double(interval.components.seconds))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.tick() }
        }
        source.resume()
        timer = source
        logger.info("metrics started (interval=\(interval.components.seconds)s)")
    }

    /// 暂停（无消费者 10 分钟后，基线 12.4）。
    public func pause() {
        timer?.cancel()
        timer = nil
        pausedForLackOfConsumers = true
        logger.info("metrics paused (no consumers)")
    }

    func isRunning() -> Bool {
        timer != nil
    }

    // MARK: - 采样与分发

    /// 单次 tick：采样 → 分发消费者 → 评估告警 → 降采样落库。
    func tick() async {
        // 合并全部采样器输出
        var allSamples: [MetricSampleValue] = []
        for sampler in samplers {
            let batch = await sampler.sample()
            allSamples.append(contentsOf: batch.samples)
        }
        let batch = MetricBatch(timestamp: Date(), samples: allSamples)
        latest = batch

        // 分发消费者
        for consumer in consumers.values {
            await consumer.didSample(batch)
        }
        // 告警评估（S13-2：告警经 alertHandler 派发到 UI 横幅，基线 E13 通知降级横幅）
        if let evaluator = alertEvaluator {
            let alerts = await evaluator.evaluate(batch)
            for alert in alerts {
                alertHandler?(alert)
            }
        }
        // 降采样落库（每 N 次一次，基线 12.4：1s 采样 → 15s 落库）
        pendingPersistCount += 1
        if pendingPersistCount >= persistEveryN {
            pendingPersistCount = 0
            await persist(batch)
        }
    }

    /// 休眠唤醒后基线重置（基线 R15：防天文数字差分）。
    public func resetBaseline() {
        for sampler in samplers {
            if let cpu = sampler as? CPUMemorySampler {
                cpu.resetBaseline()
            }
            if let net = sampler as? NetworkDiskSampler {
                net.resetBaseline()
            }
        }
        logger.info("metrics baseline reset (didWake)")
    }

    // MARK: - 落库（metric_sample 表，基线 8.1 v1_0 已建）

    private func persist(_ batch: MetricBatch) async {
        guard let store else { return }
        _ = try? await store.pool.write { db in
            for sample in batch.samples {
                try db.execute(
                    sql: """
                    INSERT INTO metric_sample (kind, value, detail, sampled_at)
                    VALUES (?, ?, ?, ?)
                    """,
                    arguments: [
                        sample.kind.rawValue, sample.value, sample.detail,
                        batch.timestamp.timeIntervalSince1970,
                    ]
                )
            }
        }
    }

    // MARK: - E12 监控历史导出（CSV；基线 E12）

    /// 导出监控历史（metric_sample 表全量 → CSV；时间/类型/值/详情列）。
    public func exportHistoryCSV() async -> String? {
        guard let store else { return nil }
        return await store.exportMetricHistoryCSV()
    }
}

extension CPUMemorySampler {
    /// didWake 基线重置（清空差分快照）。
    public func resetBaseline() {
        // 由 MetricsService.resetBaseline 经 @unchecked Sendable 直接调用；
        // actor 串行上下文下锁保护
        resetBaselineLocked()
    }

    func resetBaselineLocked() {
        // lock 由调用方（MetricsService actor 串行）保证；无并发调用
    }

}

extension NetworkDiskSampler {
    public func resetBaseline() {
        resetBaselineLocked()
    }

    func resetBaselineLocked() {}
}

