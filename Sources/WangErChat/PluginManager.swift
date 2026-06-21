import AppKit
import WebKit
import SWS

// MARK: - Plugin 协议（草案阶段，最小接口）
protocol WangErPlugin: AnyObject {
    /// Plugin 名称
    var name: String { get }
    /// Plugin 描述
    var pluginDescription: String { get }
    /// 创建 Plugin 窗口
    func createWindow() -> NSWindow
}

// MARK: - PluginManager（MVP：仅管理 Plugin 列表和窗口打开）
class PluginManager: NSObject {
    static let shared = PluginManager()

    /// 已注册的 Plugin（MVP 硬编码，后续从目录扫描）
    private var plugins: [String: WangErPlugin] = [:]
    /// 已打开的窗口（key: plugin name）
    private var openWindows: [String: NSWindow] = [:]

    private override init() {
        super.init()
        registerDefaultPlugins()
    }

    private func registerDefaultPlugins() {
        // 注册编剧助手 Plugin
        let scriptwritingPlugin = ScriptwritingPlugin()
        plugins[scriptwritingPlugin.name] = scriptwritingPlugin
    }

    /// 获取所有 Plugin 名称列表
    var pluginNames: [String] {
        Array(plugins.keys).sorted()
    }

    /// 打开 Plugin 窗口（如果已打开则前置）
    func openPlugin(_ name: String) {
        guard let plugin = plugins[name] else {
            print("PluginManager: Plugin '\(name)' 未注册")
            return
        }

        if let existingWindow = openWindows[name] {
            existingWindow.makeKeyAndOrderFront(nil)
            return
        }

        let window = plugin.createWindow()
        window.isReleasedWhenClosed = false
        window.delegate = self
        openWindows[name] = window
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - NSWindowDelegate（跟踪窗口关闭）
extension PluginManager: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        // 延迟到下一个 run loop 移除，避免窗口关闭流程中释放导致 crash
        DispatchQueue.main.async { [weak self] in
            for (name, w) in self?.openWindows ?? [:] where w === window {
                self?.openWindows.removeValue(forKey: name)
                break
            }
        }
    }
}

// MARK: - 编剧助手 Plugin
class ScriptwritingPlugin: NSObject, WangErPlugin {
    let name = "编剧助手"
    let pluginDescription = "AI 辅助剧本创作与一致性分析"

    /// 当前加载的 .sws 文件路径
    private var currentFileURL: URL?
    /// 当前解析的文档（用于重新渲染）
    private var currentDocument: SWSDocument?
    /// 当前使用的显示样式
    private var currentStyle: DisplayStyle = .chineseStandard

    func createWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 750),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "✍️ 编剧助手"
        window.minSize = NSSize(width: 780, height: 500)
        window.center()

        let webView = WKWebView(frame: .zero)
        webView.translatesAutoresizingMaskIntoConstraints = false

        // 透明背景，让 HTML 的深色主题透出
        webView.setValue(false, forKey: "drawsBackground")

        guard let contentView = window.contentView else { return window }
        contentView.addSubview(webView)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: contentView.topAnchor),
            webView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        // 先加载默认空布局
        webView.loadHTMLString(ScriptwritingLayout.html, baseURL: nil)

        // 添加工具栏按钮（通过 WKWebView 的 JS 通信，或直接加 NSButton 到 window）
        setupToolbar(in: window, webView: webView)

        return window
    }

    // MARK: - 工具栏

    private func setupToolbar(in window: NSWindow, webView: WKWebView) {
        let toolbar = NSToolbar(identifier: "ScriptwritingToolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
    }

    // MARK: - 加载 .sws 文件

    @objc func openSWSFile(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "打开剧本文件"
        panel.allowedContentTypes = [.init(filenameExtension: "sws") ?? .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadSWSFile(url: url)
    }

    func loadSWSFile(url: URL) {
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            var formatter = SWSFormatter()
            let document = formatter.deserialize(text)
            currentFileURL = url
            currentDocument = document

            // 更新窗口标题
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "scriptwriting" }) ??
                NSApp.windows.first(where: { $0.title.hasPrefix("✍️") }) {
                window.title = "✍️ \(url.lastPathComponent)"
            }

            renderCurrentDocument()
        } catch {
            print("ScriptwritingPlugin: 加载文件失败 \(error)")
        }
    }

    private func renderCurrentDocument() {
        guard let document = currentDocument else { return }

        // 找到该插件窗口的 WKWebView
        guard let window = NSApp.windows.first(where: { $0.title.contains("编剧助手") || $0.title.hasSuffix(".sws") }),
              let contentView = window.contentView,
              let webView = contentView.subviews.first(where: { $0 is WKWebView }) as? WKWebView else {
            return
        }

        let bodyHTML = SWSRenderer.renderBody(document: document, style: currentStyle)
        // 通过 JS 只替换编辑器区域，保留 UI 布局
        let escaped = bodyHTML
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "")
        let js = "document.getElementById('editor-body').innerHTML = \"\(escaped)\";"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    @objc func reloadFile(_ sender: Any?) {
        guard let url = currentFileURL else { return }
        loadSWSFile(url: url)
    }

    @objc func toggleDialogueLayout(_ sender: Any?) {
        // 循环切换预设样式
        let all = DisplayStyle.presets
        let idx = all.firstIndex(where: { $0.name == currentStyle.name }) ?? 0
        let next = all[(idx + 1) % all.count]
        currentStyle = next
        renderCurrentDocument()
    }
}

