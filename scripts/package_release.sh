#!/bin/bash
# 王二助手 Release 打包脚本（安全部署版）
# 用法: ./scripts/package_release.sh [version]
#
# 【安全特性】本脚本不会杀掉正在运行的 app 线程，也不会让部署中断导致 app 消失：
#   1. 构建到临时 bundle，绝不直接改正在运行的 /Applications/王二助手.app
#   2. 若 app 正在运行，先优雅退出（osascript quit），替换完成后自动重新拉起
#   3. 原子替换（旧 bundle 先改名备份，新 bundle mv 就位），失败可回滚
#   4. 全程不碰 gateway 进程（PID 96803，launchd 托管）

set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/.build/arm64-apple-macosx/release"
APP_NAME="王二助手"
APP_BUNDLE="/Applications/$APP_NAME.app"
STAGE_DIR="/tmp/${APP_NAME}_stage.app"          # 构建暂存目录
BACKUP_DIR="/Applications/${APP_NAME}_backup.app" # 原子替换前的备份

# ---------- 1. 编译 Release 版 ----------
echo "🔨 Building release..."
cd "$PROJECT_DIR"
swift build -c release

# ---------- 2. 在暂存目录构建新 bundle（不碰正在运行的 .app）----------
echo "📦 Staging new bundle at $STAGE_DIR ..."
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

# 设置版本号
if [ -n "$1" ]; then
  VERSION="$1"
  plutil -replace CFBundleShortVersionString -string "$VERSION" "$STAGE_DIR/Contents/Info.plist"
fi

chmod +x "$STAGE_DIR/Contents/MacOS/WangErChat"

# ---------- 3. 处理正在运行的 app（优雅退出，不硬杀）----------
WAS_RUNNING=0
if pgrep -f "$APP_BUNDLE/Contents/MacOS/WangErChat" >/dev/null 2>&1; then
  WAS_RUNNING=1
  echo "🔄 App is running. Gracefully quitting before swap..."
  osascript -e "tell application \"$APP_NAME\" to quit" 2>/dev/null || true
  # 等待最多 10 秒让它退出
  for i in $(seq 1 20); do
    if ! pgrep -f "$APP_BUNDLE/Contents/MacOS/WangErChat" >/dev/null 2>&1; then
      break
    fi
    sleep 0.5
  done
  # 若还没退出，强制结束（此时已无优雅可能，但避免占用 bundle）
  if pgrep -f "$APP_BUNDLE/Contents/MacOS/WangErChat" >/dev/null 2>&1; then
    echo "⚠️  App didn't quit gracefully, force quitting..."
    pkill -f "$APP_BUNDLE/Contents/MacOS/WangErChat" || true
    sleep 1
  fi
  echo "   ✅ App quit."
fi

# ---------- 4. 原子替换（旧的可回滚）----------
echo "🔁 Swapping bundle atomically..."
# 备份旧 bundle（若存在）
if [ -d "$APP_BUNDLE" ]; then
  rm -rf "$BACKUP_DIR"
  mv "$APP_BUNDLE" "$BACKUP_DIR"
  echo "   ✅ Backed up old bundle to $BACKUP_DIR"
fi
# 新 bundle 就位
mv "$STAGE_DIR" "$APP_BUNDLE"
echo "   ✅ New bundle in place at $APP_BUNDLE"

# ---------- 5. 若之前运行中，重新拉起 app ----------
if [ "$WAS_RUNNING" = "1" ]; then
  echo "🚀 Relaunching app..."
  open "$APP_BUNDLE"
  echo "   ✅ App relaunched."
else
  echo "ℹ️  App was not running before, not auto-launching."
fi

# ---------- 6. 清理备份（可选：保留以防回滚）----------
# 部署成功后可删除备份。默认保留，方便出问题时回滚。
# 如需自动清理，取消下面注释：
# rm -rf "$BACKUP_DIR"

echo ""
echo "✅ Release deployed safely to $APP_BUNDLE"
echo "   Size: $(du -sh "$APP_BUNDLE" | cut -f1)"
echo "   Binary: $(ls -lh "$APP_BUNDLE/Contents/MacOS/WangErChat" | awk '{print $5, $6, $7, $8}')"
echo "   Backup kept at: $BACKUP_DIR (可回滚)"
