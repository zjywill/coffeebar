#!/bin/bash
# 打包成 CoffeeBar.app。屏幕录制 / 辅助功能权限是按 .app 授的，裸二进制会把权限授给 Terminal。
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
APP=build/CoffeeBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/CoffeeBar "$APP/Contents/MacOS/CoffeeBar"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.zjywill.coffeebar</string>
    <key>CFBundleName</key><string>CoffeeBar</string>
    <key>CFBundleExecutable</key><string>CoffeeBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# 签名身份决定系统权限记录认不认得这个 App：
# ad-hoc 签名每次重新打包 cdhash 都变，权限会失效；有 Developer ID 就用它，身份固定。
# 可以用 SIGN_IDENTITY 环境变量覆盖，传 "-" 强制 ad-hoc。
if [ -z "${SIGN_IDENTITY:-}" ]; then
  SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -o '"Developer ID Application[^"]*"' | head -1 | tr -d '"')
  SIGN_IDENTITY="${SIGN_IDENTITY:--}"
fi
codesign --force --sign "$SIGN_IDENTITY" "$APP"
echo "signed with: $SIGN_IDENTITY"
echo "built $APP"
