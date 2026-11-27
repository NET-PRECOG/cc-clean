import Foundation

/// 指标类型（基线 8.1 metric_sample 表 metric_kind 口径）。
public enum MetricKind: String, Codable, Sendable, CaseIterable {
    case cpuUsage          // 总 CPU 使用率 %
    case cpuPerCore        // 逐核使用率（JSON 数组）
    case memoryUsed        // 已用内存（字节）
    case memoryPressure    // 内存压力等级
    case swapUsed          // swap 使用（字节）
    case networkRx         // 接收速率（B/s，差分）
    case networkTx         // 发送速率（B/s，差分）
    case diskRead          // 磁盘读速率（B/s，差分）
    case diskWrite         // 磁盘写速率（B/s，差分）
    case temperature       // 温度（SMC，℃）
    case fanRPM            // 风扇转速
    case batteryPercent    // 电池百分比
    case batteryHealth     // 电池健康
}

/// 单条指标采样值。
public struct MetricSampleValue: Codable, Sendable, Equatable {    public let kind: MetricKind
    public let value: Double
    /// 逐核等复合指标的 JSON 序列化附加数据
    public let detail: String?

    public init(kind: MetricKind, value: Double, detail: String? = nil) {
        self.kind = kind
        self.value = value
        self.detail = detail
    }
}

/// 一次完整采样（时间戳 + 全部指标）。
public struct MetricBatch: Codable, Sendable, Equatable {
    public let timestamp: Date
    public let samples: [MetricSampleValue]

    public init(timestamp: Date = Date(), samples: [MetricSampleValue]) {
        self.timestamp = timestamp
        self.samples = samples
    }
}

/// 采样器协议（基线 13.1：协议注入 Fake，真实实现走系统 API）。
public protocol MetricSampling: Sendable {
    /// 执行一次采样（全部指标一次采集，避免多次调用时间错位）。
    func sample() async -> MetricBatch
}

/// 采样错误（优雅降级：采样失败项跳过而非中断）。
public enum MetricError: Error, Equatable {
    case unsupported(reason: String)
}