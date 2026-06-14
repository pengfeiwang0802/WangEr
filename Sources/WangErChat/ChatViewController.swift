import AppKit
import WebKit

// MARK: - 数据模型
struct Conversation: Codable {
    var id = UUID()
    var title: String
    var messages: [[String: String]] = []
    var createdAt = Date()
}

struct AgentInfo: Codable {
    let id: String
    let identityName: String?
    let identityEmoji: String?
    let model: String?
    let workspace: String?
    let isDefault: Bool?
    
    var displayName: String {
        let emoji = identityEmoji ?? "🤖"
        let name = identityName ?? id
        return "\(emoji) \(name)"
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

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
    
    // Agent 参数面板
    private let agentPanelView = NSView()
    private let agentPanelLabel = NSTextField()
    private let agentPanelName = NSTextField()
    private let agentPanelModel = NSTextField()
    private let agentPanelID = NSTextField()
    private let agentPanelDivider = NSBox()
    
    // 聊天区
    private let webView = WKWebView()
    private let textView = SendTextView()
    private let textScrollView = NSScrollView()
    private let sendButton = NSButton()
    private let stopButton = NSButton()
    
    // 底部状态栏
    private let statusBar = NSView()
    private let modelLabel = NSTextField()
    private let statusLabel = NSTextField()
    private let tokenLabel = NSTextField()
    private let balanceLabel = NSTextField()
    
    // 模型选择
    private let modelMenu = NSMenu()
    
    // 可用模型列表（从 openclaw.json 读取）
    private struct ModelOption {
        let displayName: String
        let apiModelId: String  // 格式: providerName/modelId
    }
    
    private var availableModels: [ModelOption] = []
    
    // === 状态 ===
    private var conversations: [Conversation] = []
    private var currentConversationIndex = 0
    private var isGenerating = false
    private var currentStreamTask: URLSessionDataTask?
    private var safetyTimer: Timer?
    private var totalPromptTokens = 0
    private var totalCompletionTokens = 0
    private var streamCharCount = 0
    
    private var currentModel = "DeepSeek V4 Flash"
    private var dsBalance: String = "--"
    private var moonshotBalance: String = "--"
    private var agents: [AgentInfo] = []
    private var currentAgentId = "main"
    
    private var currentMessages: [[String: String]] {
        get { conversations[safe: currentConversationIndex]?.messages ?? [] }
        set { if conversations.indices.contains(currentConversationIndex) { conversations[currentConversationIndex].messages = newValue; saveConversations() } }
    }
    
    private let savePath = "\(NSHomeDirectory())/.openclaw/workspace/WangErChat/conversations.json"
    
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
        loadAvailableModels()
        setupModelMenu()
        // 加载持久化的会话，没有则创建默认
        loadConversations()
        if conversations.isEmpty {
            conversations = [Conversation(title: "💬 新对话 1")]
        }
        loadChatHTML()
        setupAgentPanel()
        updateUsageDisplay()
        fetchBalance()
        conversationTableView.reloadData()
        let lastIndex = min(conversations.count - 1, 0)
        conversationTableView.selectRowIndexes(IndexSet(integer: lastIndex), byExtendingSelection: false)
        if conversations.count > 1 || !conversations[0].messages.isEmpty {
            switchToConversation(lastIndex)
        }
        loadAgents()
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
        
        setupAgentPanel()
        conversationTableView.dataSource = self; conversationTableView.delegate = self
        conversationTableView.doubleAction = #selector(doubleClickConversation)
        agentsTableView.dataSource = self; agentsTableView.delegate = self
        setupAgentPanel()
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
        
        // Focus input on launch
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.textView.window?.makeFirstResponder(self?.textView)
        }
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
        
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.stringValue = "🤖 就绪"
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.isEditable = false; statusLabel.isBordered = false; statusLabel.backgroundColor = .clear
        statusBar.addSubview(statusLabel)
        
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
            statusLabel.leadingAnchor.constraint(equalTo: modelLabel.trailingAnchor, constant: 12),
            statusLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
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
    
