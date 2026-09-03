import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 允许后台藏光标（Thaw 的做法），否则挪图标时的光标 warp 会被看见。
        Bridging.setConnectionProperty(true, forKey: "SetsCursorInBackground")
        NSLog("CoffeeBar: SetsCursorInBackground = \(String(describing: Bridging.connectionProperty(forKey: "SetsCursorInBackground")))")
        controller = MenuBarController()
        if ProcessInfo.processInfo.environment["COFFEEBAR_ARRANGE"] != nil {
            controller?.debugArrange()
        }
        if let name = ProcessInfo.processInfo.environment["COFFEEBAR_DROPLEFT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [controller] in
                controller?.debugDropLeftOfToggle(appNamed: name)
            }
        }
        if let name = ProcessInfo.processInfo.environment["COFFEEBAR_HIDE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [controller] in
                controller?.debugHide(appNamed: name)
            }
        }
        if let name = ProcessInfo.processInfo.environment["COFFEEBAR_DRIFT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [controller] in
                controller?.debugDrift(appNamed: name)
            }
        }
        if let name = ProcessInfo.processInfo.environment["COFFEEBAR_TEMPSHOW"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [controller] in
                controller?.debugTempShow(appNamed: name)
            }
        }
        if let name = ProcessInfo.processInfo.environment["COFFEEBAR_ACTIVATE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [controller] in
                controller?.debugActivate(appNamed: name)
            }
        }
    }
}
