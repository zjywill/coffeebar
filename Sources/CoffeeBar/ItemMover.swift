import AppKit

/// 用合成的 ⌘ 拖拽把单个菜单栏图标挪到别的位置（Ice 的做法）。
///
/// 关键在于事件里写入目标窗口 ID 的几个字段：窗口服务器据此把事件路由到图标窗口，
/// 而不看鼠标实际在哪。这样可以把一个在屏幕外的图标"拖"到可见区，而不必展开其它图标。
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

        let start = CGPoint(x: 20_000, y: 20_000)
        let end = CGPoint(x: (rightSide ? targetFrame.maxX : targetFrame.minX) + xOffset, y: targetFrame.midY)
        guard let down = event(.leftMouseDown, at: start, windowID: windowID, pid: ownerPID, flags: .maskCommand, source: source),
              let up = event(.leftMouseUp, at: end, windowID: targetWindowID, pid: ownerPID, flags: [], source: source)
        else { return nil }

        // 合成事件期间不要让系统压制本地鼠标事件。
        for state in [CGEventSuppressionState.eventSuppressionStateRemoteMouseDrag, .eventSuppressionStateSuppressionInterval] {
            source.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents], state: state)
        }
        source.localEventsSuppressionInterval = 0

        // 拖拽会把光标扯走，先藏起来，完事再放回原处。
        let cursor = CGEvent(source: nil)?.location ?? .zero
        CGDisplayHideCursor(CGMainDisplayID())
        defer {
            CGWarpMouseCursorPosition(cursor)
            CGDisplayShowCursor(CGMainDisplayID())
        }

        down.post(tap: .cgSessionEventTap)
        let afterDown = await waitForFrameChange(of: windowID, from: itemFrame, timeout: 0.3)
        up.post(tap: .cgSessionEventTap)
        let afterUp = await waitForFrameChange(of: windowID, from: afterDown ?? itemFrame, timeout: 0.5)
        NSLog("CoffeeBar: move \(windowID): \(itemFrame) -> down \(String(describing: afterDown)) -> up \(String(describing: afterUp))")
        return afterUp ?? afterDown
    }
}
