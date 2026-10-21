#!/bin/bash
# 构建并打包「嬉皮小剧场.app」安装到 ~/Applications 并启动
set -euo pipefail

cd "$(dirname "$0")/.."

if [ -d "/Applications/Xcode.app/Contents/Developer" ] && [ -z "${DEVELOPER_DIR:-}" ]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

echo "== swift build -c release =="
swift build -c release

APP_DIR="dist"
APP="$APP_DIR/嬉皮小剧场.app"
INSTALL_DIR="$HOME/Applications"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/Xipixiaojuchang "$APP/Contents/MacOS/Xipixiaojuchang"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/"
fi
if [ -d Resources/Prompts ]; then
  cp -R Resources/Prompts "$APP/Contents/Resources/"
fi

# ad-hoc 签名（本地构建无 quarantine；同时稳定 Keychain 访问）
xattr -cr "$APP"
codesign --force --sign - "$APP"

mkdir -p "$INSTALL_DIR"
BIN="$INSTALL_DIR/嬉皮小剧场.app/Contents/MacOS/Xipixiaojuchang"

# 先让旧实例退出，再换文件（open 遇同 bundle id 的旧实例只会激活旧实例，不启动新版）。
# 新版收到 TERM 会正常退出（先落盘、清掉「运行中」标记）；还没带这个处理的旧版会被直接结束，
# 所以最多等 10 秒，等不到再强杀。
if pgrep -f "$BIN" >/dev/null 2>&1; then
  echo "== 让旧版退出（先存盘）=="
  pkill -TERM -f "$BIN" 2>/dev/null || true
  for _ in $(seq 1 40); do
    pgrep -f "$BIN" >/dev/null 2>&1 || break
    sleep 0.25
  done
  pkill -KILL -f "$BIN" 2>/dev/null || true
fi

rm -rf "$INSTALL_DIR/嬉皮小剧场.app"
cp -R "$APP" "$INSTALL_DIR/"

echo "== 已安装到 $INSTALL_DIR/嬉皮小剧场.app =="
open "$INSTALL_DIR/嬉皮小剧场.app"
