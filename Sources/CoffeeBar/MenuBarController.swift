import AppKit

/// 核心原理（和 Bartender / Ice / Hidden Bar 一样）：
/// 菜单栏图标从右往左排。我们放一个"分隔符" NSStatusItem，
/// 把它的宽度拉到极大，分隔符左侧的所有图标就被挤出屏幕，等于"隐藏"。
///
/// 访问隐藏图标有两种方式：
/// 1. 左键点 `<`：在菜单栏下方弹一个面板，显示隐藏图标的截图，点它就转发给真图标（默认）。
/// 2. ⌥ + 左键点 `<`：把分隔符缩回去，图标直接在菜单栏里展开（屏幕够宽时可用）。
@MainActor
final class MenuBarController: NSObject {
    private static let hiddenLength: CGFloat = 10_000
    private static let shownLength: CGFloat = 12

    private let toggleItem: NSStatusItem
    private let separatorItem: NSStatusItem
    private let panel = DropPanel()

    private var isInlineShown = false
    /// 上次打开面板时扫到的辅助功能索引，点击兜底时用。
    private var axExtras: [AXMenuExtra] = []
    private var mouseUpMonitor: Any?
    private var rehideTimer: Timer?

    override init() {
        // 首次启动时把两个图标放在菜单栏最右侧并相邻，这样默认就把所有第三方图标藏起来。
        // macOS 用 "NSStatusItem Preferred Position <autosaveName>" 记录位置，数值越小越靠右。
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "NSStatusItem Preferred Position CoffeeBar.separator") == nil {
            defaults.set(0, forKey: "NSStatusItem Preferred Position CoffeeBar.toggle")
            defaults.set(1, forKey: "NSStatusItem Preferred Position CoffeeBar.separator")
        }

        let bar = NSStatusBar.system
        // 先创建的在右，后创建的在左。所以先建开关，再建分隔符。
        toggleItem = bar.statusItem(withLength: NSStatusItem.variableLength)
        separatorItem = bar.statusItem(withLength: Self.hiddenLength)
        super.init()

        toggleItem.autosaveName = "CoffeeBar.toggle"
        separatorItem.autosaveName = "CoffeeBar.separator"

        if let button = toggleItem.button {
            button.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Show hidden items")
            button.target = self
            button.action = #selector(toggleClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        if let button = separatorItem.button {
            button.image = NSImage(systemSymbolName: "line.diagonal", accessibilityDescription: "Separator")
            button.imagePosition = .imageOnly
            button.isEnabled = false
            button.appearsDisabled = false
        }

        panel.onItemClick = { [weak self] item, right in
            self?.activate(item, rightButton: right)
        }

