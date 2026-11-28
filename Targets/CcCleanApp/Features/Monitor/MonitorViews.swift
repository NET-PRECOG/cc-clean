import SwiftUI
import CcCleanCore
import CcCleanOps
import CcCleanMetrics

/// 监控 ViewModel（E1/E10/E13）：消费者订阅 + Top 5 + 进程管理 + 告警横幅 + E3 逐核历史。
@Observable
@MainActor
final class MonitorViewModel {

    private let metricsService: MetricsService
    private let processSampler = CcCleanMetrics.ProcessSampler()
    private let terminator = ProcessTerminator()

    private(set) var latest: MetricBatch?
    private(set) var topProcesses: [CcCleanMetrics.ProcessEntry] = []
    private(set) var allProcesses: [CcCleanMetrics.ProcessEntry] = []
    private(set) var lastActionMessage: String?
    private var consumerRegistered = false
    private var processRefreshTask: Task<Void, Never>?

    /// E3 逐核历史（每核 60 点环形缓冲；丢点以负值标记，曲线虚线呈现不插值）
    private(set) var coreHistory: [[Double]] = []
    private let coreHistoryCapacity = 60

    /// E13 告警横幅（最多保留 3 条）
    private(set) var banners: [AlertEvaluator.Alert] = []

    init(store: DatabaseStore = DatabaseStoreHolder.shared) {
        let evaluator = AlertEvaluator()
        metricsService = MetricsService(
            samplers: [CcCleanMetrics.CPUMemorySampler(), CcCleanMetrics.NetworkDiskSampler()],
            store: store,
            alertEvaluator: evaluator,
            logger: Logger(category: .metrics)
        )
        // E13 告警派发钩子（actor tick → MainActor 横幅，基线 6.4 notification 降级横幅）
        Task { [metricsService] in
            await metricsService.setAlertHandler { [weak self] alert in
                Task { @MainActor in
                    self?.appendBanner(alert)
                }
            }
        }
    }

    /// 注册消费者（进入监控页/打开菜单栏时）。
    func activate() async {
        if !consumerRegistered {
            consumerRegistered = true
            await metricsService.addConsumer(self)
            startProcessRefresh()
        }
    }

    /// 移除消费者（离开时；10 分钟无消费者自动暂停）。
    func deactivate() async {
        await metricsService.removeConsumer(id: "monitor-view")
        processRefreshTask?.cancel()
    }

    /// 进程列表周期刷新（E10：2s 周期）。
    private func startProcessRefresh() {
        processRefreshTask?.cancel()
        processRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let entries = self.processSampler.sample()
                self.allProcesses = entries
                self.topProcesses = Array(entries.prefix(5))
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: - E13 告警横幅

    private func appendBanner(_ alert: AlertEvaluator.Alert) {
        banners.append(alert)
        if banners.count > 3 {
            banners.removeFirst(banners.count - 3)
        }
    }

    func dismissBanner(_ alert: AlertEvaluator.Alert) {
        banners.removeAll { $0 == alert }
    }

    // MARK: - 格式化（E1 弹出面板）

    var cpuText: String {
        let v = latest?.samples.first { $0.kind == .cpuUsage }?.value ?? 0
        return String(format: "%.0f%%", v)
    }

    /// CPU 占用 0~1（状态栏面板环形圈）。
    var cpuFraction: Double {
        let v = latest?.samples.first { $0.kind == .cpuUsage }?.value ?? 0
        return max(min(v / 100, 1), 0)
    }

    /// 内存已用字节（状态栏面板 RAM 环形圈）。
    var memoryUsedBytes: Double {
        latest?.samples.first { $0.kind == .memoryUsed }?.value ?? 0
    }

    var memoryText: String {
        let v = latest?.samples.first { $0.kind == .memoryUsed }?.value ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(v), countStyle: .memory)
    }

    var networkRxText: String {
        let v = latest?.samples.first { $0.kind == .networkRx }?.value ?? 0
        return rateText(v)
    }

    var networkTxText: String {
        let v = latest?.samples.first { $0.kind == .networkTx }?.value ?? 0
        return rateText(v)
    }

