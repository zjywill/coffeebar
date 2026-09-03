import AppKit
import CoreGraphics

/// 一个菜单栏图标。每个 NSStatusItem 在窗口服务器里都是一个独立的小窗口，
/// 层级固定是 status 层，所以可以不靠任何权限枚举出来。
/// 注意 macOS 26 起这些窗口全部归 Control Center 进程所有（第三方 App 只是往里画），
/// 所以不能靠 PID 区分是谁的，也不能靠 PID 排除我们自己。
struct MenuBarItem: Identifiable, Hashable {
    let windowID: CGWindowID
    /// macOS 26 上永远是 Control Center，没什么用；面板显示的名字来自 AccessibilityIndex。
    let ownerPID: pid_t
    var ownerName: String
    var icon: NSImage?
    /// CG 坐标系（原点左上），单位是 point。
    var bounds: CGRect

    var id: CGWindowID { windowID }
}

enum MenuBarScanner {
    /// 枚举所有菜单栏图标窗口，按从左到右排序。
    static func allStatusItems() -> [MenuBarItem] {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let statusLevel = Int(CGWindowLevelForKey(.statusWindow))

        let items = list.compactMap { info -> MenuBarItem? in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == statusLevel,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict)
            else { return nil }
            // 过滤掉明显不是图标的东西（比如我们自己几千宽的分隔符）。
            guard bounds.width > 0, bounds.width < 600, bounds.height > 0, bounds.height < 60 else { return nil }
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            guard alpha > 0 else { return nil }
            let name = info[kCGWindowOwnerName as String] as? String ?? "pid \(pid)"
            return MenuBarItem(windowID: CGWindowID(info[kCGWindowNumber as String] as? Int ?? 0),
                               ownerPID: pid, ownerName: name, bounds: bounds)
        }
        return items.sorted { $0.bounds.minX < $1.bounds.minX }
    }

    /// 被分隔符挤出屏幕的图标。"隐藏" 的定义就是：不在任何一块显示器上。
    static func hiddenItems() -> [MenuBarItem] {
        allStatusItems().filter { !isOnScreen($0.bounds) }
    }

    /// 某个进程当前在屏幕上的窗口及其层级。用来判断点击之后有没有弹出菜单 / 弹窗。
    static func onScreenWindows(ownedBy pid: pid_t) -> [CGWindowID: Int] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return [:] }
        var result: [CGWindowID: Int] = [:]
        for info in list {
            guard let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
                  let number = info[kCGWindowNumber as String] as? Int
            else { continue }
            result[CGWindowID(number)] = info[kCGWindowLayer as String] as? Int ?? 0
        }
        return result
    }

    static func bounds(of windowID: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
              let info = list.first,
              let dict = info[kCGWindowBounds as String] as? NSDictionary
        else { return nil }
        return CGRect(dictionaryRepresentation: dict)
    }

    static func isOnScreen(_ rect: CGRect) -> Bool {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return displayBounds().contains { $0.contains(center) }
    }

    static func displayBounds() -> [CGRect] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }
}
