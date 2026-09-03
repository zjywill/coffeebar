import AppKit
import ApplicationServices

/// 两个权限：屏幕录制用来给隐藏图标截图，辅助功能用来把点击转发给真实图标。
enum Permissions {
    static var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }
    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    /// 系统只会弹一次授权框，之后要用户自己去设置里开。
    static func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
    }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    /// 屏幕录制权限要重启进程才生效。
    static func relaunch() {
        let path = Bundle.main.bundleURL.pathExtension == "app"
            ? Bundle.main.bundleURL.path
            : Bundle.main.executablePath ?? ""
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5; open -n \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    private static func open(_ url: String) {
        if let url = URL(string: url) {
            NSWorkspace.shared.open(url)
        }
    }
}
