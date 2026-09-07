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

// 调试用：`CoffeeBar --capture <dir>` 截一次隐藏图标存成 PNG。
if let index = CommandLine.arguments.firstIndex(of: "--capture") {
    let dir = CommandLine.arguments.count > index + 1 ? CommandLine.arguments[index + 1] : NSTemporaryDirectory()
    print("skylight: \(ItemCapture.isAvailable)  screen recording: \(ItemCapture.hasPermission)")
    let extras = AccessibilityIndex.scan()
    let items = MenuBarScanner.hiddenItems()
    let started = Date()
    let capture = ItemCapture.capture(items.map(\.windowID))
    let images = capture.images
    print("captured \(images.count)/\(items.count) in \(Int(Date().timeIntervalSince(started) * 1000)) ms, light glyphs: \(capture.glyphsAreLight)")
    for item in items {
        let name = AccessibilityIndex.match(item.bounds, in: extras)?.appName ?? "unknown"
        guard let image = images[item.windowID], let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { print("  \(name): no image"); continue }
        let path = "\(dir)/\(item.windowID)-\(name.replacingOccurrences(of: " ", with: "_")).png"
        try? png.write(to: URL(fileURLWithPath: path))
        print("  \(name): \(image.size) -> \(path)")
    }
    exit(0)
}

let app = NSApplication.shared
// 不显示 Dock 图标，只住在菜单栏。
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
