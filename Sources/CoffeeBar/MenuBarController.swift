import AppKit

/// 核心原理（和 Bartender / Ice / Hidden Bar 一样）：
/// 菜单栏图标从右往左排。我们放一个"分隔符" NSStatusItem，
/// 把它的宽度拉到极大，分隔符左侧的所有图标就被挤出屏幕，等于"隐藏"。
///
/// 两种状态：
/// - 隐藏（默认）：分隔符撑满，图标在屏幕外。
/// - 整理模式：用户主动展开，用来 ⌘ 拖动排布图标；不会自动收回，再点一次 `<` 才收。
///
/// 点面板里的图标时不展开：用合成 ⌘ 拖拽把那**一个**图标挪到 `<` 左边，点它，
/// 等它的菜单 / 弹窗关掉再挪回原位（Ice 的做法，也是 Bartender 的表现）。
@MainActor
final class MenuBarController: NSObject {
    private static let hiddenLength: CGFloat = 10_000
    private static let shownLength: CGFloat = 12

    /// expanded：外接宽屏上不用面板，直接展开，点菜单栏以外的地方自动收回。
    private enum InlineState { case hidden, arranging, expanded }

    private let toggleItem: NSStatusItem
    private let separatorItem: NSStatusItem
    private let panel = DropPanel()
    private let updater = UpdateController()
    private let layoutManager = LayoutManager()
    private var outsideClickMonitor: Any?

    private static let panelOnlyOnBuiltInKey = "CoffeeBar.panelOnlyOnBuiltIn"
    /// 外接显示器够宽，不需要面板；只在内建屏（有刘海、窄）上用面板。
    private var panelOnlyOnBuiltIn: Bool {
        get { UserDefaults.standard.bool(forKey: Self.panelOnlyOnBuiltInKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.panelOnlyOnBuiltInKey) }
    }

    private var inlineState: InlineState = .hidden

    /// 一个临时挪出来的图标：记着它原来在谁左边，好挪回去。
    private struct TempShown {
        let item: MenuBarItem
        let returnLeftOf: CGWindowID?
        let returnRightOf: CGWindowID?
        let pid: pid_t?
        /// 点击后目标 App 新冒出来的窗口（菜单、弹窗或普通窗口），它还在就不收。
        var interfaceWindow: CGWindowID?
    }
    private var tempShown: [TempShown] = []
    private var rehideTimer: Timer?
    private var mouseUpMonitor: Any?
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

