import SwiftUI
import AppKit
import CcCleanCore
import CcCleanMetrics

extension Notification.Name {
    /// 主窗口跳转智能扫描页（状态栏面板「运行智能扫描」触发）。
    static let openSmartScan = Notification.Name("app.cclean.openSmartScan")
}

/// 状态栏面板（iStat 风格深色仪表盘，9 卡片布局，宽 540 无滚动）：
/// 卡1 设备信息（含开机时长）｜卡2 系统信息｜卡2/3 CPU·GPU｜卡4/5 RAM·磁盘｜卡6/7 网速·风扇｜卡8 电量｜卡9 操作条。
struct StatusPanelView: View {
    @Environment(\.openWindow) private var openWindow
    @State private var model = StatusPanelViewModel()

    var body: some View {
        VStack(spacing: 12) {
            deviceCard                       // 卡 1


            HStack(spacing: 12) {
                ringCard(icon: "cpu", title: "CPU",
                         fraction: model.cpuFraction, ringColor: Color(hex: "FF9F0A")) {
                    subText(model.chipBrand + (model.cpuCores > 0 ? " · \(model.cpuCores)核" : ""))
                }                    // 卡 2
                ringCard(icon: "bolt.horizontal.circle", title: "GPU",
                         fraction: nil, ringColor: Color(hex: "BF5AF2")) {
                    subText(model.chipBrand + (model.gpuCores != nil ? " · \(model.gpuCores!)核" : ""))
                }                    // 卡 3
            }
            HStack(spacing: 12) {
                ringCard(icon: "memorychip", title: "RAM",
                         fraction: model.ramFraction, ringColor: Color(hex: "30D158")) {
                    subText("共 \(model.ramTotalText)")
                }                    // 卡 4
                ringCard(icon: "internaldrive", title: "磁盘空间",
                         fraction: model.diskFraction, ringColor: Color(hex: "0A84FF")) {
                    subText("可用 \(model.diskFreeText)")
                }                    // 卡 5
            }
            HStack(spacing: 12) {
                panelCard(icon: "wifi", title: "网速") {
                    VStack(alignment: .leading, spacing: 6) {
                        if model.ipText != "--" {
                            Text(model.ipText)
                                .font(.system(size: 11))
                                .foregroundStyle(Color(hex: "9A9A9E"))
                        }
                        HStack(spacing: 10) {
                            rateItem("↑", model.monitor.networkRxText, color: Color(hex: "FFD60A"))
                            rateItem("↓", model.monitor.networkTxText, color: Color(hex: "30D158"))
                        }
                    }
                }                    // 卡 6
                panelCard(icon: "fan", title: "风扇") {
                    if model.fanReadings.isEmpty {
                        subText("-")
                    } else {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(model.fanReadings, id: \.index) { fan in
                                HStack(spacing: 6) {
                                    Image(systemName: "fan")
                                        .font(.system(size: 10))
                                        .foregroundStyle(Color(hex: "9A9A9E"))
                                    Text("\(Self.fanLabel(fan)) \(Int(fan.rpm)) RPM")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.white)
                                        .monospacedDigit()
                                }
                            }
                        }
                    }
                }                    // 卡 7
            }
            batteryCard              // 卡 8
            actionBar                // 卡 9
        }
        .padding(12)
        // 宽度增加 1/2（360→540），VStack 固有高度完全展示无滚动条（MenuBarExtra 按内容自适应）
        .frame(width: 540)
        .background(Color(hex: "0A0A0A"))
        .task {
            await model.start()
            // 面板窗口完成布局后水平居中于状态栏图标正下方
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { repositionPanel() }
        }
        .onDisappear { model.stop() }
    }

    /// 卡 2-7 统一高度（对齐内容最高项：环形卡 ≈106pt）。
    private let metricCardHeight: CGFloat = 110

    /// 面板位置调整：SwiftUI MenuBarExtra 默认左对齐状态栏图标，
    /// 手动把面板窗口水平居中到图标正下方（clamp 在图标所在屏范围内）。
    private func repositionPanel() {
        // 面板窗口识别：statusBar 层级 + 面板宽 540
        // （SDK 27.2 已无 NSStatusBar.statusItems 枚举 API；
        //   MenuBarExtra 默认把面板左缘锚定在图标下方 → 图标中心 ≈ panel.minX + 12）
        guard let panel = NSApp.windows.first(where: {
            $0.isVisible && $0.level == .statusBar && abs($0.frame.width - 540) < 2
        }), let screen = panel.screen ?? NSScreen.main else { return }
        let iconCenterX = panel.frame.minX + 12
        var origin = panel.frame.origin
        origin.x = min(max(iconCenterX - panel.frame.width / 2, screen.frame.minX + 8),
                       screen.frame.maxX - panel.frame.width - 8)
        panel.setFrameOrigin(origin)
    }

    /// 风扇标签（SMC 名称 → 左/右；无名称按序号）。
    static func fanLabel(_ fan: FanReading) -> String {
        if let name = fan.name?.lowercased() {
            if name.contains("left") { return "左风扇" }
            if name.contains("right") { return "右风扇" }
        }
        switch fan.index {
        case 0: return "左风扇"
        case 1: return "右风扇"
        default: return "风扇 \(fan.index + 1)"
        }
    }

    // MARK: - 卡 1 设备信息（含开机时长）

    private var deviceCard: some View {
        panelCard(icon: "desktopcomputer", title: "") {
            EmptyView()
        } header: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(CCleanTheme.Accent.scan.gradient)
                    .frame(width: 38, height: 38)
                    .overlay {
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: 17))
                            .foregroundStyle(.white)
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.deviceName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    HStack(spacing: 5) {
                        Circle().fill(Color(hex: "34C759")).frame(width: 7, height: 7)
                        Text(model.healthy ? "Mac 状态良好" : "存在告警")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(hex: "9A9A9E"))
                    }
                    Text("\(model.osVersionText) · 已开机 \(model.uptimeText)")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(hex: "9A9A9E"))
                }
                Spacer()
            }
        }
    }

    // MARK: - 卡 8 电量

    private var batteryCard: some View {
        panelCard(icon: "battery.100.bolt", title: "电量") {
            HStack(spacing: 16) {
                Text(model.batteryPercent.map { "\(Int($0))%" } ?? "--")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                VStack(alignment: .leading, spacing: 5) {
                    if let cycles = model.batteryCycles {
                        Text("循环 \(cycles) 次")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(hex: "9A9A9E"))
                    }
                    if let health = model.batteryHealthPercent {
                        Text("健康度 \(Int(health))%")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(hex: "34C759"))
                    }
                    Text(model.batteryCharging ? "充电中" : (model.batteryAC ? "电源供电" : "电池供电"))
                        .font(.system(size: 11))
                        .foregroundStyle(Color(hex: "9A9A9E"))
                }
                Spacer()
            }
        }
    }

    // MARK: - 卡 9 操作条

    private var actionBar: some View {
        HStack(spacing: 8) {
            panelButton("打开主界面", "macwindow.on.rectangle") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            VStack(spacing: 1) {
                Text(model.appVersion)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                Text(model.hasUpdate ? "有可用更新" : "已是最新")
                    .font(.system(size: 9))
                    .foregroundStyle(model.hasUpdate ? Color(hex: "FFD60A") : Color(hex: "9A9A9E"))
            }
            .frame(maxWidth: .infinity)
            panelButton("退出", "power") {
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: - 通用组件

    /// 卡片容器（可选标题头；height 指定时卡片高度固定）。
    @ViewBuilder
    private func panelCard(
        icon: String, title: String,
        height: CGFloat? = nil,
        @ViewBuilder content: () -> some View,
        @ViewBuilder header: () -> some View = { EmptyView() }
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if title.isEmpty {
                header()
            } else {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                        .foregroundStyle(Color(hex: "9A9A9E"))
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
                content()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: height, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(hex: "1C1C1E"))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color(hex: "3A3A3C"), lineWidth: 1)
                )
        )
    }

    /// 环形进度卡片（CPU/GPU/RAM/磁盘）。
    private func ringCard(
        icon: String, title: String, fraction: Double?, ringColor: Color,
        height: CGFloat? = nil,
        @ViewBuilder sub: () -> some View
    ) -> some View {
        panelCard(icon: icon, title: title, height: height) {
            HStack(spacing: 14) {
                RingGauge(
                    fraction: fraction,
                    color: ringColor,
                    label: fraction.map { "\(Int($0 * 100))%" } ?? "--"
                )
                sub()
                Spacer(minLength: 0)
            }
        }
    }

    private func subText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Color(hex: "9A9A9E"))
            .lineLimit(2)
            .multilineTextAlignment(.leading)
    }

    private func rateItem(_ arrow: String, _ text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(arrow).font(.system(size: 11)).foregroundStyle(color)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .monospacedDigit()
        }
    }

    private func panelButton(
        _ title: String, _ icon: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(hex: "2C2C2E"))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 信息项（图标 + 标签 + 数值）。
    private func infoItem(_ label: String, _ value: String, _ icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(Color(hex: "9A9A9E"))
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Color(hex: "9A9A9E"))
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .monospacedDigit()
                .lineLimit(1)
        }
    }
}

