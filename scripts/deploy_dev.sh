#!/bin/bash
# 王二助手 开发版部署脚本
# 用法: ./scripts/deploy_dev.sh [version]
#
# 【设计目标】把"日常使用版"和"开发部署版"物理分开，互不干扰。
#   - 日常版: /Applications/王二助手.app        (bundle id: com.pengfei.wanger)
#   - 开发版: /Applications/王二助手_dev.app     (bundle id: com.pengfei.wanger.dev)
#
# 【安全特性】
#   1. 本脚本【完全不碰】日常版 /Applications/王二助手.app
#      - 不会 quit / kill / 替换 日常版，日常版进程一直稳定运行
#   2. 只操作开发版 /Applications/王二助手_dev.app
#      - 若开发版在跑，优雅退出后原子替换，再自动拉起
#   3. 独立 bundle id (com.pengfei.wanger.dev)，与日常版在 macOS 层面彻底隔离
#      - 各自的 UserDefaults / LaunchServices 互不污染
#   4. 全程不碰 gateway 进程
#
# 【手动替换到日常版】由用户自己用 Finder 拖拽完成，脚本不做。

set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/.build/arm64-apple-macosx/release"
APP_NAME="王二助手"
DEV_NAME="王二助手_dev"
DEV_APP="/Applications/${DEV_NAME}.app"
DEV_BUNDLE_ID="com.pengfei.wanger.dev"
STAGE_DIR="/tmp/${DEV_NAME}_stage.app"
BACKUP_DIR="/Applications/${DEV_NAME}_backup.app"

# ---------- 1. 编译 Release 版 ----------
echo "🔨 Building release..."
cd "$PROJECT_DIR"
swift build -c release

# ---------- 2. 在暂存目录构建开发版 bundle（不碰任何正在运行的 .app）----------
echo "📦 Staging dev bundle at $STAGE_DIR ..."
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR/Contents/MacOS"
mkdir -p "$STAGE_DIR/Contents/Resources"

cp "$BUILD_DIR/WangErChat" "$STAGE_DIR/Contents/MacOS/"
cp "$PROJECT_DIR/Sources/WangErChat/Info.plist" "$STAGE_DIR/Contents/"

# 复制外部资源文件
if [ -f "$PROJECT_DIR/Sources/WangErChat/avatar_expression.json" ]; then
  cp "$PROJECT_DIR/Sources/WangErChat/avatar_expression.json" "$STAGE_DIR/Contents/Resources/"
fi

# 复制 App 图标（.icns）
if [ -f "$PROJECT_DIR/Sources/WangErChat/AppIcon.icns" ]; then
  cp "$PROJECT_DIR/Sources/WangErChat/AppIcon.icns" "$STAGE_DIR/Contents/Resources/"
  echo "   ✅ Copied AppIcon.icns to Resources"
else
  echo "   ⚠️  AppIcon.icns not found, skipping icon"
fi

# 改成独立的开发版 bundle id（与日常版隔离）
plutil -replace CFBundleIdentifier -string "$DEV_BUNDLE_ID" "$STAGE_DIR/Contents/Info.plist"

# 设置版本号（可选）
if [ -n "$1" ]; then
  VERSION="$1"
  plutil -replace CFBundleShortVersionString -string "$VERSION" "$STAGE_DIR/Contents/Info.plist"
  plutil -replace CFBundleVersion -string "$VERSION" "$STAGE_DIR/Contents/Info.plist"
fi

chmod +x "$STAGE_DIR/Contents/MacOS/WangErChat"

# ---------- 3. 处理正在运行的【开发版】（优雅退出，不硬杀）----------
# 注意：只匹配开发版路径，绝不匹配日常版
WAS_RUNNING=0
if pgrep -f "$DEV_APP/Contents/MacOS/WangErChat" >/dev/null 2>&1; then
  WAS_RUNNING=1
  echo "🔄 Dev app is running. Gracefully quitting before swap..."
  osascript -e "tell application \"$DEV_NAME\" to quit" 2>/dev/null || true
  # 等待最多 10 秒让它退出
  for i in $(seq 1 20); do
    if ! pgrep -f "$DEV_APP/Contents/MacOS/WangErChat" >/dev/null 2>&1; then
      break
    fi
    sleep 0.5
  done
  # 若还没退出，强制结束（仅针对开发版）
  if pgrep -f "$DEV_APP/Contents/MacOS/WangErChat" >/dev/null 2>&1; then
    echo "⚠️  Dev app didn't quit gracefully, force quitting..."
    pkill -f "$DEV_APP/Contents/MacOS/WangErChat" || true
    sleep 1
  fi
  echo "   ✅ Dev app quit."
fi

# ---------- 4. 原子替换开发版（旧的可回滚）----------
echo "🔁 Swapping dev bundle atomically..."
if [ -d "$DEV_APP" ]; then
  rm -rf "$BACKUP_DIR"
  mv "$DEV_APP" "$BACKUP_DIR"
  echo "   ✅ Backed up old dev bundle to $BACKUP_DIR"
fi
mv "$STAGE_DIR" "$DEV_APP"
echo "   ✅ New dev bundle in place at $DEV_APP"

# ---------- 5. 若之前开发版运行中，重新拉起 ----------
if [ "$WAS_RUNNING" = "1" ]; then
  echo "🚀 Relaunching dev app..."
  open "$DEV_APP"
  echo "   ✅ Dev app relaunched."
else
  echo "ℹ️  Dev app was not running before, not auto-launching."
fi

# ---------- 6. 确认日常版未被触碰 ----------
if pgrep -f "/Applications/王二助手.app/Contents/MacOS/WangErChat" >/dev/null 2>&1; then
  echo "✅ 日常版 /Applications/王二助手.app 仍在运行，未被触碰"
else
  echo "ℹ️  日常版当前未在运行（本脚本不会主动启动它）"
fi

echo ""
echo "✅ Dev release deployed safely to $DEV_APP"
echo "   Bundle ID: $DEV_BUNDLE_ID"
echo "   Size: $(du -sh "$DEV_APP" | cut -f1)"
echo "   Backup kept at: $BACKUP_DIR (可回滚)"
echo ""
echo "📌 提示：要把开发版变成日常版，请手动用 Finder 把 $DEV_APP"
echo "   拖拽覆盖到 /Applications/王二助手.app（替换前建议先退出日常版）"
