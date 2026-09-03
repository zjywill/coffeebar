#!/bin/bash
# 打包成 build/CoffeeBar.app。
#
# 屏幕录制 / 辅助功能权限是按 .app 授的，裸二进制会把权限授给 Terminal，所以必须打包运行。
#
# 环境变量：
#   ARCHS                         默认 "arm64 x86_64"（通用二进制），本地开发可设 ARCHS=arm64 加快构建
#   SIGN_IDENTITY                 签名身份，默认取钥匙串里的 Developer ID Application，没有就 ad-hoc（"-"）
#   HARDENED_RUNTIME=1            开启 hardened runtime（公证必需），release.sh 会设
#   COFFEEBAR_FEED_URL            Sparkle appcast 地址
#   COFFEEBAR_SPARKLE_PUBLIC_KEY  Sparkle EdDSA 公钥
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd -P)"

VERSION=$(tr -d '[:space:]' < VERSION)
BUILD_NUMBER=$(git rev-list --count HEAD)
ARCHS=${ARCHS:-"arm64 x86_64"}
FEED_URL=${COFFEEBAR_FEED_URL:-https://raw.githubusercontent.com/zjywill/coffeebar/master/appcast.xml}
PUBLIC_KEY=${COFFEEBAR_SPARKLE_PUBLIC_KEY:-jYWo8ceOhb12yGRhNfhxIKIfVHDgfEnbE+0Qzq6444o=}

# ---- 1. 编译 ----------------------------------------------------------------
ARCH_FLAGS=()
for arch in $ARCHS; do ARCH_FLAGS+=(--arch "$arch"); done
swift build -c release "${ARCH_FLAGS[@]}"
BIN_DIR=$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)

# ---- 2. 组装 bundle ---------------------------------------------------------
APP="$ROOT/build/CoffeeBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/CoffeeBar" "$APP/Contents/MacOS/CoffeeBar"

# Sparkle：SwiftPM 只负责链接，框架要自己放进 Contents/Frameworks 并补 rpath。
SPARKLE_FW="$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[ -d "$SPARKLE_FW" ] || { echo "Sparkle.framework not found, run: swift package resolve" >&2; exit 1; }
cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/CoffeeBar"

# 本地化字符串。
for lproj in "$ROOT"/Resources/*.lproj; do
  cp -R "$lproj" "$APP/Contents/Resources/"
done

# 图标：Resources/CoffeeBar.icon 是 Icon Composer 格式，用 Xcode 的 actool 编译成 .icns + Assets.car。
ICON_KEYS=""
if xcrun --find actool >/dev/null 2>&1; then
  # actool 按 PWD 环境变量解析相对路径，这里一律用绝对路径。
  xcrun actool "$ROOT/Resources/CoffeeBar.icon" \
    --compile "$APP/Contents/Resources" \
    --platform macosx --minimum-deployment-target 26.0 \
    --app-icon CoffeeBar \
    --output-partial-info-plist /dev/null \
    --output-format human-readable-text >/dev/null
  ICON_KEYS='    <key>CFBundleIconFile</key><string>CoffeeBar</string>
    <key>CFBundleIconName</key><string>CoffeeBar</string>'
else
  echo "warning: actool not found (install Xcode), skipping app icon" >&2
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.zjywill.coffeebar</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
    <key>CFBundleName</key><string>CoffeeBar</string>
    <key>CFBundleExecutable</key><string>CoffeeBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>AGPL-3.0</string>
$ICON_KEYS
    <key>SUFeedURL</key><string>$FEED_URL</string>
    <key>SUPublicEDKey</key><string>$PUBLIC_KEY</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUScheduledCheckInterval</key><integer>86400</integer>
</dict>
</plist>
PLIST

# ---- 3. 签名 ----------------------------------------------------------------
# 签名身份决定系统权限记录认不认得这个 App：
# ad-hoc 签名每次重新打包 cdhash 都变，权限会失效；有 Developer ID 就用它，身份固定。
if [ -z "${SIGN_IDENTITY:-}" ]; then
  SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -o '"Developer ID Application[^"]*"' | head -1 | tr -d '"')
  SIGN_IDENTITY="${SIGN_IDENTITY:--}"
fi
SIGN_FLAGS=(--force --sign "$SIGN_IDENTITY" --timestamp)
[ "$SIGN_IDENTITY" = "-" ] && SIGN_FLAGS=(--force --sign -)
[ "${HARDENED_RUNTIME:-0}" = "1" ] && SIGN_FLAGS+=(--options runtime)

# Sparkle 要由内向外逐个签，XPC 服务保留自带的 entitlements。
FW="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign "${SIGN_FLAGS[@]}" --preserve-metadata=entitlements "$FW/XPCServices/Downloader.xpc"
codesign "${SIGN_FLAGS[@]}" --preserve-metadata=entitlements "$FW/XPCServices/Installer.xpc"
codesign "${SIGN_FLAGS[@]}" "$FW/Autoupdate"
codesign "${SIGN_FLAGS[@]}" "$FW/Updater.app"
codesign "${SIGN_FLAGS[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
codesign "${SIGN_FLAGS[@]}" "$APP"
codesign --verify --deep --strict "$APP"

echo "built $APP  (version $VERSION build $BUILD_NUMBER, archs: $ARCHS, signed: $SIGN_IDENTITY)"
