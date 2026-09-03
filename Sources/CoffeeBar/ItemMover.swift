import AppKit

/// 用合成的 ⌘ 拖拽把单个菜单栏图标挪到别的位置（Ice / Thaw 的做法）。
///
/// 事件里写入目标窗口 ID 的几个字段：窗口服务器据此把事件路由到图标窗口，而不看鼠标实际在哪。
///
/// 光标处理（实测 macOS 26）：
/// - 鼠标事件带的坐标会把光标带过去，投递给进程、脱钩鼠标都拦不住。
/// - 按下事件的坐标放在当前光标处即可，光标不动；落点由抬起事件决定。
/// - 目标在屏幕内时，抬起事件的坐标也放在当前光标处，靠窗口字段定位，光标全程不动。
///   落在目标的哪一侧由光标 x 和目标中心比较决定。
/// - 目标在屏幕外（隐藏区）时，抬起事件必须带屏幕外坐标，光标会被夹到屏幕边缘；
///   只在抬起前后几十毫秒藏起光标并挪回，肉眼基本看不到。
enum ItemMover {
    private static let windowIDField = CGEventField(rawValue: 0x33)!

    private static func event(_ type: CGEventType, at point: CGPoint, windowID: CGWindowID, pid: pid_t,
                              flags: CGEventFlags, source: CGEventSource) -> CGEvent? {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return nil }
        event.flags = flags
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(pid))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowID))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowID))
        event.setIntegerValueField(windowIDField, value: Int64(windowID))
        return event
    }

    private static func waitForFrameChange(of windowID: CGWindowID, from old: CGRect, timeout: TimeInterval) async -> CGRect? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let now = MenuBarScanner.bounds(of: windowID), now != old { return now }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }

    /// 把 `windowID` 挪到 `targetWindowID` 的左边（或右边）。返回挪动后的位置，失败返回 nil。
    @MainActor
    static func move(windowID: CGWindowID, ownerPID: pid_t, toLeftOf targetWindowID: CGWindowID, rightSide: Bool = false, xOffset: CGFloat = 0) async -> CGRect? {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let itemFrame = MenuBarScanner.bounds(of: windowID),
              let targetFrame = MenuBarScanner.bounds(of: targetWindowID)
        else {
            NSLog("CoffeeBar: move precondition failed: item \(windowID) bounds=\(String(describing: MenuBarScanner.bounds(of: windowID))) target \(targetWindowID) bounds=\(String(describing: MenuBarScanner.bounds(of: targetWindowID)))")
            return nil
        }

        let cursor = CGEvent(source: nil)?.location ?? .zero
        // 屏幕内的目标：落点放到目标左（右）缘再往外半个图标宽，明确落在那一侧
        //（落点正好等于目标左缘时窗口服务器会把它排到右边）。
        // 屏幕外的目标（隐藏区）：落点就用目标左缘，实测能精确回到原来的位置。
        let targetOnScreen = MenuBarScanner.isOnScreen(targetFrame)
        let sideOffset = targetOnScreen ? (itemFrame.width / 2 + 4) * (rightSide ? 1 : -1) : 0
        let dropPoint = CGPoint(x: (rightSide ? targetFrame.maxX : targetFrame.minX) + sideOffset + xOffset, y: targetFrame.midY)
        // 目标在屏幕内且光标已在目标的正确一侧：抬起也放在光标处，光标全程不动。
        let cursorOnWantedSide = rightSide ? cursor.x > targetFrame.midX : cursor.x < targetFrame.midX
        let stayPut = targetOnScreen && cursorOnWantedSide

        guard let down = event(.leftMouseDown, at: cursor, windowID: windowID, pid: ownerPID, flags: .maskCommand, source: source),
              let up = event(.leftMouseUp, at: stayPut ? cursor : dropPoint, windowID: targetWindowID, pid: ownerPID, flags: [], source: source)
        else { return nil }

        // 合成事件期间不要让系统压制本地鼠标事件。
        for state in [CGEventSuppressionState.eventSuppressionStateRemoteMouseDrag, .eventSuppressionStateSuppressionInterval] {
            source.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents], state: state)
        }
        source.localEventsSuppressionInterval = 0

        down.post(tap: .cgSessionEventTap)
        let afterDown = await waitForFrameChange(of: windowID, from: itemFrame, timeout: 0.3)

        if !stayPut { CGDisplayHideCursor(CGMainDisplayID()) }
        up.post(tap: .cgSessionEventTap)
        let afterUp = await waitForFrameChange(of: windowID, from: afterDown ?? itemFrame, timeout: 0.5)
        if !stayPut {
            CGWarpMouseCursorPosition(cursor)
            CGAssociateMouseAndMouseCursorPosition(1) // 解除 warp 之后系统对物理鼠标移动的短暂压制，否则会有"鼠标卡一下"的感觉
            CGDisplayShowCursor(CGMainDisplayID())
        }
        NSLog("CoffeeBar: move \(windowID) \(stayPut ? "(cursor untouched)" : "(cursor hidden at drop)"): \(itemFrame) -> \(String(describing: afterUp ?? afterDown))")
        return afterUp ?? afterDown
    }
}
