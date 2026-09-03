import AppKit
import ScreenCaptureKit

/// 用 ScreenCaptureKit 给单个图标窗口截图。
/// `desktopIndependentWindow` 过滤器不关心窗口在不在屏幕内，所以隐藏中的图标也能截到。
enum ItemCapturer {
    static func capture(_ items: [MenuBarItem]) async -> [CGWindowID: NSImage] {
        guard !items.isEmpty else { return [:] }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            NSLog("CoffeeBar: SCShareableContent failed: \(error)")
            return [:]
        }
        if ProcessInfo.processInfo.environment["COFFEEBAR_DEBUG"] != nil {
            NSLog("CoffeeBar: shareable windows=\(content.windows.count)")
            for w in content.windows where w.frame.minY <= 0 && w.frame.height <= 60 {
                NSLog("  sc window id=\(w.windowID) layer=\(w.windowLayer) onScreen=\(w.isOnScreen) app=\(w.owningApplication?.applicationName ?? "?") \(w.frame)")
            }
        }

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        var result: [CGWindowID: NSImage] = [:]

        await withTaskGroup(of: (CGWindowID, NSImage?).self) { group in
            for item in items {
                guard let window = content.windows.first(where: { $0.windowID == item.windowID }) else {
                    NSLog("CoffeeBar: window \(item.windowID) not in shareable content")
                    continue
                }
                group.addTask {
                    let filter = SCContentFilter(desktopIndependentWindow: window)
                    let config = SCStreamConfiguration()
                    config.width = Int(item.bounds.width * scale)
                    config.height = Int(item.bounds.height * scale)
                    config.showsCursor = false
                    config.ignoreShadowsSingleWindow = true
                    config.captureResolution = .best
                    do {
                        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                        return (item.windowID, NSImage(cgImage: cgImage, size: item.bounds.size))
                    } catch {
                        NSLog("CoffeeBar: capture \(item.windowID) failed: \(error)")
                        return (item.windowID, nil)
                    }
                }
            }
            for await (id, image) in group {
                if let image { result[id] = image }
            }
        }
        return result
    }
}
