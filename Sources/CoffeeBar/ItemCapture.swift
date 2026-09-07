import AppKit
import ScreenCaptureKit

/// 截取菜单栏图标窗口的真实画面，面板里用它代替 App 图标，这样微信的未读角标、Moti 的读数都能看到。
///
/// 照 Thaw 的 MenuBarCaptureService：隐藏图标的窗口停在屏幕外（x 是很大的负数），ScreenCaptureKit 截不到，
/// 只有 SkyLight 的私有函数 `SLWindowListCreateImageFromArray` 能截。一次把整段窗口打包合成一张图，
/// 再按各窗口的 bounds 切片。需要屏幕录制权限。
///
/// 这个私有函数每次调用会漏约 168 字节（Thaw 的实测），Thaw 为此把它放进单独的 XPC 进程定期重启。
/// 我们只在面板打开时以 1 fps 截，一小时才 600 KB，不值得多开一个进程。
enum ItemCapture {
    private typealias CreateImageFn = @convention(c) (CGRect, CFArray, CGWindowImageOption) -> Unmanaged<CGImage>?

    private static let createImage: CreateImageFn? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW) else {
            NSLog("CoffeeBar: dlopen SkyLight failed")
            return nil
        }
        guard let symbol = dlsym(handle, "SLWindowListCreateImageFromArray") else {
            NSLog("CoffeeBar: SLWindowListCreateImageFromArray not found")
            return nil
        }
        return unsafeBitCast(symbol, to: CreateImageFn.self)
    }()

    static var isAvailable: Bool { createImage != nil }

    /// 有没有屏幕录制权限。照 Thaw 的 checkPermissions：有权限时别的进程的窗口才带标题；
    /// CGPreflightScreenCaptureAccess 只反映启动时的状态，作兜底。
    static var hasPermission: Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return CGPreflightScreenCaptureAccess()
        }
        let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
        let me = ProcessInfo.processInfo.processIdentifier
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == statusLevel,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != me
            else { continue }
            return info[kCGWindowName as String] != nil
        }
        return CGPreflightScreenCaptureAccess()
    }

    /// 触发系统的屏幕录制授权框。CGRequestScreenCaptureAccess 在新系统上不可靠（Thaw 的经验），
    /// 用 SCShareableContent 触发；再补一次 CGRequest 兜底。
    static func requestPermission() {
        SCShareableContent.getWithCompletionHandler { _, _ in }
        _ = CGRequestScreenCaptureAccess()
    }

    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    struct Result {
        var images: [CGWindowID: NSImage] = [:]
        /// 字形整体是亮色（菜单栏在深色壁纸上画白字形）还是暗色。面板据此切换外观，不然白字形在浅色面板上看不见。
        var glyphsAreLight = false
    }

    /// 一次截下所有给定窗口，返回每个窗口的图（point 尺寸，左右透明边已裁掉）。截不到的窗口不在结果里。
    static func capture(_ windowIDs: [CGWindowID]) -> Result {
        guard let createImage else { return Result() }
        var bounds: [CGWindowID: CGRect] = [:]
        var union = CGRect.null
        for id in windowIDs {
            guard let rect = MenuBarScanner.bounds(of: id), rect.width > 0, rect.height > 0, rect.width < 600, rect.height < 60 else { continue }
            bounds[id] = rect
            union = union.union(rect)
        }
        // 窗口服务器会按像素尺寸分配纹理，太大会把 WindowServer 弄崩（Thaw #759），保守限制。
        guard !bounds.isEmpty, union.width < 8000, union.height < 200 else { return Result() }

        var pointers: [UnsafeRawPointer?] = bounds.keys.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        var callbacks = CFArrayCallBacks(version: 0, retain: nil, release: nil, copyDescription: nil, equal: nil)
        guard let array = CFArrayCreate(nil, &pointers, pointers.count, &callbacks) else { return Result() }
        guard let composite = createImage(.null, array, [.boundsIgnoreFraming, .bestResolution])?.takeRetainedValue() else {
            return Result()
        }
        let scale = CGFloat(composite.width) / union.width
        guard scale > 0, scale.isFinite else { return Result() }

        var result = Result()
        var luminanceSum: Double = 0
        var luminanceCount = 0
        for (id, rect) in bounds {
            let crop = CGRect(x: (rect.minX - union.minX) * scale, y: (rect.minY - union.minY) * scale,
                              width: rect.width * scale, height: rect.height * scale)
            guard let cropped = composite.cropping(to: crop), let trimmed = trimHorizontalTransparency(cropped, luminance: &luminanceSum, count: &luminanceCount) else { continue }
            result.images[id] = NSImage(cgImage: trimmed, size: CGSize(width: CGFloat(trimmed.width) / scale, height: CGFloat(trimmed.height) / scale))
        }
        result.glyphsAreLight = luminanceCount > 0 && luminanceSum / Double(luminanceCount) > 0.5
        return result
    }

    /// 裁掉左右两侧完全透明的列（Thaw 的 trimmingTransparency(around: [.minXEdge, .maxXEdge])）。
    /// 整张全透明返回 nil（窗口没画东西，不该显示）。顺手累计不透明像素的亮度，用来判断字形是亮是暗。
    private static func trimHorizontalTransparency(_ image: CGImage, luminance: inout Double, count: inout Int) -> CGImage? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        func columnHasContent(_ x: Int) -> Bool {
            for y in 0..<height where pixels[(y * width + x) * 4 + 3] > 8 { return true }
            return false
        }
        // 预乘 BGRA：亮度按 alpha 还原，只统计基本不透明的像素（抗锯齿边缘会拉低平均值）。
        var index = 0
        while index < pixels.count {
            let alpha = Int(pixels[index + 3])
            if alpha > 200 {
                let b = Double(pixels[index]), g = Double(pixels[index + 1]), r = Double(pixels[index + 2])
                luminance += (0.2126 * r + 0.7152 * g + 0.0722 * b) / Double(alpha)
                count += 1
            }
            index += 4
        }
        guard let first = (0..<width).first(where: columnHasContent), let last = (0..<width).last(where: columnHasContent) else { return nil }
        return image.cropping(to: CGRect(x: first, y: 0, width: last - first + 1, height: height))
    }
}