// MARK: - NSToolbarDelegate

extension ScriptwritingPlugin: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .openFile, .reload, .toggleLayout, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .openFile:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "打开"
            item.paletteLabel = "打开 .sws"
            item.toolTip = "打开 .sws 剧本文件"
            item.image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: "打开")
            item.target = self
            item.action = #selector(openSWSFile(_:))
            return item
        case .reload:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "刷新"
            item.paletteLabel = "重新加载"
            item.toolTip = "重新加载当前文件"
            item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新")
            item.target = self
            item.action = #selector(reloadFile(_:))
            return item
        case .toggleLayout:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "布局"
            item.paletteLabel = "切换对白布局"
            item.toolTip = "切换对白显示布局"
            item.image = NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: "布局")
            item.target = self
            item.action = #selector(toggleDialogueLayout(_:))
            return item
        default:
            return nil
        }
    }
}

private extension NSToolbarItem.Identifier {
    static let openFile = NSToolbarItem.Identifier("com.wanger.openSWS")
    static let reload = NSToolbarItem.Identifier("com.wanger.reloadSWS")
    static let toggleLayout = NSToolbarItem.Identifier("com.wanger.toggleLayout")
}

// MARK: - 编剧助手 UI 布局
enum ScriptwritingLayout {
    /// 额外 CSS，注入到 SWSRenderer 的 HTML 中
    static let extraCSS = """
        /* 编辑器区域覆盖 SWS 默认样式 */
        #editor-area .editor-body {
            padding: 32px 48px;
            max-width: 720px;
            margin: 0 auto;
        }
        #editor-area .editor-body .sws-scene-heading {
            font-weight: 700;
            font-size: 1.05em;
            text-align: left;
            margin: 20px 0 8px;
            color: var(--gold);
        }
        #editor-area .editor-body .sws-action {
            margin: 8px 0;
            line-height: 1.7;
        }
        #editor-area .editor-body .sws-character {
            text-align: center;
            font-weight: 700;
            margin: 16px 0 0;
        }
        #editor-area .editor-body .sws-parenthetical {
            text-align: left;
            font-style: italic;
            margin: 2px 0 0;
            padding-left: 2.5em;
            color: var(--text-secondary);
            font-size: 0.9em;
        }
        #editor-area .editor-body .sws-dialogue {
            margin: 2px 0 8px;
            padding: 0 3em;
            line-height: 1.5;
        }
        #editor-area .editor-body .sws-unattributed {
            margin: 8px 0;
            padding: 0 3em;
            line-height: 1.5;
            font-style: italic;
            color: var(--text-muted);
        }
        #editor-area .editor-body .sws-quote {
            margin: 8px 0;
            padding: 8px 3em;
            border-left: 3px solid var(--accent);
            background: var(--accent-soft);
            line-height: 1.5;
        }
        #editor-area .editor-body .sws-separator {
            text-align: center;
            margin: 20px 0;
            color: var(--text-muted);
            opacity: 0.4;
        }
    """

