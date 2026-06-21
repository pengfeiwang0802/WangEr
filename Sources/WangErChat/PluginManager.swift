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
    /// 持有布局切换按钮引用，方便更新 label
    private weak var layoutToolbarItem: NSToolbarItem?
    /// 编剧助手 WKWebView 引用（供原生控件调用 JS）
    private weak var scriptwritingWebView: WKWebView?
    /// 模板管理窗口关闭观察者
    private var templateManagerCloseObserver: NSObjectProtocol?

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

        guard let contentView = window.contentView else { return window }

        // 原生模式切换控件（放在 webView 上方，不用 toolbar item 避免点击事件被吞）
        let modeSwitch = NSSegmentedControl(labels: ["📋 时间轴", "📄 剧本"],
                                            trackingMode: .selectOne,
                                            target: self,
                                            action: #selector(modeSwitchChanged(_:)))
        modeSwitch.selectedSegment = 0
        modeSwitch.segmentStyle = .texturedRounded
        modeSwitch.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(modeSwitch)

        let webView = WKWebView(frame: .zero)
        webView.translatesAutoresizingMaskIntoConstraints = false

        // 透明背景，让 HTML 的深色主题透出
        webView.setValue(false, forKey: "drawsBackground")
        contentView.addSubview(webView)

        NSLayoutConstraint.activate([
            modeSwitch.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            modeSwitch.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),

            webView.topAnchor.constraint(equalTo: modeSwitch.bottomAnchor, constant: 8),
            webView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        // 先加载默认空布局
        webView.loadHTMLString(ScriptwritingLayout.html, baseURL: nil)

        // 工具栏（文件操作按钮）
        setupToolbar(in: window, webView: webView)

        // 恢复上次打开的 .sws 文件（如果有）
        restoreLastSession(webView: webView)

        return window
    }

    // MARK: - 工具栏

    private func setupToolbar(in window: NSWindow, webView: WKWebView) {
        scriptwritingWebView = webView
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

            // 持久化：记住最后打开的文件，下次打开编辑器自动恢复
            UserDefaults.standard.set(url.path, forKey: ScriptwritingPlugin.lastSWSFileKey)

            // 更新窗口标题
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "scriptwriting" }) ??
                NSApp.windows.first(where: { $0.title.hasPrefix("✍️") }) {
                window.title = "✍️ \(url.lastPathComponent)"
            }

            renderCurrentDocument()

            // 加载后清除所有红色验证标记
            if let window = findPluginWindow(),
               let webView = findWebView(in: window) {
                clearInvalidMarks(webView: webView)
            }
        } catch {
            print("ScriptwritingPlugin: 加载文件失败 \(error)")
        }
    }

    /// 恢复上次打开的 .sws 文件（如果有且文件仍存在）
    private func restoreLastSession(webView: WKWebView) {
        guard let path = UserDefaults.standard.string(forKey: Self.lastSWSFileKey) else { return }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            // 文件已被移动或删除，清除记录，编辑器保持空白
            UserDefaults.standard.removeObject(forKey: Self.lastSWSFileKey)
            return
        }
        loadSWSFile(url: url)
    }

    private static let lastSWSFileKey = "com.wanger.lastSWSFile"

    private func renderCurrentDocument() {
        guard let document = currentDocument else { return }

        // 找到该插件窗口的 WKWebView
        guard let window = NSApp.windows.first(where: { $0.title.contains("编剧助手") || $0.title.hasSuffix(".sws") }),
              let contentView = window.contentView,
              let webView = contentView.subviews.first(where: { $0 is WKWebView }) as? WKWebView else {
            return
        }

        // 生成角色→颜色映射（全局一致，跨场景同角色同色）
        let characterColors = SWSRenderer.buildCharacterColorMap(document: document)

        let bodyHTML = SWSRenderer.renderBody(document: document, style: currentStyle, characterColors: characterColors)
        // 还原 title/author（renderBody 不含，需要 full render 提取）
        let fullHTML = SWSRenderer.render(document: document, style: currentStyle, characterColors: characterColors)

        // 从 fullHTML 中提取 title 和 author（用于编辑器头）
        let titleMatch = fullHTML.range(of: "<div class='sws-title'[^>]*>([\\s\\S]*?)</div>", options: .regularExpression)
        let authorMatch = fullHTML.range(of: "<div class='sws-author'[^>]*>([\\s\\S]*?)</div>", options: .regularExpression)
        let titleHTML = titleMatch.flatMap { String(fullHTML[$0]) } ?? ""
        let authorHTML = authorMatch.flatMap { String(fullHTML[$0]) } ?? ""

        let escapedBody = bodyHTML
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "")
        let escapedFull = (titleHTML + authorHTML + bodyHTML)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "")

        // 渲染到剧本预览
        let js = """
        document.getElementById('script-wrapper').innerHTML = "\(escapedFull)";
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    @objc func reloadFile(_ sender: Any?) {
        guard let url = currentFileURL else { return }
        loadSWSFile(url: url)
    }

    // MARK: - 保存 .sws 文件

    /// 从编辑器提取文本并保存回 .sws 文件
    @objc func saveSWSFile(_ sender: Any?) {
        guard let url = currentFileURL else {
            print("ScriptwritingPlugin: 没有打开的文件，无法保存")
            return
        }
        guard let window = findPluginWindow(),
              let webView = findWebView(in: window) else {
            print("ScriptwritingPlugin: 找不到编辑器 WebView")
            return
        }

        // 先验证，再保存
        validateAndSave(webView: webView, url: url)
    }

    // MARK: - 编辑器验证

    /// 验证所有行 + 保存
    private func validateAndSave(webView: WKWebView, url: URL) {
        let js = buildValidateJS()
        webView.evaluateJavaScript(js) { [weak self] result, error in
            guard let self = self else { return }
            if let error = error {
                print("ScriptwritingPlugin: 验证失败 \(error)")
                // 降级：直接保存
                self.extractAndSave(webView: webView, url: url)
                return
            }
            guard let resultStr = result as? String else {
                print("ScriptwritingPlugin: 验证结果为空，直接保存")
                self.extractAndSave(webView: webView, url: url)
                return
            }

            // 解析验证结果
            // 格式: "OK" 或 "INVALID:行号1,行号2,..."
            if resultStr.hasPrefix("INVALID:") {
                let invalidLinesStr = String(resultStr.dropFirst(8))
                let invalidLines = invalidLinesStr.split(separator: ",").compactMap { Int($0) }
                print("ScriptwritingPlugin: 发现 \(invalidLines.count) 行格式异常")

                // 弹确认框
                let alert = NSAlert()
                alert.messageText = "有 \(invalidLines.count) 行格式异常"
                alert.informativeText = "异常行已被红色标记标出。\n\n保存后异常行将按普通文本处理，不会丢失内容。\n\n是否继续保存？"
                alert.addButton(withTitle: "继续保存")
                alert.addButton(withTitle: "取消")
                alert.alertStyle = .warning

                let response = alert.runModal()
                if response == .alertFirstButtonReturn {
                    self.extractAndSave(webView: webView, url: url)
                }
            } else {
                print("ScriptwritingPlugin: 验证通过，全部格式正确")
                self.extractAndSave(webView: webView, url: url)
            }
        }
    }

    /// 构建验证 JS：遍历编辑器每行，检查格式
    private func buildValidateJS() -> String {
        return """
        (function() {
            var body = document.getElementById('editor-body');
            if (!body) return 'OK';
            var invalidLines = [];
            var children = body.children;
            for (var i = 0; i < children.length; i++) {
                var el = children[i];
                var text = (el.innerText || el.textContent || '').trim();
                if (text === '') continue; // 空行跳过

                var type = el.getAttribute('data-sws-type') || '';
                var valid = false;

                if (type === 'dialogue') {
                    // 对白行：检查是否包含角色名信息
                    // dialogue 块内，角色名行和台词行都有 data-sws-type=dialogue
                    // 角色名行有 class="sws-dialogue-name"
                    var isNameLine = el.classList.contains('sws-dialogue-name');
                    if (isNameLine) {
                        // 角色名行：非空即可
                        valid = text.length > 0;
                    } else {
                        // 台词行：非空即可
                        valid = text.length > 0;
                    }
                } else if (type === 'action') {
                    // 动作描述行：非空即可
                    valid = text.length > 0;
                } else if (type === 'unattributed') {
                    // 未标注对白：非空即可
                    valid = text.length > 0;
                } else {
                    // 没有 data-sws-type 的行（可能是硬编码示例内容）
                    // 尝试根据 CSS 类名判断
                    if (el.classList.contains('scene-heading')) {
                        valid = text.startsWith('第') || text.startsWith('##') || text.length > 0;
                    } else if (el.classList.contains('character')) {
                        valid = text.length > 0 && text.length <= 10;
                    } else if (el.classList.contains('dialogue')) {
                        valid = text.length > 0;
                    } else if (el.classList.contains('action')) {
                        valid = text.length > 0;
                    } else {
                        // 未知类型行：宽松处理，标记为警告
                        valid = true;
                    }
                }

                if (!valid) {
                    invalidLines.push(i);
                    // 标红：加红色左边框
                    el.style.borderLeft = '3px solid #e74c3c';
                    el.style.paddingLeft = '8px';
                    el.style.backgroundColor = 'rgba(231, 76, 60, 0.08)';
                } else {
                    // 清除旧的红色标记
                    if (el.style.borderLeft && el.style.borderLeft.includes('e74c3c')) {
                        el.style.borderLeft = '';
                        el.style.paddingLeft = '';
                        el.style.backgroundColor = '';
                    }
                }
            }

            // 清除所有行左侧的旧验证标记
            // 先清除所有行的标记，再重新标记无效行
            for (var i = 0; i < children.length; i++) {
                var el = children[i];
                var text = (el.innerText || el.textContent || '').trim();
                if (text === '') continue;
                // 如果不在 invalidLines 中，清除标记
                if (invalidLines.indexOf(i) === -1) {
                    el.style.borderLeft = '';
                    el.style.paddingLeft = '';
                    el.style.backgroundColor = '';
                }
            }

            if (invalidLines.length === 0) return 'OK';
            return 'INVALID:' + invalidLines.join(',');
        })();
        """
    }

    /// 清除所有红色验证标记
    private func clearInvalidMarks(webView: WKWebView) {
        let js = """
        (function() {
            var body = document.getElementById('editor-body');
            if (!body) return;
            var children = body.children;
            for (var i = 0; i < children.length; i++) {
                var el = children[i];
                el.style.borderLeft = '';
                el.style.paddingLeft = '';
                el.style.backgroundColor = '';
            }
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// 从编辑器提取文本并保存
    private func extractAndSave(webView: WKWebView, url: URL) {
        let js = """
        (function() {
            var body = document.getElementById('editor-body');
            if (!body) return JSON.stringify([]);
            var lines = [];
            // 遍历所有 contenteditable 行（包括 dialogue 容器内的子行）
            var allEditable = body.querySelectorAll('[contenteditable="true"]');
            for (var i = 0; i < allEditable.length; i++) {
                var el = allEditable[i];
                var text = el.innerText || el.textContent || '';
                text = text.replace(/\\n/g, '').trim();
                var lineType = el.getAttribute('data-line-type') || '';
                var character = el.getAttribute('data-character') || '';
                lines.push({
                    text: text,
                    lineType: lineType,
                    character: character
                });
            }
            return JSON.stringify(lines);
        })();
        """

        webView.evaluateJavaScript(js) { [weak self] result, error in
            guard let self = self else { return }
            if let error = error {
                print("ScriptwritingPlugin: 提取编辑器内容失败 \(error)")
                return
            }
            guard let jsonStr = result as? String, !jsonStr.isEmpty,
                  let data = jsonStr.data(using: .utf8),
                  let lines = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else {
                print("ScriptwritingPlugin: 编辑器内容解析失败")
                return
            }

            // 根据 data-line-type 重建 SWSDocument
            let document = self.buildDocumentFromLines(lines)
            let formatter = SWSFormatter()
            let output = formatter.serialize(document)

            do {
                try output.write(to: url, atomically: true, encoding: .utf8)
                print("ScriptwritingPlugin: 已保存到 \(url.lastPathComponent)")
                // 更新 currentDocument
                self.currentDocument = document
            } catch {
                print("ScriptwritingPlugin: 保存失败 \(error)")
            }
        }
    }

    // MARK: - 从编辑器行重建 SWSDocument

    /// 从文本解析场景头（简化版，不依赖 SWSFormatter 的私有方法）
    private func parseSceneHeadingFromText(_ text: String) -> SWSSceneHeading {
        let t = text.hasPrefix("##") ? String(text.dropFirst(3)) : text
        let trimmed = t.trimmingCharacters(in: .whitespaces)
        // 尝试提取数字
        var s = trimmed
        for prefix in ["第", "场", "章", "Scene", "scene", "Act", "act"] {
            s = s.replacingOccurrences(of: prefix, with: "")
        }
        let number = s.trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? "1"
        return SWSSceneHeading(number: number.isEmpty ? "1" : number, separator: " · ")
    }

    /// 从编辑器行数据重建 SWSDocument
    /// 利用 data-line-type 信息，不需要重新解析文本
    private func buildDocumentFromLines(_ lines: [[String: String]]) -> SWSDocument {
        var scenes: [SWSScene] = []
        var currentHeading: SWSSceneHeading?
        var currentBlocks: [SWSBlock] = []
        /// 待绑定的角色名 + 修饰语（dialogue-name 行记录，dialogue-text 行消费）
        var pendingCharacter: (name: String, modifier: String?)?
        var currentActionLines: [String] = []

        func flushAction() {
            guard !currentActionLines.isEmpty else { return }
            let text = currentActionLines.joined(separator: "\n")
            currentBlocks.append(.action(SWSActionBlock(text: text)))
            currentActionLines = []
        }

        func flushScene() {
            flushAction()
            if currentHeading != nil || !currentBlocks.isEmpty {
                if currentBlocks.isEmpty {
                    currentBlocks.append(.emptyLine)
                }
                let scene = SWSScene(heading: currentHeading, blocks: currentBlocks)
                scenes.append(scene)
            }
            currentHeading = nil
            currentBlocks = []
            pendingCharacter = nil
            currentActionLines = []
        }

        for line in lines {
            let text = line["text"] ?? ""
            let lineType = line["lineType"] ?? ""
            let character = line["character"] ?? ""

            if text.isEmpty && lineType != "scene-heading" {
                // 空行：结束当前 action / clear pending character
                pendingCharacter = nil
                flushAction()
                currentBlocks.append(.emptyLine)
                continue
            }

            switch lineType {
            case "scene-heading":
                flushScene()
                currentHeading = parseSceneHeadingFromText(text)

            case "dialogue-name":
                flushAction()
                let (name, modifier) = extractCharacterAndModifier(from: text)
                pendingCharacter = (name, modifier)

            case "dialogue-text":
                flushAction()
                if let pc = pendingCharacter {
                    currentBlocks.append(.dialogue(SWSDialogueBlock(character: pc.name, modifier: pc.modifier, line: text)))
                } else if !character.isEmpty {
                    currentBlocks.append(.dialogue(SWSDialogueBlock(character: character, modifier: nil, line: text)))
                } else {
                    // 没有上下文，作为 unattributed
                    currentBlocks.append(.unattributed(SWSUnattributedBlock(lines: [text])))
                }

            case "action":
                pendingCharacter = nil
                currentActionLines.append(text)

            case "unattributed":
                pendingCharacter = nil
                flushAction()
                currentBlocks.append(.unattributed(SWSUnattributedBlock(lines: [text])))

            default:
                // 未知类型，尝试作为 action
                pendingCharacter = nil
                currentActionLines.append(text)
            }
        }

        // 收尾
        flushScene()

        let metadata = currentDocument?.metadata ?? SWSMetadata()
        return SWSDocument(metadata: metadata, scenes: scenes)
    }

    /// 从一行文本中提取角色名和修饰语
    /// 支持格式："王二" → ("王二", nil)
    ///           "王二（OV）" → ("王二", "OV")
    ///           "王二（低头笑了一声）" → ("王二", "低头笑了一声")
    private func extractCharacterAndModifier(from text: String) -> (String, String?) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        // 检查中文括号
        if let openIdx = trimmed.firstIndex(of: "（"),
           let closeIdx = trimmed.lastIndex(of: "）"),
           openIdx < closeIdx {
            let name = trimmed[..<openIdx].trimmingCharacters(in: .whitespaces)
            let modifier = trimmed[trimmed.index(after: openIdx)..<closeIdx].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty && !modifier.isEmpty {
                return (name, modifier)
            }
        }
        return (trimmed, nil)
    }

    // MARK: - 窗口/WebView 查找辅助

    private func findPluginWindow() -> NSWindow? {
        return NSApp.windows.first(where: {
            $0.title.contains("编剧助手") || $0.title.hasSuffix(".sws")
        })
    }

    private func findWebView(in window: NSWindow) -> WKWebView? {
        guard let contentView = window.contentView else { return nil }
        return contentView.subviews.first(where: { $0 is WKWebView }) as? WKWebView
    }

    @objc func showLayoutMenu(_ sender: NSToolbarItem) {
        // fallback: 直接循环切换
        fallbackToggleLayout()
    }

    /// 原生 NSSegmentedControl 切换时间轴/剧本模式
    /// 直接操作 DOM，不依赖 window.onModeChange（避免 WKWebView JS 函数引用丢失问题）
    @objc func modeSwitchChanged(_ sender: NSSegmentedControl) {
        let isTimeline = sender.selectedSegment == 0
        let mode = isTimeline ? "timeline" : "script"
        print("[PluginManager] modeSwitchChanged: \(mode), webView=\(scriptwritingWebView != nil ? "OK" : "NIL")")

        // 在 Swift 端决定模式布尔值，JS 端只做 DOM 操作（零依赖，全直接）
        let js = """
        (function() {
            var isTimeline = \(isTimeline ? "true" : "false");
            var tla = document.getElementById('timeline-area');
            var sca = document.getElementById('script-area');
            var sdb = document.getElementById('sidebar');
            var hdl = document.getElementById('resize-handle');
            var lbl = document.getElementById('mode-label');
            var btn = document.getElementById('btn-toggle-sidebar');

            if (tla) tla.style.display = isTimeline ? 'flex' : 'none';
            if (sca) sca.style.display = isTimeline ? 'none' : '';
            if (sdb) {
                if (isTimeline) { sdb.classList.remove('collapsed'); }
                else { sdb.classList.add('collapsed'); }
            }
            if (hdl) hdl.style.display = isTimeline ? '' : 'none';
            if (lbl) lbl.textContent = isTimeline ? '📋 时间轴（编辑）' : '📄 剧本（只读预览）';
            if (btn) btn.textContent = '📂';

            // 切换到剧本模式时，刷新预览
            if (!isTimeline && typeof window._renderScriptPreview === 'function') {
                window._renderScriptPreview();
            }
        })();
        """
        scriptwritingWebView?.evaluateJavaScript(js) { result, error in
            if let error = error {
                print("[PluginManager] modeSwitchChanged JS error: \(error.localizedDescription)")
            } else {
                print("[PluginManager] modeSwitchChanged JS OK, result=\(result ?? "nil")")
            }
        }
    }

    @objc func popUpLayoutChanged(_ sender: NSPopUpButton) {
        guard let selectedItem = sender.selectedItem,
              let style = selectedItem.representedObject as? DisplayStyle else { return }
        currentStyle = style
        renderCurrentDocument()
        layoutToolbarItem?.label = style.displayName
    }

    private func buildLayoutMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // 预设模板
        for style in DisplayStyle.presets {
            let item = NSMenuItem(title: style.displayName, action: #selector(selectLayout(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style
            if style.name == currentStyle.name {
                item.state = NSControl.StateValue.on
            }
            menu.addItem(item)
        }

        // 自定义模板（选中时打勾不显示星星）
        let customTemplates = FormatTemplate.loadAll()
        if !customTemplates.isEmpty {
            menu.addItem(NSMenuItem.separator())
            for template in customTemplates {
                let isSelected = template.name == currentStyle.name
                let title = isSelected ? template.name : "⭐️ \(template.name)"
                let item = NSMenuItem(title: title, action: #selector(selectCustomTemplate(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = template
                if isSelected { item.state = .on }
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())
        let manageItem = NSMenuItem(title: "管理模板...", action: #selector(openTemplateManager(_:)), keyEquivalent: "")
        manageItem.target = self
        menu.addItem(manageItem)
        return menu
    }

    @objc private func openTemplateManager(_ sender: Any?) {
        // 关闭时刷新菜单
        if templateManagerCloseObserver == nil {
            templateManagerCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: nil, queue: .main
            ) { [weak self] notification in
                guard let self, let win = notification.object as? NSWindow,
                      win.title == "📋 模板管理" else { return }
                self.refreshLayoutMenu()
                if let obs = self.templateManagerCloseObserver {
                    NotificationCenter.default.removeObserver(obs)
                    self.templateManagerCloseObserver = nil
                }
            }
        }
        TemplateManagerWindow.shared.onApplyTemplate = { [weak self] template in
            let style = template.toDisplayStyle()
            self?.currentStyle = style
            self?.renderCurrentDocument()
            self?.layoutToolbarItem?.label = style.displayName
            self?.refreshLayoutMenu()
        }
        TemplateManagerWindow.shared.show()
        refreshPopUpSelection()
    }

    private func refreshLayoutMenu() {
        guard let popUp = layoutToolbarItem?.view as? NSPopUpButton else { return }
        popUp.menu = buildLayoutMenu()
        refreshPopUpSelection()
    }

    private func refreshPopUpSelection() {
        guard let popUp = layoutToolbarItem?.view as? NSPopUpButton,
              let menu = popUp.menu else { return }
        popUp.title = currentStyle.displayName
        for item in menu.items {
            if let style = item.representedObject as? DisplayStyle,
               style.name == currentStyle.name {
                popUp.select(item)
                item.state = .on
            } else if item.representedObject is DisplayStyle {
                item.state = .off
            } else if let template = item.representedObject as? FormatTemplate,
                      template.name == currentStyle.name {
                popUp.select(item)
                item.state = .on
            } else if item.representedObject is FormatTemplate {
                item.state = .off
            }
        }
    }

    @objc private func selectLayout(_ sender: NSMenuItem) {
        guard let style = sender.representedObject as? DisplayStyle else { return }
        currentStyle = style
        renderCurrentDocument()
        layoutToolbarItem?.label = style.displayName
        // 更新 popUp button 的标题
        if let popUp = layoutToolbarItem?.view as? NSPopUpButton {
            popUp.title = style.displayName
        }
    }

    @objc private func selectCustomTemplate(_ sender: NSMenuItem) {
        guard let template = sender.representedObject as? FormatTemplate else { return }
        let style = template.toDisplayStyle()
        currentStyle = style
        renderCurrentDocument()
        layoutToolbarItem?.label = style.displayName
        refreshLayoutMenu()
    }

    private func fallbackToggleLayout() {
        let all = DisplayStyle.presets
        let idx = all.firstIndex(where: { $0.name == currentStyle.name }) ?? 0
        let next = all[(idx + 1) % all.count]
        currentStyle = next
        renderCurrentDocument()
        layoutToolbarItem?.label = next.displayName
        if let popUp = layoutToolbarItem?.view as? NSPopUpButton {
            popUp.title = next.displayName
        }
    }
}

// MARK: - NSToolbarDelegate

extension ScriptwritingPlugin: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .openFile, .reload, .saveFile, .toggleLayout]
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
        case .saveFile:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "保存"
            item.paletteLabel = "保存 .sws"
            item.toolTip = "保存当前编辑内容到 .sws 文件"
            item.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "保存")
            item.target = self
            item.action = #selector(saveSWSFile(_:))
            return item
        case .toggleLayout:
            let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
            popUp.menu = buildLayoutMenu()
            popUp.title = currentStyle.displayName
            popUp.bezelStyle = .texturedRounded
            popUp.target = self
            popUp.action = #selector(popUpLayoutChanged(_:))
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = currentStyle.displayName
            item.paletteLabel = "切换对白布局"
            item.toolTip = "切换对白显示布局"
            item.image = NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: "布局")
            item.view = popUp
            self.layoutToolbarItem = item
            return item
        default:
            return nil
        }
    }
}