/// 环形进度圈（截图规格：彩色圆环 + 中心百分比）。
struct RingGauge: View {
    let fraction: Double?
    let color: Color
    var label: String? = nil
    var size: CGFloat = 52

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.12), lineWidth: 6)
            if let fraction {
                Circle()
                    .trim(from: 0, to: max(min(fraction, 1), 0.02))
                    .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Text(label ?? "--")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
        }
        .frame(width: size, height: size)
    }
}

// MARK: - ViewModel

/// 状态栏面板 ViewModel：静态信息一次加载；动态指标 2 秒轮询（CPU/RAM/磁盘/网速/风扇/电池）。
@Observable
@MainActor
final class StatusPanelViewModel {
    let monitor = MonitorViewModel()   // 复用 E1 采样（CPU/内存文本 + 网速速率 + 告警）

    // 静态信息
    private(set) var deviceName = Host.current().localizedName ?? "Mac"
    private(set) var osVersionText = "--"
    private(set) var chipBrand = "--"
    private(set) var cpuCores = 0
    private(set) var gpuCores: Int?
    private(set) var ramTotalText = "--"
    private(set) var batteryCycles: Int?
    private(set) var batteryHealthPercent: Double?
    private(set) var appVersion = "v0.1.0"
    private(set) var hasUpdate = false
    private(set) var uptimeText = "--"

