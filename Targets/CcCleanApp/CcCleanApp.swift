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

/// App 生命周期：创建状态栏面板窗口控制器；转发"打开主界面"通知。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        StatusPanelWindowController.shared.setup()
        NotificationCenter.default.addObserver(
            forName: .statusPanelOpenMain, object: nil, queue: .main
        ) { [weak self] _ in
            self?.activateMainWindow()
        }
    }

    func activateMainWindow() {
        StatusPanelWindowController.shared.activateMainWindow()
    }
}