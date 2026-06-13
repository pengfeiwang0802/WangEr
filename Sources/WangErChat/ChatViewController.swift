import AppKit
import WebKit

class ChatViewController: NSViewController {
    // === UI 组件 ===
    private let splitView = NSSplitView()
    private let sidebarView = NSView()
    private let chatContainer = NSView()
    
    private let toolbarView = NSView()
    private let modelButton = NSButton()
    private let settingsButton = NSButton()
    
    // 边栏
    private let conversationLabel = NSTextField()
    private let newChatButton = NSButton()
    private let conversationTableView = NSTableView()
    private let conversationScrollView = NSScrollView()
    private let agentsLabel = NSTextField()
    private let addAgentButton = NSButton()
    private let agentsTableView = NSTableView()
    private let agentsScrollView = NSScrollView()
    private let sidebarDivider = NSBox()
    
    // 聊天区
    private let webView = WKWebView()
    private let textView = SendTextView()
    private let textScrollView = NSScrollView()
    private let sendButton = NSButton()
    private let stopButton = NSButton()
    
    // 底部状态栏
    private let statusBar = NSView()
    private let modelLabel = NSTextField()
    private let tokenLabel = NSTextField()
    private let balanceLabel = NSTextField()
    
    // 模型选择
    private let modelMenu = NSMenu()
    
    // === 状态 ===
    private var messages: [[String: String]] = []
    private var isGenerating = false
    private var currentStreamTask: URLSessionDataTask?
    private var totalPromptTokens = 0
    private var totalCompletionTokens = 0
    private var streamCharCount = 0
    
