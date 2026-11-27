import SwiftUI

/// 视觉主题（参考 CleanUp 设计语言：3D 玻璃拟态 + 每功能一色相渐变 + squircle 徽章 +
/// 顶部磁盘总览 + 功能卡片网格首页）。
/// 插画不复制原应用资源，以渐变 squircle 徽章 + 白色 SF Symbol 浮雕实现同风格。
enum CCleanTheme {

    /// 功能色相（亮部 → 暗部同 hue 双段渐变，亮部 ~80% lightness、暗部 ~35%）。
    struct Accent {
        let top: Color
        let bottom: Color

        var gradient: LinearGradient {
            LinearGradient(colors: [top, bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    // 功能色映射（对齐 CleanUp：粉=扫描、绿=磁盘、蓝=应用、品红=隐私、橙=大文件…）
    // 色相常量挂 Accent 类型上（卡片字面量可用 `.app` 简写）；尺寸常量挂 CCleanTheme 上
    /// 徽章尺寸 / 圆角 / 网格间距（对齐视觉分析规格：圆角 20、间距 16、页边距 24）。
    static let badgeSize: CGFloat = 60
    static let badgeCornerRadius: CGFloat = 18
    static let cardCornerRadius: CGFloat = 20

    /// 字节格式化（0 显示 "0 KB"——ByteCountFormatter 会输出英文 "Zero KB"）。
    static func formatBytes(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 KB" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

extension CCleanTheme.Accent {
    static let scan       = Self(top: Color(hex: "F472B6"), bottom: Color(hex: "DB2777"))  // 智能扫描·粉
    static let disk       = Self(top: Color(hex: "4ADE80"), bottom: Color(hex: "15803D"))  // 磁盘·绿
    static let app        = Self(top: Color(hex: "60A5FA"), bottom: Color(hex: "1D4ED8"))  // 应用/卸载·蓝
    static let privacy    = Self(top: Color(hex: "F472B6"), bottom: Color(hex: "A21CAF"))  // 隐私·品红
    static let loginItem  = Self(top: Color(hex: "EC4899"), bottom: Color(hex: "9D174D"))  // 登录项·玫粉

    static let devTools   = Self(top: Color(hex: "FB923C"), bottom: Color(hex: "C2410C"))  // 开发·橙
    static let packages   = Self(top: Color(hex: "818CF8"), bottom: Color(hex: "3730A3"))  // 多包·靛
    static let fileTree   = Self(top: Color(hex: "34D399"), bottom: Color(hex: "065F46"))  // 文件树·青绿
    static let inventory  = Self(top: Color(hex: "64748B"), bottom: Color(hex: "1E293B"))  // 清单·石板灰蓝
    static let largeFile  = Self(top: Color(hex: "FBBF24"), bottom: Color(hex: "B45309"))  // 大文件·琥珀
    static let duplicate  = Self(top: Color(hex: "2DD4BF"), bottom: Color(hex: "0F766E"))  // 重复文件·青绿
}

/// Color hex 初始化（设计规格色值）。
extension Color {
    init(hex: String) {
        var value: UInt64 = 0
        let sanitized = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        Scanner(string: sanitized).scanHexInt64(&value)
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

/// 渐变 squircle 徽章（3D 玻璃拟态风格：同 hue 双段渐变 + 白色 SF Symbol 浮雕 + 顶部高光）。
struct AccentBadge: View {
    let systemImage: String
    let accent: CCleanTheme.Accent
    var size: CGFloat = CCleanTheme.badgeSize

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(accent.gradient)
            // 顶部高光（顶部 45° 主光的 Fresnel 亮边模拟）
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(
                    LinearGradient(colors: [.white.opacity(0.35), .clear],
                                   startPoint: .top, endPoint: .center)
                )
            Image(systemName: systemImage)
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(.white.opacity(0.95))
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        }
        .frame(width: size, height: size)
        .shadow(color: accent.bottom.opacity(0.35), radius: 10, y: 4)
    }
}

/// 功能列表行（首页普通列表模式：徽章 + 标题/描述 + 右侧箭头；hover 高亮）。
struct FeatureRowView: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let accent: CCleanTheme.Accent
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 14) {
            AccentBadge(systemImage: systemImage, accent: accent, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.06) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
/// 统一加载遮罩：扫描/加载中显示动画层（渐变徽章旋转 + 标题 + 可选进度副标题），
/// 完毕自动消失展示内容页面。各功能页以 `.overlay(LoadingOverlay(...))` 或分支模式接入。
struct LoadingOverlay: View {
    let isLoading: Bool
    var title: String = "正在加载…"
    /// 进度副标题（如「已扫描 N 项 · 路径」）。
    var detail: String? = nil
    /// 徽章图标（默认扫描镜，可换 folder/trash 等贴语义）。
    var systemImage: String = "sparkle.magnifyingglass"
    var accent: CCleanTheme.Accent = .scan
    @State private var spinning = false

    var body: some View {
        ZStack {
            if isLoading {
                RoundedRectangle(cornerRadius: CCleanTheme.cardCornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                VStack(spacing: 18) {
                    AccentBadge(systemImage: systemImage, accent: accent, size: 64)
                        .rotationEffect(.degrees(spinning ? 360 : 0))
                        .animation(
                            .linear(duration: 1.8).repeatForever(autoreverses: false),
                            value: spinning
                        )
                        .onAppear { spinning = true }
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                    if let detail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    ProgressView()
                        .controlSize(.regular)
                }
                .padding(40)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isLoading)
        .allowsHitTesting(isLoading)   // 加载中拦截交互，完毕放行
    }
}
