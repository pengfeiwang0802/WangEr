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
class ScriptwritingPlugin: NSObject, WangErPlugin, WKNavigationDelegate {
    let name = "编剧助手"
    let pluginDescription = "AI 辅助剧本创作与一致性分析"

    /// 页面是否加载完成（避免竞态：loadHTMLString 是异步的）
    private var isPageLoaded = false
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
        webView.navigationDelegate = self
        // 注册 JS → Swift 消息通道（编辑同步）
        webView.configuration.userContentController.add(self, name: "edit")
        webView.loadHTMLString(ScriptwritingLayout.html, baseURL: nil)

        // 工具栏（文件操作按钮）
        setupToolbar(in: window, webView: webView)

        // ⚠️ restoreLastSession 移到 didFinishNavigation，等 HTML 加载完再恢复

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

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isPageLoaded = true
        // 页面加载完毕后恢复上次 session（如果有）
        restoreLastSession(webView: webView)
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
        guard let document = currentDocument else {
            print("[PluginManager] renderCurrentDocument: currentDocument is nil, skip")
            return
        }
        guard let webView = scriptwritingWebView else {
            print("[PluginManager] renderCurrentDocument: scriptwritingWebView is nil, skip")
            return
        }
        print("[PluginManager] renderCurrentDocument: webView OK, isPageLoaded=\(isPageLoaded), scenes=\(document.scenes.count)")

        // 生成角色→颜色映射（全局一致，跨场景同角色同色）
        let characterColors = SWSRenderer.buildCharacterColorMap(document: document)

        let bodyHTML = SWSRenderer.renderBody(document: document, style: currentStyle, characterColors: characterColors)
        let fullHTML = SWSRenderer.render(document: document, style: currentStyle, characterColors: characterColors)

        // 从 fullHTML 中提取 title 和 author
        let titleMatch = fullHTML.range(of: "<div class='sws-title'[^>]*>([\\s\\S]*?)</div>", options: .regularExpression)
        let authorMatch = fullHTML.range(of: "<div class='sws-author'[^>]*>([\\s\\S]*?)</div>", options: .regularExpression)
        let titleHTML = titleMatch.flatMap { String(fullHTML[$0]) } ?? ""
        let authorHTML = authorMatch.flatMap { String(fullHTML[$0]) } ?? ""

        // 渲染到剧本预览（base64 传 HTML）
        let previewHTML = titleHTML + authorHTML + bodyHTML
        let htmlB64 = previewHTML.data(using: .utf8)!.base64EncodedString(options: [])
        print("[PluginManager] preview: html=\(previewHTML.utf8.count/1024)KB, b64=\(htmlB64.utf8.count/1024)KB")

        // 使用 HTML 中定义的 b64decode（已验证可用）
        let previewJS = """
        (function(){
            var el=document.getElementById('script-wrapper');
            if(!el){console.error('[preview] script-wrapper MISSING');return;}
            try {
                var html=b64decode('\(htmlB64)');
                el.innerHTML=html;
                console.log('[preview] OK, innerHTML length='+el.innerHTML.length+' text='+el.innerText.substring(0,80));
            } catch(e) {
                console.error('[preview] FAIL: '+e.message);
            }
        })();
        """
        webView.evaluateJavaScript(previewJS) { result, error in
            if let e = error {
                print("[PluginManager] preview JS ERROR: \(e.localizedDescription)")
            } else {
                print("[PluginManager] preview JS callback OK, result=\(result ?? "nil")")
            }
        }

        // 时间轴：生成 JSON → base64 → 调用 HTML 中已验证的 renderTimelineFromSWSBase64
        let timelineJSON = buildTimelineJSON(document: document, characterColors: characterColors)
        let tB64 = timelineJSON.data(using: .utf8)!.base64EncodedString(options: [])
        print("[PluginManager] timeline: json=\(timelineJSON.utf8.count/1024)KB, b64=\(tB64.utf8.count/1024)KB")

