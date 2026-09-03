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
        refreshAccessibilityIndex()
    }

    /// 后台重扫辅助功能索引。面板打开时先用上次的结果即时显示，不等这次扫完。
    private var refreshing = false
    private func refreshAccessibilityIndex() {
        guard Permissions.hasAccessibility, !refreshing else { return }
        refreshing = true
        Task {
            let extras = await Task.detached(priority: .userInitiated) { AccessibilityIndex.scan() }.value
            axExtras = extras
            refreshing = false
        }
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
            // 没有缓存（首次授权后第一次打开）就只好等这一次扫完。
            if axExtras.isEmpty {
                axExtras = await Task.detached(priority: .userInitiated) { AccessibilityIndex.scan() }.value
            }
            for i in items.indices {
                if let extra = AccessibilityIndex.match(items[i].bounds, in: axExtras) {
                    items[i].ownerName = extra.appName
                    items[i].icon = extra.icon
                }
            }
            panel.showItems(items.map { ($0, $0.icon) }, notice: nil, anchor: anchor)
            // 顺手刷新缓存，下次更准（新启动的 App、变过位置的图标）。
            refreshAccessibilityIndex()
        }
    }

    func debugArrange() { setInline(.arranging) }

    /// 调试用：不经过面板，直接对某个 App 的隐藏图标走一遍转发流程。
    func debugActivate(appNamed name: String) {
        var items = MenuBarScanner.hiddenItems()
        axExtras = AccessibilityIndex.scan()
        for i in items.indices {
            if let extra = AccessibilityIndex.match(items[i].bounds, in: axExtras) { items[i].ownerName = extra.appName }
        }
        guard let item = items.first(where: { $0.ownerName == name }) else {
            NSLog("CoffeeBar: no hidden item for \(name); hidden = \(items.map(\.ownerName))")
            return
        }
        activate(item, rightButton: false)
    }

    /// 点了面板里的图标：把真图标临时移回菜单栏，在它上面合成一次点击。
    /// 直接对屏幕外的图标用辅助功能 AXPress 虽然返回成功，但菜单不会显示，所以必须先展开。
    func activate(_ item: MenuBarItem, rightButton: Bool) {
        panel.dismiss()
        if !Permissions.hasAccessibility {
            Permissions.requestAccessibility()
            return
        }
        setInline(.temporary)
        let extra = AccessibilityIndex.match(item.bounds, in: axExtras)
        Task {
            guard let rect = await ClickForwarder.waitUntilOnScreen(item.windowID) else {
                // 展开了也挤不进屏幕（屏幕太窄或被刘海占了），只能通过辅助功能直接按。
                NSLog("CoffeeBar: \(item.ownerName) never came on screen, AX press")
                if let extra { _ = AccessibilityIndex.press(extra) }
                return
            }
            // 窗口服务器报告图标回到屏幕时它还不能点：目标 App 自己的坐标还没更新，点击会穿到下面的窗口。
            // 等 App 的辅助功能坐标也回到屏幕上；认不出 App 的就退而求其次等一段固定时间。
            let started = Date()
            var target = rect
            if let extra, let axFrame = await AccessibilityIndex.waitUntilOnScreen(extra) {
                target = axFrame
            } else {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                target = MenuBarScanner.bounds(of: item.windowID) ?? rect
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
            NSLog("CoffeeBar: click \(item.ownerName) at \(target) after \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            let targetApp = extra.flatMap { NSRunningApplication(processIdentifier: $0.pid) }
            let before = extra.map { MenuBarScanner.onScreenWindows(ownedBy: $0.pid) } ?? [:]
            ClickForwarder.click(at: CGPoint(x: target.midX, y: target.midY), rightButton: rightButton)

            // macOS 14 起 App 只有在收到真实用户输入后才能激活自己，合成点击不算，
            // 所以"点图标就把窗口带到前台"的 App（没有菜单的那种）会被系统拒绝。
            // 点完看一眼：目标 App 弹出了菜单 / 弹窗就不打扰；什么都没弹，就替它激活。
            guard let extra, let targetApp else { return }
            try? await Task.sleep(nanoseconds: 400_000_000)
            let after = MenuBarScanner.onScreenWindows(ownedBy: extra.pid)
            let poppedUp = after.contains { id, layer in before[id] == nil && layer > 0 }
            if !poppedUp, !targetApp.isActive {
                NSLog("CoffeeBar: no popup from \(item.ownerName), activating it")
                targetApp.activate()
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
