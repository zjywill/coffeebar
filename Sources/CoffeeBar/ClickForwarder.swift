import AppKit
import ApplicationServices

/// 把面板上的点击转发给真实的菜单栏图标。
/// 需要辅助功能权限，否则系统会丢弃合成的鼠标事件。
enum ClickForwarder {
    /// 等待某个窗口出现在屏幕上（分隔符缩回去后，图标需要一两帧才会移回来）。
    static func waitUntilOnScreen(_ windowID: CGWindowID, timeout: TimeInterval = 0.6) async -> CGRect? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let rect = MenuBarScanner.bounds(of: windowID), MenuBarScanner.isOnScreen(rect) {
                return rect
            }
            try? await Task.sleep(nanoseconds: 16_000_000)
        }
        return nil
    }

    /// 在屏幕坐标（CG 坐标系）合成一次点击。
    static func click(at point: CGPoint, rightButton: Bool) {
        let source = CGEventSource(stateID: .hidSystemState)
        let button: CGMouseButton = rightButton ? .right : .left
        let downType: CGEventType = rightButton ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = rightButton ? .rightMouseUp : .leftMouseUp
        // 先把光标挪过去，有些图标只在光标悬停时才响应。
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: button)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: source, mouseType: downType, mouseCursorPosition: point, mouseButton: button)?.post(tap: .cghidEventTap)
        usleep(40_000)
        CGEvent(mouseEventSource: source, mouseType: upType, mouseCursorPosition: point, mouseButton: button)?.post(tap: .cghidEventTap)
    }
}