    private func loadAgents() {
        let pipe = Pipe()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", "/usr/local/bin/openclaw agents list --json 2>/dev/null || echo '[]'"]
        task.standardOutput = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let list = try? JSONDecoder().decode([AgentInfo].self, from: data), !list.isEmpty {
                DispatchQueue.main.async {
                    self.agents = list
                    self.agentsTableView.reloadData()
                    if let idx = list.firstIndex(where: { $0.isDefault == true || $0.id == "main" }) {
                        self.agentsTableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
                    }
                }
            } else {
                let output = String(data: data, encoding: .utf8) ?? ""
                print("agents list raw: \(output.prefix(100))")
                DispatchQueue.main.async {
                    self.agents = [AgentInfo(id: "main", identityName: "王二（你）", identityEmoji: "🤖", model: nil, workspace: nil, isDefault: true)]
                    self.agentsTableView.reloadData()
                    self.agentsTableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                }
            }
        } catch {
            print("loadAgents error: \(error)")
            DispatchQueue.main.async {
                self.agents = [AgentInfo(id: "main", identityName: "王二（你）", identityEmoji: "🤖", model: nil, workspace: nil, isDefault: true)]
                self.agentsTableView.reloadData()
            }
        }
    }
    
    private func fetchBalance() {
        // 查 DeepSeek 余额
        if let url = URL(string: "https://api.deepseek.com/user/balance") {
            var req = URLRequest(url: url)
            req.setValue("Bearer \(AppConfig.deepseekAPIKey)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
                guard let self = self, let data = data, error == nil else { return }
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let infos = json["balance_infos"] as? [[String: Any]],
                      let first = infos.first,
                      let bal = first["total_balance"] as? String else { return }
                DispatchQueue.main.async { self.dsBalance = bal; self.updateBalanceDisplay() }
            }.resume()
        }
        
        // 查 Kimi 余额
        let moonshotKey = AppConfig.moonshotAPIKey
        guard !moonshotKey.isEmpty else { return }
        if let url = URL(string: "https://api.moonshot.cn/v1/users/me/balance") {
            var req = URLRequest(url: url)
            req.setValue("Bearer \(moonshotKey)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
                guard let self = self, let data = data, error == nil else { return }
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      json["status"] as? Bool == true,
                      let balData = json["data"] as? [String: Any],
                      let bal = balData["available_balance"] as? Double else { return }
                DispatchQueue.main.async { self.moonshotBalance = String(format: "%.2f", bal); self.updateBalanceDisplay() }
            }.resume()
        }
    }
    
    private func updateBalanceDisplay() {
        let ds = dsBalance
        let ms = moonshotBalance
        if ds != "--" && ms != "--" {
            balanceLabel.stringValue = "💰 DS:\(ds) | Kimi:\(ms) 元"
        } else if ds != "--" {
            balanceLabel.stringValue = "💰 \(ds) 元"
        } else if ms != "--" {
            balanceLabel.stringValue = "💰 Kimi: \(ms) 元"
        } else {
            balanceLabel.stringValue = "💰 -- 元"
        }
    }
    
    // MARK: - 模型选择
    private func loadAvailableModels() {
        // 从 openclaw.json 读取已配置 API key 的模型
        let path = "\(NSHomeDirectory())/.openclaw/openclaw.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [String: Any],
              let providers = models["providers"] as? [String: Any] else {
            // 兜底：至少显示 DeepSeek V4 Flash
            availableModels = [ModelOption(displayName: "DeepSeek V4 Flash", apiModelId: "deepseek/deepseek-v4-flash")]
            return
        }
        
        var result: [ModelOption] = []
        for (providerName, providerConfig) in providers {
            guard let config = providerConfig as? [String: Any] else { continue }
            // 只显示配置了 API Key 的 provider 的模型
            guard let apiKey = config["apiKey"] as? String, !apiKey.isEmpty else { continue }
            guard let modelList = config["models"] as? [[String: Any]] else { continue }
            for model in modelList {
                guard let modelId = model["id"] as? String else { continue }
                let displayName = model["name"] as? String ?? modelId
                result.append(ModelOption(displayName: displayName, apiModelId: "\(providerName)/\(modelId)"))
            }
        }
        
        if result.isEmpty {
            // 兜底
            result = [ModelOption(displayName: "DeepSeek V4 Flash", apiModelId: "deepseek/deepseek-v4-flash")]
        }
        
        availableModels = result
        // 如果当前选中模型不在可用列表中，切到第一个
        if !result.contains(where: { $0.displayName == currentModel }) {
            currentModel = result.first?.displayName ?? "DeepSeek V4 Flash"
        }
    }
    
    private func setupModelMenu() {
        modelMenu.removeAllItems()
        for opt in availableModels {
            let item = NSMenuItem(title: opt.displayName, action: #selector(selectModel(_:)), keyEquivalent: "")
            item.target = self; item.state = opt.displayName == currentModel ? .on : .off; modelMenu.addItem(item)
        }
    }
    @objc func showModelMenu() {
        let buttonBounds = modelButton.bounds
        let menuOrigin = NSPoint(x: buttonBounds.minX, y: buttonBounds.minY)
        modelMenu.popUp(positioning: nil, at: menuOrigin, in: modelButton)
    }
    @objc func selectModel(_ sender: NSMenuItem) {
        modelMenu.items.forEach { $0.state = .off }; sender.state = .on
        currentModel = sender.title; modelButton.title = "🧠 \(currentModel) ▾"; modelLabel.stringValue = "🤖 \(currentModel)"
    }
    // MARK: - Agent 参数面板
    private func setupAgentPanel() {
        agentPanelView.translatesAutoresizingMaskIntoConstraints = false
        sidebarView.addSubview(agentPanelView)
        
        // 分割线
        let divider = NSBox()  // local scope
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.boxType = .separator
        agentPanelView.addSubview(divider)
        
        agentPanelLabel.translatesAutoresizingMaskIntoConstraints = false
        agentPanelLabel.stringValue = "📋 Agent 参数"
        agentPanelLabel.font = NSFont.boldSystemFont(ofSize: 13)
        agentPanelLabel.isEditable = false; agentPanelLabel.isBordered = false; agentPanelLabel.backgroundColor = .clear
        agentPanelView.addSubview(agentPanelLabel)
        
        agentPanelName.translatesAutoresizingMaskIntoConstraints = false
        agentPanelName.font = NSFont.systemFont(ofSize: 12)
        agentPanelName.isEditable = false; agentPanelName.isBordered = false; agentPanelName.backgroundColor = .clear
        agentPanelView.addSubview(agentPanelName)
        
        agentPanelID.translatesAutoresizingMaskIntoConstraints = false
        agentPanelID.font = NSFont.systemFont(ofSize: 11)
        agentPanelID.textColor = .secondaryLabelColor
        agentPanelID.isEditable = false; agentPanelID.isBordered = false; agentPanelID.backgroundColor = .clear
        agentPanelView.addSubview(agentPanelID)
        
        agentPanelModel.translatesAutoresizingMaskIntoConstraints = false
        agentPanelModel.font = NSFont.systemFont(ofSize: 11)
        agentPanelModel.textColor = .secondaryLabelColor
        agentPanelModel.isEditable = false; agentPanelModel.isBordered = false; agentPanelModel.backgroundColor = .clear
        agentPanelView.addSubview(agentPanelModel)
        
        NSLayoutConstraint.activate([
            // Panel itself pinned to bottom of sidebar
            agentPanelView.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor),
            agentPanelView.trailingAnchor.constraint(equalTo: sidebarView.trailingAnchor),
            agentPanelView.bottomAnchor.constraint(equalTo: sidebarView.bottomAnchor),
            agentPanelView.heightAnchor.constraint(equalToConstant: 90),
            
            // Divider at top of panel
            divider.topAnchor.constraint(equalTo: agentPanelView.topAnchor),
            divider.leadingAnchor.constraint(equalTo: agentPanelView.leadingAnchor, constant: 8),
            divider.trailingAnchor.constraint(equalTo: agentPanelView.trailingAnchor, constant: -8),
            
            // Label
            agentPanelLabel.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 6),
            agentPanelLabel.leadingAnchor.constraint(equalTo: agentPanelView.leadingAnchor, constant: 12),
            
            // Name
            agentPanelName.topAnchor.constraint(equalTo: agentPanelLabel.bottomAnchor, constant: 4),
            agentPanelName.leadingAnchor.constraint(equalTo: agentPanelView.leadingAnchor, constant: 12),
            agentPanelName.trailingAnchor.constraint(equalTo: agentPanelView.trailingAnchor, constant: -12),
            
            // ID
            agentPanelID.topAnchor.constraint(equalTo: agentPanelName.bottomAnchor, constant: 2),
            agentPanelID.leadingAnchor.constraint(equalTo: agentPanelView.leadingAnchor, constant: 12),
            agentPanelID.trailingAnchor.constraint(equalTo: agentPanelView.trailingAnchor, constant: -12),
            
            // Model
            agentPanelModel.topAnchor.constraint(equalTo: agentPanelID.bottomAnchor, constant: 2),
            agentPanelModel.leadingAnchor.constraint(equalTo: agentPanelView.leadingAnchor, constant: 12),
            agentPanelModel.trailingAnchor.constraint(equalTo: agentPanelView.trailingAnchor, constant: -12),
        ])
    }
    
    private func updateAgentPanel(_ agent: AgentInfo) {
        agentPanelName.stringValue = agent.displayName
        agentPanelID.stringValue = "ID: \(agent.id)"
        agentPanelModel.stringValue = "🖥 模型: \(agent.model ?? "默认")"
    }
    
    private func saveConversations() {
        guard let data = try? JSONEncoder().encode(conversations) else { return }
        try? data.write(to: URL(fileURLWithPath: savePath))
    }
    
    private func loadConversations() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: savePath)),
              let loaded = try? JSONDecoder().decode([Conversation].self, from: data) else { return }
        conversations = loaded
    }
    
    @objc func doubleClickConversation() {
        let row = conversationTableView.clickedRow
        guard row >= 0, row < conversations.count else { return }
        let view = conversationTableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView
        guard let cell = view?.textField else { return }
        cell.isEditable = true
        cell.becomeFirstResponder()
        cell.delegate = self
    }
    
    @objc func newConversation() {
        let conv = Conversation(title: "💬 新对话 \(conversations.count + 1)")
        conversations.append(conv)
        conversationTableView.reloadData()
        let newIndex = conversations.count - 1
        conversationTableView.selectRowIndexes(IndexSet(integer: newIndex), byExtendingSelection: false)
        switchToConversation(newIndex)
    }
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
        currentMessages.append(["role": "user", "content": text])
        js("addMessage('user','\(escJS(text))')")
        sendStreamToGateway(text)
    }
    
    @objc func sendMessage() { send() }
    
    @objc func stopGeneration() {
        currentStreamTask?.cancel(); currentStreamTask = nil
        if isGenerating { js("fin()"); stopGenerating() }
    }
    
    private func resetSafetyTimer() {
        safetyTimer?.invalidate()
        DispatchQueue.main.async {
            self.safetyTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
                guard let self = self, self.isGenerating else { return }
                self.currentStreamTask?.cancel()
                self.currentStreamTask = nil
                self.js("rt()")
                self.stopGenerating()
            }
        }
    }
    
    private func sendStreamToGateway(_ text: String) {
        isGenerating = true
        sendButton.isHidden = true; stopButton.isHidden = false
        statusBar.layer?.backgroundColor = NSColor(calibratedRed: 0.1, green: 0.45, blue: 0.9, alpha: 0.08).cgColor
        js("at()")
        resetSafetyTimer()
        
        var req = URLRequest(url: URL(string: "\(AppConfig.gatewayURL)/v1/responses")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(AppConfig.gatewayToken)", forHTTPHeaderField: "Authorization")
        req.setValue(currentAgentId, forHTTPHeaderField: "x-openclaw-agent-id")
        // Build conversation history as OpenResponses format
        let recentMessages = Array(currentMessages.suffix(20))
        let inputItems: [[String: Any]] = recentMessages.map { msg in
            let role = msg["role"] ?? "user"
            let content = msg["content"] ?? ""
            return [
                "type": "message",
                "role": role,
                "content": [["type": "input_text", "text": content]]
            ]
        }
        // 找到当前选中模型的 API ID
        let mappedModel = availableModels.first(where: { $0.displayName == currentModel })?.apiModelId ?? "deepseek/deepseek-v4-flash"
        print("[DEBUG] currentModel=\(currentModel) mappedModel=\(mappedModel)")
        print("[DEBUG] availableModels: \(availableModels)")
        req.setValue(mappedModel, forHTTPHeaderField: "x-openclaw-model")
        let temperature: Double = mappedModel.contains("kimi") ? 0.6 : 0.7
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": "openclaw",
            "input": inputItems,
            "max_output_tokens": 16384, "temperature": temperature,
            "stream": true
        ] as [String : Any])
        let task = URLSession(configuration: .default, delegate: self, delegateQueue: nil).dataTask(with: req)
        currentStreamTask = task; task.resume()
    }
    
    private func stopGenerating() {
        isGenerating = false; sendButton.isHidden = false; stopButton.isHidden = true
        statusBar.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        statusLabel.stringValue = "🤖 就绪"
        safetyTimer?.invalidate()
    }
    
    fileprivate func js(_ code: String) { webView.evaluateJavaScript(code) }
    fileprivate func escJS(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "") }
}