        // 调用 HTML 中定义的 renderTimelineFromSWSBase64（已验证无 bug）
        let timelineJS = "window.renderTimelineFromSWSBase64('\(tB64)');"
        webView.evaluateJavaScript(timelineJS) { result, error in
            if let e = error {
                print("[PluginManager] timeline JS ERROR: \(e.localizedDescription)")
            } else {
                // 渲染后验证 DOM
                let verifyJS = """
                (function(){
                    var el=document.getElementById('timeline-scroll');
                    if(!el) return 'NO_TIMELINE_SCROLL';
                    var cards=el.querySelectorAll('.scene-card');
                    return 'cards='+cards.length;
                })();
                """
                webView.evaluateJavaScript(verifyJS) { vResult, vError in
                    print("[PluginManager] timeline verify: \(vResult ?? "nil"), error=\(vError?.localizedDescription ?? "none")")
                }
            }
        }
    }

    /// 将 SWS 文档转为 JSON（供 JS 渲染时间轴用）
    private func buildTimelineJSON(document: SWSDocument, characterColors: [String: String]) -> String {
        var scenesJSON: [[String: Any]] = []
        for scene in document.scenes {
            var sceneDict: [String: Any] = [:]
            sceneDict["number"] = scene.heading?.number ?? "?"
            sceneDict["interiorExterior"] = scene.heading?.interiorExterior
            sceneDict["location"] = scene.heading?.location
            sceneDict["time"] = scene.heading?.time

            var blocksJSON: [[String: Any]] = []
            for block in scene.blocks {
                switch block {
                case .dialogue(let d):
                    var dDict: [String: Any] = [
                        "type": "dialogue",
                        "character": d.character,
                        "line": d.line
                    ]
                    if let modifier = d.modifier, !modifier.isEmpty {
                        dDict["modifier"] = modifier
                    }
                    blocksJSON.append(dDict)
                case .action(let a):
                    blocksJSON.append([
                        "type": "action",
                        "text": a.text
                    ])
                case .unattributed(let u):
                    blocksJSON.append([
                        "type": "unattributed",
                        "lines": u.lines
                    ])
                // .emptyLine 已废弃：block 文本中的 \n\n 替代空行
                }
            }
            sceneDict["blocks"] = blocksJSON
            scenesJSON.append(sceneDict)
        }

        var root: [String: Any] = [:]
        root["title"] = document.metadata.title ?? ""
        root["author"] = document.metadata.author ?? ""
        root["characters"] = document.allCharacters
        root["characterColors"] = characterColors
        root["scenes"] = scenesJSON

        guard let data = try? JSONSerialization.data(withJSONObject: root, options: []),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    // MARK: - 保存 .sws 文件

    /// 将当前文档直接序列化保存为 .sws 文件
    @objc func saveSWSFile(_ sender: Any?) {
        guard let url = currentFileURL else {
            print("ScriptwritingPlugin: 没有打开的文件，无法保存")
            return
        }
        guard let document = currentDocument else {
            print("ScriptwritingPlugin: 没有当前文档，无法保存")
            return
        }

        let formatter = SWSFormatter()
        let output = formatter.serialize(document)

        do {
            try output.write(to: url, atomically: true, encoding: .utf8)
            print("ScriptwritingPlugin: 已保存到 \(url.lastPathComponent)")
            setDirtyFlag(false)
        } catch {
            print("ScriptwritingPlugin: 保存失败 \(error)")
        }
    }

    /// 另存为：弹目录选择框，可换文件名、换位置
    @objc func saveAsSWSFile(_ sender: Any?) {
        guard let document = currentDocument else {
            print("ScriptwritingPlugin: 没有当前文档，无法另存为")
            return
        }

        let panel = NSSavePanel()
        panel.title = "另存为 .sws 剧本文件"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.init(filenameExtension: "sws")!]

        // 默认文件名：当前文件名 或 剧名.sws
        if let currentName = currentFileURL?.deletingPathExtension().lastPathComponent {
            panel.nameFieldStringValue = "\(currentName).sws"
        } else if let title = document.metadata.title, !title.isEmpty {
            panel.nameFieldStringValue = "\(title).sws"
        } else {
            panel.nameFieldStringValue = "未命名.sws"
        }

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }

            let formatter = SWSFormatter()
            let output = formatter.serialize(document)

            do {
                try output.write(to: url, atomically: true, encoding: .utf8)
                print("ScriptwritingPlugin: 已另存为 \(url.lastPathComponent)")
            } catch {
                print("ScriptwritingPlugin: 另存为失败 \(error)")
            }
        }
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
        [.flexibleSpace, .openFile, .saveFile, .saveAsFile, .toggleLayout]
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
        case .saveFile:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "保存"
            item.paletteLabel = "保存 .sws"
            item.toolTip = "保存当前编辑内容到 .sws 文件"
            item.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "保存")
            item.target = self
            item.action = #selector(saveSWSFile(_:))
            return item
        case .saveAsFile:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "另存为"
            item.paletteLabel = "另存为 .sws"
            item.toolTip = "选择位置和文件名保存 .sws 副本"
            item.image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: "另存为")
            item.target = self
            item.action = #selector(saveAsSWSFile(_:))
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
    static let toggleLayout = NSToolbarItem.Identifier("com.wanger.toggleLayout")
    static let saveFile = NSToolbarItem.Identifier("com.wanger.saveSWS")
    static let saveAsFile = NSToolbarItem.Identifier("com.wanger.saveAsSWS")
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

            /* ========== 文档标题栏 ========== */
            #doc-titlebar {
                height: 28px;
                min-height: 28px;
                background: var(--bg-secondary);
                border-bottom: 1px solid var(--border);
                display: flex;
                align-items: center;
                gap: 12px;
                padding: 0 16px;
                z-index: 12;
            }
            #doc-titlebar .doc-title {
                font-size: 0.85em;
                font-weight: 700;
                color: var(--text-primary);
            }
            #doc-titlebar .doc-author {
                font-size: 0.7em;
                color: var(--text-muted);
            }
            #doc-titlebar .doc-author::before {
                content: '✍️ ';
            }
            #doc-titlebar .doc-author:empty::before {
                content: '';
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

            /* ========== Timeline 可编辑元素 ========== */
            .scene-field {
                border: 1px solid transparent;
                background: transparent;
                font-size: 0.78em;
                font-weight: 600;
                padding: 3px 8px;
                border-radius: 5px;
                font-family: inherit;
                color: inherit;
                outline: none;
                min-width: 40px;
                transition: all 0.15s;
            }
            .scene-field:hover { border-color: var(--border); background: var(--bg-primary); }
            .scene-field:focus { border-color: var(--accent); background: var(--bg-primary); box-shadow: 0 0 0 2px var(--accent-soft); }
            .scene-field.ie-field { color: #f5a623; min-width: 50px; }
            .scene-field.loc-field { color: #a0a0b0; min-width: 80px; }
            .scene-field.time-field { color: #6a9fc5; min-width: 50px; }

            /* 文本编辑区（contenteditable，原地编辑，无切换） */
            .tl-content {
                flex: 1;
                font-size: 0.88em;
                line-height: 1.5;
                font-family: inherit;
                color: inherit;
                outline: none;
                border-radius: 4px;
                padding: 2px 6px;
                min-height: 1.5em;
                cursor: text;
            }
            /* block-wrap：聚焦竖线（与插入条同位置） */
            .block-wrap {
                border-left: 3px solid transparent;
                transition: border-color 0.15s;
                margin-bottom: 1px;
            }
            .block-wrap:focus-within {
                border-left-color: var(--accent);
            }
            .block-wrap[data-type="action"] .tl-content { color: #5a8a5a; }
            .block-wrap[data-type="dialogue"] .tl-content { color: var(--text-primary); }
            .block-wrap[data-type="unattributed"] .tl-content { color: #888; font-style: italic; }

            .char-chip {
                display: inline-flex;
                align-items: center;
                gap: 4px;
                padding: 2px 8px;
                border-radius: 5px;
                font-weight: 600;
                font-size: 0.88em;
                cursor: pointer;
                user-select: none;
                transition: all 0.15s;
                border: 1px solid transparent;
            }
            .char-chip:hover { filter: brightness(0.9); }

            /* 场景分隔条 */
            .scene-separator {
                height: 24px;
                display: flex;
                align-items: center;
                justify-content: center;
                border-top: 1px dashed transparent;
                border-bottom: 1px dashed transparent;
                transition: all 0.2s;
                position: relative;
            }
            .scene-separator:hover {
                border-top-color: var(--border);
                border-bottom-color: var(--border);
            }
            .add-scene-btn {
                display: none;
                width: 28px; height: 28px;
                border-radius: 50%;
                border: 1.5px dashed var(--border);
                background: var(--bg-secondary);
                color: var(--text-muted);
                font-size: 1.1em;
                cursor: pointer;
                align-items: center;
                justify-content: center;
                transition: all 0.2s;
                z-index: 2;
            }
            .scene-separator:hover .add-scene-btn {
                display: flex;
            }
            .add-scene-btn:hover {
                border-color: var(--accent);
                color: var(--accent);
                background: var(--accent-soft);
                transform: scale(1.15);
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

    <!-- ===== 文档标题栏 ===== -->
    <div id="doc-titlebar">
        <span class="doc-title">📜 未载入剧本</span>
        <span class="doc-author"></span>
    </div>

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
            <!-- 剧情块：由 renderTimelineFromSWSBase64 动态渲染 -->
            <div class="story-blocks"></div>
            <!-- 关键帧：由 renderTimelineFromSWSBase64 动态渲染 -->
            <div class="keyframe-layer"></div>
            <!-- 情绪曲线：由 renderTimelineFromSWSBase64 动态渲染 -->
            <div class="curve-layer">
                <svg viewBox="0 0 1000 50" preserveAspectRatio="none"></svg>
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
                <span class="count">—</span>
                <button class="add-char" title="添加角色">+</button>
            </div>
            <div class="char-list" id="char-list">
                <!-- 加载 .sws 文件后由 renderTimelineFromSWSBase64 动态渲染 -->
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
                <span class="timeline-title">📋 场景卡片</span>
                <span class="timeline-subtitle">— 场 · — 个角色</span>
            </div>
            <div class="timeline-scroll" id="timeline-scroll">
                <!-- 加载 .sws 文件后由 Swift 端动态渲染 -->
                <div style="text-align:center;padding:80px 20px;color:var(--text-muted);">
                    <p style="font-size:2em;margin-bottom:12px;">📋</p>
                    <p>打开 .sws 文件后自动渲染时间轴</p>
                </div>
            </div>

            <!-- 底部时间轴 -->
            <div class="timeline-axis">
                <div class="axis-line">
                    <!-- 加载 .sws 文件后由 JS 动态渲染 -->
                </div>
            </div>
        </div>

        <!-- ===== 剧本预览（只读） ===== -->
        <div id="script-area" style="display:none;">
            <div class="script-wrapper" id="script-wrapper">
                <!-- 加载 .sws 文件后由 Swift 端动态渲染 -->
                <div style="text-align:center;padding:80px 20px;color:var(--text-muted);">
                    <p style="font-size:2em;margin-bottom:12px;">📄</p>
                    <p>打开 .sws 文件后自动渲染预览</p>
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

        // _renderScriptPreview — 确保剧本预览有内容
        window._renderScriptPreview = function() {
            var scriptWrapper = document.getElementById('script-wrapper');
            if (!scriptWrapper) return;
            if (!scriptWrapper.innerText.trim() || scriptWrapper.innerText.includes('后自动渲染预览')) {
                scriptWrapper.innerHTML = '<div style="padding:80px 20px;text-align:center;color:var(--text-muted);"><p style="font-size:2em;margin-bottom:12px;">📄</p><p>打开 .sws 文件后自动渲染预览</p></div>';
            }
        };

        // ===== 时间轴节点 & 加场按钮：由 renderTimelineFromSWSBase64 动态绑定 =====
        // （初始化时 .axis-dot / .add-scene-card 尚未创建，无需绑定）

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

        // ===== 剧情块 & 关键帧：由 renderTimelineFromSWSBase64 动态绑定 =====

        // ===== 角色曲线开关：由 renderTimelineFromSWSBase64 动态绑定 =====

        // ===== 从 SWS JSON 数据渲染时间轴 =====
        // Tones cycle for story blocks: warm, cool, tense, calm, hot
        var TONES = ['warm', 'cool', 'tense', 'calm', 'hot'];
        var IE_EMOJI = { '内景': '🏠', '外景': '🌃' };
        var TIME_EMOJI = { '日': '☀️', '夜': '🌙', '黄昏': '🌅', '黎明': '🌅', '清晨': '🌄' };

        // UTF-8 safe base64 decoder (atob only does latin1!)
        function b64decode(b64) {
            console.log('[b64decode] input length:', b64.length, 'first 20:', b64.substring(0,20));
            var bin = atob(b64);
            var bytes = new Uint8Array(bin.length);
            for (var i = 0; i < bin.length; i++) { bytes[i] = bin.charCodeAt(i); }
            var result = new TextDecoder('utf-8').decode(bytes);
            console.log('[b64decode] done, output length:', result.length, 'first 40:', result.substring(0,40));
            return result;
        }

        window.renderTimelineFromSWSBase64 = function(b64) {
            console.log('[renderTimelineFromSWSBase64] called, b64 length:', b64.length);
            var jsonStr;
            try { jsonStr = b64decode(b64); } catch(e) { console.error('[timeline] base64 decode fail', e); return; }
            var data;
            try { data = JSON.parse(jsonStr); } catch(e) { console.error('parse SWS json fail', e); return; }
            if (!data || !data.scenes) return;

            var scenes = data.scenes;
            var characters = data.characters || [];
            var charColors = data.characterColors || {};
            var title = data.title || '';
            var author = data.author || '';

            // 更新文档标题栏
            var docTitleEl = document.querySelector('#doc-titlebar .doc-title');
            var docAuthorEl = document.querySelector('#doc-titlebar .doc-author');
            if (docTitleEl) docTitleEl.textContent = title ? '📜 ' + title : '📜 未命名剧本';
            if (docAuthorEl) docAuthorEl.textContent = author || '';

            // 更新时间轴 header 统计信息
            var statsTitleEl = document.querySelector('.timeline-title');
            var statsSubEl = document.querySelector('.timeline-subtitle');
            if (statsTitleEl) statsTitleEl.textContent = '📋 场景卡片';
            if (statsSubEl) statsSubEl.textContent = scenes.length + ' 场 · ' + characters.length + ' 个角色';

            // ── 渲染顶部剧情块 ──
            var blocksContainer = document.querySelector('.story-blocks');
            if (blocksContainer) {
                var pct = scenes.length > 0 ? Math.floor(90 / scenes.length) : 0;
                var lastPct = 100 - pct * (scenes.length - 1);
                var blockHTML = '';
                scenes.forEach(function(sc, i) {
                    var w = (i === scenes.length - 1) ? lastPct + '%' : pct + '%';
                    var tone = TONES[i % TONES.length];
                    var label = sc.location || ('第' + sc.number + '场');
                    if (label.length > 4) label = label.substring(0,4);
                    blockHTML += '<div class="story-block" data-tone="' + tone + '" style="width:' + w + ';" data-scene="' + sc.number + '" title="' + (sc.location || '') + '">';
                    blockHTML += '<span class="block-label">' + label + '</span>';
                    blockHTML += '</div>';
                });
                blocksContainer.innerHTML = blockHTML;
                // rebind clicks
                blocksContainer.querySelectorAll('.story-block').forEach(function(b) {
                    b.addEventListener('click', function() {
                        var sn = b.dataset.scene;
                        var card = document.getElementById('timeline-scene-' + sn);
                        if (card) { card.scrollIntoView({ behavior: 'smooth', block: 'center' }); card.style.borderColor = 'var(--accent)'; setTimeout(function(){ card.style.borderColor = ''; }, 800); }
                    });
                });
            }

            // ── 渲染关键帧标记 ──
            var kfLayer = document.querySelector('.keyframe-layer');
            if (kfLayer && scenes.length > 0) {
                var kfHTML = '';
                scenes.forEach(function(sc, i) {
                    var leftPct = (i / (scenes.length - 1 || 1)) * 100;
                    kfHTML += '<div class="keyframe-marker" style="left:' + leftPct + '%;" data-scene="' + sc.number + '" title="第' + sc.number + '场">';
                    kfHTML += '<div class="pin"></div>';
                    kfHTML += '<span class="kf-label">' + (sc.location || sc.number) + '</span>';
                    kfHTML += '</div>';
                });
                kfLayer.innerHTML = kfHTML;
                kfLayer.querySelectorAll('.keyframe-marker').forEach(function(m) {
                    m.addEventListener('click', function() {
                        var sn = m.dataset.scene;
                        var card = document.getElementById('timeline-scene-' + sn);
                        if (card) { card.scrollIntoView({ behavior: 'smooth', block: 'center' }); card.style.borderColor = 'var(--accent)'; setTimeout(function(){ card.style.borderColor = ''; }, 800); }
                    });
                });
            }

            // ── 渲染角色曲线开关 ──
            var togglesContainer = document.getElementById('curve-toggles');
            if (togglesContainer) {
                var togHTML = '';
                characters.forEach(function(name) {
                    var color = charColors[name] || '#999';
                    var id = 'char-' + name.replace(/[^a-zA-Z0-9\\u4e00-\\u9fff]/g, '');
                    togHTML += '<button class="toggle on" data-char="' + id + '"><span class="dot" style="color:' + color + ';"></span> ' + name + '</button>';
                });
                togglesContainer.innerHTML = togHTML;
            }

            // ── 渲染场景卡片（时间轴主内容） ──
            var scroll = document.getElementById('timeline-scroll');
            if (scroll) {
                var cardHTML = '';
                scenes.forEach(function(sc, i) {
                    var ie = sc.interiorExterior || '';
                    var loc = sc.location || '';
                    var time = sc.time || '';
                    var ieEmoji = IE_EMOJI[ie] || '📍';
                    var timeEmoji = TIME_EMOJI[time] || '🕐';

                    cardHTML += '<div class="scene-card" data-scene="' + sc.number + '" id="timeline-scene-' + sc.number + '">';
                    cardHTML += '<div class="scene-card-header">';
                    cardHTML += '<div class="scene-number"><span class="scene-num-circle">' + sc.number + '</span></div>';
                    cardHTML += '<div class="scene-meta-fields">';
                    cardHTML += '<input class="scene-field ie-field" data-scene="' + sc.number + '" data-field="interiorExterior" value="' + escHTML(ie) + '" placeholder="内景/外景" />';
                    cardHTML += '<input class="scene-field loc-field" data-scene="' + sc.number + '" data-field="location" value="' + escHTML(loc) + '" placeholder="地点" />';
                    cardHTML += '<input class="scene-field time-field" data-scene="' + sc.number + '" data-field="time" value="' + escHTML(time) + '" placeholder="时间" />';
                    cardHTML += '</div></div>';
                    cardHTML += '<div class="scene-card-body">';

                    var blkIdx = 0;
                    (sc.blocks || []).forEach(function(blk) {
                        if (blk.type === 'action') {
                            cardHTML += '<div class="block-wrap" data-scene="' + sc.number + '" data-block="' + blkIdx + '" data-type="action">';
                            cardHTML += '<div class="tl-block tl-action"><span class="tl-block-icon">📝</span>';
                            cardHTML += '<div class="tl-content" contenteditable="true">' + escHTML(blk.text || '') + '</div>';
                            cardHTML += '</div></div>';
                            blkIdx++;
                        } else if (blk.type === 'dialogue') {
                            var charColor = charColors[blk.character] || '#999';
                            cardHTML += '<div class="block-wrap" data-scene="' + sc.number + '" data-block="' + blkIdx + '" data-type="dialogue">';
                            cardHTML += '<div class="tl-block tl-dialogue">';
                            cardHTML += '<span class="tl-block-icon">👤</span>';
                            cardHTML += '<span class="char-chip" data-scene="' + sc.number + '" data-block="' + blkIdx + '" data-character="' + escHTML(blk.character || '') + '" style="background:' + charColor + '18;color:' + charColor + ';">' + escHTML(blk.character || '') + '</span>';
                            if (blk.modifier) cardHTML += '<span class="tl-char-mod">（' + escHTML(blk.modifier) + '）</span>';
                            cardHTML += '</div>';
                            cardHTML += '<div class="tl-block tl-dialogue-text">';
                            cardHTML += '<span class="tl-block-icon">💬</span>';
                            cardHTML += '<div class="tl-content" contenteditable="true">' + escHTML(blk.line || '') + '</div>';
                            cardHTML += '</div></div>';
                            blkIdx++;
                        } else if (blk.type === 'unattributed') {
                            (blk.lines || []).forEach(function(l) {
                                cardHTML += '<div class="block-wrap" data-scene="' + sc.number + '" data-block="' + blkIdx + '" data-type="unattributed">';
                                cardHTML += '<div class="tl-block tl-action" style="color:#888;font-style:italic;"><span class="tl-block-icon">💬</span>';
                                cardHTML += '<div class="tl-content" contenteditable="true">' + escHTML(l) + '</div>';
                                cardHTML += '</div></div>';
                                blkIdx++;
                            });
                        }
                    });

                    cardHTML += '</div></div>';

                    // scene separator (except after last scene's add-scene-card)
                    cardHTML += '<div class="scene-separator" data-after-scene="' + sc.number + '"><button class="add-scene-btn" title="添加新场景">+</button></div>';
                });

                // 底部大「添加新场」按钮（始终可见）
                cardHTML += '<div class="add-scene-card" title="添加新场" id="add-scene-big"><span class="add-scene-icon">＋</span><span class="add-scene-label">添加新场</span></div>';
                scroll.innerHTML = cardHTML;

                // rebind all add-scene buttons (separators + big bottom button)
                scroll.querySelectorAll('.add-scene-btn, .add-scene-card').forEach(function(btn) {
                    btn.addEventListener('click', function() {
                        this.style.borderColor = 'var(--accent)';
                        this.style.color = 'var(--accent)';
                        setTimeout(function(){ this.style.borderColor = ''; this.style.color = ''; }.bind(this), 300);
                    }.bind(btn));
                });
            }

            // ── 渲染底部时间轴节点 ──
            var axisLine = document.querySelector('.axis-line');
            if (axisLine && scenes.length > 0) {
                var axisHTML = '';
                scenes.forEach(function(sc, i) {
                    if (i > 0) axisHTML += '<div class="axis-connector"></div>';
                    axisHTML += '<div class="axis-dot" data-scene="' + sc.number + '" title="第' + sc.number + '场"><span class="axis-dot-circle"></span><span class="axis-dot-label">第' + sc.number + '场</span></div>';
                });
                axisLine.innerHTML = axisHTML;
                axisLine.querySelectorAll('.axis-dot').forEach(function(dot) {
                    dot.addEventListener('click', function() {
                        var sn = dot.dataset.scene;
                        var card = document.getElementById('timeline-scene-' + sn);
                        if (card) { card.scrollIntoView({ behavior: 'smooth', block: 'center' }); card.style.borderColor = 'var(--accent)'; setTimeout(function(){ card.style.borderColor = ''; }, 800); }
                    });
                });
            }

            // ── 渲染角色列表 ──
            var charList = document.getElementById('char-list');
            if (charList) {
                var charHTML = '';
                var defaultAvatars = ['🧔','👨','👩','👨‍🦳','👩‍🦰','👴','🧑','👩‍🦱','👨‍🦱'];
                characters.forEach(function(name, idx) {
                    var avatar = defaultAvatars[idx % defaultAvatars.length];
                    var color = charColors[name] || '#999';
                    var id = 'char-sid-' + name.replace(/[^a-zA-Z0-9\\u4e00-\\u9fff]/g, '');
                    charHTML += '<div class="char-item' + (idx === 0 ? ' active' : '') + '" data-char="' + id + '">';
                    charHTML += '<div class="avatar" style="background:' + color + '22;color:' + color + ';">' + avatar + '</div>';
                    charHTML += '<div class="info"><div class="name">' + escHTML(name) + '</div><div class="role">角色</div></div>';
                    charHTML += '</div>';
                });
                charList.innerHTML = charHTML;
                // rebind character selection
                charList.addEventListener('click', function(e) {
                    var item = e.target.closest('.char-item');
                    if (!item) return;
                    charList.querySelectorAll('.char-item').forEach(function(el) { el.classList.remove('active'); });
                    item.classList.add('active');
                });
            }

            // 更新角色计数
            var countEl = document.querySelector('.sidebar-header .count');
            if (countEl) countEl.textContent = characters.length;

            // 更新剧情轴 hint
            var hintEl = document.querySelector('.storybar-header .hint');
            if (hintEl) hintEl.textContent = scenes.length + ' 场 · ' + characters.length + ' 个角色';

            console.log('[Timeline] 已渲染 ' + scenes.length + ' 场, ' + characters.length + ' 个角色');
        };

        function escHTML(s) {
            if (!s) return '';
            return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
        }

        // ===== 可编辑元素事件处理 =====

        // Focusout → push edit to Swift
        document.addEventListener('focusout', function(e) {
            var el = e.target;
            var patch = null;
            
            if (el.classList.contains('scene-field')) {
                var field = el.dataset.field;
                var sceneNum = el.dataset.scene;
                var value = el.value.trim();
                patch = {
                    action: 'updateHeading',
                    scene: sceneNum,
                    field: field,
                    value: value
                };
            } else if (el.classList.contains('tl-content')) {
                var wrap = el.closest('.block-wrap');
                if (!wrap) return;
                var sceneNum = wrap.dataset.scene;
                var blockIdx = parseInt(wrap.dataset.block);
                var type = wrap.dataset.type;
                var value = el.innerText;
                patch = {
                    action: 'updateBlock',
                    scene: sceneNum,
                    blockIndex: blockIdx,
                    type: type,
                    value: value
                };
            }

            if (patch && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.edit) {
                try {
                    window.webkit.messageHandlers.edit.postMessage(patch);
                } catch(err) {
                    console.log('[Timeline] postMessage fail:', err);
                }
            }
        });

        // Cmd+Enter → 在当前块下方新建块并聚焦
        document.addEventListener('keydown', function(e) {
            if (!(e.metaKey && e.key === 'Enter')) return;
            var el = document.activeElement;
            if (!el || !el.classList.contains('tl-content')) return;
            var wrap = el.closest('.block-wrap');
            if (!wrap) return;
            e.preventDefault();
            e.stopPropagation();
            
            // 先触发 focusout 保存当前编辑
            el.blur();
            
            var sceneNum = wrap.dataset.scene;
            var blockIdx = parseInt(wrap.dataset.block);
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.edit) {
                window.webkit.messageHandlers.edit.postMessage({
                    action: 'insertBlock',
                    scene: sceneNum,
                    afterBlock: blockIdx,
                    type: 'action'
                });
            }
        });

    </script>
    </body>
    </html>
    """
}

// MARK: - WKScriptMessageHandler (编辑同步)
extension ScriptwritingPlugin: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "edit",
              let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }

        switch action {
        case "updateHeading":
            handleUpdateHeading(body)
        case "updateBlock":
            handleUpdateBlock(body)
        case "insertBlock":
            handleInsertBlock(body)
        default:
            break
        }

        // 设置脏标记
        setDirtyFlag(true)
    }

    private func handleUpdateHeading(_ body: [String: Any]) {
        guard let sceneNum = body["scene"] as? String,
              let field = body["field"] as? String,
              let value = body["value"] as? String,
              let doc = currentDocument else { return }

        // Find the scene index
        guard let sceneIdx = doc.scenes.firstIndex(where: { $0.heading?.number == sceneNum }) else { return }
        var scene = doc.scenes[sceneIdx]
        guard var heading = scene.heading else { return }

        switch field {
        case "interiorExterior": heading = SWSSceneHeading(number: heading.number, interiorExterior: value.isEmpty ? nil : value, location: heading.location, time: heading.time, separator: heading.separator)
        case "location": heading = SWSSceneHeading(number: heading.number, interiorExterior: heading.interiorExterior, location: value.isEmpty ? nil : value, time: heading.time, separator: heading.separator)
        case "time": heading = SWSSceneHeading(number: heading.number, interiorExterior: heading.interiorExterior, location: heading.location, time: value.isEmpty ? nil : value, separator: heading.separator)
        default: return
        }

        scene = SWSScene(heading: heading, blocks: scene.blocks)
        var scenes = doc.scenes
        scenes[sceneIdx] = scene
        currentDocument = SWSDocument(metadata: doc.metadata, scenes: scenes)
    }

    private func handleUpdateBlock(_ body: [String: Any]) {
        guard let sceneNum = body["scene"] as? String,
              let blockIdx = body["blockIndex"] as? Int,
              let type = body["type"] as? String,
              let value = body["value"] as? String,
              let doc = currentDocument else { return }

        guard let sceneIdx = doc.scenes.firstIndex(where: { $0.heading?.number == sceneNum }) else { return }
        var scene = doc.scenes[sceneIdx]
        guard blockIdx < scene.blocks.count else { return }

        var blocks = scene.blocks
        let block = blocks[blockIdx]

        switch (type, block) {
        case ("action", .action):
            blocks[blockIdx] = .action(SWSActionBlock(text: value))
        case ("dialogue", .dialogue(let d)):
            blocks[blockIdx] = .dialogue(SWSDialogueBlock(character: d.character, modifier: d.modifier, line: value))
        case ("unattributed", .unattributed):
            blocks[blockIdx] = .unattributed(SWSUnattributedBlock(lines: [value]))
        default:
            // Type mismatch — skip
            return
        }

        scene = SWSScene(heading: scene.heading, blocks: blocks)
        var scenes = doc.scenes
        scenes[sceneIdx] = scene
        currentDocument = SWSDocument(metadata: doc.metadata, scenes: scenes)
    }

    private func handleInsertBlock(_ body: [String: Any]) {
        guard let sceneNum = body["scene"] as? String,
              let afterBlock = body["afterBlock"] as? Int,
              let doc = currentDocument else { return }

        guard let sceneIdx = doc.scenes.firstIndex(where: { $0.heading?.number == sceneNum }) else { return }
        var scene = doc.scenes[sceneIdx]

        var blocks = scene.blocks
        let insertIdx = min(afterBlock + 1, blocks.count)
        blocks.insert(.action(SWSActionBlock(text: "")), at: insertIdx)

        scene = SWSScene(heading: scene.heading, blocks: blocks)
        var scenes = doc.scenes
        scenes[sceneIdx] = scene
        currentDocument = SWSDocument(metadata: doc.metadata, scenes: scenes)

        // Re-render timeline, then focus new block
        renderCurrentDocument()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.focusBlock(scene: sceneNum, blockIndex: insertIdx)
        }
    }

    private func focusBlock(scene: String, blockIndex: Int) {
        guard let webView = scriptwritingWebView else { return }
        let js = """
        (function(){
            var w=document.querySelector('.block-wrap[data-scene=\"\(scene)\"][data-block=\"\(blockIndex)\"]');
            if(w){var c=w.querySelector('.tl-content');if(c){c.focus();var r=document.createRange();r.selectNodeContents(c);r.collapse(false);var s=window.getSelection();s.removeAllRanges();s.addRange(r);}}
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private func setDirtyFlag(_ dirty: Bool) {
        guard let window = findPluginWindow() else { return }
        let title = window.title
        let hasDot = title.hasSuffix(" \u{25CF}")

        if dirty && !hasDot {
            window.title = title + " \u{25CF}"
        } else if !dirty && hasDot {
            window.title = String(title.dropLast(2))
        }
    }
}
