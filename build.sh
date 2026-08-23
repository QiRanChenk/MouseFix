#!/bin/bash
# 手动打包 MouseFix.app，无需 xcodegen
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="MouseFix"
APP_DIR="$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RES_DIR="$CONTENTS/Resources"

echo "==> 清理旧产物"
rm -rf "$APP_DIR"
rm -f "$APP_NAME"

echo "==> 编译"
swiftc -O \
  -target arm64-apple-macosx12.0 \
  -framework Cocoa \
  -framework Carbon \
  -framework ApplicationServices \
  -o "$APP_NAME" \
  MouseFixApp.swift

echo "==> 拼装 .app bundle"
mkdir -p "$MACOS_DIR" "$RES_DIR"
cp "$APP_NAME" "$MACOS_DIR/$APP_NAME"
cp Info.plist "$CONTENTS/Info.plist"
chmod +x "$MACOS_DIR/$APP_NAME"

echo "==> ad-hoc 签名（关闭沙箱 + 辅助功能需要）"
codesign --force --sign - --entitlements MouseFix.entitlements "$APP_DIR"

echo "==> 验证"
codesign --verify --verbose=2 "$APP_DIR" 2>&1 | head -5

echo
echo "产物：$APP_DIR"
echo "运行：open '$APP_DIR'"
echo "授权：系统设置 → 隐私与安全性 → 辅助功能 → 启用 MouseFix"