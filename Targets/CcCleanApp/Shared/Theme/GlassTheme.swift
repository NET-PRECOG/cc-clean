import SwiftUI
import AppKit

/// 全窗口 CleanUp 同款玻璃效果（2026-11-28）：
/// - 窗口底：NSVisualEffectView（.sidebar 材质 + behindWindow 模糊桌面）
/// - 窗口透明：NSWindow isOpaque=false / backgroundColor=.clear（材质直接模糊桌面）
/// - 外观：强制 darkAqua（系统 .primary/.secondary 文字自动白系，与 CleanUp 一致）
/// - 容器底：SwiftUI 窗口容器层用 `.containerBackground(.clear, for: .window)` 清空
///   （WindowGroup 主窗口关闭重开后 onAppear 不会重跑 → 由 didBecomeKey 观察者持续保证透明）
///
/// 用法：窗口根视图 `.background(GlassWindowBackground())` + `.modifier(GlassWindowSetup())`
/// + `.containerBackground(.clear, for: .window)` + `.preferredColorScheme(.dark)`。
struct GlassWindowBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// 窗口内玻璃面板（与交通灯所在窗口底完全同款：同 .sidebar 材质 + behindWindow
/// 模糊同一桌面，主内容玻璃与交通灯区域视觉一致；圆角由 layer 承载）。
/// 用于首页功能卡片等「主内容玻璃表面」。
struct GlassPanelBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var cornerRadius: CGFloat = CCleanTheme.cardCornerRadius

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.masksToBounds = true
        // 面板白描边（与窗口框一致的高光边界）
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// 持续保证主/设置窗口透明 + 强制暗色外观：
/// - onAppear 双次延迟设置（首次布局）
/// - NSWindow.didBecomeKeyNotification 观察者（窗口关闭重开、设置窗口打开等场景）
struct GlassWindowSetup: ViewModifier {
    static var observerInstalled = false

    func body(content: Content) -> some View {
        content.onAppear {
            Self.installObserverIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { Self.setupGlassWindows() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { Self.setupGlassWindows() }
        }
    }

    static func installObserverIfNeeded() {
        guard !observerInstalled else { return }
        observerInstalled = true
        // 主窗口关闭重开/设置窗口打开时不会重跑 onAppear——didBecomeKey 时补设透明
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let window, !(window is NSPanel), window.frame.width > 600 else { return }
                makeTransparent(window)
            }
        }
    }

    static func setupGlassWindows() {
        for window in NSApp.windows where !(window is NSPanel) && window.isVisible && window.frame.width > 600 {
            makeTransparent(window)
        }
    }

    static func makeTransparent(_ window: NSWindow) {
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .darkAqua)
        restoreWindowChrome(window)
    }

    /// 恢复系统标准窗口按钮（交通灯：关闭/最小化/全屏）可见性。
    /// 主窗口 orderOut 复用 + accessory↔regular 激活策略切换后，macOS 26 可能停止
    /// 渲染窗口 chrome——didBecomeKey / 主窗口唤起路径统一调用；
    /// isHidden = false 幂等，正常场景无副作用。
    static func restoreWindowChrome(_ window: NSWindow) {
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = false
        }
    }
}
extension View {
    /// 窗口容器底清空（macOS 15+ 官方 API；14.0 部署目标下优雅跳过，窗口透明由 GlassWindowSetup 兜底）。
    @ViewBuilder
    func glassContainerBackground() -> some View {
        if #available(macOS 15.0, *) {
            self.containerBackground(.clear, for: .window)
        } else {
            self
        }
    }
}
