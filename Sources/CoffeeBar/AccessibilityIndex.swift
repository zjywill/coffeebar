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

    /// 通过辅助功能激活一个已经在屏幕上的图标，完全不碰鼠标（Thaw 的做法）。
    /// 1. 先用系统级坐标命中测试拿元素，拿不到再用索引里的元素；校验它的 AX 坐标和窗口位置吻合。
    /// 2. 先 AXShowMenu 再 AXPress。动作超时不等于失败：菜单一打开 App 就进入模态跟踪循环，
    ///    答不了辅助功能消息，恰恰是成功的那次会超时。所以每步之后看图标有没有反应，有就停，
    ///    否则再按一次会把刚打开的菜单关掉。
    static func activate(item: MenuBarItem, extra: AXMenuExtra?, reacted: () -> Bool) -> Bool {
        let center = CGPoint(x: item.bounds.midX, y: item.bounds.midY)
        var element: AXUIElement?
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.25)
        var hit: AXUIElement?
        if AXUIElementCopyElementAtPosition(systemWide, Float(center.x), Float(center.y), &hit) == .success, let hit {
            element = hit
        } else {
            element = extra?.element
        }
        guard let element else { return false }
        AXUIElementSetMessagingTimeout(element, 0.25)
        guard let frame = frame(of: element), frame.insetBy(dx: -10, dy: -10).intersects(item.bounds) else {
            NSLog("CoffeeBar: AX element frame mismatch for \(item.ownerName)")
            return false
        }
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
