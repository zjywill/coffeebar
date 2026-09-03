import AppKit

/// 核心原理（和 Bartender / Ice / Hidden Bar 一样）：
/// 菜单栏图标从右往左排。我们放一个"分隔符" NSStatusItem，
/// 把它的宽度拉到极大，分隔符左侧的所有图标就被挤出屏幕，等于"隐藏"。
///
/// 三种状态：
/// - 隐藏（默认）：分隔符撑满，图标在屏幕外。
/// - 临时展开：点了面板里的图标后，把真图标移回菜单栏点一下；用户在菜单栏外松开鼠标就自动收回。
/// - 整理模式：用户主动展开，用来 ⌘ 拖动排布图标；不会自动收回，再点一次 `<` 才收。
@MainActor
final class MenuBarController: NSObject {
    private static let hiddenLength: CGFloat = 10_000
    private static let shownLength: CGFloat = 12

    private enum InlineState { case hidden, temporary, arranging }

    private let toggleItem: NSStatusItem
    private let separatorItem: NSStatusItem
    private let panel = DropPanel()
    private let updater = UpdateController()

    private var inlineState: InlineState = .hidden
    private var mouseUpMonitor: Any?
    private var rehideTimer: Timer?
    /// 上次打开面板时扫到的辅助功能索引，点击兜底时用。
    private var axExtras: [AXMenuExtra] = []

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
        // 展开状态下（不管哪种）点 `<` 都是收回。
        if inlineState != .hidden {
            setInline(.hidden)
            return
        }
        if event?.modifierFlags.contains(.option) == true {
            setInline(.arranging)
        } else {
            openPanel()
        }
    }

    // MARK: - 下拉面板

    private func openPanel() {
        guard let anchor = toggleItem.button?.window?.frame else { return }

        if !Permissions.hasAccessibility {
            Permissions.requestAccessibility()
            panel.showItems([], notice: (
                "需要「辅助功能」权限来识别和点击隐藏的图标。授权后再点一次 “<” 即可。",
                [("打开系统设置", Permissions.openAccessibilitySettings)]
            ), anchor: anchor)
            return
        }

        var items = MenuBarScanner.hiddenItems()
        Task {
            // 辅助功能扫描要跨进程问一圈，放后台线程。
            axExtras = await Task.detached { AccessibilityIndex.scan() }.value
            for i in items.indices {
                if let extra = AccessibilityIndex.match(items[i].bounds, in: axExtras) {
                    items[i].ownerName = extra.appName
                    items[i].icon = extra.icon
                }
            }
            panel.showItems(items.map { ($0, $0.icon) }, notice: nil, anchor: anchor)
        }
    }

    /// 点了面板里的图标：把真图标临时移回菜单栏，在它上面合成一次点击。
    /// 直接对屏幕外的图标用辅助功能 AXPress 虽然返回成功，但菜单不会显示，所以必须先展开。
    private func activate(_ item: MenuBarItem, rightButton: Bool) {
        panel.dismiss()
        if !Permissions.hasAccessibility {
            Permissions.requestAccessibility()
            return
        }
        setInline(.temporary)
        Task {
            if let rect = await ClickForwarder.waitUntilOnScreen(item.windowID) {
                ClickForwarder.click(at: CGPoint(x: rect.midX, y: rect.midY), rightButton: rightButton)
            } else if let extra = AccessibilityIndex.match(item.bounds, in: axExtras) {
                // 展开了也挤不进屏幕（屏幕太窄或被刘海占了），只能直接按它。
                _ = AccessibilityIndex.press(extra)
            }
        }
    }

    // MARK: - 菜单栏内展开

    private func setInline(_ state: InlineState) {
        inlineState = state
        applyInlineState()
    }

    private func applyInlineState() {
        separatorItem.length = inlineState == .hidden ? Self.hiddenLength : Self.shownLength
        let symbol: String
        switch inlineState {
        case .hidden: symbol = "chevron.left"
        case .temporary: symbol = "chevron.right"
        case .arranging: symbol = "checkmark"
        }
        toggleItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        toggleItem.button?.toolTip = inlineState == .arranging ? "整理中：⌘ 拖动图标或 “/”，完成后点这里收回" : nil

        if inlineState == .temporary {
            startRehideWatchers()
        } else {
            stopRehideWatchers()
        }
    }

    /// 临时展开时，在菜单栏以外松开鼠标（比如选了某个菜单项），或者 20 秒无操作，就自动收回。
    /// 用 mouseUp 而不是 mouseDown，是为了等对方菜单项的动作先触发。按着 ⌘ 时不收，用户可能在拖图标。
    private func startRehideWatchers() {
        stopRehideWatchers()
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) { [weak self] event in
            guard let self else { return }
            if event.modifierFlags.contains(.command) { return }
            if !Self.isInMenuBar(event.locationInWindow) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if self.inlineState == .temporary { self.setInline(.hidden) }
                }
            }
        }
        rehideTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.inlineState == .temporary else { return }
                if NSEvent.modifierFlags.contains(.command) { return }
                self.setInline(.hidden)
            }
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

    @objc private func startArranging() {
        setInline(.arranging)
    }

    @objc private func checkForUpdates() {
        updater.checkForUpdates()
    }

    private func showContextMenu() {
        let menu = NSMenu()
        let arrange = NSMenuItem(title: inlineState == .arranging ? "完成整理" : "整理图标…", action: nil, keyEquivalent: "")
        arrange.target = self
        arrange.action = inlineState == .arranging ? #selector(finishArranging) : #selector(startArranging)
        menu.addItem(arrange)
        menu.addItem(withTitle: "整理时 “/” 左边的图标会被隐藏，按住 ⌘ 拖动图标或 “/” 调整", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        menu.addItem(withTitle: "CoffeeBar \(version)", action: nil, keyEquivalent: "")
        if updater.isConfigured {
            let check = NSMenuItem(title: "检查更新…", action: #selector(checkForUpdates), keyEquivalent: "")
            check.target = self
            menu.addItem(check)
        }
        menu.addItem(withTitle: "退出 CoffeeBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        toggleItem.menu = menu
        toggleItem.button?.performClick(nil)
        toggleItem.menu = nil
    }

    @objc private func finishArranging() {
        setInline(.hidden)
    }
}
