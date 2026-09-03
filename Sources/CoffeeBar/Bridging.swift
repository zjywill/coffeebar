import CoreGraphics
import Foundation

/// 窗口服务器的私有接口（照 Thaw 的 Shared/Bridging）。
typealias CGSConnectionID = Int32

@_silgen_name("CGSMainConnectionID")
private func cgsMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSSetConnectionProperty")
private func cgsSetConnectionProperty(_ cid: CGSConnectionID, _ targetCID: CGSConnectionID, _ key: CFString, _ value: CFTypeRef) -> CGError

@_silgen_name("CGSCopyConnectionProperty")
private func cgsCopyConnectionProperty(_ cid: CGSConnectionID, _ targetCID: CGSConnectionID, _ key: CFString, _ outValue: inout Unmanaged<CFTypeRef>?) -> CGError

enum Bridging {
    static func connectionProperty(forKey key: String) -> Any? {
        let cid = cgsMainConnectionID()
        var value: Unmanaged<CFTypeRef>?
        guard cgsCopyConnectionProperty(cid, cid, key as CFString, &value) == .success else { return nil }
        return value?.takeRetainedValue()
    }

    /// 给自己的连接设属性。
    /// "SetsCursorInBackground" = true：允许后台 App 藏光标。不设的话 CGDisplayHideCursor 在后台是空操作，
    /// 挪图标时 warp 到菜单栏顶边那一下就会被看见（Thaw 在启动时就设了这个）。
    static func setConnectionProperty(_ value: Any?, forKey key: String) {
        let cid = cgsMainConnectionID()
        let result = cgsSetConnectionProperty(cid, cid, key as CFString, value as CFTypeRef)
        if result != .success { NSLog("CoffeeBar: CGSSetConnectionProperty(\(key)) failed: \(result.rawValue)") }
    }
}
