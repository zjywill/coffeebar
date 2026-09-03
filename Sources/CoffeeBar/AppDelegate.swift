import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = MenuBarController()
        if ProcessInfo.processInfo.environment["COFFEEBAR_ARRANGE"] != nil {
            controller?.debugArrange()
        }
        if let name = ProcessInfo.processInfo.environment["COFFEEBAR_ACTIVATE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [controller] in
                controller?.debugActivate(appNamed: name)
            }
        }
    }
}
