import SwiftUI
import AppKit

/// 全窗口 CleanUp 同款玻璃效果（2026-11-28）：
/// - 窗口底：NSVisualEffectView（.sidebar 材质 + behindWindow 模糊桌面）+ 黑 tint 15%
/// - 窗口透明：NSWindow isOpaque=false / backgroundColor=.clear（材质直接模糊桌面）
/// - 外观：全窗口强制暗色（系统 .primary/.secondary 文字自动白系，与 CleanUp 一致）
///
/// 用法：窗口根视图 `.background(GlassWindowBackground())` + `.modifier(GlassWindowSetup())`
/// + `.preferredColorScheme(.dark)`。
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

/// 找到本视图所在 NSWindow（主窗口/设置窗口）并设置全透明 + 强制暗色外观。
struct GlassWindowSetup: ViewModifier {
    func body(content: Content) -> some View {
        content.onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { setupGlassWindow() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { setupGlassWindow() }
        }
    }

    private func setupGlassWindow() {
        // 主窗口/设置窗口：非 NSPanel、可见、宽 > 600（排除状态栏面板）
        for window in NSApp.windows where !(window is NSPanel) && window.isVisible && window.frame.width > 600 {
            window.isOpaque = false
            window.backgroundColor = .clear
            window.appearance = NSAppearance(named: .darkAqua)
        }
    }
}