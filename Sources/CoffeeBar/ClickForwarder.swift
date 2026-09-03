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
    /// 给了 pid 就直接投递给那个进程（绕过窗口服务器的命中测试和坐标映射），否则走 HID 事件流。
    static func click(at point: CGPoint, rightButton: Bool, pid: pid_t? = nil) {
        let source = CGEventSource(stateID: .hidSystemState)
        let button: CGMouseButton = rightButton ? .right : .left
        let downType: CGEventType = rightButton ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = rightButton ? .rightMouseUp : .leftMouseUp
        // 先发一个 mouseMoved 把光标挪过去：只 warp 光标不发事件的话，菜单栏收不到悬停，
        // 随后的 mouseDown 会被当成落在别处而丢掉。
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: button)?.post(tap: .cghidEventTap)
        usleep(60_000)
        let down = CGEvent(mouseEventSource: source, mouseType: downType, mouseCursorPosition: point, mouseButton: button)
        let up = CGEvent(mouseEventSource: source, mouseType: upType, mouseCursorPosition: point, mouseButton: button)
        if let pid {
            down?.postToPid(pid)
            usleep(40_000)
            up?.postToPid(pid)
        } else {
            down?.post(tap: .cghidEventTap)
            usleep(40_000)
            up?.post(tap: .cghidEventTap)
        }
    }
}
