import WidgetKit
import SwiftUI
import CcCleanCore

/// E14 桌面组件（基线 E14：E1 数据源最新快照）。
/// SwiftPM 层完成代码与编译验证；打包为 .appex 需 Xcode 工程 extension target
/// （Package.swift 头注释同源约定），appex 组装归 release 流程。

struct MetricWidgetEntry: TimelineEntry {
    let date: Date
    let cpuUsage: Double?      // %
    let memoryUsed: Double?    // 字节
    let swapUsed: Double?      // 字节
}

struct MetricWidgetProvider: TimelineProvider {

    func placeholder(in context: Context) -> MetricWidgetEntry {
        MetricWidgetEntry(date: Date(), cpuUsage: nil, memoryUsed: nil, swapUsed: nil)
    }

    func getSnapshot(
        in context: Context, completion: @escaping @Sendable (MetricWidgetEntry) -> Void
    ) {
        Task { completion(await read()) }
    }

    func getTimeline(
        in context: Context,
        completion: @escaping @Sendable (Timeline<MetricWidgetEntry>) -> Void
    ) {
        Task {
            let entry = await read()
            completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(900))))
        }
    }

    /// 读库最新快照（打开失败 → nil 优雅降级，UI 显示「等待数据」）。
    private func read() async -> MetricWidgetEntry {
        guard let store = try? DatabaseStore.open(
            at: Paths.mainDatabase, logger: Logger(category: .general)
        ) else {
            return MetricWidgetEntry(date: Date(), cpuUsage: nil, memoryUsed: nil, swapUsed: nil)
        }
        async let cpu = store.latestMetricValue(kind: "cpuUsage")
        async let memory = store.latestMetricValue(kind: "memoryUsed")
        async let swap = store.latestMetricValue(kind: "swapUsed")
        return MetricWidgetEntry(
            date: Date(), cpuUsage: await cpu, memoryUsed: await memory, swapUsed: await swap)
    }
}

struct MetricWidgetView: View {
    var entry: MetricWidgetEntry

    private static func gb(_ bytes: Double?) -> String {
        guard let bytes else { return "--" }
        return String(format: "%.1f GB", bytes / 1024 / 1024 / 1024)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("CcClean 监控")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Image(systemName: "cpu").font(.caption)
                Text(entry.cpuUsage.map { String(format: "%.0f%%", $0) } ?? "--")
                    .font(.headline).monospacedDigit()
            }
            HStack {
                Image(systemName: "memorychip").font(.caption)
                Text(Self.gb(entry.memoryUsed))
                    .font(.caption).monospacedDigit()
            }
            HStack {
                Image(systemName: "externaldrive.badge.timemachine").font(.caption)
                Text(Self.gb(entry.swapUsed))
                    .font(.caption).monospacedDigit()
            }
            Text(entry.date, style: .time)
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(4)
    }
}

struct MetricWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "app.cclean.metrics", provider: MetricWidgetProvider()) {
            MetricWidgetView(entry: $0)
        }
        .configurationDisplayName("CcClean 监控")
        .description("CPU / 内存 / Swap 最新快照（15 分钟刷新）")
        .supportedFamilies([.systemSmall])
    }
}

@main
struct CcCleanWidgetBundle: WidgetBundle {
    var body: some Widget {
        MetricWidget()
    }
}