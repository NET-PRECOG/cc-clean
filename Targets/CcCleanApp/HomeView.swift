import SwiftUI
import CcCleanCore

/// 普通列表模式首页：品牌行 → 一键清理 → 磁盘空间 → 其余功能行；
/// 无自定义背景色；内容滚动经过顶部时呈毛玻璃穿透效果；窗口交通灯保持不动。
struct HomeView: View {
    @Environment(CapabilityViewModel.self) private var capability
    /// 导航路径（状态栏面板「运行智能扫描」经通知驱动跳转）。
    @State private var path = NavigationPath()

    /// 磁盘行副标题（refreshDisk 拉取真实用量后更新）。
    @State private var diskSubtitle = "空间分析 · 大文件 · 重复文件"

    /// 功能行清单（第一行品牌在列表内；第二行一键清理；第三行磁盘空间；其余顺次）。
    private var cards: [(title: String, subtitle: String, icon: String, accent: CCleanTheme.Accent, destination: AnyView)] { [
        ("一键清理", "智能扫描并清理基础垃圾", "sparkle.magnifyingglass", .scan, AnyView(SmartScanView())),
        ("磁盘空间", diskSubtitle, "externaldrive.fill", .disk, AnyView(SpaceView())),
        ("应用卸载", "深度卸载应用并清理全部残留", "trash.fill", .app, AnyView(UninstallView())),
        ("启动项与守护项", "管理开机自启动与后台守护项", "paperplane.fill", .loginItem, AnyView(StartupItemsView())),
        ("更新中心", "多来源版本检测与批量更新", "arrow.triangle.2.circlepath", .update, AnyView(UpdateCenterView())),
        ("应用清单", "已装应用台账：来源/签名/架构", "list.bullet.rectangle.fill", .inventory, AnyView(AppInventoryView())),
        ("安全与隐私", "可疑签名 · TCC 权限 · 隐私痕迹", "hand.raised.fill", .privacy, AnyView(SecurityView())),
        ("图标墙", "全库应用图标一览（缓存 ≤ 200）", "square.grid.2x2.fill", .iconWall, AnyView(IconGridView())),
        ("开发环境", "JDK / PATH / 缓存 / Android SDK", "hammer.fill", .devTools, AnyView(DevToolsView())),
        ("多包管理器", "npm · pnpm · uv · conda · cargo", "shippingbox.fill", .packages, AnyView(MultiPackageManagerView())),
        ("关联文件树", "懒加载目录树，体积与 F1 同源", "folder.fill", .fileTree, AnyView(FileTreeView())),
    ] }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 0) {
                    // 第一行：品牌（leading 预留交通灯空间）
                    brandRow

                    // 能力横幅（基线 11.3 ⑦ 统一降级组件）
                    capabilityBanner
                        .padding(.horizontal, 24)
                        .padding(.top, 12)

                    // 功能列表（普通列表模式，行间分隔线）
                    VStack(spacing: 2) {
                        ForEach(cards, id: \.title) { card in
                            NavigationLink(value: card.title) {
                                FeatureRowView(
                                    title: card.title, subtitle: card.subtitle,
                                    systemImage: card.icon, accent: card.accent)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 14)
                    .padding(.bottom, 24)
                }
            }
            // 顶部毛玻璃垫层：内容滚动经过时透出模糊（交通灯悬浮区内）
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear
                    .frame(height: 10)
                    .frame(maxWidth: .infinity)
                    .background(.ultraThinMaterial)
            }
            .navigationDestination(for: String.self) { key in
                if key == "一键清理" {
                    SmartScanView()
                } else if key == "去清理系统垃圾" {
                    JunkPreviewView()
                } else if let match = cards.first(where: { $0.title == key }) {
                    match.destination
                }
            }
            // 状态栏面板「运行智能扫描」→ 打开主窗口并直达智能扫描页
            .onReceive(NotificationCenter.default.publisher(for: .openSmartScan)) { _ in
                path.append("一键清理")
            }
            .task { await refreshDisk() }
        }
        .frame(minWidth: 900, minHeight: 620)
    }

    // MARK: - 品牌行

    /// 第一行品牌（清除背景色后直接置于列表顶部；leading 避开交通灯）。
    private var brandRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("CcClean")
                .font(.system(size: 26, weight: .bold))
            Text("macOS 软件管家 · 本地处理、无云、无遥测")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 76)
        .padding(.trailing, 24)
        .padding(.top, 10)
    }

    // MARK: - 数据

    /// 根卷用量（volumeTotalCapacity / volumeAvailableCapacity；失败保持占位）。
    private func refreshDisk() async {
        do {
            let values = try URL(fileURLWithPath: "/")
                .resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
            let total = Int64(values.volumeTotalCapacity ?? 0)
            let free = Int64(values.volumeAvailableCapacity ?? 0)
            guard total > 0 else { return }
            let used = max(total - free, 0)
            let fraction = Int(used * 100 / total)
            let usedText = ByteCountFormatter.string(fromByteCount: used, countStyle: .decimal)
            let totalText = ByteCountFormatter.string(fromByteCount: total, countStyle: .decimal)
            diskSubtitle = "已用 \(fraction)% · \(usedText) / \(totalText)"
        } catch {
            // 保持占位（不伪造）
        }
    }

    /// 统一降级组件（基线 11.3 ⑦）。
    @ViewBuilder
    private var capabilityBanner: some View {
        if capability.missingCount > 0 {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text("缺少 \(capability.missingCount) 项权限，部分功能降级")
                Spacer()
                Button("去授权") { Task { await capability.requestFirstMissing() } }
                Button("设置…") {}
            }
            .padding(10)
            .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}