    /// 网速文本（0 特判为 "0 KB/s"；ByteCountFormatter 对 0 输出 "Zero KB/s" 不符合面板口径）。
    private func rateText(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return "0 KB/s" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .memory) + "/s"
    }

    // MARK: - E10 结束进程

    /// 结束进程（三级：terminate→SIGTERM→SIGKILL；Apple 系统进程拒绝，基线 E10 边界）。
    func terminate(_ entry: CcCleanMetrics.ProcessEntry) async {
        guard !entry.isAppleSystem else {
            lastActionMessage = "系统进程禁止结束（基线 E10 边界）"
            return
        }
        guard let path = entry.path else {
            lastActionMessage = "无法定位进程路径"
            return
        }
        let failures = await terminator.terminate(bundlePath: path)
        lastActionMessage = failures.isEmpty
            ? "已结束 \(entry.name)"
            : (failures.values.first ?? "结束失败")
    }
}

/// MonitorViewModel 实现 MetricsConsumer（消费采样分发 → E3 逐核历史缓冲）。
extension MonitorViewModel: MetricsConsumer {
    nonisolated var id: String { "monitor-view" }

    func didSample(_ batch: MetricBatch) async {
        // 保存最新采样（面板/监控页 CPU、内存、网速读数来源）
        latest = batch

        // E3：逐核值追加历史（每核 60 点环形；首次采样无差分记录为 -1 → 曲线虚线段）
        guard let detail = batch.samples.first(where: { $0.kind == .cpuPerCore })?.detail,
              let data = detail.data(using: .utf8),
              var cores = try? JSONDecoder().decode([Double].self, from: data) else { return }

        // 历史核数与当前不一致（内核拓扑变化罕见）时重置
        if coreHistory.count != cores.count {
            coreHistory = cores.map { _ in [] }
        }
        for (i, value) in cores.enumerated() where i < coreHistory.count {
            coreHistory[i].append(value)
            if coreHistory[i].count > 60 {
                coreHistory[i].removeFirst(coreHistory[i].count - 60)
            }
        }
        _ = cores.map { $0 < 0 }
    }
}

// MARK: - E13 告警横幅

/// 告警横幅（基线 6.4 notification 降级为应用内横幅；同类 10 分钟去重已在 Evaluator）。
struct AlertBannerView: View {
    let banners: [AlertEvaluator.Alert]
    let onDismiss: (AlertEvaluator.Alert) -> Void

