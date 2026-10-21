#!/bin/bash
# 把「嬉皮小剧场.app」打包成 dmg 安装包（含 Applications 快捷方式）
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="嬉皮小剧场"
APP="$HOME/Applications/$APP_NAME.app"

# 始终先重新构建安装最新版（含图标等资源）
bash scripts/make_app.sh

DMG_DIR="dist/dmg"
DMG="dist/$APP_NAME.dmg"

rm -rf "$DMG_DIR"
mkdir -p "$DMG_DIR"

cp -R "$APP" "$DMG_DIR/"
ln -s /Applications "$DMG_DIR/Applications"

rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_DIR" -ov -format UDZO "$DMG"

rm -rf "$DMG_DIR"
echo "== dmg 已生成: $DMG =="
