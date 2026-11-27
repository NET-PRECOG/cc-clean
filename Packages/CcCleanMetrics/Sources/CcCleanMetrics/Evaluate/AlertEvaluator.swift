import Foundation
import CcCleanCore

/// 阈值告警评估器（E13，基线 E 组）：
/// 阈值判定 + 10 分钟同类告警去重（基线 E13 验收）。
public actor AlertEvaluator {

    /// 告警定义。
    public struct Rule: Sendable, Equatable {
        public let kind: MetricKind
        /// 超过该值触发（各指标口径不同）
        public let threshold: Double
        /// 比较方向：true = value >= threshold 触发；false = value <= threshold
        public let isUpperBound: Bool
        public let title: String
        public let message: String

        public init(
            kind: MetricKind, threshold: Double, isUpperBound: Bool,
            title: String, message: String
        ) {
            self.kind = kind
            self.threshold = threshold
            self.isUpperBound = isUpperBound
            self.title = title
            self.message = message
        }

        /// 默认规则集（基线 E13：CPU 持续 > 90%、内存压力、磁盘紧张）。
        public static let defaults: [Rule] = [
            Rule(
                kind: .cpuUsage, threshold: 90, isUpperBound: true,
                title: "CPU 使用率过高",
                message: "CPU 使用率超过 90%，可在进程管理器中查看占用最高的进程"
            ),
            Rule(
                kind: .memoryPressure, threshold: 3, isUpperBound: true,
                title: "内存压力过高",
                message: "系统内存压力达到临界，建议关闭部分应用或清理内存"
            ),
        ]
    }

    /// 触发的告警（通知降级为应用内横幅，基线 6.4 notification 降级映射）。
    public struct Alert: Sendable, Equatable {
        public let rule: Rule
        public let value: Double
        public let at: Date
    }

    private var rules: [Rule]
    /// 同类告警去重窗口（基线 E13：10 分钟）
    private let dedupInterval: TimeInterval
    private var lastFired: [MetricKind: Date] = [:]

    public init(rules: [Rule] = Rule.defaults, dedupInterval: TimeInterval = 600) {
        self.rules = rules
        self.dedupInterval = dedupInterval
    }

    /// 评估一批采样，返回触发的新告警（同类 10 分钟内不重复）。
    public func evaluate(_ batch: MetricBatch) async -> [Alert] {
        var alerts: [Alert] = []
        for rule in rules {
            guard let value = batch.samples.first(where: { $0.kind == rule.kind }) else { continue }
            let triggered = rule.isUpperBound
                ? value.value >= rule.threshold
                : value.value <= rule.threshold
            guard triggered else { continue }

            // 同类去重（基线 E13 要点 2）
            if let last = lastFired[rule.kind],
               batch.timestamp.timeIntervalSince(last) < dedupInterval {
                continue
            }
            lastFired[rule.kind] = batch.timestamp
            alerts.append(Alert(rule: rule, value: value.value, at: batch.timestamp))
        }
        if !alerts.isEmpty {
            logger.info("alerts fired: \(alerts.map(\.rule.title).joined(separator: ", "))")
        }
        return alerts
    }

    /// 更新规则（UI 阈值设置）。
    public func updateRules(_ rules: [Rule]) {
        self.rules = rules
    }

    private let logger = Logger(category: .metrics)
}