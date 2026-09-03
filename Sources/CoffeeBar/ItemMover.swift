import AppKit

/// 用合成的 ⌘ 拖拽把单个菜单栏图标挪到别的位置。做法照 Thaw 的 postMoveEvents：
///
/// - 按下和抬起用同一个点：目标落点。事件里写入窗口 ID 字段，窗口服务器据此把按下路由到要挪的图标，
///   把抬起路由到目标图标，不看鼠标实际在哪。拖拽中的图标就停在落点上，不会在别处冒出幽灵。
/// - 落点在屏幕内时先把光标 warp 过去、藏起来、等 20 毫秒再发事件；落点在屏幕外（隐藏区）时只藏光标。
///   完成后把光标挪回原位再显示。
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

    /// 1 毫秒轮询等窗口位置变化。
    private static func waitForFrameChange(of windowID: CGWindowID, from old: CGRect, timeout: TimeInterval) async -> CGRect? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let now = MenuBarScanner.bounds(of: windowID), now != old { return now }
            try? await Task.sleep(nanoseconds: 1_000_000)
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
            NSLog("CoffeeBar: move precondition failed: item \(windowID) target \(targetWindowID)")
            return nil
        }

        // 落点：屏幕内的目标往指定一侧偏半个图标宽（正好落在边缘时窗口服务器会排到右边）；
        // 屏幕外的目标用边缘本身，能精确回到原来的槽位。y 用目标的中线（Thaw 对屏幕外目标也这样，避免落进热角）。
        let targetOnScreen = MenuBarScanner.isOnScreen(targetFrame)
        let sideOffset = targetOnScreen ? (itemFrame.width / 2 + 4) * (rightSide ? 1 : -1) : 0
        let point = CGPoint(x: (rightSide ? targetFrame.maxX : targetFrame.minX) + sideOffset + xOffset, y: targetFrame.midY)
        let pointOnScreen = MenuBarScanner.isOnScreen(CGRect(origin: point, size: CGSize(width: 1, height: 1)))

        guard let down = event(.leftMouseDown, at: point, windowID: windowID, pid: ownerPID, flags: .maskCommand, source: source),
              let up = event(.leftMouseUp, at: point, windowID: targetWindowID, pid: ownerPID, flags: [], source: source)
        else { return nil }

        // 合成事件期间不要让系统压制本地鼠标事件。
        for state in [CGEventSuppressionState.eventSuppressionStateRemoteMouseDrag, .eventSuppressionStateSuppressionInterval] {
            source.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents], state: state)
        }
        source.localEventsSuppressionInterval = 0

        let t0 = Date()
        let cursor = CGEvent(source: nil)?.location ?? .zero
        if pointOnScreen { CGWarpMouseCursorPosition(point) }
        CGDisplayHideCursor(CGMainDisplayID())
        defer {
            CGWarpMouseCursorPosition(cursor)
            CGAssociateMouseAndMouseCursorPosition(1) // 解除 warp 之后系统对物理鼠标移动的短暂压制
            CGDisplayShowCursor(CGMainDisplayID())
        }
        if pointOnScreen { try? await Task.sleep(nanoseconds: 20_000_000) }

        down.post(tap: .cgSessionEventTap)
        let afterDown = await waitForFrameChange(of: windowID, from: itemFrame, timeout: 0.3)
        up.post(tap: .cgSessionEventTap)
        let afterUp = await waitForFrameChange(of: windowID, from: afterDown ?? itemFrame, timeout: 0.5)
        NSLog("CoffeeBar: move \(windowID): \(itemFrame) -> \(String(describing: afterUp ?? afterDown)) in \(Int(Date().timeIntervalSince(t0) * 1000))ms (cursor hidden throughout)")
        return afterUp ?? afterDown
    }
}
