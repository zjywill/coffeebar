import AppKit
import ApplicationServices

/// 只需要一个权限：辅助功能。用来识别隐藏图标属于哪个 App，以及把点击转发给真图标。
enum Permissions {
    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    /// 系统只会弹一次授权框，之后要用户自己去设置里开。授权后立即生效，不用重启。
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
