#!/bin/bash
# 构建「嬉皮小剧场开源版.app」并打包成 dmg 安装包（含 Applications 快捷方式）。
# 只打包、不安装，也不碰正在运行的应用。
set -euo pipefail

cd "$(dirname "$0")/.."

if [ -d "/Applications/Xcode.app/Contents/Developer" ] && [ -z "${DEVELOPER_DIR:-}" ]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

APP_NAME="嬉皮小剧场开源版"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)

echo "== swift build -c release =="
swift build -c release

APP="dist/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Xipixiaojuchang "$APP/Contents/MacOS/Xipixiaojuchang"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -R Resources/Prompts "$APP/Contents/Resources/"
xattr -cr "$APP"
codesign --force --sign - "$APP"

DMG_DIR="dist/dmg"
# 英文文件名：GitHub Releases 会把附件名里的中文去掉
DMG="dist/Xipixiaojuchang-Open-$VERSION.dmg"
rm -rf "$DMG_DIR" "$DMG"
mkdir -p "$DMG_DIR"
cp -R "$APP" "$DMG_DIR/"
ln -s /Applications "$DMG_DIR/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_DIR" -ov -format UDZO "$DMG"
rm -rf "$DMG_DIR"
echo "== dmg 已生成: $DMG =="
