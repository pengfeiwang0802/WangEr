# 王二助手 Release Notes

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
