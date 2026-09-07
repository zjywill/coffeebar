#!/bin/bash
# 对外发版：打包 → 公证 → staple → 生成 Sparkle appcast → 建 GitHub Release → 推 appcast。
#
# 用法：
#   scripts/release.sh            # 全部做完但只建草稿 Release，不推 appcast
#   scripts/release.sh --publish  # 正式发布并推 appcast
#   scripts/release.sh --dry-run  # 只打包公证，不碰 GitHub
#
# 环境变量：
#   COFFEEBAR_NOTARY_PROFILE   notarytool 钥匙串 profile，默认 KiteNotary
#   COFFEEBAR_RELEASE_NOTES    发布说明文件（markdown），不给就写一行版本号
#
# 版本号来自 VERSION 文件；构建号是 git 提交数，所以每次发布前先提交。
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd -P)"

REPO=zjywill/coffeebar
KEY_ACCOUNT=com.zjywill.coffeebar
NOTARY_PROFILE=${COFFEEBAR_NOTARY_PROFILE:-KiteNotary}
NOTES_FILE=${COFFEEBAR_RELEASE_NOTES:-}
FEED_URL=https://raw.githubusercontent.com/zjywill/coffeebar/master/appcast.xml

PUBLISH=0; DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --publish) PUBLISH=1 ;;
    --dry-run) DRY_RUN=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
die() { echo "$1" >&2; exit 2; }

VERSION=$(tr -d '[:space:]' < VERSION)
TAG="v$VERSION"
[ -z "$(git status --porcelain)" ] || die "working tree is dirty, commit first (build number = commit count)"
if [ "$DRY_RUN" = "0" ] && gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  die "release $TAG already exists"
fi

# ---- 1. 打包（通用二进制 + hardened runtime）----------------------------------
HARDENED_RUNTIME=1 COFFEEBAR_FEED_URL="$FEED_URL" scripts/make-app.sh
APP="$ROOT/build/CoffeeBar.app"
# 先存进变量再匹配：pipefail 下 grep -q 提前退出会让 codesign 吃 SIGPIPE，整条管道判失败。
SIGN_INFO=$(codesign -dv --verbose=4 "$APP" 2>&1)
grep -q 'Authority=Developer ID Application' <<< "$SIGN_INFO" || die "not signed with Developer ID"
grep -q 'flags=.*runtime' <<< "$SIGN_INFO" || die "hardened runtime missing"
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")

# ---- 2. 公证 + staple ---------------------------------------------------------
REL="$ROOT/build/release"
rm -rf "$REL"; mkdir -p "$REL"
ditto -c -k --keepParent --norsrc --noextattr "$APP" "$REL/notarize.zip"
xcrun notarytool submit "$REL/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=4 "$APP"

ASSET="CoffeeBar-$VERSION.zip"
# spctl 的评估会给 bundle 里每一项打上 com.apple.provenance；ditto 默认把 xattr 写成
# ._xxx 的 AppleDouble 条目，而 Archive Utility / unzip 解压时符号链接设不了 xattr，
# 就会在 Sparkle.framework 根目录留下实体 ._xxx 文件 —— 封印破了，Gatekeeper 报"已损坏"。
# 所以打包前清干净 xattr，并让 ditto 不写 AppleDouble。
xattr -cr "$APP"
ditto -c -k --keepParent --norsrc --noextattr "$APP" "$REL/$ASSET"

# 按用户的真实路径验一遍：普通 unzip 解出来也必须通过 Gatekeeper。
VERIFY="$REL/verify"
rm -rf "$VERIFY"; mkdir -p "$VERIFY"
(cd "$VERIFY" && unzip -q "$REL/$ASSET")
spctl --assess --type execute --verbose=4 "$VERIFY/CoffeeBar.app" \
  || die "zip 解压后 Gatekeeper 不认，检查 bundle 里的 ._* 残留"
xcrun stapler validate "$VERIFY/CoffeeBar.app" >/dev/null || die "解压后公证票丢了"
rm -rf "$VERIFY"

# ---- 3. appcast ---------------------------------------------------------------
# appcast 里只放这一版：GitHub 的下载地址按 tag 分，generate_appcast 会用同一个前缀重写所有条目。
STAGE="$ROOT/build/appcast"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp "$REL/$ASSET" "$STAGE/"
"$ROOT/.build/artifacts/sparkle/Sparkle/bin/generate_appcast" \
  --account "$KEY_ACCOUNT" \
  --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
  "$STAGE"
grep -q 'sparkle:edSignature' "$STAGE/appcast.xml" || die "appcast has no EdDSA signature (keychain account $KEY_ACCOUNT?)"

echo
echo "Prepared: $TAG (build $BUILD_NUMBER)  $REL/$ASSET"
[ "$DRY_RUN" = "0" ] || { echo "--dry-run: nothing uploaded."; exit 0; }

# ---- 4. GitHub Release --------------------------------------------------------
set -- gh release create "$TAG" "$REL/$ASSET" --repo "$REPO" --title "CoffeeBar $VERSION"
if [ -n "$NOTES_FILE" ] && [ -f "$NOTES_FILE" ]; then set -- "$@" --notes-file "$NOTES_FILE"
else set -- "$@" --notes "CoffeeBar $VERSION (build $BUILD_NUMBER)"; fi
[ "$PUBLISH" = "1" ] || set -- "$@" --draft
"$@"

if [ "$PUBLISH" != "1" ]; then
  echo "Draft created. appcast NOT pushed (draft asset URLs 404). Re-run with --publish."
  exit 0
fi

# ---- 5. 推 appcast ------------------------------------------------------------
cp "$STAGE/appcast.xml" "$ROOT/appcast.xml"
git add appcast.xml
git commit -m "release: $TAG appcast"
git push
echo
echo "Published: https://github.com/$REPO/releases/tag/$TAG"
echo "Feed:      $FEED_URL"