    var body: some View {
        ForEach(banners, id: \.at) { alert in
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(alert.rule.title).font(.callout.weight(.semibold))
                    Text("\(alert.rule.message)（当前 \(String(format: "%.0f", alert.value))）")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    onDismiss(alert)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(10)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

// MARK: - E3 逐核曲线（Canvas，1fps 数据驱动；丢点虚线不插值）

/// 逐核 CPU 曲线（60s 窗口；基线 E3：丢点虚线不插值、1fps 渲染节流由数据频率决定）。
struct PerCoreCurveView: View {
    let coreHistory: [[Double]]

    var body: some View {
        Canvas { context, size in
            let cores = coreHistory
            guard !cores.isEmpty else { return }
            let coreHeight = size.height / CGFloat(cores.count)

            for (index, series) in cores.enumerated() {
                guard series.count > 1 else { continue }
                let yBase = coreHeight * CGFloat(index)
                let stepX = size.width / CGFloat(max(series.count - 1, 1))

                // 分段绘制：值 < 0（丢点/基线未建立）断开并虚线
                var path = Path()
                var dashedSegment = false
                var segmentOpen = false

                for (pointIndex, value) in series.enumerated() {
                    let x = stepX * CGFloat(pointIndex)
                    let valid = value >= 0
                    let y = yBase + coreHeight * (1 - CGFloat(max(value, 0)) / 100)

                    if valid {
                        if segmentOpen {
                            path.addLine(to: CGPoint(x: x, y: y))
                        } else {
                            path.move(to: CGPoint(x: x, y: y))
                            segmentOpen = true
                        }
                    } else {
                        segmentOpen = false
                        if dashedSegment == false {
                            dashedSegment = true
                        }
                    }
                }

                // 正常段：实线；含丢点的系列整体用虚线提示（基线 E3：丢点虚线不插值）
                let hasGap = series.contains { $0 < 0 }
                var stroke = Path()
                stroke.addPath(path)
                context.stroke(
                    stroke,
                    with: .color(index == 0 ? .blue.opacity(0.8) : .blue.opacity(0.45)),
                    style: StrokeStyle(lineWidth: 1.2, dash: hasGap ? [3, 3] : [])
                )

                // 核分隔线
                if index > 0 {
                    var separator = Path()
                    separator.move(to: CGPoint(x: 0, y: yBase))
                    separator.addLine(to: CGPoint(x: size.width, y: yBase))
                    context.stroke(separator, with: .color(.gray.opacity(0.2)), lineWidth: 0.5)
                }
            }
        }
        .frame(height: 120)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - E1 菜单栏弹出面板

/// 菜单栏监控面板（基线 11.3 ② E1：4 指标 + E3 迷你曲线 + Top 5 进程；内存预算 < 120MB）。
struct MenuBarMonitorView: View {
    @State private var model = MonitorViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            metricRow("CPU", value: model.cpuText, icon: "cpu")
            metricRow("内存", value: model.memoryText, icon: "memorychip")
            metricRow("下行", value: model.networkRxText, icon: "arrow.down")
            metricRow("上行", value: model.networkTxText, icon: "arrow.up")

            if !model.banners.isEmpty {
                Divider()
                AlertBannerView(banners: model.banners) { alert in
                    model.dismissBanner(alert)
                }
            }

            Divider()
            Text("逐核 CPU（60s）").font(.caption).foregroundStyle(.secondary)
            PerCoreCurveView(coreHistory: model.coreHistory)

            Divider()
            Text("Top 5 进程").font(.caption).foregroundStyle(.secondary)
            ForEach(model.topProcesses) { entry in
                HStack {
                    Text(entry.name).lineLimit(1)
                    Spacer()
                    Text(String(format: "%.1f%%", entry.cpuPercent))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
        .padding(12)
        .frame(width: 280)
        .task { await model.activate() }
        .onDisappear { Task { await model.deactivate() } }
    }

    private func metricRow(_ label: String, value: String, icon: String) -> some View {
        HStack {
            Image(systemName: icon).frame(width: 18)
            Text(label)
            Spacer()
            Text(value).monospacedDigit().fontWeight(.medium)
        }
        .font(.callout)
    }
}

// MARK: - E10 进程管理器

/// 进程管理器（基线 11.3 ② E10：CPU 排序 + 结束进程（系统进程拒绝）+ 主操作唯一）。
struct ProcessManagerView: View {
    @State private var model = MonitorViewModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("按 CPU 排序 · \(model.allProcesses.count) 个进程")
                    .foregroundStyle(.secondary)
                Spacer()
                if let message = model.lastActionMessage {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(12)
            .background(.bar)

            if !model.banners.isEmpty {
                AlertBannerView(banners: model.banners) { alert in
                    model.dismissBanner(alert)
                }
                .padding(.horizontal, 12)
            }

            List(model.allProcesses) { entry in
                HStack(spacing: 10) {
                    Circle()
                        .fill(entry.isAppleSystem ? Color.gray : Color.blue)
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name).lineLimit(1)
                        Text("pid \(entry.pid)").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: entry.rssBytes, countStyle: .memory))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    Text(String(format: "%.1f%%", entry.cpuPercent))
                        .font(.caption).monospacedDigit()
                        .frame(minWidth: 52, alignment: .trailing)
                    if !entry.isAppleSystem {
                        Button("结束") {
                            Task { await model.terminate(entry) }
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.vertical, 2)
            }
            .listStyle(.inset)
        }
        .navigationTitle("进程管理器")
        .task { await model.activate() }
        .onDisappear { Task { await model.deactivate() } }
    }
}