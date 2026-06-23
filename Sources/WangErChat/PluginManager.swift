import AppKit
import WebKit
import UniformTypeIdentifiers
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
    /// 项目文件管理器（.swsproj）
    private let projectManager = SWSProjectManager()
    /// Bridge ID counter
    private var bridgeIdCounter: Int = 0

    func createWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 750),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("scriptwriting")
        window.title = "✍️ 编剧助手"
        window.minSize = NSSize(width: 780, height: 500)
        window.center()

        guard let contentView = window.contentView else { return window }

        let webView = WKWebView(frame: .zero)
        webView.translatesAutoresizingMaskIntoConstraints = false

        // 透明背景，让 HTML 的深色主题透出
        webView.setValue(false, forKey: "drawsBackground")
        contentView.addSubview(webView)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: contentView.topAnchor),
            webView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        // 先加载默认空布局
        webView.navigationDelegate = self
        webView.uiDelegate = self
        // 注册 JS → Swift 消息通道
        webView.configuration.userContentController.add(self, name: "bridge")
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

            // 窗口标题始终是编剧助手
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "scriptwriting" }) {
                window.title = "✍️ 编剧助手"
            }

            renderCurrentDocument()

            // 刷新 sidebar（项目内文件 vs 游离文件）
            pushSidebarToWebView()

            // 加载后清除所有红色验证标记
            clearInvalidMarks()
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
        guard scriptwritingWebView != nil else {
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
        // 渲染剧本预览
        let previewHTML = titleHTML + authorHTML + bodyHTML
        let htmlB64 = previewHTML.data(using: .utf8)!.base64EncodedString(options: [])
        print("[PluginManager] preview: html=\(previewHTML.utf8.count/1024)KB, b64=\(htmlB64.utf8.count/1024)KB")
        bridgeSend(action: "renderScript", payload: ["htmlB64": htmlB64])

        // 时间轴：生成 JSON → base64 → 通过 bridge 渲染
        let timelineJSON = buildTimelineJSON(document: document, characterColors: characterColors)
        let tB64 = timelineJSON.data(using: .utf8)!.base64EncodedString(options: [])
        print("[PluginManager] timeline: json=\(timelineJSON.utf8.count/1024)KB, b64=\(tB64.utf8.count/1024)KB")
        bridgeSend(action: "renderTimeline", payload: ["b64": tB64, "expectedScenes": document.scenes.count])
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

    /// 清除所有红色验证标记
    private func clearInvalidMarks() {
        bridgeSend(action: "clearInvalidMarks")
    }

    // MARK: - Bridge Protocol

    private func bridgeSend(action: String, payload: [String: Any] = [:], id: String? = nil) {
        guard let webView = scriptwritingWebView else { return }
        let msgId = id ?? "s2j_\(nextBridgeId())"
        let envelope: [String: Any] = ["id": msgId, "action": action, "payload": payload]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: envelope),
              let jsonStr = String(data: jsonData, encoding: .utf8) else {
            print("[Bridge] failed to serialize envelope for action: \(action)")
            return
        }
        webView.evaluateJavaScript("window.__bridgeReceive(\(jsonStr))") { result, error in
            if let e = error {
                print("[Bridge] JS error for \(action) (\(msgId)): \(e.localizedDescription)")
            }
        }
    }

    private func nextBridgeId() -> Int {
        bridgeIdCounter += 1
        return bridgeIdCounter
    }

    // MARK: - 项目文件管理（.swsproj）

    @objc func newSWSProject(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.title = "新建编剧项目"
        panel.nameFieldStringValue = "未命名"
        panel.prompt = "创建"
        panel.message = "选择一个位置，将创建以项目名命名的文件夹。\n文件夹内包含 .swsproj 项目文件和初始剧本。"

        guard let window = findPluginWindow() else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            // url 是用户指定的路径（如 /Users/xxx/Documents/我的电影）
            // createProject 会在此路径创建文件夹
            let title = url.lastPathComponent
            do {
                try self.projectManager.createProject(at: url, title: title)
                self.pushProjectToWebView()
            } catch {
                self.showAlert("无法创建项目：\(error.localizedDescription)")
            }
        }
    }

    @objc func openSWSProject(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "打开编剧项目"
        panel.allowedContentTypes = [UTType(filenameExtension: "swsproj") ?? .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard let window = findPluginWindow() else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                try self.projectManager.loadProject(from: url)
                self.pushProjectToWebView()
            } catch {
                self.showAlert("无法打开项目：\(error.localizedDescription)")
            }
        }
    }

    @objc func saveSWSProject(_ sender: Any?) {
        guard projectManager.isProjectOpen else { return }
        if projectManager.fileURL != nil {
            do {
                try projectManager.save()
            } catch {
                showAlert("保存失败：\(error.localizedDescription)")
            }
        } else {
            saveSWSProjectAs()
        }
    }

    private func saveSWSProjectAs() {
        guard projectManager.isProjectOpen else { return }
        let panel = NSSavePanel()
        panel.title = "另存为 .swsproj"
        panel.nameFieldStringValue = projectManager.fileName
        panel.prompt = "保存"
        panel.allowedContentTypes = [UTType(filenameExtension: "swsproj") ?? .json]

        guard let window = findPluginWindow() else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                try self.projectManager.saveAs(to: url)
            } catch {
                self.showAlert("保存失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - 推送项目到 WebView

    /// 推送项目数据到 WebView（含 sidebar tree，自动包含游离文件）
    private func pushProjectToWebView() {
        guard let proj = projectManager.project else { return }

        // 构建完整 sidebar tree（含游离文件）
        var externalURLs: [URL] = []
        if let currentURL = currentFileURL, !projectManager.isScriptInProject(currentURL) {
            externalURLs.append(currentURL)
        }
        let fullTree = projectManager.sidebarTree(externalScripts: externalURLs)
        let json = ScriptwritingEditHandler.encodeProjectToJSON(proj, treeOverride: fullTree)
        bridgeSend(action: "loadProject", payload: ["json": json])
    }

    /// 仅推送 sidebar tree 到 WebView（无项目或游离文件场景）
    private func pushSidebarToWebView() {
        // 收集当前打开的野生 .sws 文件
        var externalURLs: [URL] = []
        if let currentURL = currentFileURL {
            if projectManager.isProjectOpen {
                if !projectManager.isScriptInProject(currentURL) {
                    externalURLs.append(currentURL)
                }
            } else {
                externalURLs.append(currentURL)
            }
        }

        if projectManager.isProjectOpen {
            // 有项目：完整 project JSON + 游离文件
            pushProjectToWebView()
        } else {
            // 无项目：只推 sidebar tree（虚拟项目骨架）
            let tree = projectManager.sidebarTree(externalScripts: externalURLs)
            let treeJSON = ScriptwritingEditHandler.encodeSidebarTree(tree)
            bridgeSend(action: "loadSidebar", payload: ["json": treeJSON])
        }
    }

    private func showAlert(_ message: String) {
        DispatchQueue.main.async {
            guard let window = self.findPluginWindow() else { return }
            let alert = NSAlert()
            alert.messageText = "编剧助手"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "确定")
            alert.beginSheetModal(for: window)
        }
    }

    // MARK: - 窗口/WebView 查找辅助

    private func findPluginWindow() -> NSWindow? {
        return NSApp.windows.first(where: { $0.identifier?.rawValue == "scriptwriting" })
    }

    @objc func showLayoutMenu(_ sender: NSToolbarItem) {
        // fallback: 直接循环切换
        fallbackToggleLayout()
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
        TemplateManagerWindow.shared.onWillClose = { [weak self] in
            self?.refreshLayoutMenu()
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
        [.newProject, .openProject, .openFile, .saveFile, .saveProject, .saveAsFile, .flexibleSpace, .toggleLayout]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .newProject:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "新建项目"
            item.paletteLabel = "新建项目"
            item.toolTip = "新建 .swsproj 编剧项目"
            item.image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: "新建项目")
            item.target = self
            item.action = #selector(newSWSProject(_:))
            return item
        case .openProject:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "打开项目"
            item.paletteLabel = "打开 .swsproj"
            item.toolTip = "打开 .swsproj 编剧项目"
            item.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: "打开项目")
            item.target = self
            item.action = #selector(openSWSProject(_:))
            return item
        case .saveProject:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "保存项目"
            item.paletteLabel = "保存 .swsproj"
            item.toolTip = "保存项目到 .swsproj 文件"
            item.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "保存项目")
            item.target = self
            item.action = #selector(saveSWSProject(_:))
            return item
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
    static let newProject = NSToolbarItem.Identifier("com.wanger.newProject")
    static let openProject = NSToolbarItem.Identifier("com.wanger.openProject")
    static let saveProject = NSToolbarItem.Identifier("com.wanger.saveProject")
    static let openFile = NSToolbarItem.Identifier("com.wanger.openSWS")
    static let toggleLayout = NSToolbarItem.Identifier("com.wanger.toggleLayout")
    static let saveFile = NSToolbarItem.Identifier("com.wanger.saveSWS")
    static let saveAsFile = NSToolbarItem.Identifier("com.wanger.saveAsSWS")
}

