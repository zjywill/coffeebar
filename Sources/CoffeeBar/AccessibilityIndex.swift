import AppKit
import ApplicationServices

/// 通过辅助功能 API 找到的一个菜单栏图标。
/// macOS 26 起，所有图标窗口都归 Control Center 进程，窗口信息里看不出图标属于哪个 App，
/// 只能拿每个 App 的 AXExtrasMenuBar 按 x 坐标和窗口对上。
struct AXMenuExtra {
    let element: AXUIElement
    let appName: String
    let pid: pid_t
    let frame: CGRect
    /// App 图标，面板里用它代替图标截图（截图要屏幕录制权限，而且屏幕外的窗口截不到）。
    let icon: NSImage?
}

enum AccessibilityIndex {
    /// 遍历所有可能有菜单栏图标的 App。没有辅助功能权限时返回空。
    static func scan() -> [AXMenuExtra] {
        guard AXIsProcessTrusted() else { return [] }
        // .prohibited 的是纯后台进程，不可能有菜单栏图标。
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy != .prohibited }
        // 每个 App 都要跨进程问一次，串行要一秒多；并发做，慢的 App 只拖累自己。
        var perApp = [[AXMenuExtra]](repeating: [], count: apps.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: apps.count) { index in
            let found = extras(of: apps[index])
            lock.lock(); perApp[index] = found; lock.unlock()
        }
        return perApp.flatMap { $0 }
    }

    private static func extras(of app: NSRunningApplication) -> [AXMenuExtra] {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        // 别让一个卡死的 App 拖住整个扫描。
        AXUIElementSetMessagingTimeout(axApp, 0.25)
        var extras: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, "AXExtrasMenuBar" as CFString, &extras) == .success,
              let bar = extras
        else { return [] }
        var children: AnyObject?
        guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children) == .success,
              let elements = children as? [AXUIElement]
        else { return [] }
        let name = app.localizedName ?? "pid \(app.processIdentifier)"
        return elements.compactMap { element in
            guard let frame = frame(of: element) else { return nil }
            return AXMenuExtra(element: element, appName: name, pid: app.processIdentifier, frame: frame, icon: app.icon)
        }
    }

    /// 找和某个窗口位置最接近的图标。
    static func match(_ bounds: CGRect, in extras: [AXMenuExtra], tolerance: CGFloat = 8) -> AXMenuExtra? {
        extras
            .map { ($0, abs($0.frame.minX - bounds.minX)) }
            .filter { $0.1 <= tolerance }
            .min { $0.1 < $1.1 }?.0
    }

    /// 某个 App 的 AXExtrasMenuBar 下的子元素（它的菜单栏图标们）。
    private static func extrasChildren(pid: pid_t) -> [AXUIElement] {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.25)
        var extras: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, "AXExtrasMenuBar" as CFString, &extras) == .success, let bar = extras else { return [] }
        var children: AnyObject?
        guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children) == .success,
              let elements = children as? [AXUIElement]
        else { return [] }
        return elements
    }

    /// 是不是 Electron 应用（照 Thaw 的 isElectronItem：看包里有没有 Electron Framework）。
    /// 这类 App 的托盘图标不认合成点击，只能走辅助功能 AXPress。
    static func isElectron(pid: pid_t) -> Bool {
        guard let url = NSRunningApplication(processIdentifier: pid)?.bundleURL else { return false }
        let framework = url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        return FileManager.default.fileExists(atPath: framework.path)
    }

    /// 照 Thaw 的 pressItemViaAccessibility：在 App 自己的 AXExtrasMenuBar 里找到和窗口位置对得上的那个子元素 AXPress。
    /// 只有一个子元素时不用比对；多个时取中心距离最近且不超过 10 点的。找不到或按不动返回 false，让调用方退回合成点击。
    static func pressViaExtrasMenuBar(pid: pid_t, itemBounds: CGRect) -> Bool {
        let children = extrasChildren(pid: pid)
        guard !children.isEmpty else { return false }
        let target: AXUIElement
        if children.count == 1 {
            target = children[0]
        } else {
            let center = CGPoint(x: itemBounds.midX, y: itemBounds.midY)
            func distance(_ element: AXUIElement) -> CGFloat {
                guard let frame = frame(of: element) else { return .greatestFiniteMagnitude }
                return hypot(frame.midX - center.x, frame.midY - center.y)
            }
            guard let best = children.min(by: { distance($0) < distance($1) }), distance(best) <= 10 else { return false }
            target = best
        }
        AXUIElementSetMessagingTimeout(target, 0.25)
        let result = AXUIElementPerformAction(target, kAXPressAction as CFString)
        if result != .success { NSLog("CoffeeBar: AXPress via extras menu bar (pid \(pid)) failed: \(result.rawValue)") }
        return result == .success
    }

    /// 通过辅助功能激活一个已经在屏幕上的图标，完全不碰鼠标（Thaw 的 AXItemActivator）。
    /// 1. 先用系统级坐标命中测试拿元素；拿不到就到 App 自己的 AXExtrasMenuBar 里找包含该点的子元素，
    ///    再不行用索引里的元素。最后校验它的 AX 坐标和窗口位置吻合。
    /// 2. 先 AXShowMenu 再 AXPress。动作超时不等于失败：菜单一打开 App 就进入模态跟踪循环，
    ///    答不了辅助功能消息，恰恰是成功的那次会超时。所以每步之后看图标有没有反应，有就停，
    ///    否则再按一次会把刚打开的菜单关掉。
    static func activate(item: MenuBarItem, extra: AXMenuExtra?, reacted: () -> Bool, trustExtra: Bool = false) -> Bool {
        let center = CGPoint(x: item.bounds.midX, y: item.bounds.midY)
        var element: AXUIElement?
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.25)
        var hit: AXUIElement?
        if AXUIElementCopyElementAtPosition(systemWide, Float(center.x), Float(center.y), &hit) == .success, let hit {
            element = hit
        } else if let extra {
            element = extrasChildren(pid: extra.pid).first { frame(of: $0)?.contains(center) == true } ?? extra.element
        }
        guard let element else { return false }
        AXUIElementSetMessagingTimeout(element, 0.25)
        guard let frame = frame(of: element), frame.insetBy(dx: -10, dy: -10).intersects(item.bounds) else {
            return false
        }
        _ = trustExtra
        for action in [kAXShowMenuAction, kAXPressAction] {
            let result = AXUIElementPerformAction(element, action as CFString)
            if result == .success { NSLog("CoffeeBar: \(action) accepted by \(item.ownerName)"); return true }
            if reacted() { NSLog("CoffeeBar: \(action) timed out but \(item.ownerName) reacted"); return true }
            NSLog("CoffeeBar: \(action) on \(item.ownerName) failed: \(result.rawValue)")
        }
        return false
    }

    static func press(_ extra: AXMenuExtra) -> Bool {
        // 有些 App 按下后要等菜单关闭才返回，别让它卡住我们：超时就当失败，走鼠标点击兜底。
        AXUIElementSetMessagingTimeout(extra.element, 0.3)
        let result = AXUIElementPerformAction(extra.element, kAXPressAction as CFString)
        if result != .success { NSLog("CoffeeBar: AXPress \(extra.appName) failed: \(result.rawValue)") }
        return result == .success
    }

    /// 等目标 App 自己的辅助功能坐标也回到屏幕上。
    /// 窗口服务器移动图标窗口之后，App 内部的坐标要过一会儿才更新，而点击命中靠的是后者。
    static func waitUntilOnScreen(_ extra: AXMenuExtra, timeout: TimeInterval = 2.5) async -> CGRect? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let frame = frame(of: extra.element), MenuBarScanner.isOnScreen(frame) {
                return frame
            }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        return nil
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        var posValue: AnyObject?
        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success
        else { return nil }
        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posValue as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }
}