    private var currentModel = "DeepSeek V4"
    private var balance: String = "--"
    
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 860, height: 660))
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupSplitView()
        setupStatusBar()
        setupSidebar()
        setupToolbar()
        setupChatArea()
        setupModelMenu()
        loadChatHTML()
        updateUsageDisplay()
        fetchBalance()
    }
    
    // MARK: - 主布局
    private func setupSplitView() {
        splitView.isVertical = true; splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(splitView)
        sidebarView.translatesAutoresizingMaskIntoConstraints = false
        splitView.addArrangedSubview(sidebarView)
        chatContainer.translatesAutoresizingMaskIntoConstraints = false
        splitView.addArrangedSubview(chatContainer)
        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: view.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sidebarView.widthAnchor.constraint(equalToConstant: 220),
        ])
    }
    
    // MARK: - 左侧边栏
    private func setupSidebar() {
        sidebarView.wantsLayer = true
        sidebarView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        
        conversationLabel.translatesAutoresizingMaskIntoConstraints = false
        conversationLabel.stringValue = "💬 会话"
        conversationLabel.font = NSFont.boldSystemFont(ofSize: 13)
        conversationLabel.isEditable = false; conversationLabel.isBordered = false; conversationLabel.backgroundColor = .clear
        sidebarView.addSubview(conversationLabel)
        
        newChatButton.translatesAutoresizingMaskIntoConstraints = false
        newChatButton.title = "＋"; newChatButton.bezelStyle = .smallSquare
        newChatButton.action = #selector(newConversation); newChatButton.target = self
        sidebarView.addSubview(newChatButton)
        
        let convCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("conversation"))
        convCol.width = 200
        conversationTableView.addTableColumn(convCol)
        conversationTableView.headerView = nil; conversationTableView.style = .plain
        conversationTableView.rowHeight = 32; conversationTableView.backgroundColor = .clear
        conversationTableView.selectionHighlightStyle = .sourceList
        conversationScrollView.documentView = conversationTableView
        conversationScrollView.hasVerticalScroller = false
        conversationScrollView.translatesAutoresizingMaskIntoConstraints = false
        sidebarView.addSubview(conversationScrollView)
        
        sidebarDivider.translatesAutoresizingMaskIntoConstraints = false
        sidebarDivider.boxType = .separator
        sidebarView.addSubview(sidebarDivider)
        
        agentsLabel.translatesAutoresizingMaskIntoConstraints = false
        agentsLabel.stringValue = "🤖 Agents"
        agentsLabel.font = NSFont.boldSystemFont(ofSize: 13)
        agentsLabel.isEditable = false; agentsLabel.isBordered = false; agentsLabel.backgroundColor = .clear
        sidebarView.addSubview(agentsLabel)
        
        addAgentButton.translatesAutoresizingMaskIntoConstraints = false
        addAgentButton.title = "＋"; addAgentButton.bezelStyle = .smallSquare
        addAgentButton.action = #selector(addAgent); addAgentButton.target = self
        sidebarView.addSubview(addAgentButton)
        
        let agentCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("agent"))
        agentCol.width = 200
        agentsTableView.addTableColumn(agentCol)
        agentsTableView.headerView = nil; agentsTableView.style = .plain
        agentsTableView.rowHeight = 32; agentsTableView.backgroundColor = .clear
        agentsTableView.selectionHighlightStyle = .sourceList
        agentsScrollView.documentView = agentsTableView
        agentsScrollView.hasVerticalScroller = true
        agentsScrollView.translatesAutoresizingMaskIntoConstraints = false
        sidebarView.addSubview(agentsScrollView)
        
        NSLayoutConstraint.activate([
            conversationLabel.topAnchor.constraint(equalTo: sidebarView.topAnchor, constant: 12),
            conversationLabel.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor, constant: 12),
            conversationLabel.trailingAnchor.constraint(equalTo: newChatButton.leadingAnchor, constant: -4),
            newChatButton.centerYAnchor.constraint(equalTo: conversationLabel.centerYAnchor),
            newChatButton.trailingAnchor.constraint(equalTo: sidebarView.trailingAnchor, constant: -8),
            newChatButton.widthAnchor.constraint(equalToConstant: 24), newChatButton.heightAnchor.constraint(equalToConstant: 24),
            conversationScrollView.topAnchor.constraint(equalTo: conversationLabel.bottomAnchor, constant: 6),
            conversationScrollView.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor),
            conversationScrollView.trailingAnchor.constraint(equalTo: sidebarView.trailingAnchor),
            conversationScrollView.heightAnchor.constraint(equalTo: sidebarView.heightAnchor, multiplier: 0.4),
            sidebarDivider.topAnchor.constraint(equalTo: conversationScrollView.bottomAnchor, constant: 4),
            sidebarDivider.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor, constant: 8),
            sidebarDivider.trailingAnchor.constraint(equalTo: sidebarView.trailingAnchor, constant: -8),
            agentsLabel.topAnchor.constraint(equalTo: sidebarDivider.bottomAnchor, constant: 8),
            agentsLabel.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor, constant: 12),
            agentsLabel.trailingAnchor.constraint(equalTo: addAgentButton.leadingAnchor, constant: -4),
            addAgentButton.centerYAnchor.constraint(equalTo: agentsLabel.centerYAnchor),
            addAgentButton.trailingAnchor.constraint(equalTo: sidebarView.trailingAnchor, constant: -8),
            addAgentButton.widthAnchor.constraint(equalToConstant: 24), addAgentButton.heightAnchor.constraint(equalToConstant: 24),
            agentsScrollView.topAnchor.constraint(equalTo: agentsLabel.bottomAnchor, constant: 6),
            agentsScrollView.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor),
            agentsScrollView.trailingAnchor.constraint(equalTo: sidebarView.trailingAnchor),
            agentsScrollView.bottomAnchor.constraint(equalTo: sidebarView.bottomAnchor),
        ])
        conversationTableView.dataSource = self; conversationTableView.delegate = self
        agentsTableView.dataSource = self; agentsTableView.delegate = self
    }
    
    // MARK: - 顶部工具栏
    private func setupToolbar() {
        toolbarView.translatesAutoresizingMaskIntoConstraints = false
        toolbarView.wantsLayer = true
        toolbarView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        chatContainer.addSubview(toolbarView)
        
        modelButton.translatesAutoresizingMaskIntoConstraints = false
        modelButton.title = "🧠 \(currentModel) ▾"
        modelButton.bezelStyle = .rounded
        modelButton.action = #selector(showModelMenu); modelButton.target = self
        toolbarView.addSubview(modelButton)
        
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        settingsButton.title = "⚙️"; settingsButton.bezelStyle = .rounded
        settingsButton.action = #selector(showSettings); settingsButton.target = self
        toolbarView.addSubview(settingsButton)
        
        NSLayoutConstraint.activate([
            toolbarView.topAnchor.constraint(equalTo: chatContainer.topAnchor),
            toolbarView.leadingAnchor.constraint(equalTo: chatContainer.leadingAnchor),
            toolbarView.trailingAnchor.constraint(equalTo: chatContainer.trailingAnchor),
            toolbarView.heightAnchor.constraint(equalToConstant: 40),
            modelButton.leadingAnchor.constraint(equalTo: toolbarView.leadingAnchor, constant: 12),
            modelButton.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),
            modelButton.heightAnchor.constraint(equalToConstant: 26),
            settingsButton.trailingAnchor.constraint(equalTo: toolbarView.trailingAnchor, constant: -12),
            settingsButton.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),
            settingsButton.heightAnchor.constraint(equalToConstant: 26),
        ])
    }
    
    // MARK: - 聊天区
    private func setupChatArea() {
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.setValue(false, forKey: "drawsBackground")
        chatContainer.addSubview(webView)
        
        // NSTextView with Command+Enter handling
        textScrollView.translatesAutoresizingMaskIntoConstraints = false
        textScrollView.borderType = .bezelBorder
        textScrollView.hasVerticalScroller = true
        
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.isRichText = false
        textView.isEditable = true
        textView.drawsBackground = false
        textView.delegate = self
        textView.onCommandEnter = { [weak self] in self?.send() }
        textScrollView.documentView = textView
        chatContainer.addSubview(textScrollView)
        
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.title = "发送"; sendButton.bezelStyle = .rounded
        sendButton.action = #selector(sendMessage); sendButton.target = self
        chatContainer.addSubview(sendButton)
        
        stopButton.translatesAutoresizingMaskIntoConstraints = false
        stopButton.title = "⏹ 停止"; stopButton.bezelStyle = .rounded
        stopButton.action = #selector(stopGeneration); stopButton.target = self
        stopButton.isHidden = true
        chatContainer.addSubview(stopButton)
        
        NSLayoutConstraint.activate([
            // WebView fills above input
            webView.topAnchor.constraint(equalTo: toolbarView.bottomAnchor, constant: 4),
            webView.leadingAnchor.constraint(equalTo: chatContainer.leadingAnchor, constant: 8),
            webView.trailingAnchor.constraint(equalTo: chatContainer.trailingAnchor, constant: -8),
            webView.bottomAnchor.constraint(equalTo: textScrollView.topAnchor, constant: -8),
            
            // Input area at bottom, full width
            textScrollView.leadingAnchor.constraint(equalTo: chatContainer.leadingAnchor, constant: 8),
            textScrollView.trailingAnchor.constraint(equalTo: chatContainer.trailingAnchor, constant: -75),
            textScrollView.bottomAnchor.constraint(equalTo: statusBar.topAnchor, constant: -8),
            textScrollView.heightAnchor.constraint(equalToConstant: 60),
            
            // Send button to the right of the input
            sendButton.leadingAnchor.constraint(equalTo: textScrollView.trailingAnchor, constant: 8),
            sendButton.trailingAnchor.constraint(equalTo: chatContainer.trailingAnchor, constant: -8),
            sendButton.bottomAnchor.constraint(equalTo: textScrollView.bottomAnchor, constant: 0),
            sendButton.widthAnchor.constraint(equalToConstant: 60),
            
            // Stop button same position
            stopButton.leadingAnchor.constraint(equalTo: textScrollView.trailingAnchor, constant: 8),
            stopButton.trailingAnchor.constraint(equalTo: chatContainer.trailingAnchor, constant: -8),
            stopButton.bottomAnchor.constraint(equalTo: textScrollView.bottomAnchor, constant: 0),
            stopButton.widthAnchor.constraint(equalToConstant: 60),
        ])
    }
    
    // MARK: - 底部状态栏
    private func setupStatusBar() {
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.wantsLayer = true
        statusBar.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        chatContainer.addSubview(statusBar)
        
        modelLabel.translatesAutoresizingMaskIntoConstraints = false
        modelLabel.stringValue = "🤖 \(currentModel)"
        modelLabel.font = NSFont.systemFont(ofSize: 11)
        modelLabel.textColor = .secondaryLabelColor
        modelLabel.isEditable = false; modelLabel.isBordered = false; modelLabel.backgroundColor = .clear
        statusBar.addSubview(modelLabel)
        
        tokenLabel.translatesAutoresizingMaskIntoConstraints = false
        tokenLabel.stringValue = "⚡ 0 tok"
        tokenLabel.font = NSFont.systemFont(ofSize: 11)
        tokenLabel.textColor = .secondaryLabelColor
        tokenLabel.isEditable = false; tokenLabel.isBordered = false; tokenLabel.backgroundColor = .clear
        statusBar.addSubview(tokenLabel)
        
        balanceLabel.translatesAutoresizingMaskIntoConstraints = false
        balanceLabel.stringValue = "💰 -- 元"
        balanceLabel.font = NSFont.systemFont(ofSize: 11)
        balanceLabel.textColor = .secondaryLabelColor
        balanceLabel.isEditable = false; balanceLabel.isBordered = false; balanceLabel.backgroundColor = .clear
        statusBar.addSubview(balanceLabel)
        
        NSLayoutConstraint.activate([
            statusBar.leadingAnchor.constraint(equalTo: chatContainer.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: chatContainer.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: chatContainer.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 24),
            modelLabel.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 12),
            modelLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            tokenLabel.centerXAnchor.constraint(equalTo: statusBar.centerXAnchor),
            tokenLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            balanceLabel.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -12),
            balanceLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
        ])
    }
    
    private func updateUsageDisplay() {
        let total = totalPromptTokens + totalCompletionTokens
        tokenLabel.stringValue = "⚡ \(formatNumber(totalPromptTokens)) + \(formatNumber(totalCompletionTokens)) = \(formatNumber(total)) tok"
    }
    
    private func formatNumber(_ n: Int) -> String {
        return n >= 1000 ? String(format: "%.1fK", Double(n)/1000) : "\(n)"
    }
    
    private func fetchBalance() {
        guard let url = URL(string: "https://api.deepseek.com/user/balance") else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(AppConfig.deepseekAPIKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
            guard let self = self, let data = data, error == nil else { return }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let infos = json["balance_infos"] as? [[String: Any]],
                  let first = infos.first,
                  let bal = first["total_balance"] as? String else { return }
            DispatchQueue.main.async { self.balance = bal; self.balanceLabel.stringValue = "💰 \(bal) 元" }
        }.resume()
    }
    
    // MARK: - 模型选择
    private func setupModelMenu() {
        for name in ["DeepSeek V4", "Kimi K2.6", "GPT-4o", "Claude 4 Sonnet"] {
            let item = NSMenuItem(title: name, action: #selector(selectModel(_:)), keyEquivalent: "")
            item.target = self; item.state = name == currentModel ? .on : .off; modelMenu.addItem(item)
        }
    }
    @objc func showModelMenu() { modelButton.menu = modelMenu; modelButton.performClick(nil) }
    @objc func selectModel(_ sender: NSMenuItem) {
        modelMenu.items.forEach { $0.state = .off }; sender.state = .on
        currentModel = sender.title; modelButton.title = "🧠 \(currentModel) ▾"; modelLabel.stringValue = "🤖 \(currentModel)"
    }
    @objc func newConversation() { print("新建会话（暂未实现）") }
    @objc func addAgent() { print("添加 Agent（暂未实现）") }
    @objc func showSettings() { print("设置（暂未实现）") }
    
    // MARK: - Chat HTML
    private func loadChatHTML() { webView.loadHTMLString(chatHTML(), baseURL: nil) }
    private func chatHTML() -> String { return """
        <!DOCTYPE html><html><head><meta charset="utf-8"><meta name="color-scheme" content="light dark">
        <style>*{margin:0;padding:0;box-sizing:border-box}body{font-family:-apple-system,"SF Pro","PingFang SC",sans-serif;font-size:14px;line-height:1.6;padding:16px;color:#1d1d1f}@media(prefers-color-scheme:dark){body{color:#f5f5f7}}.message{margin-bottom:16px;padding:10px 14px;border-radius:12px;max-width:85%;word-wrap:break-word;white-space:pre-wrap}.user{background:#007aff;color:white;margin-left:auto;border-bottom-right-radius:4px}.assistant{background:#e9e9eb;margin-right:auto;border-bottom-left-radius:4px}@media(prefers-color-scheme:dark){.assistant{background:#2c2c2e}}.message code{font-family:"SF Mono",Menlo,monospace;font-size:13px}.typing{opacity:.5;animation:blink 1s ease-in-out infinite}@keyframes blink{50%{opacity:.2}}.time{font-size:11px;opacity:.5;margin-top:4px}#messages{padding-bottom:8px}.welcome{text-align:center;margin-top:40%;opacity:.4}.welcome h2{font-size:24px;margin-bottom:8px}.welcome p{font-size:14px}</style></head><body>
        <div id="messages"><div class="welcome"><h2>👋 你好，王鹏飞</h2><p>发送消息开始对话</p></div></div>
        <script>
        function addMessage(r,c){removeWelcome();var m=document.getElementById('messages'),d=document.createElement('div');d.className='message '+r;d.innerHTML='<p>'+esc(c)+'</p>';var t=document.createElement('div');t.className='time';t.textContent=new Date().toLocaleTimeString();d.appendChild(t);m.appendChild(d);d.scrollIntoView({behavior:'smooth'});return d}
        function apd(t){removeWelcome();var m=document.getElementById('messages'),l=document.getElementById('s');if(!l){var d=document.createElement('div');d.className='message assistant';d.id='s';d.innerHTML='<p></p>';d.appendChild(document.createElement('div')).className='time';m.appendChild(d);l=d}l.querySelector('p').textContent+=t;l.scrollIntoView({behavior:'smooth'})}
        function fin(){var e=document.getElementById('s');if(e){e.querySelector('.time').textContent=new Date().toLocaleTimeString();e.id=''}rt()}
        function esc(t){return t.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')}
        function removeWelcome(){var e=document.querySelector('.welcome');if(e)e.remove()}
        function at(){var m=document.getElementById('messages'),d=document.createElement('div');d.className='message assistant typing';d.id='t';d.innerHTML='<p>🤔 思考中...</p>';m.appendChild(d);d.scrollIntoView({behavior:'smooth'})}
        function rt(){var e=document.getElementById('t');if(e)e.remove()}
        </script></body></html>
        """}
}

