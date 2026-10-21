#!/bin/bash
# 从源图片生成 AppIcon.icns（默认取桌面「嬉皮小剧场.JPG」，可传参指定）
set -euo pipefail

cd "$(dirname "$0")/.."

SRC="${1:-$HOME/Desktop/嬉皮小剧场.JPG}"
ICONSET="dist/AppIcon.iconset"

if [ ! -f "$SRC" ]; then
  echo "找不到图片: $SRC" >&2
  exit 1
fi

rm -rf "$ICONSET"
mkdir -p "$ICONSET"

# 用 AppKit 生成带 alpha 的各尺寸 PNG（iconutil 需要 RGBA，sips 转 JPEG 是 RGB 会失败）
swift scripts/make_icon.swift "$SRC" "$ICONSET"
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
rm -rf "$ICONSET"

echo "== AppIcon.icns 已生成到 Resources/ =="
