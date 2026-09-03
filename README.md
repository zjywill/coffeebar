# CoffeeBar

一个极简的 macOS 菜单栏图标隐藏工具，只做一件事：把不常用的菜单栏图标藏起来。

原理和 Bartender / Ice 相同：放一个宽度极大的分隔符 `NSStatusItem`，把它左侧的图标挤出屏幕。不需要辅助功能权限，也不需要录屏权限。

## 使用

```bash
swift build -c release
.build/release/CoffeeBar
```

- 菜单栏右侧出现 `<` 按钮，点击切换隐藏 / 显示。
- 按住 ⌘ 拖动 `/` 分隔符到想要的位置，它左边的图标都会被隐藏。
- 显示状态下点击菜单栏以外的地方，或 8 秒无操作，自动收回。
- 右键 `<` 按钮可退出。

## 要求

macOS 13+，Swift 5.9+。

## 重置位置

位置记录在 `~/Library/Preferences/CoffeeBar.plist`，想恢复默认布局：

```bash
defaults delete CoffeeBar
```
