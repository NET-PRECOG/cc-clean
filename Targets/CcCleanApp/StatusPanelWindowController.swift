import AppKit
import SwiftUI

/// 状态栏面板窗口控制器（CleanUp 同款架构：NSStatusItem + 全透明 NSPanel）。
/// 完全掌控窗口透明/层级/定位，替代 MenuBarExtra（其窗口透明无法可靠设置）。
@MainActor
final class StatusPanelWindowController {
    static let shared = StatusPanelWindowController()

    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isSetup = false

    func setup() {
        guard !isSetup else { return }
        isSetup = true

        // 状态栏图标
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "gauge", accessibilityDescription: "CcClean")
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        statusItem = item

        // 全透明面板（CleanUp 同款：无底色，仅卡片浮层）
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 445, height: 560),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: StatusPanelView())

        self.panel = panel
        installMonitors()
    }

    @objc private func togglePanel() {
        guard let panel else { return }
        if panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        guard let panel, let item = statusItem else { return }
        positionBelowStatusItem(panel: panel, button: item.button)
        panel.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(
            name: .statusPanelVisibilityChanged, object: nil,
            userInfo: ["visible": true])
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        NotificationCenter.default.post(
            name: .statusPanelVisibilityChanged, object: nil,
            userInfo: ["visible": false])
    }

    /// 打开主界面（面板操作条按钮经通知调用）：激活已有主窗口。
    func activateMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        let main = NSApp.windows.first { window in
            !(window is NSPanel) && window.isVisible
                && window.frame.width > 600          // 排除状态栏面板/小窗口/设置窗口
        }
        main?.makeKeyAndOrderFront(nil)
    }

    /// 定位到状态栏图标正下方水平居中（clamp 在图标所在屏范围内）。
    private func positionBelowStatusItem(panel: NSPanel, button: NSStatusBarButton?) {
        guard let button, let buttonWindow = button.window else { return }
        let iconRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let iconCenterX = iconRect.midX
        let screen = buttonWindow.screen ?? NSScreen.main
        var origin = NSPoint(
            x: iconCenterX - panel.frame.width / 2,
            y: iconRect.minY - panel.frame.height - 6)
        if let screen {
            origin.x = min(max(origin.x, screen.frame.minX + 8),
                           screen.frame.maxX - panel.frame.width - 8)
            origin.y = min(max(origin.y, screen.visibleFrame.minY + 8),
                           screen.visibleFrame.maxY - panel.frame.height)
        }
        panel.setFrameOrigin(origin)
    }

    /// 点击面板外任意处自动关闭（CleanUp 同款行为）。
    private func installMonitors() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideIfOutsideClick() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            let clicked = event.window
            MainActor.assumeIsolated {
                self?.hideIfOutsideClick(window: clicked)
            }
            // 若点击在面板外 hide() 已 orderOut；事件本身放行（避免吞掉状态栏图标点击）
            return event
        }
    }

    private func hideIfOutsideClick(window: NSWindow? = nil) {
        guard let panel, panel.isVisible else { return }
        if let w = window, w === panel { return }                       // 点击面板内部
        if panel.frame.contains(NSEvent.mouseLocation) { return }       // 鼠标仍在面板范围
        hide()
    }
}

extension Notification.Name {
    /// 面板显示/隐藏（userInfo: visible: Bool）——面板内视图据此启停采样轮询。
    static let statusPanelVisibilityChanged = Notification.Name("statusPanelVisibilityChanged")
    /// 面板"打开主界面"按钮 → 激活主窗口。
    static let statusPanelOpenMain = Notification.Name("statusPanelOpenMain")
}