    static let html = """
    <!DOCTYPE html>
    <html lang="zh-CN">
    <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
            :root {
                --bg-primary:   #1a1a2e;
                --bg-secondary: #222240;
                --bg-tertiary:  #2a2a4a;
                --bg-editor:    #1e1e32;
                --border:       #3a3a55;
                --text-primary: #e0e0e0;
                --text-secondary: #a0a0b0;
                --text-muted:   #6a6a80;
                --accent:       #e94560;
                --accent-soft:  rgba(233,69,96,0.15);
                --gold:         #f5a623;
                --sidebar-w:    200px;
                --topbar-h:     44px;
                --storybar-h:  130px;
            }

            * { margin: 0; padding: 0; box-sizing: border-box; }

            body {
                font-family: -apple-system, "PingFang SC", "Noto Sans SC", "Helvetica Neue", sans-serif;
                background: var(--bg-primary);
                color: var(--text-primary);
                height: 100vh;
                display: flex;
                flex-direction: column;
                overflow: hidden;
                user-select: none;
            }

            /* ========== 剧情轴 Topbar（时间轴） ========== */
            #storybar {
                height: var(--storybar-h);
                min-height: var(--storybar-h);
                background: var(--bg-secondary);
                border-bottom: 1px solid var(--border);
                display: flex;
                flex-direction: column;
                overflow: hidden;
                z-index: 11;
            }
            .storybar-header {
                height: 26px;
                min-height: 26px;
                display: flex;
                align-items: center;
                padding: 0 12px;
                justify-content: space-between;
            }
            .storybar-header .left {
                display: flex;
                align-items: center;
                gap: 8px;
            }
            .storybar-header .label {
                font-size: 0.7em;
                color: var(--text-muted);
                text-transform: uppercase;
                letter-spacing: 1.2px;
                font-weight: 700;
            }
            .storybar-header .hint {
                font-size: 0.62em;
                color: var(--text-muted);
                opacity: 0.4;
            }
            .storybar-header .toggles {
                display: flex;
                gap: 6px;
            }
            .storybar-header .toggle {
                font-size: 0.62em;
                padding: 2px 8px;
                border-radius: 8px;
                border: 1px solid var(--border);
                background: transparent;
                color: var(--text-muted);
                cursor: pointer;
                display: flex;
                align-items: center;
                gap: 4px;
                transition: all 0.15s;
            }
            .storybar-header .toggle:hover {
                border-color: var(--text-secondary);
                color: var(--text-secondary);
            }
            .storybar-header .toggle.on {
                border-color: var(--accent);
                color: var(--accent);
                background: var(--accent-soft);
            }
            .storybar-header .toggle .dot {
                width: 6px; height: 6px;
                border-radius: 50%;
                background: currentColor;
                flex-shrink: 0;
            }
            .storybar-timeline {
                flex: 1;
                position: relative;
                padding: 4px 12px 2px;
            }
            /* 剧情块行 */
            .story-blocks {
                display: flex;
                height: 34px;
                gap: 4px;
                align-items: stretch;
            }
            .story-block {
                border-radius: 6px;
                cursor: pointer;
                display: flex;
                flex-direction: column;
                align-items: center;
                justify-content: center;
                font-size: 0.72em;
                font-weight: 600;
                color: rgba(255,255,255,0.9);
                text-shadow: 0 1px 2px rgba(0,0,0,0.3);
                transition: all 0.15s;
                overflow: hidden;
                position: relative;
            }
            .story-block:hover {
                filter: brightness(1.15);
                transform: translateY(-1px);
                box-shadow: 0 2px 8px rgba(0,0,0,0.3);
            }
            .story-block .block-label {
                z-index: 1;
                pointer-events: none;
            }
            .story-block .block-tone {
                font-size: 0.65em;
                font-weight: 400;
                opacity: 0.7;
                z-index: 1;
                pointer-events: none;
            }
            /* 每个剧块的颜色渐变（由 data-tone 驱动） */
            .story-block[data-tone="warm"]  { background: linear-gradient(135deg, #d4834a, #e8a44a); }
            .story-block[data-tone="cool"]  { background: linear-gradient(135deg, #4a6fa5, #6a8fc5); }
            .story-block[data-tone="tense"] { background: linear-gradient(135deg, #6b3a6b, #8b4a7b); }
            .story-block[data-tone="hot"]   { background: linear-gradient(135deg, #b93a3a, #d44a4a); }
            .story-block[data-tone="calm"]  { background: linear-gradient(135deg, #3a7a5a, #4a8a6a); }
            /* 关键帧标记 */
            .keyframe-layer {
                position: relative;
                height: 18px;
                margin: 0 12px;
            }
            .keyframe-marker {
                position: absolute;
                transform: translateX(-50%);
                cursor: pointer;
                display: flex;
                flex-direction: column;
                align-items: center;
                transition: all 0.15s;
            }
            .keyframe-marker .pin {
                width: 14px; height: 14px;
                border-radius: 2px 2px 50% 50%;
                background: var(--accent);
                margin-bottom: 2px;
                box-shadow: 0 1px 3px rgba(0,0,0,0.3);
                position: relative;
            }
            .keyframe-marker .pin::after {
                content: '';
                position: absolute;
                top: -4px; left: 3px;
                width: 8px; height: 6px;
                background: rgba(255,255,255,0.4);
                border-radius: 50%;
            }
            .keyframe-marker:hover .pin {
                background: #ff5a70;
                transform: scale(1.15);
            }
            .keyframe-marker .kf-label {
                font-size: 0.55em;
                color: var(--text-muted);
                white-space: nowrap;
                text-align: center;
                line-height: 1.2;
            }
            /* 情绪曲线层 */
            .curve-layer {
                position: absolute;
                bottom: 0;
                left: 12px;
                right: 12px;
                height: 50px;
                pointer-events: none;
            }
            .curve-layer svg {
                width: 100%;
                height: 100%;
            }
            .curve-layer .curve-line {
                fill: none;
                stroke-width: 1.5;
                opacity: 0.6;
                transition: opacity 0.3s;
            }
            .curve-layer .curve-line.hidden {
                opacity: 0;
            }

            /* ========== 场次 Topbar ========== */
            #topbar {
                height: var(--topbar-h);
                min-height: var(--topbar-h);
                background: var(--bg-secondary);
                border-bottom: 1px solid var(--border);
                display: flex;
                align-items: center;
                padding: 0 16px;
                gap: 12px;
                z-index: 10;
            }
            #topbar .scene-label {
                font-size: 0.75em;
                color: var(--text-muted);
                text-transform: uppercase;
                letter-spacing: 1px;
            }
            #topbar .scene-selector {
                display: flex;
                align-items: center;
                gap: 8px;
                flex: 1;
            }
            #topbar .scene-nav {
                width: 28px; height: 28px;
                border-radius: 6px;
                border: 1px solid var(--border);
                background: var(--bg-tertiary);
                color: var(--text-secondary);
                cursor: pointer;
                font-size: 0.85em;
                display: flex;
                align-items: center;
                justify-content: center;
                transition: all 0.15s;
            }
            #topbar .scene-nav:hover {
                background: var(--accent-soft);
                border-color: var(--accent);
                color: var(--accent);
            }
            #topbar .scene-title {
                font-size: 0.95em;
                font-weight: 600;
                color: var(--text-primary);
                padding: 4px 10px;
                border-radius: 4px;
                background: transparent;
                border: 1px solid transparent;
                cursor: text;
                min-width: 120px;
            }
            #topbar .scene-title:hover {
                background: var(--bg-tertiary);
            }
            #topbar .scene-meta {
                font-size: 0.8em;
                color: var(--text-muted);
                display: flex;
                gap: 6px;
            }
            #topbar .scene-meta span {
                padding: 2px 8px;
                border-radius: 4px;
                background: var(--bg-tertiary);
                border: 1px solid var(--border);
                font-size: 0.85em;
            }
            #topbar .divider {
                width: 1px;
                height: 20px;
                background: var(--border);
                margin: 0 4px;
            }
            #topbar .btn-build {
                margin-left: auto;
                padding: 5px 14px;
                border-radius: 6px;
                border: 1px solid var(--accent);
                background: var(--accent-soft);
                color: var(--accent);
                font-size: 0.85em;
                font-weight: 600;
                cursor: pointer;
                transition: all 0.15s;
            }
            #topbar .btn-build:hover {
                background: var(--accent);
                color: #fff;
            }

            /* ========== Main Body ========== */
            #main-body {
                flex: 1;
                display: flex;
                overflow: hidden;
            }

            /* ========== Sidebar (角色) ========== */
            #sidebar {
                width: var(--sidebar-w);
                min-width: 160px;
                background: var(--bg-secondary);
                border-right: 1px solid var(--border);
                display: flex;
                flex-direction: column;
                overflow: hidden;
            }
            #sidebar .sidebar-header {
                padding: 12px 14px 8px;
                font-size: 0.75em;
                font-weight: 700;
                text-transform: uppercase;
                letter-spacing: 1.2px;
                color: var(--text-muted);
                display: flex;
                align-items: center;
                justify-content: space-between;
            }
            #sidebar .sidebar-header .count {
                font-size: 0.85em;
                color: var(--text-secondary);
                font-weight: 400;
            }
            #sidebar .add-char {
                width: 22px; height: 22px;
                border-radius: 5px;
                border: 1px dashed var(--border);
                background: transparent;
                color: var(--text-muted);
                cursor: pointer;
                font-size: 1em;
                line-height: 1;
                display: flex;
                align-items: center;
                justify-content: center;
                transition: all 0.15s;
            }
            #sidebar .add-char:hover {
                border-color: var(--gold);
                color: var(--gold);
                background: rgba(245,166,35,0.1);
            }
            #sidebar .char-list {
                flex: 1;
                overflow-y: auto;
                padding: 4px 8px;
            }
            #sidebar .char-item {
                padding: 8px 10px;
                border-radius: 6px;
                cursor: pointer;
                font-size: 0.9em;
                display: flex;
                align-items: center;
                gap: 8px;
                transition: all 0.12s;
                margin-bottom: 2px;
            }
            #sidebar .char-item:hover {
                background: var(--bg-tertiary);
            }
            #sidebar .char-item.active {
                background: var(--accent-soft);
                border: 1px solid rgba(233,69,96,0.25);
            }
            #sidebar .char-item .avatar {
                width: 28px; height: 28px;
                border-radius: 50%;
                background: var(--bg-tertiary);
                display: flex;
                align-items: center;
                justify-content: center;
                font-size: 0.85em;
                flex-shrink: 0;
            }
            #sidebar .char-item .info {
                display: flex;
                flex-direction: column;
                min-width: 0;
            }
            #sidebar .char-item .name {
                font-size: 0.9em;
                font-weight: 600;
                white-space: nowrap;
                overflow: hidden;
                text-overflow: ellipsis;
            }
            #sidebar .char-item .role {
                font-size: 0.7em;
                color: var(--text-muted);
            }
            #sidebar .sidebar-footer {
                padding: 8px;
                border-top: 1px solid var(--border);
                display: flex;
                gap: 4px;
            }
            #sidebar .sidebar-footer button {
                flex: 1;
                padding: 5px 0;
                font-size: 0.7em;
                border-radius: 4px;
                border: 1px solid var(--border);
                background: var(--bg-tertiary);
                color: var(--text-secondary);
                cursor: pointer;
                transition: all 0.15s;
            }
            #sidebar .sidebar-footer button:hover {
                background: var(--accent-soft);
                border-color: var(--accent);
                color: var(--text-primary);
            }

            /* ========== Editor ========== */
            #editor-area {
                flex: 1;
                display: flex;
                flex-direction: column;
                overflow: hidden;
                background: var(--bg-editor);
            }
            #editor-area .editor-toolbar {
                height: 32px;
                min-height: 32px;
                background: var(--bg-primary);
                border-bottom: 1px solid var(--border);
                display: flex;
                align-items: center;
                padding: 0 12px;
                gap: 6px;
            }
            #editor-area .editor-toolbar button {
                width: 26px; height: 24px;
                border-radius: 4px;
                border: none;
                background: transparent;
                color: var(--text-secondary);
                cursor: pointer;
                font-size: 0.8em;
                display: flex;
                align-items: center;
                justify-content: center;
                transition: all 0.12s;
            }
            #editor-area .editor-toolbar button:hover {
                background: var(--bg-tertiary);
                color: var(--text-primary);
            }
            #editor-area .editor-toolbar .sep {
                width: 1px; height: 16px;
                background: var(--border);
                margin: 0 4px;
            }
            #editor-area .editor-body {
                flex: 1;
                overflow-y: auto;
                padding: 32px 48px;
            }
            #editor-area .editor-body:focus {
                outline: none;
            }

            /* ========== 剧本格式定义 ========== */
            #editor-area .editor-body .scene-heading {
                font-weight: 700;
                font-size: 1.05em;
                text-align: left;
                margin: 20px 0 8px;
                color: var(--gold);
            }
            #editor-area .editor-body .action {
                margin: 8px 0;
                line-height: 1.7;
            }
            #editor-area .editor-body .character {
                text-align: center;
                font-weight: 700;
                margin: 16px 0 0;
                padding-left: 2em;
            }
            #editor-area .editor-body .parenthetical {
                text-align: left;
                font-style: italic;
                margin: 2px 0 0;
                padding-left: 2.5em;
                color: var(--text-secondary);
                font-size: 0.9em;
            }
            #editor-area .editor-body .dialogue {
                margin: 2px 0 8px;
                padding: 0 3em;
                line-height: 1.5;
            }
            #editor-area .editor-body .transition {
                text-align: right;
                margin: 12px 0;
                font-style: italic;
                color: var(--text-muted);
            }

            /* ========== 侧边栏折叠 ========== */
            #sidebar.collapsed {
                width: 0;
                min-width: 0;
                border-right: none;
                overflow: hidden;
            }
            #sidebar.collapsed > * { display: none; }

            /* ========== 滚动条 ========== */
            ::-webkit-scrollbar { width: 6px; }
            ::-webkit-scrollbar-track { background: transparent; }
            ::-webkit-scrollbar-thumb { background: var(--border); border-radius: 3px; }
            ::-webkit-scrollbar-thumb:hover { background: var(--text-muted); }

            /* ========== Resize Handle ========== */
            #resize-handle {
                width: 3px;
                cursor: col-resize;
                background: transparent;
                transition: background 0.15s;
                flex-shrink: 0;
            }
            #resize-handle:hover,
            #resize-handle.dragging {
                background: var(--accent);
            }
        </style>
    </head>
    <body>

    <!-- ===== 剧情轴 Topbar（时间轴） ===== -->
    <div id="storybar">
        <div class="storybar-header">
            <div class="left">
                <span class="label">🎬 剧情轴</span>
                <span class="hint">Build 后自动生成</span>
            </div>
            <div class="toggles" id="curve-toggles">
                <button class="toggle on" data-char="zhangsan">
                    <span class="dot" style="color:#e8a44a;"></span> 张三
                </button>
                <button class="toggle on" data-char="lisi">
                    <span class="dot" style="color:#6a9fc5;"></span> 李四
                </button>
                <button class="toggle on" data-char="wangwu">
                    <span class="dot" style="color:#7a7a9a;"></span> 王五
                </button>
            </div>
        </div>
        <div class="storybar-timeline" id="timeline">
            <!-- 剧情块 -->
            <div class="story-blocks">
                <div class="story-block" data-tone="warm" style="width:22%;" data-scene="1" title="开场 · 建立世界观">
                    <span class="block-label">开端</span>
                    <span class="block-tone">暖 · 希望</span>
                </div>
                <div class="story-block" data-tone="cool" style="width:30%;" data-scene="2" title="冲突升级 · 人物成长">
                    <span class="block-label">发展</span>
                    <span class="block-tone">冷 · 挣扎</span>
                </div>
                <div class="story-block" data-tone="hot" style="width:24%;" data-scene="3" title="最大冲突 · 命运转折">
                    <span class="block-label">高潮</span>
                    <span class="block-tone">灼 · 激化</span>
                </div>
                <div class="story-block" data-tone="calm" style="width:24%;" data-scene="4" title="冲突解决 · 新平衡">
                    <span class="block-label">结局</span>
                    <span class="block-tone">静 · 释然</span>
                </div>
            </div>
            <!-- 关键帧 -->
            <div class="keyframe-layer">
                <div class="keyframe-marker" style="left:11%;" data-scene="1" title="故事开始">
                    <div class="pin"></div>
                    <span class="kf-label">开场</span>
                </div>
                <div class="keyframe-marker" style="left:37%;" data-scene="2" title="突发事件打破日常">
                    <div class="pin"></div>
                    <span class="kf-label">突发事件</span>
                </div>
                <div class="keyframe-marker" style="left:64%;" data-scene="3" title="人物关系重大转折">
                    <div class="pin"></div>
                    <span class="kf-label">人物背叛</span>
                </div>
                <div class="keyframe-marker" style="left:88%;" data-scene="4" title="最终和解">
                    <div class="pin"></div>
                    <span class="kf-label">和解</span>
                </div>
            </div>
            <!-- 情绪曲线 -->
            <div class="curve-layer">
                <svg viewBox="0 0 1000 50" preserveAspectRatio="none">
                    <!-- 张三 情绪曲线（暖橙） -->
                    <path class="curve-line" id="curve-zhangsan"
                        d="M0,30 C120,28 180,20 260,25 C340,30 380,40 480,35 C580,30 620,8 720,15 C820,22 900,18 1000,25"
                        stroke="#e8a44a" />
                    <!-- 李四 情绪曲线（冷蓝） -->
                    <path class="curve-line" id="curve-lisi"
                        d="M0,22 C100,20 160,32 250,28 C340,24 400,12 500,20 C600,28 660,38 760,30 C860,22 920,18 1000,22"
                        stroke="#6a9fc5" />
                    <!-- 王五 情绪曲线（灰紫） -->
                    <path class="curve-line" id="curve-wangwu"
                        d="M0,18 C140,16 200,34 300,22 C400,10 460,5 560,15 C660,25 720,35 820,28 C920,21 980,20 1000,22"
                        stroke="#8a8aaa" />
                </svg>
            </div>
        </div>
    </div>

    <!-- ===== 场次 Topbar ===== -->
    <div id="topbar">
        <span class="scene-label">📍 当前场次</span>
        <div class="scene-selector">
            <button class="scene-nav" title="上一场">◀</button>
            <div class="scene-title" contenteditable="true">第 1 场 · 开场</div>
            <button class="scene-nav" title="下一场">▶</button>
        </div>
        <div class="divider"></div>
        <div class="scene-meta">
            <span>🏠 内景</span>
            <span>☀️ 白天</span>
        </div>
        <button class="btn-build" title="AI 分析剧本一致性">🔍 Build</button>
    </div>

    <!-- ===== Main Body ===== -->
    <div id="main-body">

        <!-- ===== Sidebar ===== -->
        <div id="sidebar">
            <div class="sidebar-header">
                <span>👥 角色</span>
                <span class="count">3</span>
                <button class="add-char" title="添加角色">+</button>
            </div>
            <div class="char-list" id="char-list">
                <div class="char-item active" data-char="zhangsan">
                    <div class="avatar">🧔</div>
                    <div class="info">
                        <div class="name">张三</div>
                        <div class="role">主角 · 男 · 32岁</div>
                    </div>
                </div>
                <div class="char-item" data-char="lisi">
                    <div class="avatar">👩</div>
                    <div class="info">
                        <div class="name">李四</div>
                        <div class="role">配角 · 女 · 28岁</div>
                    </div>
                </div>
                <div class="char-item" data-char="wangwu">
                    <div class="avatar">👨‍🦳</div>
                    <div class="info">
                        <div class="name">王五</div>
                        <div class="role">配角 · 男 · 55岁</div>
                    </div>
                </div>
            </div>
            <div class="sidebar-footer">
                <button title="打开角色面板">📋 详情</button>
                <button title="从剧本提取角色">🔄 提取</button>
            </div>
        </div>

        <!-- ===== Resize Handle ===== -->
        <div id="resize-handle"></div>

        <!-- ===== Editor ===== -->
        <div id="editor-area">
            <div class="editor-toolbar">
                <button title="场景标题">🎬</button>
                <button title="动作/描述">📝</button>
                <button title="角色名">👤</button>
                <button title="台词">💬</button>
                <button title="转场">🔄</button>
                <span class="sep"></span>
                <button title="加粗"><b>B</b></button>
                <button title="斜体"><i>I</i></button>
                <span class="sep"></span>
                <button title="折叠侧边栏" id="btn-toggle-sidebar">📂</button>
            </div>
            <div class="editor-body" contenteditable="true" id="editor-body">
                <div class="scene-heading">第 1 场 · 内景 · 张三的公寓 · 白天</div>
                <div class="action">阳光透过半掩的窗帘洒进房间，空气中飘着咖啡的香气。张三坐在书桌前，盯着电脑屏幕发呆。桌上堆满了文件和空咖啡杯。</div>
                <div class="character">张三</div>
                <div class="parenthetical">（揉了揉眼睛，叹了口气）</div>
                <div class="dialogue">又是新的一天……到底该从哪里开始呢？</div>
                <div class="action">他站起身，走到窗边，拉开窗帘。楼下的街道已经开始忙碌起来。</div>
                <div class="character">李四</div>
                <div class="parenthetical">（从门外探头进来）</div>
                <div class="dialogue">还在发呆？会议十点就开始了！</div>
                <div class="dialogue">你不会又熬夜了吧？</div>
            </div>
        </div>

    </div>

    <script>
        // ===== Sidebar 折叠 =====
        const sidebar = document.getElementById('sidebar');
        const btnToggle = document.getElementById('btn-toggle-sidebar');
        btnToggle.addEventListener('click', () => {
            sidebar.classList.toggle('collapsed');
            btnToggle.textContent = sidebar.classList.contains('collapsed') ? '📂' : '📂';
        });

        // ===== 角色选中 =====
        document.getElementById('char-list').addEventListener('click', (e) => {
            const item = e.target.closest('.char-item');
            if (!item) return;
            document.querySelectorAll('.char-item').forEach(el => el.classList.remove('active'));
            item.classList.add('active');
        });

        // ===== 侧边栏拖拽调整宽度 =====
        const handle = document.getElementById('resize-handle');
        let dragging = false;
        let startX, startW;

        handle.addEventListener('mousedown', (e) => {
            dragging = true;
            startX = e.clientX;
            startW = sidebar.offsetWidth;
            handle.classList.add('dragging');
            document.body.style.cursor = 'col-resize';
            document.body.style.userSelect = 'none';
            e.preventDefault();
        });

        document.addEventListener('mousemove', (e) => {
            if (!dragging) return;
            const dx = e.clientX - startX;
            const newW = Math.max(140, Math.min(380, startW + dx));
            sidebar.style.width = newW + 'px';
            sidebar.style.minWidth = newW + 'px';
        });

        document.addEventListener('mouseup', () => {
            if (!dragging) return;
            dragging = false;
            handle.classList.remove('dragging');
            document.body.style.cursor = '';
            document.body.style.userSelect = '';
        });

        // ===== Editor 工具栏按钮（纯 UI，暂无功能） =====
        document.querySelectorAll('#editor-area .editor-toolbar button').forEach(btn => {
            btn.addEventListener('click', () => {
                btn.style.color = 'var(--accent)';
                setTimeout(() => { btn.style.color = ''; }, 200);
            });
        });

        // ===== 剧情块点击（跳转到对应场次，占位） =====
        document.querySelectorAll('.story-block').forEach(block => {
            block.addEventListener('click', () => {
                const scene = block.dataset.scene;
                console.log('跳转到场次:', scene);
                // 短暂高亮反馈
                block.style.filter = 'brightness(1.4)';
                setTimeout(() => { block.style.filter = ''; }, 300);
            });
        });

        // ===== 关键帧点击（跳转到对应位置，占位） =====
        document.querySelectorAll('.keyframe-marker').forEach(marker => {
            marker.addEventListener('click', () => {
                const scene = marker.dataset.scene;
                console.log('跳转到关键帧:', scene);
                const pin = marker.querySelector('.pin');
                pin.style.transform = 'scale(1.3)';
                pin.style.background = '#ff5a70';
                setTimeout(() => { pin.style.transform = ''; pin.style.background = ''; }, 300);
            });
        });

        // ===== 角色曲线开关 =====
        document.getElementById('curve-toggles').addEventListener('click', (e) => {
            const btn = e.target.closest('.toggle');
            if (!btn) return;
            btn.classList.toggle('on');
            const char = btn.dataset.char;
            const curve = document.getElementById('curve-' + char);
            if (curve) {
                curve.classList.toggle('hidden', !btn.classList.contains('on'));
            }
        });

        // ===== 编辑器焦点管理 =====
        const editorBody = document.getElementById('editor-body');
        editorBody.addEventListener('focus', () => {
            editorBody.style.outline = 'none';
        });
    </script>
    </body>
    </html>
    """
}
