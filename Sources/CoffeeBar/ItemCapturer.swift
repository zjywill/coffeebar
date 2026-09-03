import AppKit
import ScreenCaptureKit

/// 用 ScreenCaptureKit 给单个图标窗口截图。
/// `desktopIndependentWindow` 过滤器不关心窗口在不在屏幕内，所以隐藏中的图标也能截到。
enum ItemCapturer {
    static func capture(_ items: [MenuBarItem]) async -> [CGWindowID: NSImage] {
        guard !items.isEmpty,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        else { return [:] }

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        var result: [CGWindowID: NSImage] = [:]

        await withTaskGroup(of: (CGWindowID, NSImage?).self) { group in
            for item in items {
                guard let window = content.windows.first(where: { $0.windowID == item.windowID }) else { continue }
                group.addTask {
                    let filter = SCContentFilter(desktopIndependentWindow: window)
                    let config = SCStreamConfiguration()
                    config.width = Int(item.bounds.width * scale)
                    config.height = Int(item.bounds.height * scale)
                    config.showsCursor = false
                    config.ignoreShadowsSingleWindow = true
                    config.captureResolution = .best
                    guard let cgImage = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else {
                        return (item.windowID, nil)
                    }
                    return (item.windowID, NSImage(cgImage: cgImage, size: item.bounds.size))
                }
            }
            for await (id, image) in group {
                if let image { result[id] = image }
            }
        }
        return result
    }
}