        applyInlineState()
    }

    // MARK: - 开关按钮

    @objc private func toggleClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            showContextMenu()
            return
        }
        if panel.isVisible {
            panel.dismiss()
            return
        }
        if isInlineShown {
            hideInline()
            return
        }
        if event?.modifierFlags.contains(.option) == true {
            showInline()
        } else {
            openPanel()
        }
    }

    // MARK: - 下拉面板

    private func openPanel() {
        guard let anchor = toggleItem.button?.window?.frame else { return }

        if !Permissions.hasScreenRecording {
            Permissions.requestScreenRecording()
            panel.showItems([], notice: (
                "需要「屏幕录制」权限来预览隐藏的图标。授权后请重新启动 CoffeeBar。\n（或者按住 ⌥ 点击 “<” 直接在菜单栏里展开）",
                Permissions.openScreenRecordingSettings
            ), anchor: anchor)
            return
        }

        var items = MenuBarScanner.hiddenItems()
        let notice: (String, (() -> Void)?)? = Permissions.hasAccessibility ? nil : (
            "需要「辅助功能」权限才能点击面板里的图标。", Permissions.openAccessibilitySettings
        )

        Task {
            // 辅助功能扫描要跨进程问一圈，放后台线程。
            axExtras = await Task.detached { AccessibilityIndex.scan() }.value
            for i in items.indices {
                if let extra = AccessibilityIndex.match(items[i].bounds, in: axExtras) {
                    items[i].ownerName = extra.appName
                }
            }
            var images = await ItemCapturer.capture(items)
            // 兜底：个别窗口在屏幕外截不到，就临时展开一下再截。
            let missing = items.filter { images[$0.windowID] == nil }
            if !missing.isEmpty {
                separatorItem.length = Self.shownLength
                try? await Task.sleep(nanoseconds: 150_000_000)
                let extra = await ItemCapturer.capture(missing)
                separatorItem.length = Self.hiddenLength
                images.merge(extra) { $1 }
            }
            let entries = items.compactMap { item in images[item.windowID].map { (item, $0) } }
            panel.showItems(entries, notice: notice, anchor: anchor)
        }
    }

    /// 点了面板里的图标：把真图标临时移回菜单栏，在它上面合成一次点击。
    private func activate(_ item: MenuBarItem, rightButton: Bool) {
        panel.dismiss()
        if !Permissions.hasAccessibility {
            Permissions.requestAccessibility()
            return
        }
        showInline()
        Task {
            if let rect = await ClickForwarder.waitUntilOnScreen(item.windowID) {
                ClickForwarder.click(at: CGPoint(x: rect.midX, y: rect.midY), rightButton: rightButton)
            } else {
                // 展开了也挤不进屏幕（屏幕太窄或被刘海占了），直接按它。
                if let extra = AccessibilityIndex.match(item.bounds, in: axExtras) {
                    _ = AccessibilityIndex.press(extra)
                }
            }
        }
    }

    // MARK: - 菜单栏内展开

    private func showInline() {
        isInlineShown = true
        applyInlineState()
    }

    private func hideInline() {
        isInlineShown = false
        applyInlineState()
    }

    private func applyInlineState() {
        separatorItem.length = isInlineShown ? Self.shownLength : Self.hiddenLength
        toggleItem.button?.image = NSImage(
            systemSymbolName: isInlineShown ? "chevron.right" : "chevron.left",
            accessibilityDescription: nil
        )
        if isInlineShown {
            startRehideWatchers()
        } else {
            stopRehideWatchers()
        }
    }

    /// 展开状态下，在菜单栏以外松开鼠标（比如选了某个菜单项），或者 20 秒无操作，就自动收回。
    /// 用 mouseUp 而不是 mouseDown，是为了等对方菜单项的动作先触发。
    private func startRehideWatchers() {
        stopRehideWatchers()
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) { [weak self] event in
            guard let self else { return }
            if !Self.isInMenuBar(event.locationInWindow) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.hideInline() }
            }
        }
        rehideTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.hideInline() }
        }
    }

    private func stopRehideWatchers() {
        if let mouseUpMonitor {
            NSEvent.removeMonitor(mouseUpMonitor)
            self.mouseUpMonitor = nil
        }
        rehideTimer?.invalidate()
        rehideTimer = nil
    }

    /// AppKit 屏幕坐标（原点左下）。菜单栏高度用 frame 和 visibleFrame 的差算，刘海屏也对。
    private static func isInMenuBar(_ point: NSPoint) -> Bool {
        NSScreen.screens.contains { screen in
            let menuBarTop = screen.frame.maxY
            let menuBarBottom = screen.visibleFrame.maxY
            return point.x >= screen.frame.minX && point.x <= screen.frame.maxX
                && point.y >= menuBarBottom - 2 && point.y <= menuBarTop
        }
    }

    // MARK: - 右键菜单

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "“/” 左边的图标会被隐藏，按住 ⌘ 拖动图标或 “/” 调整", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "左键：弹出面板    ⌥+左键：在菜单栏内展开", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 CoffeeBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        toggleItem.menu = menu
        toggleItem.button?.performClick(nil)
        toggleItem.menu = nil
    }
}