// MARK: - 编剧助手 UI 布局
enum ScriptwritingLayout {
    static let html: String = {
        guard let url = Bundle.module.url(forResource: "scriptwriting", withExtension: "html"),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            fatalError("scriptwriting.html not found in bundle")
        }
        return content
    }()
}

// MARK: - WKScriptMessageHandler (bridge dispatch)
extension ScriptwritingPlugin: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "bridge",
              let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }

        let payload = body["payload"] as? [String: Any] ?? [:]
        let msgId = body["id"] as? String ?? "?"

        // 剧本编辑操作（原 edit 通道）
        if ScriptwritingEditHandler.isEditAction(action) {
            handleEditAction(action, payload: payload)
            return
        }

        // 项目管理操作（原 swsproj 通道）
        handleProjectAction(action, payload: payload, msgId: msgId)
    }

    private func handleEditAction(_ action: String, payload: [String: Any]) {
        guard let doc = currentDocument else { return }
        let result = ScriptwritingEditHandler.processEdit(action: action, body: payload, document: doc)
        guard case .updated(let newDoc, let postActions) = result else { return }

        currentDocument = newDoc
        setDirtyFlag(true)

        for pa in postActions {
            switch pa {
            case .reRender:
                renderCurrentDocument()
            case .focusBlock(let scene, let idx):
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    self?.focusBlock(scene: scene, blockIndex: idx)
                }
            case .focusBlockChipSelected(let scene, let idx):
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    self?.focusBlockChipSelected(scene: scene, blockIndex: idx)
                }
            }
        }
    }

    private func handleProjectAction(_ action: String, payload: [String: Any], msgId: String) {
        let mgr = projectManager
        switch action {
        case "markDirty": mgr.markDirty()
        case "updateOutline":
            if let md = payload["content"] as? String { mgr.updateOutline(md) }
        case "updateScript":
            if let text = payload["content"] as? String { mgr.updateScript(text) }
        case "updateCharacter":
            if let id = payload["id"] as? String {
                mgr.updateCharacter(id: id, name: payload["name"] as? String, tagline: payload["tagline"] as? String, bio: payload["bio"] as? String, avatar: payload["avatar"] as? String)
                try? mgr.save()
                pushProjectToWebView()
            }
        case "updateScene":
            if let id = payload["id"] as? String {
                mgr.updateScene(id: id, title: payload["title"] as? String, content: payload["content"] as? String, location: payload["location"] as? String, time: payload["time"] as? String)
            }
        case "addCharacter":
            if let name = payload["name"] as? String {
                mgr.addCharacter(name: name, avatar: payload["avatar"] as? String, tagline: payload["tagline"] as? String, bio: payload["bio"] as? String)
                try? mgr.save()
                pushProjectToWebView()
            }
        case "deleteCharacter":
            if let id = payload["id"] as? String {
                mgr.deleteCharacter(id: id)
                try? mgr.save()
                pushProjectToWebView()
            }
        case "addScene":
            if let title = payload["title"] as? String {
                mgr.addScene(title: title, location: payload["location"] as? String, time: payload["time"] as? String, content: payload["content"] as? String)
            }
        case "selectNode":
            if let nodeType = payload["nodeType"] as? String,
               let nodeRef = payload["nodeRef"] as? String {
                handleSelectNode(type: nodeType, ref: nodeRef)
            }
        case "requestSync": pushProjectToWebView()
        case "sidebarRenderVerify":
            let expected = payload["expected"] as? Int ?? -1
            let rendered = payload["rendered"] as? Int ?? -1
            let categories = payload["categories"] as? String ?? "?"
            if expected != rendered {
                print("[Scriptwriting] ⚠️ Sidebar render mismatch: expected \(expected) nodes, rendered \(rendered), cats=[\(categories)]")
            } else {
                print("[Scriptwriting] ✅ Sidebar render OK: \(expected) nodes, cats=[\(categories)]")
            }
        default:
            print("[Bridge] unknown action: \(action), id=\(msgId)")
        }
    }

    private func handleSelectNode(type: String, ref: String) {
        switch type {
        case "script":
            guard let proj = projectManager.project else { return }
            guard let scriptRef = proj.scriptRef(id: ref) else { return }
            do {
                let doc = try projectManager.loadScript(ref: scriptRef)
                let dir = projectManager.projectDir
                let swsURL = dir?.appendingPathComponent(scriptRef.path) ?? URL(fileURLWithPath: "/")
                currentFileURL = swsURL
                currentDocument = doc
                renderCurrentDocument()
            } catch {
                print("ScriptwritingPlugin: 加载项目脚本失败 \(error)")
            }
        case "externalScript":
            let url = URL(fileURLWithPath: ref)
            guard FileManager.default.fileExists(atPath: ref) else {
                showAlert("文件不存在：\(ref)")
                return
            }
            loadSWSFile(url: url)
        default:
            break
        }
    }

    private func focusBlockChipSelected(scene: String, blockIndex: Int) {
        bridgeSend(action: "focusBlockChipSelected", payload: ["scene": scene, "blockIndex": blockIndex])
    }

    private func focusBlock(scene: String, blockIndex: Int) {
        bridgeSend(action: "focusBlock", payload: ["scene": scene, "blockIndex": blockIndex])
    }

    // encodeProjectToJSON / encodeTreeNode 已移至 ScriptwritingEditHandler

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

// MARK: - WKUIDelegate (JS alert/confirm 弹窗)
extension ScriptwritingPlugin: WKUIDelegate {
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard let window = findPluginWindow() else {
            completionHandler()
            return
        }
        let alert = NSAlert()
        alert.messageText = "编剧助手"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "确定")
        alert.beginSheetModal(for: window) { _ in
            completionHandler()
        }
    }
}
