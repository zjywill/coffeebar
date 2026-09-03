# CoffeeBar

一个极简的 macOS 菜单栏图标隐藏工具，只做一件事：把不常用的菜单栏图标藏起来，需要时从一个下拉面板里点。

原理和 Bartender / Ice 相同：放一个宽度极大的分隔符 `NSStatusItem`，把它左侧的图标挤出屏幕。

## 使用

```bash
ARCHS=arm64 ./scripts/make-app.sh   # 本地开发只编本机架构，快
open build/CoffeeBar.app
```

- 菜单栏右侧出现 `<` 按钮。首次启动时它左边的所有第三方图标都会被隐藏。
- **左键点 `<`**：在菜单栏下方弹出面板，显示所有隐藏图标；点面板里的图标等于点了真图标，左右键都支持。屏幕再窄、有刘海都不影响。
- **⌥ + 左键点 `<`**：把隐藏的图标直接在菜单栏里展开（屏幕够宽时可用）。点菜单栏以外的地方自动收回。
- 想让某个图标常显：按住 ⌘ 把它拖到 `/` 分隔符右边（分隔符只在展开时可见）。
- 右键 `<` 可退出。

## 权限

面板模式需要两个权限，首次点 `<` 时会引导：

| 权限 | 用途 | 不给会怎样 |
| --- | --- | --- |
| 屏幕录制 | 给隐藏图标截图，显示在面板里 | 面板打不开，只能用 ⌥ 展开 |
| 辅助功能 | 把面板里的点击转发给真图标 | 面板能看不能点 |

权限是按 .app 授的，所以必须用 `make-app.sh` 打包后运行，不要直接跑 `.build` 里的裸二进制。脚本会优先用钥匙串里的 Developer ID 证书签名，这样重新打包后权限不会失效；没有证书则 ad-hoc 签名，每次重新打包都要重新授权。授权屏幕录制后 CoffeeBar 会自动重启。

## 安装（普通用户）

到 [Releases](https://github.com/zjywill/coffeebar/releases) 下载最新的 `CoffeeBar-x.y.z.zip`，解压后拖进「应用程序」。已用 Developer ID 签名并经过 Apple 公证，可直接打开。

之后的更新走 Sparkle：右键 `<` 里有「检查更新…」，每天也会自动检查一次。

## 发版（维护者）

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

## 重置位置

```bash
defaults delete com.zjywill.coffeebar
```

## 要求

macOS 14+，Swift 5.9+。在 macOS 26 上开发验证。

## 许可证

AGPL-3.0，见 [LICENSE](LICENSE)。
