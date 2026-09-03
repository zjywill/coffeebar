import AppKit

/// 照 Thaw 的 ClickReactionVerifier：点击 / 辅助功能动作发出去之后，看目标 App 有没有真的反应。
///
/// 只认正面证据：
/// - App 在屏幕上新开了窗口（菜单、弹窗、面板）。
/// - 图标自己的窗口变了宽高，或者离开了屏幕（开关类图标常常这样重绘）。
/// 两样都没有不代表失败：只换个字形的开关图标在这里看不出来。所以"没看见反应"只是不确定，
/// 不能据此再补一次点击，否则会把刚打开的菜单又关掉、或者让光标白白跳一下。
enum ClickReactionVerifier {
    enum Reaction: Equatable {
        /// App 新开了窗口；关联值是最像"点击打开的界面"的那个窗口。
        case openedInterface(CGWindowID)
        /// 图标自己的窗口变了尺寸或离开屏幕。
        case itemChanged
        /// 什么都没观察到。
        case unobserved

        var didReact: Bool { self != .unobserved }
        var openedWindowID: CGWindowID? {
            if case let .openedInterface(id) = self { return id }
            return nil
        }
    }

    struct Snapshot {
        let pids: Set<pid_t>
        let itemWindowID: CGWindowID
        let itemBounds: CGRect
        let onScreenWindowIDs: Set<CGWindowID>
    }

    private static let budget: TimeInterval = 0.25
    private static let pollInterval: UInt64 = 20_000_000
    private static let boundsEpsilon: CGFloat = 1

    /// 点击之前先拍快照。
    static func snapshot(item: MenuBarItem, pids: Set<pid_t>) -> Snapshot {
        Snapshot(pids: pids,
                 itemWindowID: item.windowID,
                 itemBounds: MenuBarScanner.bounds(of: item.windowID) ?? item.bounds,
                 onScreenWindowIDs: Set(MenuBarScanner.onScreenWindowOwners().keys))
    }

    /// 最多等 250 毫秒，一有反应立刻返回。
    static func verify(against snapshot: Snapshot) async -> Reaction {
        let deadline = Date().addingTimeInterval(budget)
        while true {
            if let reaction = observe(snapshot) { return reaction }
            if Date() >= deadline { return .unobserved }
            try? await Task.sleep(nanoseconds: pollInterval)
        }
    }

    /// 只看一眼，不花等待预算。辅助功能动作阻塞到超时才返回的情况下，问题不是"会不会反应"
    /// 而是"我阻塞期间它反应了没有"，这个当场就能回答。
    static func reactionSoFar(against snapshot: Snapshot) -> Reaction? {
        observe(snapshot)
    }

    private static func observe(_ snapshot: Snapshot) -> Reaction? {
        let now = MenuBarScanner.onScreenWindowOwners()
        let newOwned = now.filter { !snapshot.onScreenWindowIDs.contains($0.key) && snapshot.pids.contains($0.value) }
        if let first = newOwned.keys.min() {
            // 菜单级别的窗口最像点击打开的界面；没有就随便挑一个，反正都是 App 在动。
            let menuLike = newOwned.keys.first { MenuBarScanner.windowLayer(of: $0).map { $0 >= Int(CGWindowLevelForKey(.popUpMenuWindow)) } ?? false }
            return .openedInterface(menuLike ?? first)
        }
        if itemChanged(snapshot) { return .itemChanged }
        return nil
    }

    private static func itemChanged(_ snapshot: Snapshot) -> Bool {
        guard let after = MenuBarScanner.bounds(of: snapshot.itemWindowID) else { return true }
        if !MenuBarScanner.isOnScreen(after) {
            // 现在在屏幕外：只有拍快照时它在屏幕上，才算是 App 自己把它收掉了。
            return snapshot.onScreenWindowIDs.contains(snapshot.itemWindowID)
        }
        return abs(after.width - snapshot.itemBounds.width) > boundsEpsilon
            || abs(after.height - snapshot.itemBounds.height) > boundsEpsilon
    }
}
