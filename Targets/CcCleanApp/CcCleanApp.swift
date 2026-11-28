import SwiftUI
import CcCleanCore

/// CcClean App 入口（S0 骨架：设置页 + 能力总览卡；完整信息架构自 S2 起按基线 11.1 搭建）。
@main
struct CcCleanApp: App {

    @State private var capabilityModel = CapabilityViewModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(id: "main") {
            // 列表式首页（参考 CleanUp 设计语言，2026-11-27）
            HomeView()
                .environment(capabilityModel)
        }
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsView()
                .environment(capabilityModel)
        }
        // 状态栏面板已迁移为 NSStatusItem + 透明 NSPanel（CleanUp 同款架构），
        // 由 StatusPanelWindowController 在 applicationDidFinishLaunching 创建。
    }
}

/// App 生命周期：
/// - 创建状态栏面板窗口控制器；转发"打开主界面"通知
/// - Dock / Cmd+Q 的退出 = 仅隐藏主窗口（状态栏面板常驻，不真正退出）
/// - 面板"退出"按钮（requestRealExit）才是真正退出软件
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// 面板"退出"按钮设置后才允许真正终止（区分 Dock/Cmd+Q 的退出请求）。
    private var realExitRequested = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        StatusPanelWindowController.shared.setup()
        NotificationCenter.default.addObserver(
            forName: .statusPanelOpenMain, object: nil, queue: .main
        ) { [weak self] _ in
            self?.activateMainWindow()
        }
    }

    /// 关闭主窗口后 app 不退出（状态栏面板常驻）。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Dock 右键"退出"/Cmd+Q：拦截为隐藏主窗口；面板"退出"按钮放行真退出。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if realExitRequested { return .terminateNow }
        NSApp.hide(nil)
        return .terminateCancel
    }

    /// 自定义 Dock 菜单：打开主界面 + 真正退出（面板常驻不受影响）。
    /// 必须显式设 target=self：AppDelegate 不在 responder chain，
    /// 省略 target 时 action 沿响应链找不到接收者 → 菜单项点击无效。
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()

        let openItem = NSMenuItem(
            title: "打开主界面", action: #selector(activateMainWindow), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let exitItem = NSMenuItem(
            title: "退出 CClean", action: #selector(exitFromDock), keyEquivalent: "")
        exitItem.target = self
        menu.addItem(exitItem)

        return menu
    }

    /// 面板"退出"按钮 → 真正退出软件。
    func requestRealExit() {
        realExitRequested = true
        NSApp.terminate(nil)
    }

    /// Dock 菜单"退出 CClean" → 真正退出（与面板退出同一通路）。
    @objc func exitFromDock() {
        requestRealExit()
    }

    @objc func activateMainWindow() {
        StatusPanelWindowController.shared.activateMainWindow()
    }
}