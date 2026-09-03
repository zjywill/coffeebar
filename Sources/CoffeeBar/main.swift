import AppKit

// 调试用：`CoffeeBar --scan` 打印当前所有菜单栏图标窗口，不启动 App。
if CommandLine.arguments.contains("--scan") {
    let extras = AccessibilityIndex.scan()
    print("accessibility: \(Permissions.hasAccessibility)  screen recording: \(Permissions.hasScreenRecording)  ax extras: \(extras.count)")
    for item in MenuBarScanner.allStatusItems() {
        let state = MenuBarScanner.isOnScreen(item.bounds) ? "visible" : "hidden "
        let app = AccessibilityIndex.match(item.bounds, in: extras)?.appName ?? "?"
        print("\(state)  id=\(item.windowID)  \(app)  \(item.bounds)")
    }
    exit(0)
}

// 调试用：`CoffeeBar --capture <dir>` 把所有隐藏图标截图存到目录里。
if let i = CommandLine.arguments.firstIndex(of: "--capture"), i + 1 < CommandLine.arguments.count {
    let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        let items = MenuBarScanner.hiddenItems()
        let images = await ItemCapturer.capture(items)
        print("hidden: \(items.count)  captured: \(images.count)")
        for item in items {
            guard let image = images[item.windowID],
                  let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
            else { continue }
            try? png.write(to: dir.appendingPathComponent("\(item.windowID).png"))
        }
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
}

// 调试用：`CoffeeBar --capture-window <id> <out.png>` 截任意窗口。
if let i = CommandLine.arguments.firstIndex(of: "--capture-window"), i + 2 < CommandLine.arguments.count,
   let id = UInt32(CommandLine.arguments[i + 1]) {
    let out = URL(fileURLWithPath: CommandLine.arguments[i + 2])
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        let bounds = MenuBarScanner.bounds(of: id) ?? .zero
        let item = MenuBarItem(windowID: id, ownerPID: 0, ownerName: "?", bounds: bounds)
        let images = await ItemCapturer.capture([item])
        if let image = images[id], let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: out)
            print("ok \(bounds)")
        } else {
            print("failed \(bounds)")
        }
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
}

let app = NSApplication.shared
// 不显示 Dock 图标，只住在菜单栏。
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
