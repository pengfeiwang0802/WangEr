# 王二助手 Release Notes

## v0.4.21 — 修复输入框上拖时聊天区底边不跟随

### 修复

- **输入框向上拖拽时聊天区底边同步上移** — 调整高度后立即强制 `layoutSubtreeIfNeeded()`，拖动过程中每帧重排，不再等到 mouseUp 才刷新
- **v0.4.20 打包产物是"半新半旧"** — 上次 `swift build -c release` 复用了 9 月的旧目标文件（`ChatViewController.swift.o` 停留在 Sep 10），导致发布包里聊天区布局仍是旧逻辑。本次先清空 release 产物再全量编译，19 个目标文件时间戳全部一致

### 版本

- `0.4.21`，重装方式不变：`scripts/package_release.sh 0.4.21`

## v0.4.20 — 输入框可拖拽 + 模型改名收口

### 新增功能

- **输入框高度可拖拽调整** — 输入框上方新增 8pt 拖拽条，上下拖动改高度，双击恢复默认 72pt；高度自动记忆（UserDefaults `inputAreaHeight`），上限为窗口高度 65%，聊天区至少保留 100pt

### 修复与加固

- **模型改名收口** — 全面切换到 `deepseek/deepseek-flash`（DeepSeek-V4.1-Flash-1017）
  - `Models.retiredAliases` 自动把旧 id `deepseek/deepseek-v4-flash` 归一到新 id，旧数据不再触发 400
  - 会话级模型持久化：`Conversation.model` 记录每个会话使用的模型，切换会话时恢复
  - 模型选择收敛为唯一入口 `currentModelId`（菜单、底栏、请求头统一读到它）
- **Kimi 余额查询** — 超时 10s → 30s，改用 ephemeral session 避免共享缓存/连接池问题
- **历史会话滚动** — 恢复历史会话时滚动条正确停在底部

### 版本说明

- 版本号 `0.4.20`：`0.4.11`–`0.4.19` 已被编剧助手时期的历史 tag 占用，故顺延

## v0.3.1 — 从能用变好用

> 里程碑版本：完成从 0 到 1 的基本功能闭环

### 新增功能

- **快捷键支持** — 输入框支持 Cmd+A/C/V/X/Z/Shift+Z（全选/复制/粘贴/剪切/撤销/重做）
- **消息可选** — 聊天框消息气泡文字可选中、复制

### 界面优化

- **Sidebar 文字居中** — 会话列表和 Agents 列表文字垂直居中，不再贴底
- **版本号显示修复** — Debug 编译不再显示 `v?.?.?`，兜底显示硬编码版本号

### 代码重构

- **ChatViewController.swift 分拆为 12 个文件**（2217 行 → 1792 行）
  - `Models.swift` — 数据模型
  - `Utils.swift` — 工具函数
  - `DropTargetView.swift` — 文件拖拽叠加层
  - `SendTextView.swift` — 输入框子类
  - `ChatViewController+WebKit.swift` — WKWebView 协议实现
  - `ChatViewController+Extensions.swift` — TableView/TextField 代理
- 每步编译验证 + 本地 tag 记录，零部署风险

### 技术细节

- 纯 Swift + AppKit + WKWebView
- Apple Silicon arm64
- 无外部依赖
- 版本号来源：Info.plist（release）→ 硬编码兜底（debug）