// MARK: - Key handling via NSTextView subclass
class SendTextView: NSTextView {
    var onCommandEnter: (() -> Void)?
    
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) && event.keyCode == 36 { // enter
            onCommandEnter?()
            return
        }
        super.keyDown(with: event)
    }
}

extension ChatViewController: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        // no-op: just to keep delegate wired
    }
    
    private func send() {
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isGenerating else { return }
        textView.string = ""
        messages.append(["role": "user", "content": text])
        js("addMessage('user','\(escJS(text))')")
        sendStreamToGateway(text)
    }
    
    @objc func sendMessage() { send() }
    
    @objc func stopGeneration() {
        currentStreamTask?.cancel(); currentStreamTask = nil
        if isGenerating { js("fin()"); stopGenerating() }
    }
    
    private func sendStreamToGateway(_ text: String) {
        isGenerating = true
        sendButton.isHidden = true; stopButton.isHidden = false
        statusBar.layer?.backgroundColor = NSColor(calibratedRed: 0.1, green: 0.45, blue: 0.9, alpha: 0.08).cgColor
        js("at()")
        
        var req = URLRequest(url: URL(string: "\(AppConfig.gatewayURL)/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(AppConfig.gatewayToken)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": "openclaw", "messages": Array(messages.suffix(20)),
            "max_tokens": 4096, "temperature": 0.7, "stream": true
        ])
        let task = URLSession(configuration: .default, delegate: self, delegateQueue: nil).dataTask(with: req)
        currentStreamTask = task; task.resume()
    }
    
    private func stopGenerating() {
        isGenerating = false; sendButton.isHidden = false; stopButton.isHidden = true
        statusBar.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }
    
    private func js(_ code: String) { webView.evaluateJavaScript(code) }
    private func escJS(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "") }
}

