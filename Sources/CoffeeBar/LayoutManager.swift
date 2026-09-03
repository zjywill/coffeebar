import AppKit

/// 记住每个 App 的图标该在哪一侧，并在它跑偏时挪回去；新装的 App 图标默认露出来。
///
/// 解决的是 Ice / Bartender 用户投诉最多的两件事：
/// 1. 重启或 App 重启后图标自己跑到隐藏区（Ice #344）。
/// 2. 新图标出现在最左边直接被藏起来，用户不知道它存在（Ice #6）。
///
/// App 身份用 bundle id；一个 App 多个图标按同一侧处理。系统自带的（com.apple.*）不碰。
@MainActor
final class LayoutManager {
    enum Side: String, Codable { case visible, hidden }

    private static let layoutKey = "CoffeeBar.layout"
    private static let knownAppsKey = "CoffeeBar.knownApps"

    /// 期望布局：bundle id -> 侧。
    private(set) var layout: [String: Side]
    /// 见过的 App，用来识别"新"图标。
    private var knownApps: Set<String>
    /// 上次扫描看到的窗口 ID，变了才做昂贵的辅助功能扫描。
    private var lastWindowIDs: Set<CGWindowID> = []

    /// 由控制器提供：当前是否允许挪动（没在整理、没有临时挪出的图标、面板没开）。
    var canMove: () -> Bool = { true }
    var toggleWindowID: () -> CGWindowID? = { nil }
    var refreshAccessibilityIndex: () async -> [AXMenuExtra] = { [] }

    private var timer: Timer?
    private var busy = false
    /// 挪不动的窗口（比如某些系统模块），失败几次就放弃，别每 4 秒骚扰一次。
    private var moveFailures: [CGWindowID: Int] = [:]
    private static let maxMoveFailures = 3

    private func move(_ item: MenuBarItem, toLeftOf target: CGWindowID) async {
        guard moveFailures[item.windowID, default: 0] < Self.maxMoveFailures else { return }
        if await ItemMover.move(windowID: item.windowID, ownerPID: item.ownerPID, toLeftOf: target) == nil {
            moveFailures[item.windowID, default: 0] += 1
            if moveFailures[item.windowID] == Self.maxMoveFailures {
                NSLog("CoffeeBar: giving up on moving window \(item.windowID)")
            }
        } else {
            moveFailures[item.windowID] = 0
        }
    }

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.layoutKey),
           let saved = try? JSONDecoder().decode([String: Side].self, from: data) {
            layout = saved
        } else {
            layout = [:]
        }
        knownApps = Set(defaults.stringArray(forKey: Self.knownAppsKey) ?? [])
    }

    func start() {
        // 启动后先等菜单栏稳定下来，再开始周期检查。App 启动时也立即安排一次。
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
        Task { @MainActor in await check() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                await self?.check(force: true)
            }
        }
    }

    /// 把当前状态记为用户意图。整理结束、我们自己挪完图标后调用。
    func recordCurrent(extras: [AXMenuExtra]) {
        let items = MenuBarScanner.allStatusItems()
        var next = layout
        for item in items {
            guard let bundleID = Self.bundleID(for: item, extras: extras) else { continue }
            next[bundleID] = MenuBarScanner.isOnScreen(item.bounds) ? .visible : .hidden
        }
        layout = next
        knownApps.formUnion(next.keys)
        save()
    }

    /// 首次运行：把现在所有 App 都当作见过的，不然它们全会被当成"新图标"露出来。
    func seedIfEmpty(extras: [AXMenuExtra]) {
        guard knownApps.isEmpty else { return }
        recordCurrent(extras: extras)
    }

    // MARK: - 周期检查

    private func check(force: Bool = false) async {
        guard !busy, canMove(), Permissions.hasAccessibility else { return }
        guard NSEvent.pressedMouseButtons == 0, !NSEvent.modifierFlags.contains(.command) else { return }
        let items = MenuBarScanner.allStatusItems()
        let ids = Set(items.map(\.windowID))
        guard force || ids != lastWindowIDs else { return }
        NSLog("CoffeeBar: layout check running over \(items.count) items")
        lastWindowIDs = ids

        busy = true
        defer { busy = false }
        var extras = await refreshAccessibilityIndex()
        seedIfEmpty(extras: extras)
        guard let toggle = toggleWindowID(), let separator = MenuBarScanner.separatorWindowID() else { return }

        // 每挪一次，隐藏区里其它图标的坐标都会变，所以一次只处理一个，然后重新扫描。
        var changed = false
        for _ in 0..<12 {
            let current = MenuBarScanner.allStatusItems()
            var acted = false
            for item in current {
                if Self.isSystemItem(item, extras: extras) {
                    guard !MenuBarScanner.isOnScreen(item.bounds), moveFailures[item.windowID, default: 0] < Self.maxMoveFailures else { continue }
                    NSLog("CoffeeBar: system item drifted into hidden area, moving it back")
                    await move(item, toLeftOf: toggle)
                    acted = true
                    break
                }
                guard let bundleID = Self.bundleID(for: item, extras: extras) else { continue }
                let actual: Side = MenuBarScanner.isOnScreen(item.bounds) ? .visible : .hidden

                if !knownApps.contains(bundleID) {
                    // 新 App：默认露出来，让用户看见它。
                    knownApps.insert(bundleID)
                    layout[bundleID] = .visible
                    changed = true
                    if actual == .hidden {
                        NSLog("CoffeeBar: new app \(bundleID), revealing its item")
                        await move(item, toLeftOf: toggle)
                        acted = true
                        break
                    }
                    continue
                }

                guard let wanted = layout[bundleID], wanted != actual,
                      moveFailures[item.windowID, default: 0] < Self.maxMoveFailures else { continue }
                NSLog("CoffeeBar: \(bundleID) drifted to \(actual.rawValue), moving back to \(wanted.rawValue)")
                await move(item, toLeftOf: wanted == .visible ? toggle : separator)
                acted = true
                break
            }
            guard acted else { break }
            try? await Task.sleep(nanoseconds: 150_000_000)
            extras = await refreshAccessibilityIndex()
        }
        if changed { save() }
        lastWindowIDs = Set(MenuBarScanner.allStatusItems().map(\.windowID))
    }

    // MARK: - 工具

    static func bundleID(for item: MenuBarItem, extras: [AXMenuExtra]) -> String? {
        guard let extra = AccessibilityIndex.match(item.bounds, in: extras),
              let app = NSRunningApplication(processIdentifier: extra.pid),
              let bundleID = app.bundleIdentifier
        else { return nil }
        // 系统自带的（控制中心模块、Spotlight、输入法）走 isSystem 那条规则，不进布局表。
        if isSystem(bundleID) { return nil }
        // 自己也不管。
        if bundleID == Bundle.main.bundleIdentifier { return nil }
        return bundleID
    }

    /// 系统自带的菜单栏项：电池、Wi-Fi、控制中心、聚焦、输入法、时钟等。永远不藏。
    static func isSystem(_ bundleID: String) -> Bool {
        bundleID.hasPrefix("com.apple.")
    }

    static func isSystemItem(_ item: MenuBarItem, extras: [AXMenuExtra]) -> Bool {
        guard let extra = AccessibilityIndex.match(item.bounds, in: extras),
              let bundleID = NSRunningApplication(processIdentifier: extra.pid)?.bundleIdentifier
        else { return false }
        return isSystem(bundleID)
    }

    private func save() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(layout) { defaults.set(data, forKey: Self.layoutKey) }
        defaults.set(Array(knownApps).sorted(), forKey: Self.knownAppsKey)
    }
}