// MARK: - Streaming SSE (OpenResponses)
extension ChatViewController: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        var foundDone = false
        
        // Parse SSE lines — OpenResponses format: event: <type>\ndata: {...}\n\n
        let lines = text.components(separatedBy: "\n")
        var currentEvent = ""
        
        for line in lines {
            if line.hasPrefix("event: ") {
                currentEvent = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data: ") {
                let currentData = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                
                if currentData == "[DONE]" {
                    foundDone = true
                    break
                }
                
                if !currentData.isEmpty {
                    processResponsesEvent(event: currentEvent, data: currentData)
                }
                currentEvent = ""
            }
        }
        
        if foundDone { DispatchQueue.main.async { self.finalizeAndUpdateStats() } }
    }
    
    private func processResponsesEvent(event: String, data: String) {
        guard let d = data.data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let type = j["type"] as? String else { return }
        
        switch type {
        case "response.created":
            DispatchQueue.main.async {
                self.statusBar.layer?.backgroundColor = NSColor(calibratedRed: 0.1, green: 0.45, blue: 0.9, alpha: 0.12).cgColor
                self.statusLabel.stringValue = "🤖 启动..."
            }
            
        case "response.in_progress":
            DispatchQueue.main.async { self.statusLabel.stringValue = "🤖 思考中..." }
            
        case "response.output_item.added":
            if let item = j["item"] as? [String: Any], item["type"] as? String == "function_call" {
                let name = item["name"] as? String ?? ""
                DispatchQueue.main.async { self.statusLabel.stringValue = "🔧 调用工具: \(name)" }
            } else {
                DispatchQueue.main.async { self.statusLabel.stringValue = "🤖 思考中..." }
            }
            
        case "response.output_text.delta":
            if let content = j["delta"] as? String {
                DispatchQueue.main.async {
                    self.js("apd('\(self.escJS(content))')")
                    self.streamCharCount += content.count
                    let liveTotal = self.totalPromptTokens + self.totalCompletionTokens + self.streamCharCount / 3
                    self.tokenLabel.stringValue = "⚡ \(self.formatNumber(self.totalPromptTokens)) + \(self.formatNumber(self.totalCompletionTokens + self.streamCharCount / 3)) = \(self.formatNumber(liveTotal)) tok"
                    self.statusLabel.stringValue = "📝 生成回复..."
                }
            }
            
        case "response.completed":
            if let resp = j["response"] as? [String: Any], let usage = resp["usage"] as? [String: Any] {
                DispatchQueue.main.async {
                    if let inputTokens = usage["input_tokens"] as? Int {
                        self.totalPromptTokens = inputTokens
                    }
                    if let outputTokens = usage["output_tokens"] as? Int {
                        self.totalCompletionTokens = outputTokens
                    }
                    self.updateUsageDisplay()
                }
            }
            DispatchQueue.main.async { self.statusLabel.stringValue = "🤖 就绪" }
            
        case "response.failed":
            if let err = j["error"] as? [String: Any], let msg = err["message"] as? String {
                DispatchQueue.main.async {
                    self.js("addMessage('assistant','❌ 错误: \(self.escJS(msg))')")
                }
            }
            
        default:
            break
        }
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
                self.currentMessages.append(["role": "assistant", "content": t])
                let compTok = max(1, self.streamCharCount / 3)
                let promptTok = max(1, (self.currentMessages.filter { $0["role"] == "user" }.last?["content"] ?? "").count / 3)
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
    
    private func switchToConversation(_ index: Int) {
        guard conversations.indices.contains(index) else { return }
        currentConversationIndex = index
        totalPromptTokens = 0
        totalCompletionTokens = 0
        streamCharCount = 0
        updateUsageDisplay()
        // Re-render messages
        let conv = conversations[index]
        let html = chatHTML()
        webView.loadHTMLString(html, baseURL: nil)
        // Re-add all messages to webview after load
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            for msg in conv.messages {
                let role = msg["role"] ?? "user"
                let content = msg["content"] ?? ""
                self.js("addMessage('\(self.escJS(role))','\(self.escJS(content))')")
            }
        }
    }
}

