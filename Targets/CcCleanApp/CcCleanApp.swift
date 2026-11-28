import SwiftUI
import AppKit
import CcCleanCore

/// CcClean 入口：AppKit 生命周期（CleanUp 同款）。
/// 背景：SwiftUI App 生命周期（WindowGroup）在 SwiftPM 裸构建 + 手工 bundle 下，
/// 主窗口交通灯 chrome 完全不被系统渲染（2026-11-28 像素级实证：红/黄/绿 0 像素；
/// 而纯 AppKit NSWindow 同环境渲染正常，CleanUp 同架构亦正常）——
/// 因此主窗口改由 AppKit 创建、NSHostingView 承载 SwiftUI 内容。
@main
final class CcCleanMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

/// App 生命周期（CleanUp 同款退出语义）：
/// - Dock 右键"退出"/Cmd+Q：仅隐藏主窗口 + Dock 图标消失（app 收进状态栏，非真退出）
/// - 面板"退出"按钮（requestRealExit 时间窗标志）：真退出
/// - 主窗口由 AppKit 创建并常驻（close/orderOut 均可复用，单窗口保证）
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// 面板"退出"按钮的放行截止时间（时间窗标志：窗口内 shouldTerminate 一律放行）。
    private var realExitDeadline = Date.distantPast

    /// 跨功能共享 ViewModel（原 SwiftUI @State 迁移至此）。
    private let capabilityModel = CapabilityViewModel()

    /// AppKit 托管主窗口（NSHostingView 承载 HomeView）。
    private var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {

        NSApp.setActivationPolicy(.regular)
        StatusPanelWindowController.shared.setup()
        NotificationCenter.default.addObserver(
            forName: .statusPanelOpenMain, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.activateMainWindow()
            }
        }
        setupMainWindow()
        // app.run() 前窗口未上屏（实测 CGWindowList 无此窗口）——延迟至事件循环激活后强制上屏
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let w = self?.mainWindow else { return }
            w.orderFrontRegardless()
        }
    }

    /// 创建 AppKit 主窗口（CleanUp 同款玻璃形态：fullSizeContentView + 隐藏标题 +
    /// 透明标题栏 + 透明窗口底；内容层毛玻璃由 HomeView 的 GlassWindowBackground 承载）。
    /// 创建 AppKit 主窗口（CleanUp 同款玻璃形态：fullSizeContentView + 隐藏标题 +
    /// 透明标题栏 + 透明窗口底；内容层毛玻璃由 HomeView 的 GlassWindowBackground 承载）。
    /// 交通灯：系统标准按钮（AppKit 生命周期 + fullSizeContentView 下正常渲染，
    /// GlassWindowSetup.restoreWindowChrome 兜底恢复可见性）——不自绘。
    private func setupMainWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 648),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "CcClean"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 900, height: 620)
        window.isReleasedWhenClosed = false   // 关闭后对象存活，可复用（单窗口保证）

        let content = HomeView()
            .environment(capabilityModel)
            .preferredColorScheme(.dark)
        let hostingView = NSHostingView(rootView: content)
        // macOS 13+ sizingOptions：禁用内容驱动窗口尺寸（Text 固有尺寸曾把窗口压成 47×44）
        hostingView.sizingOptions = []
        window.contentView = hostingView
        mainWindow = window
    }


    /// 关闭主窗口后 app 不退出（状态栏面板常驻）。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// 退出语义（CleanUp 同款）：
    /// - Dock 右键"退出"/Cmd+Q → 只隐藏主窗口 + Dock 图标消失（app 收进状态栏，非真退出）
    /// - 面板"退出"按钮 → 真退出
    /// 时间窗判断：requestRealExit 置 2s 截止时间，窗口内到达的 shouldTerminate 一律放行；
    /// 过期自动失效，不会误放行后续 Dock/Cmd+Q 退出请求。
    /// 注意：隐藏只对主窗口 orderOut——NSApp.hide 会连状态栏面板一起藏，勿用。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Date() < realExitDeadline { return .terminateNow }
        hideMainWindow()
        // Dock 图标同步退出（CleanUp 同款）：app 降级为 accessory，仅状态栏驻留；
        // 主窗口经 activateMainWindow 唤起时切回 regular 恢复图标。
        NSApp.setActivationPolicy(.accessory)
        return .terminateCancel
    }

    /// Dock 图标点击（app reopen）：唤起主窗口，保证单窗口。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { activateMainWindow() }
        return true
    }

    /// URL scheme（cclean://main）：AppKit 生命周期由 delegate 接管（原 HomeView.onOpenURL）。
    func application(_ application: NSApplication, open urls: [URL]) {
        if urls.contains(where: { $0.scheme == "cclean" }) {
            activateMainWindow()
        }
    }

    /// 自定义 Dock 菜单：仅"打开主界面"（系统"退出"经上面拦截 = 隐藏主窗口）。
    /// 必须显式设 target=self：AppDelegate 不在 responder chain，省略 target 时菜单项无效。
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let openItem = NSMenuItem(
            title: "打开主界面", action: #selector(activateMainWindow), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        return menu
    }

    /// 面板"退出"按钮 → 真正退出软件。
    /// terminate 放行时进程结束不会执行到末行；任何环节失效时 exit 兜底强制终止
    /// （本应用无未保存文档，exit 安全）。
    func requestRealExit() {
        realExitDeadline = Date().addingTimeInterval(2)
        NSApp.terminate(nil)
        exit(0)
    }

    /// 主窗口隐藏：窗口仍留在内存（isReleasedWhenClosed=false），随时可复用唤起。
    private func hideMainWindow() {
        mainWindow?.orderOut(nil)
    }

    /// 打开主界面：复用 AppKit 托管窗口（close/orderOut 均可唤起），单窗口保证。
    /// 主窗口出现时切回 regular——恢复 Dock 图标（与 Dock 退出的 accessory 降级配对）。
    @objc func activateMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        if mainWindow == nil { setupMainWindow() }
        mainWindow?.makeKeyAndOrderFront(nil)
    }
}