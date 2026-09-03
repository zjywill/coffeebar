# Development

构建、发版、调试和维护说明。用户向的介绍见 [README](../README.md)。

## 本地构建与运行

```bash
ARCHS=arm64 ./scripts/make-app.sh   # 本地开发只编本机架构，快
open build/CoffeeBar.app
```

- 菜单栏右侧出现 `<` 按钮。首次启动时它左边的所有第三方图标都会被隐藏。
- **左键点 `<`**：在菜单栏下方弹出面板，用 App 图标列出所有隐藏项。点面板里的图标，CoffeeBar 会把**那一个**真图标挪到 `<` 旁边并点它（左右键都支持），其它隐藏图标不动；等它的菜单或弹窗关掉后自动挪回原位。和 Bartender / Ice 的表现一致，屏幕再窄、有刘海都不影响。
- **面板搜索**：面板打开后直接打字按 App 名过滤，← → 选择，回车打开，Esc 关闭。
- **新装的 App 图标默认可见**：新出现的菜单栏图标会被挪到可见区，让你知道它存在；想藏再拖走。
- **系统自带的项永远不藏**：电池、Wi-Fi、控制中心、聚焦、输入法这些如果被挤进隐藏区，会自动挪回可见区，面板里也不列。
- **位置不乱跑**：记住每个 App 的图标在哪一侧，重启或 App 重启后跑偏了会自动挪回去。你自己拖动的会被记为新的意图，不会被改回去。
- **只在内建屏使用面板**：右键 `<` 里的开关。开了以后在外接屏上点 `<` 直接整体展开，点别处收回；在笔记本屏上仍用面板。
- **隐藏 / 显示某个图标**：按住 ⌘ 把图标拖到 `<` 左边就隐藏，拖到右边就常显，CoffeeBar 会记住。要批量调整可以右键 `<` 选「整理图标…」（或 ⌥ + 左键），隐藏的图标会全部展开并保持住，整理完点 `<`（此时显示为 ✓）收回。
- 右键 `<` 里有检查更新和退出。

## 权限

只需要「辅助功能」一个权限，首次点 `<` 时会引导。用来识别隐藏图标属于哪个 App（取图标和名字），以及把面板里的点击转发给真图标。授权后立即生效，不用重启。

权限是按 .app 授的，所以必须用 `make-app.sh` 打包后运行，不要直接跑 `.build` 里的裸二进制。脚本会优先用钥匙串里的 Developer ID 证书签名，这样重新打包后权限不会失效；没有证书则 ad-hoc 签名，每次重新打包都要重新授权。

## 发版

```bash
# 1. 改 VERSION 文件，提交
# 2. 发布
./scripts/release.sh --publish
```

脚本会打通用二进制、hardened runtime 签名、Apple 公证、staple、生成 Sparkle appcast、建 GitHub Release 并把 `appcast.xml` 推到 master。不带 `--publish` 只建草稿 Release，不推 appcast。

一次性准备：Developer ID Application 证书、`notarytool` 钥匙串 profile（默认名 `KiteNotary`，可用 `COFFEEBAR_NOTARY_PROFILE` 覆盖）、钥匙串账户 `com.zjywill.coffeebar` 下的 Sparkle EdDSA 私钥。私钥丢了已装用户就再也收不到更新，记得备份：

```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account com.zjywill.coffeebar -x coffeebar-sparkle-key.txt
```

## 调试

```bash
.build/debug/CoffeeBar --scan
```

打印当前所有菜单栏图标窗口及其隐藏状态。

## 重置

```bash
defaults delete com.zjywill.coffeebar
```

会清掉分隔符位置、布局记忆和已知 App 列表。

## 要求

macOS 14+，Swift 5.9+。在 macOS 26 上开发验证。