    // 动态指标
    private(set) var cpuFraction: Double = 0
    private(set) var ramFraction: Double = 0
    private(set) var ramTotalBytes: UInt64 = 0
    private(set) var diskFraction: Double = 0
    private(set) var diskFreeText = "--"
    private(set) var diskTotalText = "--"
    private(set) var ipText = "--"
    private(set) var fanReadings: [FanReading] = []
    private(set) var batteryPercent: Double?
    private(set) var batteryCharging = false
    private(set) var batteryAC = false

    /// Mac 状态健康（E13 有未恢复告警即视为异常）。
    var healthy: Bool { monitor.banners.isEmpty }

    private let info = SystemInfoService(logger: Logger(category: .metrics))
    private var pollingTask: Task<Void, Never>?

    func start() async {
        await monitor.activate()
        loadStatic()
        refreshUptime()
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshDynamic()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        Task { await monitor.deactivate() }
    }

    /// 开机时长（kern.boottime；CleanUp 同款文案）。
    private func refreshUptime() {
        var boottime = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boottime, &size, nil, 0) == 0 else { return }
        let boot = Date(timeIntervalSince1970: TimeInterval(boottime.tv_sec))
        let interval = max(Date().timeIntervalSince(boot), 0)
        let d = Int(interval) / 86400
        let h = Int(interval) % 86400 / 3600
        let m = Int(interval) % 3600 / 60
        uptimeText = d > 0 ? "\(d)天\(h)小时\(m)分" : "\(h)小时\(m)分"
    }

    /// 静态信息（一次性）。
    private func loadStatic() {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        osVersionText = "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            appVersion = "v\(version)"
        }
        Task { [weak self] in
            guard let self else { return }
            let panel = await self.info.hardwarePanel()
            chipBrand = panel.cpuBrand
            cpuCores = panel.cpuCoreCount
            ramTotalBytes = panel.physicalMemory
            ramTotalText = ByteCountFormatter.string(
                fromByteCount: Int64(panel.physicalMemory), countStyle: .memory)
            gpuCores = SystemInfoService.gpuCoreCount()
            if let detail = SystemInfoService.batteryDetail() {
                batteryCycles = detail.cycles
                batteryHealthPercent = detail.healthPercent
            }
            // 主用 IPv4（首个非 lo0 在线接口）
            let interfaces = await self.info.networkInterfaces()
            if let primary = interfaces.first(where: {
                $0.isUp && $0.name != "lo0" && $0.address != nil
            }) {
                ipText = primary.address ?? "--"
            }
        }
    }

    /// 动态指标刷新（CPU/RAM 占用、磁盘、风扇、电池）。
    private func refreshDynamic() async {
        // CPU / RAM 占用（E1 采样，MonitorViewModel 数值属性）
        cpuFraction = monitor.cpuFraction
        if ramTotalBytes > 0 {
            ramFraction = max(min(monitor.memoryUsedBytes / Double(ramTotalBytes), 1), 0)
        }
        // 磁盘
        if let values = try? URL(fileURLWithPath: "/").resourceValues(
            forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]) {
            let total = Int64(values.volumeTotalCapacity ?? 0)
            let free = Int64(values.volumeAvailableCapacity ?? 0)
            if total > 0 {
                let used = max(total - free, 0)
                diskFraction = Double(used) / Double(total)
                diskFreeText = CCleanTheme.formatBytes(free)
                diskTotalText = CCleanTheme.formatBytes(total)
            }
        }
        // 风扇（SMC 用户态）
        fanReadings = SystemInfoService.fanReadings()
        // 电池（E9：电量/充电/电源状态）
        if let health = await info.batteryHealth() {
            batteryPercent = health.percent
            batteryCharging = health.isCharging
            batteryAC = health.usingAC
        }
    }
}