// MARK: - Streaming SSE
extension ChatViewController: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        var foundDone = false
        for line in text.components(separatedBy: "\n") {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { foundDone = true; break }
            guard let d = payload.data(using: .utf8),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let c = j["choices"] as? [[String: Any]],
                  let f = c.first,
                  let delta = f["delta"] as? [String: Any],
                  let content = delta["content"] as? String else { continue }
            DispatchQueue.main.async {
                self.js("apd('\(self.escJS(content))')")
                self.streamCharCount += content.count
                let liveTotal = self.totalPromptTokens + self.totalCompletionTokens + self.streamCharCount / 3
                self.tokenLabel.stringValue = "⚡ \(self.formatNumber(self.totalPromptTokens)) + \(self.formatNumber(self.totalCompletionTokens + self.streamCharCount / 3)) = \(self.formatNumber(liveTotal)) tok"
            }
        }
        if foundDone { DispatchQueue.main.async { self.finalizeAndUpdateStats() } }
    }
    
    private func finalizeAndUpdateStats() {
        let getJS = """
            (function(){
                var e=document.getElementById('s');
                if(!e)return '';
                var p=e.querySelector('p');
                if(!p)return '';
                var t=p.textContent;
                e.id='';
                var ti=e.querySelector('.time');
                if(ti)ti.textContent=new Date().toLocaleTimeString();
                return t;
            })()
            """
        webView.evaluateJavaScript(getJS) { [weak self] r, _ in
            guard let self = self else { return }
            self.js("rt()")
            if let t = r as? String, !t.isEmpty {
                self.messages.append(["role": "assistant", "content": t])
                let compTok = max(1, self.streamCharCount / 3)
                let promptTok = max(1, (self.messages.filter { $0["role"] == "user" }.last?["content"] ?? "").count / 3)
                self.totalPromptTokens += promptTok
                self.totalCompletionTokens += compTok
                self.updateUsageDisplay()
            }
            self.streamCharCount = 0
            self.fetchBalance()
            self.stopGenerating()
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        DispatchQueue.main.async {
            if let e = error as NSError?, e.code != NSURLErrorCancelled {
                self.js("addMessage('assistant','❌ \(self.escJS(e.localizedDescription))')")
                self.js("rt()")
                self.stopGenerating()
            }
        }
    }
}

// MARK: - NSTableView
extension ChatViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { return 3 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("c")
        var cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView
        if cell == nil {
            cell = NSTableCellView(); cell?.identifier = id
            let tf = NSTextField(); tf.isBezeled = false; tf.drawsBackground = false; tf.isEditable = false
            tf.font = NSFont.systemFont(ofSize: 12); cell?.addSubview(tf); cell?.textField = tf
        }
        if tableView == conversationTableView {
            cell?.textField?.stringValue = ["📝 Vinfast 报价单", "📊 项目进度", "💬 日常聊天"][row]
        } else {
            cell?.textField?.stringValue = ["⭐ main（你）", "🔧 translator", "📊 data-analyzer"][row]
        }
        cell?.textField?.frame = NSRect(x: 4, y: 0, width: 200, height: 32)
        cell?.textField?.sizeToFit()
        return cell
    }
}
