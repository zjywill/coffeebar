import Foundation

/// 本地化：键就是英文原文，中文在 zh-Hans.lproj/Localizable.strings 里。
/// 裸跑 .build 里的二进制时没有 strings 文件，会直接显示英文，正好。
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}
