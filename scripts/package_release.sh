#!/bin/bash
# 王二助手 Release 打包脚本
# 用法: ./scripts/package_release.sh [version]

set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/.build/arm64-apple-macosx/release"
APP_NAME="王二助手"
APP_BUNDLE="/Applications/$APP_NAME.app"

# 1. 编译 Release 版
echo "🔨 Building release..."
cd "$PROJECT_DIR"
swift build -c release

# 2. 创建 .app bundle 结构
echo "📦 Creating .app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# 3. 复制二进制
cp "$BUILD_DIR/WangErChat" "$APP_BUNDLE/Contents/MacOS/"

# 4. 复制 Info.plist
cp "$PROJECT_DIR/Sources/WangErChat/Info.plist" "$APP_BUNDLE/Contents/"

# 5. 复制外部资源文件（表情 JSON 等）
if [ -f "$PROJECT_DIR/Sources/WangErChat/avatar_expression.json" ]; then
  cp "$PROJECT_DIR/Sources/WangErChat/avatar_expression.json" "$APP_BUNDLE/Contents/Resources/"
  echo "   ✅ Copied avatar_expression.json to Resources"
fi

# 6. 设置版本号
if [ -n "$1" ]; then
  VERSION="$1"
  plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP_BUNDLE/Contents/Info.plist"
  echo "   ✅ Version set to $VERSION"
fi

# 7. 设置权限
chmod +x "$APP_BUNDLE/Contents/MacOS/WangErChat"

echo "✅ Release bundle created at $APP_BUNDLE"
echo "   Size: $(du -sh "$APP_BUNDLE" | cut -f1)"
ls -lh "$APP_BUNDLE/Contents/MacOS/WangErChat"
