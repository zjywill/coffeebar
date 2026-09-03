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
    /// 展开时分隔符宽度为 0（Ice / Thaw 的分隔符也是 0 宽），不占位、不留空隙。
    private static let shownLength: CGFloat = 0

    /// expanded：外接宽屏上不用面板，直接展开，点菜单栏以外的地方自动收回。
    private enum InlineState { case hidden, arranging, expanded }

    private let toggleItem: NSStatusItem
    private let separatorItem: NSStatusItem
    private let panel = DropPanel()
    private let updater = UpdateController()
    private let layoutManager = LayoutManager()
    private var outsideClickMonitor: Any?

    enum RevealMode: String { case section, item }
    private static let revealModeKey = "CoffeeBar.revealMode"
    /// 从面板打开图标的方式。默认只露出该图标（Thaw / Bartender 的做法）；可选展开整段。
    private var revealMode: RevealMode {
        get { RevealMode(rawValue: UserDefaults.standard.string(forKey: Self.revealModeKey) ?? "") ?? .item }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.revealModeKey) }
    }

    /// 左键点 `<` 时弹面板而不是在菜单栏展开（默认关，Thaw 的默认交互是展开 / 收起）。
    private static let clickOpensPanelKey = "CoffeeBar.clickOpensPanel"
    private var clickOpensPanel: Bool {
        get { UserDefaults.standard.bool(forKey: Self.clickOpensPanelKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.clickOpensPanelKey) }
    }

    /// 刘海屏上菜单栏展不开（刘海下面不画图标，放不下的会被 macOS 藏掉），默认改用面板。
    private static let panelOnNotchKey = "CoffeeBar.panelOnNotch"
    private var panelOnNotch: Bool {
        get { UserDefaults.standard.object(forKey: Self.panelOnNotchKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.panelOnNotchKey) }
    }

    /// 杯子所在的屏幕有没有刘海。
    private var cupScreenHasNotch: Bool {
        guard let screen = toggleItem.button?.window?.screen ?? NSScreen.main else { return false }
        return screen.auxiliaryTopLeftArea != nil
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

    /// 每个 App 学到的激活方式："ax" 或 "click"。
    private static let ledgerKey = "CoffeeBar.activationLedger"
    private var activationLedger: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: Self.ledgerKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.ledgerKey) }
    }
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
            button.image = Self.cupImage(unfolded: false)
            button.target = self
            button.action = #selector(toggleClicked(_:))
            // 按下即响应（和系统菜单一样），不等松开。⌘ 按住时按下不处理，留给 ⌘ 拖动；⌘ 点击在松开时处理。
            button.sendAction(on: [.leftMouseDown, .leftMouseUp, .rightMouseUp])
        }
        if let button = separatorItem.button {
            // 分隔符不可见：它只是把左边的图标挤出屏幕的机制。
            button.image = nil
            button.title = ""
            button.isEnabled = false
            button.appearsDisabled = false
            // 状态栏窗口里有一条横向约束把内容宽度绑成"按钮 + 16 点内边距"。展开时要把它关掉，
            // 窗口才能真正缩到 1 点宽（Thaw 的做法），否则空隙去不掉。
            if let contentView = button.window?.contentView {
                separatorPaddingConstraint = contentView.constraintsAffectingLayout(for: .horizontal)
                    .first { $0.secondItem === button.superview }
            }
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
        let commandHeld = event?.modifierFlags.contains(.command) == true
        // 左键：不带 ⌘ 在按下时处理；带 ⌘ 在松开时处理（按下要留给 ⌘ 拖动杯子本身）。
        if event?.type == .leftMouseDown, commandHeld { return }
        if event?.type == .leftMouseUp, !commandHeld { return }
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
        // 默认（Thaw 的交互）：左键在菜单栏里展开 / 收起隐藏区，用户自己点图标，不做任何自动点击。
        // ⌥ + 左键：进入整理模式（展开且不自动收回）。开了"弹面板"选项则左右对调。
        // 面板 or 展开：全局开关，或者刘海屏自动用面板；⌥ 反转。
        let panelByDefault = clickOpensPanel || (panelOnNotch && cupScreenHasNotch)
        let wantPanel = panelByDefault != (event?.modifierFlags.contains(.option) == true)
        if wantPanel {
            openPanel()
        } else if event?.modifierFlags.contains(.command) == true {
            setInline(.arranging)
        } else {
            setInline(.expanded)
        }
    }

    // MARK: - 下拉面板

    private func openPanel() {
        guard let anchor = toggleItem.button?.window?.frame else { return }

        if !Permissions.hasAccessibility {
            Permissions.requestAccessibility()
            panel.showItems([], notice: (
                L("Accessibility permission is needed to identify and click hidden items. Grant it, then click the cup again."),
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
            // macOS 15 及更早：控制中心为所有未显示的模块保留屏幕外窗口，它们对不上任何 App，
            // 不是真的隐藏图标，别列出来。macOS 26 起所有图标窗口都归控制中心，不能这么过滤。
            if ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 26 {
                items.removeAll { item in
                    AccessibilityIndex.match(item.bounds, in: axExtras) == nil
                        && NSRunningApplication(processIdentifier: item.ownerPID)?.bundleIdentifier == "com.apple.controlcenter"
                }
            }
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
        let leftNeighbor = index > 0 ? items[index - 1] : nil
        Task {
            let shown = await ItemMover.move(windowID: item.windowID, ownerPID: item.ownerPID, toLeftOf: toggleWindowID)
            NSLog("CoffeeBar: temp show \(name) -> \(String(describing: shown))")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            _ = leftNeighbor
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
        if revealMode == .section {
            await revealSectionAndActivate(item, extra: extra, rightButton: rightButton)
            return
        }
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

        await activateOnScreen(item, extra: extra, rightButton: rightButton, rehide: true)
    }

    /// 图标已经在屏幕上了：用辅助功能按它，按 App 学到的方式决定要不要真实点击，
    /// 只显示窗口的 App 替它激活到前台。
    private func activateOnScreen(_ item: MenuBarItem, extra: AXMenuExtra?, rightButton: Bool, rehide: Bool) async {
        let context = TempShown(item: item, returnLeftOf: nil, returnRightOf: nil, pid: extra?.pid, interfaceWindow: nil)
        // 窗口挪好了。辅助功能激活不依赖坐标，立刻按，让图标出现和高亮几乎同时发生；
        // 只有退回鼠标点击时才需要等 App 自己的坐标更新。
        var target = MenuBarScanner.bounds(of: item.windowID) ?? item.bounds
        let before = context.pid.map { MenuBarScanner.onScreenWindows(ownedBy: $0) } ?? [:]
        // 左键优先走辅助功能：完全不碰鼠标。
        // 有的 App（Chrome 的 Gemini）接受 AXPress 却只认真实点击，按 App 学一次并记住：
        //   "ax"    辅助功能就够（菜单类、只显示窗口的 App）
        //   "click" 必须真实点击（光标会闪一下）
        let bundleID = context.pid.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
        let learned = bundleID.flatMap { activationLedger[$0] }
        var pressed = false
        var newWindowSeen = false
        func newWindows() -> Bool {
            guard let pid = context.pid else { return false }
            return MenuBarScanner.onScreenWindows(ownedBy: pid).contains { before[$0.key] == nil }
        }
        if !rightButton, learned != "click", ProcessInfo.processInfo.environment["COFFEEBAR_NO_AXPRESS"] == nil {
            let pid = context.pid
            let startBounds = MenuBarScanner.bounds(of: item.windowID) ?? item.bounds
            func reacted() -> Bool {
                if newWindows() { return true }
                if let now = MenuBarScanner.bounds(of: item.windowID), abs(now.width - startBounds.width) > 1 || !MenuBarScanner.isOnScreen(now) { return true }
                return false
            }
            var live = item
            live.bounds = startBounds
            // 图标刚挪进来，App 自己的坐标要过一会儿才更新；每 30 毫秒试一次，坐标一就绪立即按。
            let t0 = Date()
            if let ms = UInt64(ProcessInfo.processInfo.environment["COFFEEBAR_AX_DELAY_MS"] ?? "") { try? await Task.sleep(nanoseconds: ms * 1_000_000) }
            for attempt in 0..<10 {
                live.bounds = MenuBarScanner.bounds(of: item.windowID) ?? live.bounds
                pressed = AccessibilityIndex.activate(item: live, extra: extra, reacted: reacted)
                if pressed || reacted() { break }
                if attempt < 9 { try? await Task.sleep(nanoseconds: 30_000_000) }
            }
            NSLog("CoffeeBar: AX activation attempt loop took \(Int(Date().timeIntervalSince(t0) * 1000)) ms, accepted=\(pressed)")
            if pressed || reacted() {
                pressed = true
                if learned == "ax" {
                    // 已知辅助功能足够，不用再观察。
                } else {
                    // 还没学过：给它最多 600 毫秒看有没有弹出新窗口。
                    for _ in 0..<30 {
                        if newWindows() { newWindowSeen = true; break }
                        try? await Task.sleep(nanoseconds: 20_000_000)
                    }
                    if !newWindowSeen {
                        // 没弹窗：可能是只认真实点击的 App，也可能是只显示窗口的 App。补一次点击来分辨。
                        pressed = false
                        _ = pid
                    }
                }
            }
        }
        if !pressed {
            // 退回鼠标点击：这时才需要等 App 自己的坐标也回到屏幕上，否则点击会穿到下面的窗口。
            if let extra, let axFrame = await AccessibilityIndex.waitUntilOnScreen(extra) {
                target = axFrame
            } else {
                try? await Task.sleep(nanoseconds: 300_000_000)
                target = MenuBarScanner.bounds(of: item.windowID) ?? target
            }
            NSLog("CoffeeBar: click \(item.ownerName) at \(target)")
            let beforeClick = context.pid.map { MenuBarScanner.onScreenWindows(ownedBy: $0) } ?? [:]
            ClickForwarder.click(at: CGPoint(x: target.midX, y: target.midY), rightButton: rightButton,
                                 windowID: item.windowID, ownerPID: item.ownerPID, targetPID: extra?.pid)
            if !rightButton, let bundleID, learned == nil {
                // 学习：点击弹出了新窗口 => 这个 App 必须真实点击；没弹 => 辅助功能就够。
                try? await Task.sleep(nanoseconds: 500_000_000)
                let clickOpened = context.pid.map { MenuBarScanner.onScreenWindows(ownedBy: $0).contains { beforeClick[$0.key] == nil } } ?? false
                activationLedger[bundleID] = clickOpened ? "click" : "ax"
                NSLog("CoffeeBar: learned \(bundleID) -> \(activationLedger[bundleID]!)")
            }
        } else if let bundleID, learned == nil, newWindowSeen {
            activationLedger[bundleID] = "ax"
            NSLog("CoffeeBar: learned \(bundleID) -> ax")
        }

        guard let pid = context.pid, let targetApp = NSRunningApplication(processIdentifier: pid) else {
            if rehide { scheduleRehide(after: 1) }
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
        if rehide { scheduleRehide(after: 1) }
    }

    /// 展开整段隐藏区再激活（默认）：分隔符是我们自己的状态项，缩回去不需要任何合成鼠标事件，
    /// 所以没有拖拽幽灵、没有插入闪、光标不动。代价是菜单打开期间所有隐藏图标都会露出来。
    private func revealSectionAndActivate(_ item: MenuBarItem, extra: AXMenuExtra?, rightButton: Bool) async {
        setInline(.expanded)
        guard await ClickForwarder.waitUntilOnScreen(item.windowID) != nil else {
            // 展开了也挤不进屏幕（屏幕太窄）：退回只露出该图标的方式。
            setInline(.hidden)
            if let toggleWindowID, await ItemMover.move(windowID: item.windowID, ownerPID: item.ownerPID, toLeftOf: toggleWindowID) != nil {
                tempShown.append(TempShown(item: item, returnLeftOf: nil, returnRightOf: nil, pid: extra?.pid, interfaceWindow: nil))
                await activateOnScreen(item, extra: extra, rightButton: rightButton, rehide: true)
            }
            return
        }
        let before = extra.map { MenuBarScanner.onScreenWindows(ownedBy: $0.pid) } ?? [:]
        await activateOnScreen(item, extra: extra, rightButton: rightButton, rehide: false)
        // 收回：目标 App 点击后弹出的窗口还开着、或鼠标按着，就等；否则撑回分隔符。
        // 点击菜单栏以外的地方也会收（applyInlineState 里的监听），这里兜底处理 Esc 关菜单等情况。
        guard let extra else { return }
        try? await Task.sleep(nanoseconds: 400_000_000)
        let opened = MenuBarScanner.onScreenWindows(ownedBy: extra.pid).filter { before[$0.key] == nil }
        for _ in 0..<600 {
            guard inlineState == .expanded else { return }
            let stillOpen = opened.keys.contains { MenuBarScanner.onScreenWindows(ownedBy: extra.pid)[$0] != nil }
            if !stillOpen && NSEvent.pressedMouseButtons == 0 && !NSEvent.modifierFlags.contains(.command) { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if inlineState == .expanded { setInline(.hidden) }
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

    /// 菜单栏图标：手绘的 SVG 杯子（矢量，任何缩放都清晰），折叠 = 实心，展开 = 描边加热气。
    /// 裸跑没有资源时退回 SF Symbols。
    private static func cupImage(unfolded: Bool) -> NSImage? {
        let name = unfolded ? "cup-unfolded" : "cup-folded"
        if let url = Bundle.main.url(forResource: name, withExtension: "svg", subdirectory: "MenuBarIcons"),
           let image = NSImage(contentsOf: url) {
            image.isTemplate = true
            image.size = NSSize(width: 22, height: 18)
            return image
        }
        return NSImage(systemSymbolName: unfolded ? "cup.and.saucer" : "cup.and.saucer.fill", accessibilityDescription: nil)
    }

    private var separatorPaddingConstraint: NSLayoutConstraint?

    private func applyInlineState() {
        // 展开时把分隔符整个从菜单栏拿掉（状态项再窄 macOS 也留 16 点内边距，会留出空隙）。
        // 收起时先把保存的位置写回、以 0 宽放回原槽位、等它落位，再撑大。
        // 展开：分隔符宽度 0，并绕过 macOS 的 16 点内边距，把它的窗口缩到 1 点宽（Thaw 的做法）。
        // 收起：恢复约束和宽度。两个方向都只改宽度，一帧完成，没有增删动画。
        if inlineState == .hidden {
            separatorPaddingConstraint?.isActive = true
            separatorItem.length = Self.hiddenLength
        } else {
            separatorPaddingConstraint?.isActive = false
            separatorItem.length = 0
            if let window = separatorItem.button?.window {
                var size = window.frame.size
                size.width = 1
                window.setContentSize(size)
            }
        }
        toggleItem.button?.image = inlineState == .arranging
            ? NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
            : Self.cupImage(unfolded: inlineState != .hidden)
        toggleItem.button?.toolTip = inlineState == .arranging ? L("Arranging: ⌘-drag items left of the cup to hide them, then click the cup to finish") : nil

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
        menu.addItem(withTitle: L("Click the cup to expand or collapse. ⌘-drag an item left of the cup to hide it, right of it to keep it visible."), action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        let panelItem = NSMenuItem(title: L("Clicking the cup opens the panel instead of expanding the menu bar"), action: #selector(toggleClickOpensPanel), keyEquivalent: "")
        panelItem.target = self
        panelItem.state = clickOpensPanel ? .on : .off
        menu.addItem(panelItem)
        let onlyItem = NSMenuItem(title: L("Panel: expand the whole hidden section when opening an item"), action: #selector(toggleRevealMode), keyEquivalent: "")
        onlyItem.target = self
        onlyItem.state = revealMode == .section ? .on : .off
        menu.addItem(onlyItem)
        let notch = NSMenuItem(title: L("On a display with a notch, open the panel instead"), action: #selector(togglePanelOnNotch), keyEquivalent: "")
        notch.target = self
        notch.state = panelOnNotch ? .on : .off
        menu.addItem(notch)
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

    @objc private func toggleClickOpensPanel() {
        clickOpensPanel.toggle()
    }

    @objc private func toggleRevealMode() {
        revealMode = revealMode == .item ? .section : .item
    }

    @objc private func togglePanelOnNotch() {
        panelOnNotch.toggle()
    }
}