// MARK: - NSTextFieldDelegate (会话重命名)
extension ChatViewController: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let tf = obj.object as? NSTextField else { return }
        let row = conversationTableView.selectedRow
        guard row >= 0, row < conversations.count else { return }
        let newTitle = tf.stringValue.trimmingCharacters(in: .whitespaces)
        if !newTitle.isEmpty {
            conversations[row].title = newTitle
            saveConversations()
        }
        tf.isEditable = false
        conversationTableView.reloadData()
    }
}

// MARK: - NSTableView
extension ChatViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView == conversationTableView { return conversations.count }
        return agents.count
    }
    
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("c")
        var cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView
        if cell == nil {
            cell = NSTableCellView(); cell?.identifier = id
            let tf = NSTextField(); tf.isBezeled = false; tf.drawsBackground = false; tf.isEditable = false
            tf.font = NSFont.systemFont(ofSize: 12); cell?.addSubview(tf); cell?.textField = tf
        }
        if tableView == conversationTableView {
            cell?.textField?.stringValue = conversations[safe: row]?.title ?? "会话"
        } else {
            cell?.textField?.stringValue = agents[safe: row]?.displayName ?? ""
        }
        cell?.textField?.frame = NSRect(x: 4, y: 0, width: 200, height: 32)
        cell?.textField?.sizeToFit()
        return cell
    }
    
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tableView = notification.object as? NSTableView else { return }
        let row = tableView.selectedRow
        if tableView == conversationTableView {
            if row >= 0 && row < conversations.count {
                switchToConversation(row)
            }
        } else if tableView == agentsTableView {
            if row >= 0 && row < agents.count {
                currentAgentId = agents[row].id
                updateAgentPanel(agents[row])
                print("Switched to agent: \(currentAgentId)")
            }
        }
    }
}