        layoutManager.canMove = { [weak self] in
            guard let self else { return false }
            return inlineState == .hidden && tempShown.isEmpty && !panel.isVisible
        }
        layoutManager.toggleWindowID = { [weak self] in self?.toggleWindowID }
        layoutManager.refreshAccessibilityIndex = { [weak self] in
            let extras = await Task.detached(priority: .utility) { AccessibilityIndex.scan() }.value
            self?.axExtras = extras
            return extras
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [layoutManager] in layoutManager.start() }
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
            let wasArranging = inlineState == .arranging
            setInline(.hidden)
            if wasArranging { recordLayoutSoon() }
            return
        }
        if event?.modifierFlags.contains(.option) == true {
            setInline(.arranging)
            return
        }
        if panelOnlyOnBuiltIn, let screen = toggleItem.button?.window?.screen, !MenuBarScanner.isBuiltIn(screen) {
            setInline(.expanded)
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
                L("Accessibility permission is needed to identify and click hidden items. Grant it, then click “<” again."),
                [(L("Open System Settings"), Permissions.openAccessibilitySettings)]
            ), anchor: anchor)
            return
        }

        var items = MenuBarScanner.hiddenItems()
        Task {
            // 没有缓存（首次授权后第一次打开），或者有图标对不上（挪动过后隐藏区的坐标全变了），就现场重扫。
            let stale = axExtras.isEmpty || items.contains { AccessibilityIndex.match($0.bounds, in: axExtras) == nil }
            if stale {
                axExtras = await Task.detached(priority: .userInitiated) { AccessibilityIndex.scan() }.value
            }
            for i in items.indices {
                if let extra = AccessibilityIndex.match(items[i].bounds, in: axExtras) {
                    items[i].ownerName = extra.appName
                    items[i].icon = extra.icon
                }
            }
            // 系统自带的项不该出现在隐藏区，布局管理器马上会把它们挪回去，面板里不列。
            items.removeAll { LayoutManager.isSystemItem($0, extras: axExtras) }
            panel.showItems(items.map { ($0, $0.icon) }, notice: nil, anchor: anchor)
            // 顺手刷新缓存，下次更准（新启动的 App、变过位置的图标）。
            refreshAccessibilityIndex()
        }
    }

    func debugArrange() { setInline(.arranging) }

    /// 调试用：模拟用户把一个隐藏图标拖到 `<` 左边（落在分隔符和 `<` 之间）。
    func debugDropLeftOfToggle(appNamed name: String) {
        var items = MenuBarScanner.hiddenItems()
        axExtras = AccessibilityIndex.scan()
        for i in items.indices {
            if let extra = AccessibilityIndex.match(items[i].bounds, in: axExtras) { items[i].ownerName = extra.appName }
        }
        guard let item = items.first(where: { $0.ownerName == name }), let toggleWindowID else { return }
        Task {
            let r = await ItemMover.move(windowID: item.windowID, ownerPID: item.ownerPID, toLeftOf: toggleWindowID, xOffset: -(item.bounds.width / 2 + 40))
            NSLog("CoffeeBar: drop-left test moved \(name) to \(String(describing: r)); toggle at \(String(describing: MenuBarScanner.bounds(of: toggleWindowID)))")
        }
    }

    /// 调试用：把某个可见图标（比如系统的 Spotlight）挪进隐藏区，看会不会被挪回来。
    func debugHide(appNamed name: String) {
        axExtras = AccessibilityIndex.scan()
        let items = MenuBarScanner.allStatusItems().filter { MenuBarScanner.isOnScreen($0.bounds) }
        guard let item = items.first(where: { AccessibilityIndex.match($0.bounds, in: axExtras)?.appName == name }),
              let separator = MenuBarScanner.separatorWindowID()
        else { NSLog("CoffeeBar: no visible item for \(name)"); return }
        Task {
            let r = await ItemMover.move(windowID: item.windowID, ownerPID: item.ownerPID, toLeftOf: separator)
            NSLog("CoffeeBar: hide test moved \(name) to \(String(describing: r))")
        }
    }

    /// 调试用：把某个 App 的隐藏图标挪到可见区但不记录意图，看布局管理器会不会把它挪回去。
    func debugDrift(appNamed name: String) {
        var items = MenuBarScanner.hiddenItems()
        axExtras = AccessibilityIndex.scan()
        for i in items.indices {
            if let extra = AccessibilityIndex.match(items[i].bounds, in: axExtras) { items[i].ownerName = extra.appName }
        }
        guard let item = items.first(where: { $0.ownerName == name }), let toggleWindowID else { return }
        Task {
            layoutManager.seedIfEmpty(extras: axExtras)
            let r = await ItemMover.move(windowID: item.windowID, ownerPID: item.ownerPID, toLeftOf: toggleWindowID)
            NSLog("CoffeeBar: drift test moved \(name) to \(String(describing: r))")
        }
    }

    /// `<` 按钮的窗口 ID。NSStatusBarButton 的 windowNumber 在 macOS 26 上可能拿不到（负数），
    /// 拿不到就从窗口列表里找：第一个在屏幕上、紧挨着分隔符右侧的状态项窗口。
    private var toggleWindowID: CGWindowID? {
        if let number = toggleItem.button?.window?.windowNumber, number > 0, number < Int(UInt32.max) { return CGWindowID(number) }
        guard let frame = toggleItem.button?.window?.frame else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cgFrame = CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
        return MenuBarScanner.allStatusItems().min { abs($0.bounds.minX - cgFrame.minX) < abs($1.bounds.minX - cgFrame.minX) }?.windowID
    }

    /// 调试用：把某个 App 的隐藏图标单独挪到 `<` 左边，2 秒后挪回去。
    func debugTempShow(appNamed name: String) {
        var items = MenuBarScanner.hiddenItems()
        axExtras = AccessibilityIndex.scan()
        for i in items.indices {
            if let extra = AccessibilityIndex.match(items[i].bounds, in: axExtras) { items[i].ownerName = extra.appName }
        }
        NSLog("CoffeeBar: toggle windowNumber = \(toggleItem.button?.window?.windowNumber ?? -999)")
        guard let index = items.firstIndex(where: { $0.ownerName == name }),
              let toggleWindowID = toggleWindowID
        else { NSLog("CoffeeBar: no hidden item for \(name) or no toggle window"); return }
        let item = items[index]
        let rightNeighbor = index + 1 < items.count ? items[index + 1] : nil
        Task {
            let shown = await ItemMover.move(windowID: item.windowID, ownerPID: item.ownerPID, toLeftOf: toggleWindowID)
            NSLog("CoffeeBar: temp show \(name) -> \(String(describing: shown))")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if let rightNeighbor {
                let back = await ItemMover.move(windowID: item.windowID, ownerPID: item.ownerPID, toLeftOf: rightNeighbor.windowID)
                NSLog("CoffeeBar: moved back -> \(String(describing: back))")
            }
        }
    }

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
        let extra = AccessibilityIndex.match(item.bounds, in: axExtras)
        Task { await tempShowAndClick(item, extra: extra, rightButton: rightButton) }
    }

    private func tempShowAndClick(_ item: MenuBarItem, extra: AXMenuExtra?, rightButton: Bool) async {
        guard let toggleWindowID else { return }
        // 记下回程位置：原来右边那个图标的左边；没有右邻居就用左邻居的右边。
        let hidden = MenuBarScanner.hiddenItems()
        var context = TempShown(item: item, returnLeftOf: nil, returnRightOf: nil, pid: extra?.pid, interfaceWindow: nil)
        if let index = hidden.firstIndex(where: { $0.windowID == item.windowID }) {
            if index + 1 < hidden.count { context = TempShown(item: item, returnLeftOf: hidden[index + 1].windowID, returnRightOf: nil, pid: extra?.pid, interfaceWindow: nil) }
            else if index > 0 { context = TempShown(item: item, returnLeftOf: nil, returnRightOf: hidden[index - 1].windowID, pid: extra?.pid, interfaceWindow: nil) }
        }

        let alreadyShown = tempShown.contains { $0.item.windowID == item.windowID }
        if !alreadyShown {
            guard await ItemMover.move(windowID: item.windowID, ownerPID: item.ownerPID, toLeftOf: toggleWindowID) != nil else {
                NSLog("CoffeeBar: could not move \(item.ownerName) into view, falling back to expanding everything")
                await expandAllAndClick(item, extra: extra, rightButton: rightButton)
                return
            }
            tempShown.append(context)
        }

        // 窗口挪好了，App 自己的坐标还要过一会儿才更新，等它也回到屏幕上再点。
        var target = MenuBarScanner.bounds(of: item.windowID) ?? item.bounds
        if let extra, let axFrame = await AccessibilityIndex.waitUntilOnScreen(extra) {
            target = axFrame
        } else {
            try? await Task.sleep(nanoseconds: 400_000_000)
            target = MenuBarScanner.bounds(of: item.windowID) ?? target
        }
        try? await Task.sleep(nanoseconds: 50_000_000)

        let before = context.pid.map { MenuBarScanner.onScreenWindows(ownedBy: $0) } ?? [:]
        NSLog("CoffeeBar: click \(item.ownerName) at \(target)")
        ClickForwarder.click(at: CGPoint(x: target.midX, y: target.midY), rightButton: rightButton)

        guard let pid = context.pid, let targetApp = NSRunningApplication(processIdentifier: pid) else {
            scheduleRehide(after: 1)
            return
        }
        try? await Task.sleep(nanoseconds: 400_000_000)
        let after = MenuBarScanner.onScreenWindows(ownedBy: pid)
        let newWindows = after.filter { before[$0.key] == nil }
        if let index = tempShown.firstIndex(where: { $0.item.windowID == item.windowID }) {
            tempShown[index].interfaceWindow = newWindows.keys.first
        }
        // macOS 14 起 App 只有在收到真实用户输入后才能激活自己，合成点击不算：
        // 没弹出任何菜单 / 弹窗的（只显示窗口的那种 App），替它激活到前台。
        let poppedUp = newWindows.contains { $0.value > 0 }
        if !poppedUp, !targetApp.isActive {
            NSLog("CoffeeBar: no popup from \(item.ownerName), activating it")
            targetApp.activate()
        }
        scheduleRehide(after: 1)
    }

    /// 图标实在挪不动时的兜底：整体展开再点。
    private func expandAllAndClick(_ item: MenuBarItem, extra: AXMenuExtra?, rightButton: Bool) async {
        setInline(.arranging)
        guard let rect = await ClickForwarder.waitUntilOnScreen(item.windowID) else {
            if let extra { _ = AccessibilityIndex.press(extra) }
            return
        }
        var target = rect
        if let extra, let axFrame = await AccessibilityIndex.waitUntilOnScreen(extra) { target = axFrame }
        try? await Task.sleep(nanoseconds: 50_000_000)
        ClickForwarder.click(at: CGPoint(x: target.midX, y: target.midY), rightButton: rightButton)
    }

    // MARK: - 收回临时挪出来的图标

    private func scheduleRehide(after seconds: TimeInterval) {
        rehideTimer?.invalidate()
        rehideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.rehideTempShownIfIdle() }
        }
        if mouseUpMonitor == nil {
            // 用户在别处松开鼠标（比如选了菜单项、点了别处关掉弹窗）时尽快收，不用等定时器。
            mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) { [weak self] _ in
                self?.scheduleRehide(after: 0.4)
            }
        }
    }

    /// 目标 App 的界面还开着、或者鼠标还按着，就过会儿再看；否则把图标挪回去。
    private func rehideTempShownIfIdle() async {
        guard !tempShown.isEmpty else { return }
        let mouseDown = NSEvent.pressedMouseButtons != 0
        let showingInterface = tempShown.contains { context in
            guard let pid = context.pid, let window = context.interfaceWindow else { return false }
            return MenuBarScanner.onScreenWindows(ownedBy: pid)[window] != nil
        }
        if mouseDown || showingInterface || NSEvent.modifierFlags.contains(.command) {
            scheduleRehide(after: 1)
            return
        }
        while let context = tempShown.popLast() {
            let item = context.item
            var moved: CGRect?
            if let left = context.returnLeftOf {
                moved = await ItemMover.move(windowID: item.windowID, ownerPID: item.ownerPID, toLeftOf: left)
            } else if let right = context.returnRightOf {
                moved = await ItemMover.move(windowID: item.windowID, ownerPID: item.ownerPID, toLeftOf: right, rightSide: true)
            }
            if moved == nil { NSLog("CoffeeBar: failed to move \(item.ownerName) back") }
        }
        if let mouseUpMonitor { NSEvent.removeMonitor(mouseUpMonitor); self.mouseUpMonitor = nil }
        rehideTimer?.invalidate(); rehideTimer = nil
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
        case .arranging: symbol = "checkmark"
        case .expanded: symbol = "chevron.right"
        }
        toggleItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        toggleItem.button?.toolTip = inlineState == .arranging ? L("Arranging: ⌘-drag items or “/”, then click here to finish") : nil

        if inlineState == .expanded {
            if outsideClickMonitor == nil {
                outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                    guard let self, self.inlineState == .expanded else { return }
                    if !Self.isInMenuBar(event.locationInWindow) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { if self.inlineState == .expanded { self.setInline(.hidden) } }
                    }
                }
            }
        } else if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    /// AppKit 屏幕坐标（原点左下）。菜单栏高度用 frame 和 visibleFrame 的差算，刘海屏也对。
    private static func isInMenuBar(_ point: NSPoint) -> Bool {
        NSScreen.screens.contains { screen in
            point.x >= screen.frame.minX && point.x <= screen.frame.maxX
                && point.y >= screen.visibleFrame.maxY - 2 && point.y <= screen.frame.maxY
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
        let arrange = NSMenuItem(title: inlineState == .arranging ? L("Finish Arranging") : L("Arrange Items…"), action: nil, keyEquivalent: "")
        arrange.target = self
        arrange.action = inlineState == .arranging ? #selector(finishArranging) : #selector(startArranging)
        menu.addItem(arrange)
        menu.addItem(withTitle: L("While arranging, items left of “/” are hidden. ⌘-drag items or “/” to adjust."), action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        let builtIn = NSMenuItem(title: L("Use panel only on built-in display (expand inline on external displays)"), action: #selector(togglePanelOnlyOnBuiltIn), keyEquivalent: "")
        builtIn.target = self
        builtIn.state = panelOnlyOnBuiltIn ? .on : .off
        menu.addItem(builtIn)
        menu.addItem(.separator())
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        menu.addItem(withTitle: "CoffeeBar \(version)", action: nil, keyEquivalent: "")
        if updater.isConfigured {
            let check = NSMenuItem(title: L("Check for Updates…"), action: #selector(checkForUpdates), keyEquivalent: "")
            check.target = self
            menu.addItem(check)
        }
        menu.addItem(withTitle: L("Quit CoffeeBar"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        toggleItem.menu = menu
        toggleItem.button?.performClick(nil)
        toggleItem.menu = nil
    }

    @objc private func finishArranging() {
        setInline(.hidden)
        recordLayoutSoon()
    }

    /// 整理结束后把当前布局记为用户意图（等位置稳定一下）。
    private func recordLayoutSoon() {
        Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            axExtras = await Task.detached(priority: .userInitiated) { AccessibilityIndex.scan() }.value
            layoutManager.recordCurrent(extras: axExtras)
        }
    }

    @objc private func togglePanelOnlyOnBuiltIn() {
        panelOnlyOnBuiltIn.toggle()
    }
}
