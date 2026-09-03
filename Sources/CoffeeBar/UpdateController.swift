import AppKit
import Sparkle

/// Sparkle 的门面。SUFeedURL 和 SUPublicEDKey 在打包时写进 Info.plist，
/// 开发环境裸跑没有这两个键时就静默禁用。
@MainActor
final class UpdateController {
    private var updaterController: SPUStandardUpdaterController?

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let feed = info["SUFeedURL"] as? String, !feed.isEmpty,
              let key = info["SUPublicEDKey"] as? String, !key.isEmpty
        else { return }
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    var isConfigured: Bool { updaterController != nil }

    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }
}
