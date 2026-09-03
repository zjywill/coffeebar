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
        var result: [AXMenuExtra] = []
        // .prohibited 的是纯后台进程，不可能有菜单栏图标。
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy != .prohibited {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            // 别让一个卡死的 App 拖住整个扫描。
            AXUIElementSetMessagingTimeout(axApp, 0.25)
            var extras: AnyObject?
            guard AXUIElementCopyAttributeValue(axApp, "AXExtrasMenuBar" as CFString, &extras) == .success,
                  let bar = extras
            else { continue }
            var children: AnyObject?
            guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children) == .success,
                  let elements = children as? [AXUIElement]
            else { continue }
            let name = app.localizedName ?? "pid \(app.processIdentifier)"
            for element in elements {
                guard let frame = frame(of: element) else { continue }
                result.append(AXMenuExtra(element: element, appName: name, pid: app.processIdentifier, frame: frame, icon: app.icon))
            }
        }
        return result
    }

    /// 找和某个窗口位置最接近的图标。
    static func match(_ bounds: CGRect, in extras: [AXMenuExtra], tolerance: CGFloat = 8) -> AXMenuExtra? {
        extras
            .map { ($0, abs($0.frame.minX - bounds.minX)) }
            .filter { $0.1 <= tolerance }
            .min { $0.1 < $1.1 }?.0
    }

    static func press(_ extra: AXMenuExtra) -> Bool {
        AXUIElementPerformAction(extra.element, kAXPressAction as CFString) == .success
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
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