private extension NSToolbarItem.Identifier {
    static let modeSwitch = NSToolbarItem.Identifier("com.wanger.modeSwitch")
    static let openFile = NSToolbarItem.Identifier("com.wanger.openSWS")
    static let reload = NSToolbarItem.Identifier("com.wanger.reloadSWS")
    static let toggleLayout = NSToolbarItem.Identifier("com.wanger.toggleLayout")
    static let saveFile = NSToolbarItem.Identifier("com.wanger.saveSWS")
}

// MARK: - 编剧助手 UI 布局
enum ScriptwritingLayout {
    static let html = """
    <!DOCTYPE html>
    <html lang="zh-CN">
    <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
            :root {
                --bg-primary:   #ffffff;
                --bg-secondary: #f5f5f5;
                --bg-tertiary:  #e8e8e8;
                --bg-editor:    #ffffff;
                --border:       #d0d0d0;
                --text-primary: #1a1a1a;
                --text-secondary: #555555;
                --text-muted:   #999999;
                --accent:       #e94560;
                --accent-soft:  rgba(233,69,96,0.08);
                --gold:         #d4920a;
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
                filter: brightness(1.1);
                transform: translateY(-1px);
                box-shadow: 0 2px 8px rgba(0,0,0,0.12);
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
                box-shadow: 0 1px 3px rgba(0,0,0,0.1);
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

            /* ========== 模式切换栏（显示区左上方） ========== */
            #mode-toolbar {
                height: 34px;
                min-height: 34px;
                background: var(--bg-secondary);
                border-bottom: 1px solid var(--border);
                display: flex;
                align-items: center;
                padding: 0 16px;
                gap: 6px;
                position: relative;
                z-index: 20;
            }
            #mode-toolbar .mode-label {
                font-size: 0.7em;
                color: var(--text-muted);
                margin-left: auto;
                opacity: 0.5;
            }

            /* ========== Timeline 视图 ========== */
            #timeline-area {
                flex: 1;
                display: flex;
                flex-direction: column;
                overflow: hidden;
                background: var(--bg-primary);
            }
            .timeline-header {
                padding: 12px 20px 8px;
                border-bottom: 1px solid var(--border);
                display: flex;
                align-items: baseline;
                gap: 10px;
            }
            .timeline-title {
                font-size: 0.9em;
                font-weight: 700;
                color: var(--text-primary);
            }
            .timeline-subtitle {
                font-size: 0.7em;
                color: var(--text-muted);
            }
            .timeline-scroll {
                flex: 1;
                overflow-y: auto;
                padding: 16px 20px;
                display: flex;
                flex-direction: column;
                gap: 14px;
            }

            /* 场景卡片 */
            .scene-card {
                background: var(--bg-secondary);
                border: 1px solid var(--border);
                border-radius: 10px;
                overflow: visible;
                flex-shrink: 0;
                transition: border-color 0.15s;
            }
            .scene-card:hover {
                border-color: var(--accent);
                box-shadow: 0 2px 8px rgba(0,0,0,0.06);
            }
            .scene-card-header {
                display: flex;
                align-items: center;
                gap: 12px;
                padding: 10px 14px;
                background: var(--bg-tertiary);
                border-bottom: 1px solid var(--border);
                border-radius: 10px 10px 0 0;
            }
            .scene-number { flex-shrink: 0; }
            .scene-num-circle {
                display: inline-flex;
                align-items: center;
                justify-content: center;
                width: 30px;
                height: 30px;
                border-radius: 50%;
                background: var(--accent);
                color: #fff;
                font-weight: 700;
                font-size: 0.85em;
            }
            .scene-meta-fields {
                display: flex;
                gap: 8px;
                flex-wrap: wrap;
            }
            .scene-tag {
                padding: 3px 10px;
                border-radius: 5px;
                font-size: 0.78em;
                font-weight: 600;
                background: var(--bg-secondary);
                border: 1px solid var(--border);
                color: var(--text-secondary);
            }
            .scene-tag.ie-tag { color: #f5a623; }
            .scene-tag.loc-tag { color: #a0a0b0; }
            .scene-tag.time-tag { color: #6a9fc5; }

            .scene-card-body {
                padding: 8px 14px 12px;
                display: flex;
                flex-direction: column;
                gap: 2px;
            }

            /* Timeline 行块 */
            .tl-block {
                display: flex;
                align-items: center;
                gap: 8px;
                padding: 6px 8px;
                border-radius: 5px;
                font-size: 0.88em;
                line-height: 1.5;
            }
            .tl-block-icon {
                width: 22px;
                flex-shrink: 0;
                text-align: center;
                font-size: 0.8em;
                opacity: 0.6;
            }
            .tl-block.tl-action {
                color: #5a8a5a;
            }
            .tl-block.tl-dialogue {
                color: #4a80a8;
            }
            .tl-block.tl-dialogue-text {
                color: var(--text-primary);
                padding-left: 30px;
                border-left: 2px solid var(--border);
                margin-left: 7px;
            }
            .tl-char-name {
                font-weight: 600;
                color: #e8a44a;
            }
            .tl-char-mod {
                font-size: 0.85em;
                color: var(--text-muted);
            }
            .tl-block-text {
                color: var(--text-secondary);
            }
            .tl-block.tl-dialogue-text .tl-block-text {
                color: var(--text-primary);
            }

            /* 添加新场卡片 */
            .add-scene-card {
                display: flex;
                align-items: center;
                justify-content: center;
                gap: 8px;
                padding: 14px;
                border: 2px dashed var(--border);
                border-radius: 10px;
                cursor: pointer;
                transition: all 0.15s;
                color: var(--text-muted);
                font-size: 0.85em;
            }
            .add-scene-card:hover {
                border-color: var(--accent);
                color: var(--accent);
                background: var(--accent-soft);
            }
            .add-scene-icon {
                font-size: 1.2em;
                font-weight: 300;
            }

            /* ========== 剧本预览（只读） ========== */
            #script-area {
                flex: 1;
                display: flex;
                flex-direction: column;
                overflow-y: auto;
                background: #fafafa;
                padding: 0;
            }
            #script-area .script-wrapper {
                max-width: 680px;
                margin: 40px auto;
                padding: 60px 50px;
                background: #ffffff;
                box-shadow: 0 1px 8px rgba(0,0,0,0.04);
                border-radius: 2px;
                border: 1px solid #e8e8e8;
                color: #1a1a1a;
                font-size: 15px;
                line-height: 1.8;
                font-family: "PingFang SC", "Noto Serif SC", "Songti SC", Georgia, serif;
                min-height: 100%;
            }

            /* 底部时间轴 */
            .timeline-axis {
                height: 64px;
                min-height: 64px;
                background: var(--bg-secondary);
                border-top: 1px solid var(--border);
                display: flex;
                align-items: center;
                padding: 0 28px;
            }
            .axis-line {
                width: 100%;
                display: flex;
                align-items: center;
                justify-content: space-between;
            }
            .axis-dot {
                display: flex;
                flex-direction: column;
                align-items: center;
                gap: 4px;
                cursor: pointer;
                position: relative;
            }
            .axis-dot-circle {
                width: 14px;
                height: 14px;
                border-radius: 50%;
                background: var(--accent);
                border: 2px solid var(--bg-secondary);
                transition: all 0.15s;
            }
            .axis-dot:hover .axis-dot-circle {
                transform: scale(1.3);
                background: #ff5a70;
            }
            .axis-dot-label {
                font-size: 0.65em;
                color: var(--text-muted);
                white-space: nowrap;
            }
            .axis-connector {
                flex: 1;
                height: 2px;
                background: var(--border);
                margin: 0 -20px;
                margin-bottom: 20px;
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
            ::-webkit-scrollbar-thumb { background: #cccccc; border-radius: 3px; }
            ::-webkit-scrollbar-thumb:hover { background: #aaaaaa; }

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
                <button class="toggle on" data-char="zhengyiyuan">
                    <span class="dot" style="color:#e8a44a;"></span> 郑希远
                </button>
                <button class="toggle on" data-char="xiangnan">
                    <span class="dot" style="color:#6a9fc5;"></span> 向南
                </button>
                <button class="toggle on" data-char="linxiaoyu">
                    <span class="dot" style="color:#b87a9a;"></span> 林小雨
                </button>
                <button class="toggle on" data-char="chenshu">
                    <span class="dot" style="color:#8a8aaa;"></span> 陈叔
                </button>
            </div>
        </div>
        <div class="storybar-timeline" id="timeline">
            <!-- 剧情块 -->
            <div class="story-blocks">
                <div class="story-block" data-tone="warm" style="width:17%;" data-scene="1" title="书房诀别">
                    <span class="block-label">诀别</span>
                    <span class="block-tone">暖 · 不舍</span>
                </div>
                <div class="story-block" data-tone="cool" style="width:17%;" data-scene="2" title="码头回忆">
                    <span class="block-label">回忆</span>
                    <span class="block-tone">冷 · 追思</span>
                </div>
                <div class="story-block" data-tone="tense" style="width:17%;" data-scene="3" title="孤独等待">
                    <span class="block-label">等待</span>
                    <span class="block-tone">郁 · 孤独</span>
                </div>
                <div class="story-block" data-tone="warm" style="width:17%;" data-scene="4" title="茶馆揭示">
                    <span class="block-label">揭示</span>
                    <span class="block-tone">暖 · 曙光</span>
                </div>
                <div class="story-block" data-tone="hot" style="width:17%;" data-scene="5" title="轮渡抉择">
                    <span class="block-label">抉择</span>
                    <span class="block-tone">灼 · 新生</span>
                </div>
                <div class="story-block" data-tone="cool" style="width:15%;" data-scene="6" title="身世之谜">
                    <span class="block-label">谜底</span>
                    <span class="block-tone">静 · 悬念</span>
                </div>
            </div>
            <!-- 关键帧 -->
            <div class="keyframe-layer">
                <div class="keyframe-marker" style="left:8%;" data-scene="1" title="郑希远催促向南离开">
                    <div class="pin"></div>
                    <span class="kf-label">离别</span>
                </div>
                <div class="keyframe-marker" style="left:25%;" data-scene="2" title="码头回忆往事">
                    <div class="pin"></div>
                    <span class="kf-label">往事</span>
                </div>
                <div class="keyframe-marker" style="left:42%;" data-scene="3" title="林小雨收到信">
                    <div class="pin"></div>
                    <span class="kf-label">信</span>
                </div>
                <div class="keyframe-marker" style="left:58%;" data-scene="4" title="陈叔交出怀表">
                    <div class="pin"></div>
                    <span class="kf-label">怀表</span>
                </div>
                <div class="keyframe-marker" style="left:75%;" data-scene="5" title="向南登上轮渡">
                    <div class="pin"></div>
                    <span class="kf-label">启程</span>
                </div>
                <div class="keyframe-marker" style="left:92%;" data-scene="6" title="怀表里的秘密">
                    <div class="pin"></div>
                    <span class="kf-label">秘密</span>
                </div>
            </div>
            <!-- 情绪曲线 -->
            <div class="curve-layer">
                <svg viewBox="0 0 1000 50" preserveAspectRatio="none">
                    <path class="curve-line" id="curve-zhengyiyuan"
                        d="M0,30 C80,28 120,20 190,22 C260,28 320,38 400,30 C480,22 520,8 600,15 C680,25 720,12 800,18 C880,24 940,20 1000,25"
                        stroke="#e8a44a" />
                    <path class="curve-line" id="curve-xiangnan"
                        d="M0,18 C60,16 100,28 180,20 C260,12 320,5 400,18 C480,32 540,38 620,28 C700,20 760,8 840,15 C920,22 980,18 1000,20"
                        stroke="#6a9fc5" />
                    <path class="curve-line" id="curve-linxiaoyu"
                        d="M0,22 C140,24 200,34 300,28 C400,22 480,8 580,18 C680,28 740,40 820,32 C900,24 960,22 1000,18"
                        stroke="#b87a9a" />
                    <path class="curve-line" id="curve-chenshu"
                        d="M0,35 C200,32 300,28 440,22 C520,18 560,14 620,20 C680,28 720,32 800,28 C880,24 940,22 1000,25"
                        stroke="#8a8aaa" />
                </svg>
            </div>
        </div>
    </div>

    <!-- ===== 显示区模式切换栏 ===== -->
    <div id="mode-toolbar">
        <span class="mode-label" id="mode-label">📋 时间轴（编辑）</span>
        <span style="flex:1;"></span>
        <button title="折叠侧边栏" id="btn-toggle-sidebar">📂</button>
    </div>

    <!-- ===== Main Body（显示区） ===== -->
    <div id="main-body">

        <!-- ===== Sidebar ===== -->
        <div id="sidebar">
            <div class="sidebar-header">
                <span>👥 角色</span>
                <span class="count">4</span>
                <button class="add-char" title="添加角色">+</button>
            </div>
            <div class="char-list" id="char-list">
                <div class="char-item active" data-char="zhengyiyuan">
                    <div class="avatar">🧔</div>
                    <div class="info">
                        <div class="name">郑希远</div>
                        <div class="role">主角 · 男 · 35岁</div>
                    </div>
                </div>
                <div class="char-item" data-char="xiangnan">
                    <div class="avatar">👨</div>
                    <div class="info">
                        <div class="name">向南</div>
                        <div class="role">主角 · 男 · 33岁</div>
                    </div>
                </div>
                <div class="char-item" data-char="linxiaoyu">
                    <div class="avatar">👩</div>
                    <div class="info">
                        <div class="name">林小雨</div>
                        <div class="role">主角 · 女 · 19岁</div>
                    </div>
                </div>
                <div class="char-item" data-char="chenshu">
                    <div class="avatar">👨‍🦳</div>
                    <div class="info">
                        <div class="name">陈叔</div>
                        <div class="role">配角 · 男 · 58岁</div>
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

        <!-- ===== Timeline View（时间轴编辑模式） ===== -->
        <div id="timeline-area">
            <div class="timeline-header">
                <span class="timeline-title">📋 时间轴</span>
                <span class="timeline-subtitle">场景概览</span>
            </div>
            <div class="timeline-scroll" id="timeline-scroll">

                <!-- 第1场 -->
                <div class="scene-card" data-scene="1" id="timeline-scene-1">
                    <div class="scene-card-header">
                        <div class="scene-number"><span class="scene-num-circle">1</span></div>
                        <div class="scene-meta-fields">
                            <span class="scene-tag ie-tag">🏠 内景</span>
                            <span class="scene-tag loc-tag">书房</span>
                            <span class="scene-tag time-tag">☀️ 日</span>
                        </div>
                    </div>
                    <div class="scene-card-body">
                        <div class="tl-block tl-action"><span class="tl-block-icon">📝</span><span class="tl-block-text">老陈站在书架前，手指划过一排排泛黄的书脊。窗外梧桐叶落了大半。</span></div>
                        <div class="tl-block tl-dialogue"><span class="tl-block-icon">👤</span><span class="tl-char-name">郑希远</span></div>
                        <div class="tl-block tl-dialogue-text"><span class="tl-block-icon">💬</span><span class="tl-block-text">走吧。再不走就赶不上船了。</span></div>
                        <div class="tl-block tl-dialogue"><span class="tl-block-icon">👤</span><span class="tl-char-name">向南</span><span class="tl-char-mod">（抬头看了一眼）</span></div>
                        <div class="tl-block tl-dialogue-text"><span class="tl-block-icon">💬</span><span class="tl-block-text">我还没想好。</span></div>
                        <div class="tl-block tl-action"><span class="tl-block-icon">📝</span><span class="tl-block-text">郑希远叹了口气，把手里的烟掐灭在窗台上。</span></div>
                        <div class="tl-block tl-dialogue"><span class="tl-block-icon">👤</span><span class="tl-char-name">郑希远</span></div>
                        <div class="tl-block tl-dialogue-text"><span class="tl-block-icon">💬</span><span class="tl-block-text">你想了一年了。</span></div>
                    </div>
                </div>

                <!-- 第2场 -->
                <div class="scene-card" data-scene="2" id="timeline-scene-2">
                    <div class="scene-card-header">
                        <div class="scene-number"><span class="scene-num-circle">2</span></div>
                        <div class="scene-meta-fields">
                            <span class="scene-tag ie-tag">🌃 外景</span>
                            <span class="scene-tag loc-tag">码头</span>
                            <span class="scene-tag time-tag">🌅 黄昏</span>
                        </div>
                    </div>
                    <div class="scene-card-body">
                        <div class="tl-block tl-action"><span class="tl-block-icon">📝</span><span class="tl-block-text">江水浑浊，汽笛声由远及近。挑夫们扛着麻袋在跳板上穿梭。远处的城市在天际线若隐若现。</span></div>
                        <div class="tl-block tl-dialogue"><span class="tl-block-icon">👤</span><span class="tl-char-name">郑希远</span><span class="tl-char-mod">（望着江水）</span></div>
                        <div class="tl-block tl-dialogue-text"><span class="tl-block-icon">💬</span><span class="tl-block-text">你还记得咱们第一次来这儿的模样吗？那时候码头还没这么乱。</span></div>
                        <div class="tl-block tl-dialogue"><span class="tl-block-icon">👤</span><span class="tl-char-name">向南</span></div>
                        <div class="tl-block tl-dialogue-text"><span class="tl-block-icon">💬</span><span class="tl-block-text">都变了。</span></div>
                        <div class="tl-block tl-action"><span class="tl-block-icon">📝</span><span class="tl-block-text">一个卖橘子的老妇人从他们身边走过，向南买了两斤。</span></div>
                        <div class="tl-block tl-dialogue"><span class="tl-block-icon">👤</span><span class="tl-char-name">向南</span><span class="tl-char-mod">（剥着橘子）</span></div>
                        <div class="tl-block tl-dialogue-text"><span class="tl-block-icon">💬</span><span class="tl-block-text">那时候你身上一共就五块钱。全买了橘子。</span></div>
                    </div>
                </div>

                <!-- 第3场 -->
                <div class="scene-card" data-scene="3" id="timeline-scene-3">
                    <div class="scene-card-header">
                        <div class="scene-number"><span class="scene-num-circle">3</span></div>
                        <div class="scene-meta-fields">
                            <span class="scene-tag ie-tag">🏠 内景</span>
                            <span class="scene-tag loc-tag">林小雨家客厅</span>
                            <span class="scene-tag time-tag">🌙 夜</span>
                        </div>
                    </div>
                    <div class="scene-card-body">
                        <div class="tl-block tl-action"><span class="tl-block-icon">📝</span><span class="tl-block-text">林小雨坐在沙发上，手里握着一封已经拆开的信。茶几上的茶早就凉了。</span></div>
                        <div class="tl-block tl-dialogue"><span class="tl-block-icon">👤</span><span class="tl-char-name">林小雨</span><span class="tl-char-mod">（自言自语）</span></div>
                        <div class="tl-block tl-dialogue-text"><span class="tl-block-icon">💬</span><span class="tl-block-text">他说"很快回来"……那是春天的事了。</span></div>
                        <div class="tl-block tl-action"><span class="tl-block-icon">📝</span><span class="tl-block-text">门外传来脚步声。林小雨迅速把信塞进抽屉，擦了擦眼角。</span></div>
                        <div class="tl-block tl-action"><span class="tl-block-icon">📝</span><span class="tl-block-text">敲门声响起。</span></div>
                        <div class="tl-block tl-dialogue"><span class="tl-block-icon">👤</span><span class="tl-char-name">陈叔</span><span class="tl-char-mod">（门外）</span></div>
                        <div class="tl-block tl-dialogue-text"><span class="tl-block-icon">💬</span><span class="tl-block-text">小雨，在家吗？我带了点桂花糕。</span></div>
                    </div>
                </div>

                <!-- 第4场 -->
                <div class="scene-card" data-scene="4" id="timeline-scene-4">
                    <div class="scene-card-header">
                        <div class="scene-number"><span class="scene-num-circle">4</span></div>
                        <div class="scene-meta-fields">
                            <span class="scene-tag ie-tag">🏠 内景</span>
                            <span class="scene-tag loc-tag">茶馆</span>
                            <span class="scene-tag time-tag">☀️ 日</span>
                        </div>
                    </div>
                    <div class="scene-card-body">
                        <div class="tl-block tl-action"><span class="tl-block-icon">📝</span><span class="tl-block-text">茶馆里烟雾缭绕，评弹声从二楼飘下来。陈叔给林小雨倒了杯茶。</span></div>
                        <div class="tl-block tl-dialogue"><span class="tl-block-icon">👤</span><span class="tl-char-name">陈叔</span></div>
                        <div class="tl-block tl-dialogue-text"><span class="tl-block-icon">💬</span><span class="tl-block-text">你爸走之前，在我这存了一样东西。</span></div>
                        <div class="tl-block tl-action"><span class="tl-block-icon">📝</span><span class="tl-block-text">他从怀里掏出一个布包，层层打开，里面是一块怀表。</span></div>
                        <div class="tl-block tl-dialogue"><span class="tl-block-icon">👤</span><span class="tl-char-name">林小雨</span><span class="tl-char-mod">（接过怀表，手指颤抖）</span></div>
                        <div class="tl-block tl-dialogue-text"><span class="tl-block-icon">💬</span><span class="tl-block-text">这是他随身带了二十年的那块表。</span></div>
                        <div class="tl-block tl-dialogue"><span class="tl-block-icon">👤</span><span class="tl-char-name">陈叔</span><span class="tl-char-mod">（低声）</span></div>
                        <div class="tl-block tl-dialogue-text"><span class="tl-block-icon">💬</span><span class="tl-block-text">表壳里藏了东西。他说等你二十岁才能给你。</span></div>
                    </div>
                </div>

                <!-- 第5场 -->
                <div class="scene-card" data-scene="5" id="timeline-scene-5">
                    <div class="scene-card-header">
                        <div class="scene-number"><span class="scene-num-circle">5</span></div>
                        <div class="scene-meta-fields">
                            <span class="scene-tag ie-tag">🌃 外景</span>
                            <span class="scene-tag loc-tag">长江轮渡</span>
                            <span class="scene-tag time-tag">🌅 黎明</span>
                        </div>
                    </div>
                    <div class="scene-card-body">
                        <div class="tl-block tl-action"><span class="tl-block-icon">📝</span><span class="tl-block-text">轮渡在晨雾中缓缓离岸。向南靠在船舷上，手里攥着那张皱巴巴的船票。</span></div>
                        <div class="tl-block tl-dialogue"><span class="tl-block-icon">👤</span><span class="tl-char-name">郑希远</span><span class="tl-char-mod">（从船舱走出来）</span></div>
                        <div class="tl-block tl-dialogue-text"><span class="tl-block-icon">💬</span><span class="tl-block-text">你终于上船了。</span></div>
                        <div class="tl-block tl-dialogue"><span class="tl-block-icon">👤</span><span class="tl-char-name">向南</span></div>
                        <div class="tl-block tl-dialogue-text"><span class="tl-block-icon">💬</span><span class="tl-block-text">我想通了。有些事不是等就能等来的。</span></div>
                        <div class="tl-block tl-action"><span class="tl-block-icon">📝</span><span class="tl-block-text">太阳从江面升起，金黄的光铺满整个江面。向南眯起眼睛望着对岸。那里是新的城市，新的生活。</span></div>
                        <div class="tl-block tl-dialogue"><span class="tl-block-icon">👤</span><span class="tl-char-name">郑希远</span><span class="tl-char-mod">（笑）</span></div>
                        <div class="tl-block tl-dialogue-text"><span class="tl-block-icon">💬</span><span class="tl-block-text">我就知道你会来。橘子都给你买好了。</span></div>
                    </div>
                </div>

                <!-- 第6场 -->
                <div class="scene-card" data-scene="6" id="timeline-scene-6">
                    <div class="scene-card-header">
                        <div class="scene-number"><span class="scene-num-circle">6</span></div>
                        <div class="scene-meta-fields">
                            <span class="scene-tag ie-tag">🏠 内景</span>
                            <span class="scene-tag loc-tag">林小雨家</span>
                            <span class="scene-tag time-tag">🌙 夜</span>
                        </div>
                    </div>
                    <div class="scene-card-body">
                        <div class="tl-block tl-action"><span class="tl-block-icon">📝</span><span class="tl-block-text">林小雨用颤抖的手打开怀表后盖。里面是一张泛黄的照片——年轻时的父亲，怀里抱着一个婴儿。</span></div>
                        <div class="tl-block tl-action"><span class="tl-block-icon">📝</span><span class="tl-block-text">照片背面写着一行字：「小雨，你不是一个人。」</span></div>
                        <div class="tl-block tl-action"><span class="tl-block-icon">📝</span><span class="tl-block-text">她把照片翻过来。婴儿的眼睛很像她的。</span></div>
                        <div class="tl-block tl-action"><span class="tl-block-icon">📝</span><span class="tl-block-text">照片右边站着另一个穿旗袍的女人。不是她妈妈。</span></div>
                        <div class="tl-block tl-dialogue"><span class="tl-block-icon">👤</span><span class="tl-char-name">林小雨</span><span class="tl-char-mod">（对着照片）</span></div>
                        <div class="tl-block tl-dialogue-text"><span class="tl-block-icon">💬</span><span class="tl-block-text">你到底是谁……</span></div>
                        <div class="tl-block tl-action"><span class="tl-block-icon">📝</span><span class="tl-block-text">窗外，秋雨细密地敲打着玻璃。桌上的桂花糕没人动过。</span></div>
                    </div>
                </div>

                <!-- 加场按钮 -->
                <div class="add-scene-card" title="添加新场">
                    <span class="add-scene-icon">＋</span>
                    <span class="add-scene-label">添加新场</span>
                </div>

            </div>

            <!-- 底部时间轴 -->
            <div class="timeline-axis">
                <div class="axis-line">
                    <div class="axis-dot" data-scene="1" title="第1场 · 书房 · 日"><span class="axis-dot-circle"></span><span class="axis-dot-label">第1场</span></div>
                    <div class="axis-connector"></div>
                    <div class="axis-dot" data-scene="2" title="第2场 · 码头 · 黄昏"><span class="axis-dot-circle"></span><span class="axis-dot-label">第2场</span></div>
                    <div class="axis-connector"></div>
                    <div class="axis-dot" data-scene="3" title="第3场 · 林小雨家 · 夜"><span class="axis-dot-circle"></span><span class="axis-dot-label">第3场</span></div>
                    <div class="axis-connector"></div>
                    <div class="axis-dot" data-scene="4" title="第4场 · 茶馆 · 日"><span class="axis-dot-circle"></span><span class="axis-dot-label">第4场</span></div>
                    <div class="axis-connector"></div>
                    <div class="axis-dot" data-scene="5" title="第5场 · 轮渡 · 黎明"><span class="axis-dot-circle"></span><span class="axis-dot-label">第5场</span></div>
                    <div class="axis-connector"></div>
                    <div class="axis-dot" data-scene="6" title="第6场 · 林小雨家 · 夜"><span class="axis-dot-circle"></span><span class="axis-dot-label">第6场</span></div>
                </div>
            </div>
        </div>

        <!-- ===== 剧本预览（只读） ===== -->
        <div id="script-area" style="display:none;">
            <div class="script-wrapper" id="script-wrapper">
                <div style="text-align:center;padding:80px 0;color:#999;">
                    <p style="font-size:1.2em;margin-bottom:8px;">📄 剧本预览</p>
                    <p style="font-size:0.85em;">打开 .sws 文件后自动渲染</p>
                </div>
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

        // ===== 选项卡切换：时间轴（编辑） / 剧本（只读预览） =====
        const timelineArea = document.getElementById('timeline-area');
        const scriptArea = document.getElementById('script-area');
        const modeLabel = document.getElementById('mode-label');
        const handle = document.getElementById('resize-handle');

        function onModeChange(mode) {
            console.log('[onModeChange] called with mode=' + mode);
            const isTimeline = mode === 'timeline';
            console.log('[onModeChange] isTimeline=' + isTimeline + ', timelineArea=' + !!timelineArea + ', scriptArea=' + !!scriptArea + ', sidebar=' + !!sidebar);

            // 更新模式标签
            if (modeLabel) {
                modeLabel.textContent = isTimeline ? '📋 时间轴（编辑）' : '📄 剧本（只读预览）';
            }

            // 切换内容区
            timelineArea.style.display = isTimeline ? 'flex' : 'none';
            scriptArea.style.display  = isTimeline ? 'none' : '';
            console.log('[onModeChange] timelineArea.display=' + timelineArea.style.display + ', scriptArea.display=' + scriptArea.style.display);

            // 时间轴模式：显示侧边栏；剧本模式：隐藏侧边栏（全宽阅读）
            if (isTimeline) {
                sidebar.classList.remove('collapsed');
                btnToggle.textContent = '📂';
                handle.style.display = '';
            } else {
                sidebar.classList.add('collapsed');
                btnToggle.textContent = '📂';
                handle.style.display = 'none';
                // 切换到剧本模式时，刷新剧本预览
                if (typeof window._renderScriptPreview === 'function') {
                    window._renderScriptPreview();
                }
            }
            console.log('[onModeChange] done');
        }
        window.onModeChange = onModeChange;

        // 默认时间轴模式
        onModeChange('timeline');

        // _renderScriptPreview — 确保剧本预览有内容（加载文件时 script-wrapper 已由 Swift 端填充）
        window._renderScriptPreview = function() {
            var scriptWrapper = document.getElementById('script-wrapper');
            if (!scriptWrapper) return;
            // 如果尚未加载文件，保持占位提示
            if (!scriptWrapper.innerHTML.trim() || scriptWrapper.innerText.trim() === '📄 剧本预览\n打开 .sws 文件后自动渲染') {
                scriptWrapper.innerHTML = '<div style="padding:80px 20px;text-align:center;color:var(--muted);font-size:1.1em;"><p style="font-size:2em;margin-bottom:12px;">📄</p><p>打开 .sws 文件后自动渲染</p></div>';
            }
        };

        // ===== 时间轴节点点击（跳转到对应场景卡片，占位） =====
        document.querySelectorAll('.axis-dot').forEach(dot => {
            dot.addEventListener('click', () => {
                const scene = dot.dataset.scene;
                const card = document.getElementById('timeline-scene-' + scene);
                if (card) {
                    card.scrollIntoView({ behavior: 'smooth', block: 'center' });
                    card.style.borderColor = 'var(--accent)';
                    setTimeout(() => { card.style.borderColor = ''; }, 800);
                }
            });
        });

        // ===== 加场按钮（占位） =====
        document.querySelector('.add-scene-card')?.addEventListener('click', () => {
            const btn = document.querySelector('.add-scene-card');
            btn.style.borderColor = 'var(--accent)';
            btn.style.color = 'var(--accent)';
            setTimeout(() => { btn.style.borderColor = ''; btn.style.color = ''; }, 300);
            console.log('[Timeline] 添加新场 — Phase 2 实现');
        });

        // ===== 角色选中 =====
        document.getElementById('char-list').addEventListener('click', (e) => {
            const item = e.target.closest('.char-item');
            if (!item) return;
            document.querySelectorAll('.char-item').forEach(el => el.classList.remove('active'));
            item.classList.add('active');
        });

        // ===== 侧边栏拖拽调整宽度 =====
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


    </script>
    </body>
    </html>
    """
}
