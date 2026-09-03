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

    /// 在屏幕坐标（CG 坐标系）合成一次点击，点完立刻把光标挪回原处。
    ///
    /// 鼠标事件会把光标带到图标上，所以点完马上 warp 回去，用户只看到一闪。
    /// 注意不能用 CGDisplayHideCursor 把光标藏起来：一藏，刚弹出的状态项菜单就会被关掉。
    static func click(at point: CGPoint, rightButton: Bool, windowID: CGWindowID? = nil, ownerPID: pid_t? = nil, targetPID: pid_t? = nil) {
        let source = CGEventSource(stateID: .hidSystemState)
        // 合成事件之后系统默认会压制物理鼠标约 250 毫秒，这里设成 0。
        for state in [CGEventSuppressionState.eventSuppressionStateRemoteMouseDrag, .eventSuppressionStateSuppressionInterval] {
            source?.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents], state: state)
        }
        source?.localEventsSuppressionInterval = 0
        let button: CGMouseButton = rightButton ? .right : .left
        let downType: CGEventType = rightButton ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = rightButton ? .rightMouseUp : .leftMouseUp
        let mode = ProcessInfo.processInfo.environment["COFFEEBAR_CLICK_MODE"] ?? "hid"

        // 事件里写目标窗口 / 进程字段会让菜单栏不再响应（0.2.0 的裸事件是通的），默认不写。
        let withFields = ProcessInfo.processInfo.environment["COFFEEBAR_CLICK_FIELDS"] != nil
        let sentinelWindow = ProcessInfo.processInfo.environment["COFFEEBAR_SENTINEL"] != nil
        func make(_ type: CGEventType) -> CGEvent? {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return nil }
            if sentinelWindow {
                // macOS 26：App 自己看到的状态项窗口号是 2^32 这个哨兵值。
                let w: Int64 = 4_294_967_296
                event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: w)
                event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: w)
                event.setIntegerValueField(CGEventField(rawValue: 0x33)!, value: w)
                event.setIntegerValueField(.mouseEventClickState, value: 1)
                return event
            }
            guard withFields else { return event }
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
        NSLog("CoffeeBar: click mode=\(mode) cursor was \(cursor)")

        if mode == "pid" {
            let which = ProcessInfo.processInfo.environment["COFFEEBAR_PID_TARGET"] ?? "app"
            let pids: [pid_t] = which == "owner" ? [ownerPID].compactMap { $0 } : which == "both" ? [targetPID, ownerPID].compactMap { $0 } : [targetPID].compactMap { $0 }
            NSLog("CoffeeBar: postToPid \(pids) fields=\(withFields)")
            for pid in pids { make(downType)?.postToPid(pid) }
            usleep(40_000)
            for pid in pids { make(upType)?.postToPid(pid) }
            return
        }

        let restore = ProcessInfo.processInfo.environment["COFFEEBAR_NO_RESTORE"] == nil
        let restoreMode = ProcessInfo.processInfo.environment["COFFEEBAR_RESTORE_MODE"] ?? "warp"
        let useHide = restore && restoreMode != "warp" && restoreMode != "delayed"
        let useWarp = restore && restoreMode != "hide"
        if useHide { CGDisplayHideCursor(CGMainDisplayID()) }
        if mode == "session" {
            make(.mouseMoved)?.post(tap: .cgSessionEventTap)
            usleep(60_000)
            make(downType)?.post(tap: .cgSessionEventTap)
            usleep(40_000)
            make(upType)?.post(tap: .cgSessionEventTap)
        } else {
            make(.mouseMoved)?.post(tap: .cghidEventTap)
            usleep(60_000)
            make(downType)?.post(tap: .cghidEventTap)
            usleep(40_000)
            make(upType)?.post(tap: .cghidEventTap)
        }
        guard restore else { return }
        usleep(restoreMode == "delayed" ? 400_000 : 30_000)
        if useWarp {
            CGWarpMouseCursorPosition(cursor)
            CGAssociateMouseAndMouseCursorPosition(1) // 解除 warp 之后系统对物理鼠标移动的短暂压制
        }
        if useHide { CGDisplayShowCursor(CGMainDisplayID()) }
    }
}
