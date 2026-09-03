import AppKit

// 调试用：`CoffeeBar --scan` 打印当前所有菜单栏图标窗口，不启动 App。
if CommandLine.arguments.contains("--scan") {
    let started = Date()
    let extras = AccessibilityIndex.scan()
    print("ax scan took \(Int(Date().timeIntervalSince(started) * 1000)) ms")
    print("accessibility: \(Permissions.hasAccessibility)  ax extras: \(extras.count)")
    for item in MenuBarScanner.allStatusItems() {
        let state = MenuBarScanner.isOnScreen(item.bounds) ? "visible" : "hidden "
        let app = AccessibilityIndex.match(item.bounds, in: extras)?.appName ?? "?"
        print("\(state)  id=\(item.windowID)  \(app)  \(item.bounds)")
    }
    exit(0)
}

let app = NSApplication.shared
// 不显示 Dock 图标，只住在菜单栏。
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
