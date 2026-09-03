import AppKit

/// 核心原理（和 Bartender / Ice / Hidden Bar 一样）：
/// 菜单栏图标从右往左排。我们放一个"分隔符" NSStatusItem，
/// 把它的宽度拉到极大，分隔符左侧的所有图标就被挤出屏幕，等于"隐藏"。
/// 把宽度缩回去，图标就"显示"。
///
/// 用户用 Cmd + 拖动 把分隔符拖到想要的位置：分隔符左边的全部会被藏起来。
final class MenuBarController: NSObject {
    /// 隐藏时分隔符的宽度。够大就行，屏幕不会比它宽。
    private static let hiddenLength: CGFloat = 10_000
    /// 显示时分隔符的宽度。
    private static let shownLength: CGFloat = 12

    /// 右侧的开关按钮，用户点它切换隐藏 / 显示。
    private let toggleItem: NSStatusItem
    /// 左侧的分隔符，靠它的宽度实现挤压。
    private let separatorItem: NSStatusItem

    private var isHidden = true
    private var clickMonitor: Any?
    private var rehideTimer: Timer?

    override init() {
        let bar = NSStatusBar.system
        // 先创建的在右，后创建的在左。所以先建开关，再建分隔符。
        toggleItem = bar.statusItem(withLength: NSStatusItem.variableLength)
        separatorItem = bar.statusItem(withLength: Self.hiddenLength)
        super.init()

        // autosaveName 让 macOS 记住用户 Cmd 拖动后的位置。
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
            // 分隔符本身不响应点击，避免误触。
            button.isEnabled = false
            button.appearsDisabled = false
        }

        applyState()
    }

    @objc private func toggleClicked(_ sender: Any?) {
        // 右键弹出退出菜单，左键切换。
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            showContextMenu()
            return
        }
        isHidden.toggle()
        applyState()
    }

    private func applyState() {
        separatorItem.length = isHidden ? Self.hiddenLength : Self.shownLength
        toggleItem.button?.image = NSImage(
            systemSymbolName: isHidden ? "chevron.left" : "chevron.right",
            accessibilityDescription: nil
        )
        if isHidden {
            stopWatchingForOutsideClick()
        } else {
            startWatchingForOutsideClick()
        }
    }

    /// 显示状态下，点击菜单栏以外的任何地方、或者 8 秒无操作，就自动收回。
    /// NSEvent 的全局鼠标监听不需要辅助功能权限（键盘才需要）。
    private func startWatchingForOutsideClick() {
        stopWatchingForOutsideClick()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return }
            let menuBarHeight = NSStatusBar.system.thickness
            let screenTop = NSScreen.screens.map { $0.frame.maxY }.max() ?? 0
            let inMenuBar = event.locationInWindow.y >= screenTop - menuBarHeight
            if !inMenuBar {
                self.hide()
            }
        }
        rehideTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
            self?.hide()
        }
    }

    private func stopWatchingForOutsideClick() {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
        rehideTimer?.invalidate()
        rehideTimer = nil
    }

    private func hide() {
        guard !isHidden else { return }
        isHidden = true
        applyState()
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "提示：按住 ⌘ 拖动 “/” 分隔符，它左边的图标会被隐藏", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 CoffeeBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        toggleItem.menu = menu
        toggleItem.button?.performClick(nil)
        toggleItem.menu = nil
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = MenuBarController()
    }
}

let app = NSApplication.shared
// 不显示 Dock 图标，只住在菜单栏。
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
