import SwiftUI
import CcCleanCore

/// CcClean App 入口（S0 骨架：设置页 + 能力总览卡；完整信息架构自 S2 起按基线 11.1 搭建）。
@main
struct CcCleanApp: App {

    @State private var capabilityModel = CapabilityViewModel()

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

        MenuBarExtra("CcClean", systemImage: "gauge") {
            // 状态栏面板（模仿 CleanUp：磁盘用量 + 系统信息 + 快捷功能 + 主界面/退出）
            StatusPanelView()
        }
        .menuBarExtraStyle(.window)
    }
}