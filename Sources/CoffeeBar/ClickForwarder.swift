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

    /// 在屏幕坐标（CG 坐标系）合成一次点击。做法照 Thaw 的 postClickEvents：
    /// 藏光标、warp 到点击点、等 10 毫秒、按下、抬起两次（防止图标卡在按下态）、挪回原位、显示。
    static func click(at point: CGPoint, rightButton: Bool, windowID: CGWindowID? = nil, ownerPID: pid_t? = nil, targetPID: pid_t? = nil) {
        let source = CGEventSource(stateID: .hidSystemState)
        for state in [CGEventSuppressionState.eventSuppressionStateRemoteMouseDrag, .eventSuppressionStateSuppressionInterval] {
            source?.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents], state: state)
        }
        source?.localEventsSuppressionInterval = 0
        let button: CGMouseButton = rightButton ? .right : .left
        let downType: CGEventType = rightButton ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = rightButton ? .rightMouseUp : .leftMouseUp
        func make(_ type: CGEventType) -> CGEvent? {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return nil }
            if let windowID {
                event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowID))
                event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowID))
                event.setIntegerValueField(CGEventField(rawValue: 0x33)!, value: Int64(windowID))
            }
            if let ownerPID { event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(ownerPID)) }
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            return event
        }
        let cursor = CGEvent(source: nil)?.location ?? point
        NSLog("CoffeeBar: click at \(point), cursor was \(cursor)")
        // 先藏再 warp，避免光标在点击点露出一帧；等 10 毫秒让窗口服务器处理完 warp 再发事件。
        CGDisplayHideCursor(CGMainDisplayID())
        CGWarpMouseCursorPosition(point)
        usleep(10_000)
        make(downType)?.post(tap: .cgSessionEventTap)
        usleep(30_000)
        make(upType)?.post(tap: .cgSessionEventTap)
        usleep(10_000)
        make(upType)?.post(tap: .cgSessionEventTap)
        usleep(20_000)
        CGWarpMouseCursorPosition(cursor)
        CGAssociateMouseAndMouseCursorPosition(1)
        CGDisplayShowCursor(CGMainDisplayID())
    }
}
