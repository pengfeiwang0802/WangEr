import AppKit
import WebKit
import UniformTypeIdentifiers

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
    private let webView: WKWebView = {
        let config = WKWebViewConfiguration()
        let userController = WKUserContentController()
        config.userContentController = userController
        return WKWebView(frame: .zero, configuration: config)
    }()
    private let textView = SendTextView()
    
    // 文件拖拽
    private let dropTargetView = DropTargetView()
    private let dropIndicator = NSView()
    private let dropLabel = NSTextField()
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
    private var isFinalizing = false // 幂等锁：防止 finalize 被多次调用
    private var currentStreamTask: URLSessionDataTask?
    private var safetyTimer: Timer?
    private var totalPromptTokens = 0
    private var totalCompletionTokens = 0
    private var streamCharCount = 0
    
    // SSE 累积缓冲区：防止 TCP 分片截断事件
    private var sseBuffer = ""
    
    /// 当前活跃的工具调用链（用于显示嵌套工具调用）
    private var activeToolStack: [String] = []
    
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
        setupFileDragDrop()
        setupDropIndicator()
        // 加载持久化的会话，没有则创建默认
        loadConversations()
        if conversations.isEmpty {
            conversations = [Conversation(title: "💬 新对话 1")]
        }
        loadChatHTML()
        // 注册 JS 消息处理
        webView.configuration.userContentController.add(self, name: "fileOpen")
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
        conversationScrollView.hasVerticalScroller = true
        conversationScrollView.autohidesScrollers = true
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
        agentsScrollView.autohidesScrollers = true
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
        webView.uiDelegate = self
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
        let errorPipe = Pipe()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", "/usr/local/bin/openclaw agents list --json 2>/dev/null || echo '[]'"]
        task.standardOutput = pipe
        task.standardError = errorPipe
        
        do {
            try task.run()
            task.waitUntilExit()
            
            // 检查命令执行是否成功
            if task.terminationStatus != 0 {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorOutput = String(data: errorData, encoding: .utf8) ?? "未知错误"
                print("[loadAgents] 命令失败 (exit \(task.terminationStatus)): \(errorOutput)")
                throw NSError(domain: "WangErChat", code: Int(task.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errorOutput])
            }
            
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
                print("[loadAgents] 解析失败或空列表，原始输出: \(output.prefix(200))")
                DispatchQueue.main.async {
                    self.agents = [AgentInfo(id: "main", identityName: "王二（你）", identityEmoji: "🤖", model: nil, workspace: nil, isDefault: true)]
                    self.agentsTableView.reloadData()
                    self.agentsTableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                }
            }
        } catch {
            print("[loadAgents] 错误: \(error)")
            DispatchQueue.main.async { [weak self] in
                self?.agents = [AgentInfo(id: "main", identityName: "王二（你）", identityEmoji: "🤖", model: nil, workspace: nil, isDefault: true)]
                self?.agentsTableView.reloadData()
                self?.agentsTableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                self?.statusLabel.stringValue = "⚠️ Agents 加载失败"
            }
        }
    }
    
    private func fetchBalance() {
        // 查 DeepSeek 余额
        let dsKey = AppConfig.deepseekAPIKey
        if !dsKey.isEmpty, let url = URL(string: "https://api.deepseek.com/user/balance") {
            var req = URLRequest(url: url)
            req.setValue("Bearer \(dsKey)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.timeoutInterval = 10 // 10秒超时
            URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
                guard let self = self else { return }
                if let error = error {
                    print("[Balance] DeepSeek 查询错误: \(error)")
                    DispatchQueue.main.async {
                        self.dsBalance = "错误"
                        self.updateBalanceDisplay()
                    }
                    return
                }
                guard let httpResponse = response as? HTTPURLResponse else {
                    print("[Balance] DeepSeek 无 HTTP 响应")
                    DispatchQueue.main.async {
                        self.dsBalance = "无响应"
                        self.updateBalanceDisplay()
                    }
                    return
                }
                guard httpResponse.statusCode == 200 else {
                    print("[Balance] DeepSeek HTTP \(httpResponse.statusCode)")
                    DispatchQueue.main.async {
                        self.dsBalance = "HTTP\(httpResponse.statusCode)"
                        self.updateBalanceDisplay()
                    }
                    return
                }
                guard let data = data else {
                    DispatchQueue.main.async {
                        self.dsBalance = "无数据"
                        self.updateBalanceDisplay()
                    }
                    return
                }
                do {
                    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    if let infos = json?["balance_infos"] as? [[String: Any]],
                       let first = infos.first,
                       let bal = first["total_balance"] as? String {
                        DispatchQueue.main.async {
                            self.dsBalance = bal
                            self.updateBalanceDisplay()
                        }
                    } else {
                        print("[Balance] DeepSeek 响应结构异常: \(String(data: data, encoding: .utf8)?.prefix(200) ?? "N/A")")
                        DispatchQueue.main.async {
                            self.dsBalance = "解析失败"
                            self.updateBalanceDisplay()
                        }
                    }
                } catch {
                    print("[Balance] DeepSeek JSON 解析错误: \(error)")
                    DispatchQueue.main.async {
                        self.dsBalance = "解析错误"
                        self.updateBalanceDisplay()
                    }
                }
            }.resume()
        }
        
        // 查 Kimi 余额
        let moonshotKey = AppConfig.moonshotAPIKey
        guard !moonshotKey.isEmpty else { return }
        if let url = URL(string: "https://api.moonshot.cn/v1/users/me/balance") {
            var req = URLRequest(url: url)
            req.setValue("Bearer \(moonshotKey)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.timeoutInterval = 10
            URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
                guard let self = self else { return }
                if let error = error {
                    print("[Balance] Kimi 查询错误: \(error)")
                    DispatchQueue.main.async {
                        self.moonshotBalance = "错误"
                        self.updateBalanceDisplay()
                    }
                    return
                }
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    print("[Balance] Kimi HTTP \(code)")
                    DispatchQueue.main.async {
                        self.moonshotBalance = "HTTP\(code)"
                        self.updateBalanceDisplay()
                    }
                    return
                }
                guard let data = data else {
                    DispatchQueue.main.async {
                        self.moonshotBalance = "无数据"
                        self.updateBalanceDisplay()
                    }
                    return
                }
                do {
                    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    if json?["status"] as? Bool == true,
                       let balData = json?["data"] as? [String: Any],
                       let bal = balData["available_balance"] as? Double {
                        DispatchQueue.main.async {
                            self.moonshotBalance = String(format: "%.2f", bal)
                            self.updateBalanceDisplay()
                        }
                    } else {
                        print("[Balance] Kimi 响应结构异常")
                        DispatchQueue.main.async {
                            self.moonshotBalance = "解析失败"
                            self.updateBalanceDisplay()
                        }
                    }
                } catch {
                    print("[Balance] Kimi JSON 解析错误: \(error)")
                    DispatchQueue.main.async {
                        self.moonshotBalance = "解析错误"
                        self.updateBalanceDisplay()
                    }
                }
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
        let url = URL(fileURLWithPath: path)
        
        guard FileManager.default.fileExists(atPath: path) else {
            print("[loadAvailableModels] openclaw.json 不存在，使用默认模型")
            availableModels = [ModelOption(displayName: "DeepSeek V4 Flash", apiModelId: "deepseek/deepseek-v4-flash")]
            return
        }
        
        do {
            let data = try Data(contentsOf: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [String: Any],
                  let providers = models["providers"] as? [String: Any] else {
                print("[loadAvailableModels] 解析 openclaw.json 结构失败")
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
        } catch {
            print("[loadAvailableModels] 读取 openclaw.json 失败: \(error)")
            availableModels = [ModelOption(displayName: "DeepSeek V4 Flash", apiModelId: "deepseek/deepseek-v4-flash")]
            DispatchQueue.main.async { [weak self] in
                self?.statusLabel.stringValue = "⚠️ 模型配置读取失败"
            }
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
    // MARK: - 文件拖拽
    private func setupFileDragDrop() {
        dropTargetView.translatesAutoresizingMaskIntoConstraints = false
        dropTargetView.wantsLayer = true
        dropTargetView.layer?.backgroundColor = NSColor.clear.cgColor
        dropTargetView.isHidden = true
        chatContainer.addSubview(dropTargetView, positioned: .above, relativeTo: webView)
        
        dropTargetView.onDragEnter = { [weak self] in self?.showDropIndicator() }
        dropTargetView.onDragExit = { [weak self] in self?.hideDropIndicator() }
        dropTargetView.onFileDrop = { [weak self] url in
            self?.hideDropIndicator()
            self?.handleDroppedFile(url: url)
        }
        
        NSLayoutConstraint.activate([
            dropTargetView.topAnchor.constraint(equalTo: webView.topAnchor),
            dropTargetView.leadingAnchor.constraint(equalTo: webView.leadingAnchor),
            dropTargetView.trailingAnchor.constraint(equalTo: webView.trailingAnchor),
            dropTargetView.bottomAnchor.constraint(equalTo: webView.bottomAnchor),
        ])
    }
    
    private func setupDropIndicator() {
        dropIndicator.translatesAutoresizingMaskIntoConstraints = false
        dropIndicator.wantsLayer = true
        dropIndicator.layer?.backgroundColor = NSColor(calibratedRed: 0, green: 0.48, blue: 1, alpha: 0.08).cgColor
        dropIndicator.layer?.borderColor = NSColor(calibratedRed: 0, green: 0.48, blue: 1, alpha: 0.3).cgColor
        dropIndicator.layer?.borderWidth = 2
        dropIndicator.layer?.cornerRadius = 12
        dropIndicator.isHidden = true
        chatContainer.addSubview(dropIndicator, positioned: .above, relativeTo: dropTargetView)
        
        dropLabel.translatesAutoresizingMaskIntoConstraints = false
        dropLabel.stringValue = "📁 拖放文件到此处"
        dropLabel.font = NSFont.systemFont(ofSize: 16, weight: .medium)
        dropLabel.textColor = NSColor(calibratedRed: 0, green: 0.48, blue: 1, alpha: 0.6)
        dropLabel.alignment = .center
        dropLabel.isEditable = false
        dropLabel.isBordered = false
        dropLabel.backgroundColor = .clear
        dropIndicator.addSubview(dropLabel)
        
        NSLayoutConstraint.activate([
            dropIndicator.topAnchor.constraint(equalTo: webView.topAnchor),
            dropIndicator.leadingAnchor.constraint(equalTo: webView.leadingAnchor),
            dropIndicator.trailingAnchor.constraint(equalTo: webView.trailingAnchor),
            dropIndicator.bottomAnchor.constraint(equalTo: webView.bottomAnchor),
            dropLabel.centerXAnchor.constraint(equalTo: dropIndicator.centerXAnchor),
            dropLabel.centerYAnchor.constraint(equalTo: dropIndicator.centerYAnchor),
        ])
    }
    
    private func showDropIndicator() {
        dropIndicator.isHidden = false
        dropTargetView.isHidden = false
    }
    
    private func hideDropIndicator() {
        dropIndicator.isHidden = true
        dropTargetView.isHidden = true
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
        do {
            let data = try JSONEncoder().encode(conversations)
            let url = URL(fileURLWithPath: savePath)
            // 确保目录存在
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: url)
        } catch {
            print("[Error] saveConversations failed: \(error)")
            DispatchQueue.main.async { [weak self] in
                self?.statusLabel.stringValue = "⚠️ 保存失败"
            }
        }
    }
    
    private func loadConversations() {
        let url = URL(fileURLWithPath: savePath)
        guard FileManager.default.fileExists(atPath: savePath) else {
            print("[loadConversations] 会话文件不存在，将创建新文件: \(savePath)")
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let loaded = try JSONDecoder().decode([Conversation].self, from: data)
            conversations = loaded
            print("[loadConversations] 已加载 \(conversations.count) 个会话")
        } catch let error as DecodingError {
            print("[loadConversations] 解析会话文件失败: \(error)")
            // 备份损坏的文件
            let backupPath = savePath + ".backup.\(Int(Date().timeIntervalSince1970))"
            try? FileManager.default.copyItem(atPath: savePath, toPath: backupPath)
            print("[loadConversations] 已备份损坏文件到: \(backupPath)")
        } catch {
            print("[loadConversations] 读取会话文件失败: \(error)")
        }
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
        saveConversations()
    }
    @objc func addAgent() {
        let alert = NSAlert()
        alert.messageText = "添加 Agent"
        alert.informativeText = "此功能尚未实现，敬请期待。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "确定")
        alert.runModal()
    }
    @objc func showSettings() {
        let alert = NSAlert()
        alert.messageText = "设置"
        alert.informativeText = "设置页面尚未实现，敬请期待。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "确定")
        alert.runModal()
    }
    
    // MARK: - Chat HTML
    private func loadChatHTML() { webView.loadHTMLString(chatHTML(), baseURL: nil) }
    private func chatHTML() -> String { return """
        <!DOCTYPE html><html><head><meta charset="utf-8"><meta name="color-scheme" content="light dark">
        <style>*{margin:0;padding:0;box-sizing:border-box}body{font-family:-apple-system,"SF Pro","PingFang SC",sans-serif;font-size:14px;line-height:1.6;padding:16px;color:#1d1d1f}@media(prefers-color-scheme:dark){body{color:#f5f5f7}}.message{margin-bottom:16px;padding:10px 14px;border-radius:12px;max-width:85%;word-wrap:break-word;white-space:pre-wrap}.user{background:#007aff;color:white;margin-left:auto;border-bottom-right-radius:4px}.assistant{background:#e9e9eb;margin-right:auto;border-bottom-left-radius:4px}@media(prefers-color-scheme:dark){.assistant{background:#2c2c2e}}.message code{font-family:"SF Mono",Menlo,monospace;font-size:13px}.typing{opacity:.5;animation:blink 1s ease-in-out infinite}@keyframes blink{50%{opacity:.2}}.time{font-size:11px;opacity:.5;margin-top:4px}#messages{padding-bottom:8px}.welcome{text-align:center;margin-top:40%;opacity:.4}.welcome h2{font-size:24px;margin-bottom:8px}.welcome p{font-size:14px}.file-card{display:flex;align-items:center;gap:10px;padding:10px 14px;background:rgba(0,122,255,0.08);border-radius:10px;border:1px solid rgba(0,122,255,0.15);margin-top:6px;cursor:pointer;transition:background 0.15s}.file-card:hover{background:rgba(0,122,255,0.14)}.file-icon{font-size:28px;flex-shrink:0}.file-info{flex:1;min-width:0}.file-name{font-weight:600;font-size:13px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.file-size{font-size:11px;opacity:.6;margin-top:1px}.file-badge{font-size:11px;padding:2px 8px;border-radius:4px;background:rgba(0,122,255,0.12);color:#007aff;font-weight:500}.image-preview{max-width:min(100%,400px);max-height:320px;border-radius:10px;margin-top:6px;cursor:pointer;transition:opacity 0.15s;display:block;object-fit:contain}.image-preview:hover{opacity:0.85}.user .file-card,.user .file-badge{background:rgba(255,255,255,0.15);border-color:rgba(255,255,255,0.2)}.user .file-badge{color:rgba(255,255,255,0.9)}@media(prefers-color-scheme:dark){.file-card{background:rgba(0,122,255,0.12);border-color:rgba(0,122,255,0.2)}.file-card:hover{background:rgba(0,122,255,0.2)}}.img-grid{display:flex;flex-wrap:wrap;gap:6px;margin-top:6px}.img-grid .image-preview{max-width:200px;max-height:200px;margin-top:0}.code-preview{margin-top:6px;border-radius:8px;overflow:hidden;border:1px solid rgba(128,128,128,0.2)}.code-preview pre{margin:0;padding:10px 14px;font-family:"SF Mono",Menlo,monospace;font-size:12px;line-height:1.5;overflow-x:auto;background:rgba(128,128,128,0.06);white-space:pre-wrap;word-break:break-word}.code-preview .code-header{display:flex;justify-content:space-between;align-items:center;padding:4px 10px;font-size:11px;background:rgba(128,128,128,0.08);color:rgba(128,128,128,0.7)}.code-preview .code-header .lang{font-weight:600;text-transform:uppercase}</style></head><body>
        <div id="messages"><div class="welcome"><h2>👋 你好，王鹏飞</h2><p>发送消息开始对话</p></div></div>
        <script>
        function addMessage(r,c){try{removeWelcome();var m=document.getElementById('messages');if(!m)return null;var d=document.createElement('div');d.className='message '+r;d.innerHTML='<p>'+esc(c)+'</p>';var t=document.createElement('div');t.className='time';t.textContent=new Date().toLocaleTimeString();d.appendChild(t);m.appendChild(d);d.scrollIntoView({behavior:'smooth'});return d}catch(e){console.error('addMessage:',e);return null}}
        function apd(t){try{removeWelcome();var m=document.getElementById('messages');if(!m)return;var l=document.getElementById('s');if(!l){var d=document.createElement('div');d.className='message assistant';d.id='s';d.innerHTML='<p></p>';d.appendChild(document.createElement('div')).className='time';m.appendChild(d);l=d}var p=l.querySelector('p');if(p)p.textContent+=t;l.scrollIntoView({behavior:'smooth'})}catch(e){console.error('apd:',e)}}
        function fin(){try{var e=document.getElementById('s');if(e){var t=e.querySelector('.time');if(t)t.textContent=new Date().toLocaleTimeString();e.id=''}}catch(ex){console.error('fin:',ex)}rt()}
        function esc(t){return t.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')}
        function removeWelcome(){var e=document.querySelector('.welcome');if(e)e.remove()}
        function at(){var m=document.getElementById('messages'),d=document.createElement('div');d.className='message assistant typing';d.id='t';d.innerHTML='<p>🤔 思考中...</p>';m.appendChild(d);d.scrollIntoView({behavior:'smooth'})}
        function rt(){var e=document.getElementById('t');if(e)e.remove()}
        function addImageMessage(r,dataUrl,filename){try{removeWelcome();var m=document.getElementById('messages');if(!m)return;var d=document.createElement('div');d.className='message '+r;var p=document.createElement('p');p.textContent='📷 '+filename;d.appendChild(p);var img=document.createElement('img');img.className='image-preview';img.src=dataUrl;img.alt=filename;img.loading='lazy';img.onclick=function(){window.open(dataUrl,'_blank')};d.appendChild(img);var t=document.createElement('div');t.className='time';t.textContent=new Date().toLocaleTimeString();d.appendChild(t);m.appendChild(d);d.scrollIntoView({behavior:'smooth'})}catch(e){console.error('addImageMessage:',e)}}
        function addFileCard(r,filename,fileSize,fileId,ext){try{removeWelcome();var m=document.getElementById('messages');if(!m)return;var d=document.createElement('div');d.className='message '+r;var p=document.createElement('p');p.textContent='📎 '+filename;d.appendChild(p);var card=document.createElement('div');card.className='file-card';var icons={'pdf':'📕','doc':'📘','docx':'📘','xls':'📗','xlsx':'📗','ppt':'📙','pptx':'📙','zip':'📦','gz':'📦','tar':'📦','js':'📄','ts':'📄','py':'📄','swift':'📄','java':'📄','cpp':'📄','txt':'📄','md':'📄','json':'📄','yaml':'📄','yml':'📄','xml':'📄','html':'📄','css':'📄','default':'📄'};var icon=icons[ext]||icons['default'];card.innerHTML='<span class="file-icon">'+icon+'</span><div class="file-info"><div class="file-name">'+esc(filename)+'</div><div class="file-size">'+fileSize+'</div></div><span class="file-badge">打开</span>';card.onclick=function(){try{window.webkit.messageHandlers.fileOpen.postMessage(fileId)}catch(e){}};d.appendChild(card);var t=document.createElement('div');t.className='time';t.textContent=new Date().toLocaleTimeString();d.appendChild(t);m.appendChild(d);d.scrollIntoView({behavior:'smooth'})}catch(e){console.error('addFileCard:',e)}}
        function addCodeBlock(r,code,lang){try{removeWelcome();var m=document.getElementById('messages');if(!m)return;var d=document.createElement('div');d.className='message '+r;var pre=document.createElement('div');pre.className='code-preview';var h=document.createElement('div');h.className='code-header';h.innerHTML='<span class="lang">'+(lang||'code')+'</span>';pre.appendChild(h);var c=document.createElement('pre');c.textContent=code;pre.appendChild(c);d.appendChild(pre);var t=document.createElement('div');t.className='time';t.textContent=new Date().toLocaleTimeString();d.appendChild(t);m.appendChild(d);d.scrollIntoView({behavior:'smooth'})}catch(e){console.error('addCodeBlock:',e)}}
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
        if isGenerating && !isFinalizing {
            js("fin()")
            finalizeAndUpdateStats()
        }
    }
    
    private func resetSafetyTimer() {
        safetyTimer?.invalidate()
        DispatchQueue.main.async {
            self.safetyTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { [weak self] _ in
                guard let self = self, self.isGenerating else { return }
                self.currentStreamTask?.cancel()
                self.currentStreamTask = nil
                self.js("rt()")
                self.js("addMessage('assistant','⚠️ 生成超时（5分钟），已自动中断')")
                self.stopGenerating()
            }
        }
    }
    
    private func sendStreamToGateway(_ text: String) {
        // 前置校验
        guard !text.isEmpty else {
            statusLabel.stringValue = "⚠️ 消息不能为空"
            return
        }
        
        guard !AppConfig.gatewayToken.isEmpty else {
            js("addMessage('assistant','❌ Gateway Token 未配置，请检查 openclaw.json')")
            statusLabel.stringValue = "⚠️ Token 未配置"
            return
        }
        
        guard URL(string: "\(AppConfig.gatewayURL)/v1/responses") != nil else {
            js("addMessage('assistant','❌ Gateway 地址无效')")
            statusLabel.stringValue = "⚠️ 地址无效"
            return
        }
        
        isGenerating = true
        isFinalizing = false
        sendButton.isHidden = true; stopButton.isHidden = false
        statusBar.layer?.backgroundColor = NSColor(calibratedRed: 0.1, green: 0.45, blue: 0.9, alpha: 0.08).cgColor
        js("at()")
        resetSafetyTimer()
        sseBuffer = ""
        
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
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": "openclaw",
                "input": inputItems,
                "max_output_tokens": 16384, "temperature": temperature,
                "stream": true
            ] as [String : Any])
        } catch {
            DispatchQueue.main.async {
                self.js("addMessage('assistant','❌ 请求构造失败: \(self.escJS(error.localizedDescription))')")
                self.stopGenerating()
            }
            return
        }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 310  // 比 safety timer 稍长
        config.timeoutIntervalForResource = 600 // 10分钟总超时
        let task = URLSession(configuration: config, delegate: self, delegateQueue: nil).dataTask(with: req)
        currentStreamTask = task; task.resume()
    }
    
    private func stopGenerating() {
        isGenerating = false; isFinalizing = false; sendButton.isHidden = false; stopButton.isHidden = true
        statusBar.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        statusLabel.stringValue = "🤖 就绪"
        safetyTimer?.invalidate()
    }
    
    fileprivate func js(_ code: String) {
        webView.evaluateJavaScript(code) { _, error in
            if let error = error {
                let nsError = error as NSError
                // WKErrorJavaScriptResultTypeIsUnsupported (code 5) is harmless:
                // it means the JS expression returned a DOM element or other
                // type that WKWebView can't serialize. Our calls don't depend
                // on return values, so we can safely skip it.
                if nsError.domain == "WKErrorDomain" && nsError.code == 5 {
                    return
                }
                print("[JS Error] \(nsError.domain) \(nsError.code): \(nsError.localizedDescription)")
                if let line = nsError.userInfo["WKJavaScriptExceptionLineNumber"] as? Int {
                    print("[JS Error]  Line: \(line)")
                }
                if let col = nsError.userInfo["WKJavaScriptExceptionColumnNumber"] as? Int {
                    print("[JS Error]  Col: \(col)")
                }
            }
        }
    }
    fileprivate func escJS(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "'", with: "\\'")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: "\\n")
         .replacingOccurrences(of: "\r", with: "\\r")
         .replacingOccurrences(of: "\t", with: "\\t")
    }
}

// MARK: - Streaming SSE (OpenResponses)
extension ChatViewController: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !data.isEmpty else { return }
        guard let chunk = String(data: data, encoding: .utf8) else {
            print("[SSE Error] 无法将数据解码为 UTF-8")
            DispatchQueue.main.async {
                self.js("addMessage('assistant','❌ 接收数据解码失败')")
                self.finalizeAndUpdateStats()
            }
            return
        }
        
        // 追加到累积缓冲区
        sseBuffer += chunk
        
        // 按 \n\n 分割完整事件块
        let blocks = sseBuffer.components(separatedBy: "\n\n")
        // 最后一段可能是不完整的，留在缓冲区等待下一批
        if sseBuffer.hasSuffix("\n\n") {
            sseBuffer = ""
        } else {
            sseBuffer = blocks.last ?? ""
        }
        
        // 处理完整的块（排除最后一个不完整的）
        let completeBlocks = blocks.dropLast(blocks.count > 1 && !sseBuffer.isEmpty ? 1 : 0)
        
        var foundDone = false
        
        for block in completeBlocks {
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            
            let lines = trimmed.components(separatedBy: "\n")
            var currentEvent = ""
            var currentData = ""
            
            for line in lines {
                if line.hasPrefix("event: ") {
                    currentEvent = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("data: ") {
                    currentData = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                }
            }
            
            if currentData == "[DONE]" {
                foundDone = true
                break
            }
            
            if !currentData.isEmpty {
                processResponsesEvent(event: currentEvent, data: currentData)
            }
        }
        
        if foundDone {
            DispatchQueue.main.async { self.finalizeAndUpdateStats() }
            return
        }
    }
    
    /// 设置状态栏颜色
    private func setStatusBarColor(_ color: NSColor, alpha: CGFloat = 0.12) {
        statusBar.layer?.backgroundColor = color.withAlphaComponent(alpha).cgColor
    }
    
    /// 重置状态栏颜色
    private func resetStatusBarColor() {
        statusBar.layer?.backgroundColor = nil
    }
    
    /// 工具名称转友好显示
    private func friendlyToolName(_ name: String) -> String {
        let map: [String: String] = [
            "web_search": "搜索网页",
            "web_fetch": "读取网页",
            "exec": "执行命令",
            "read": "读取文件",
            "write": "写入文件",
            "edit": "编辑文件",
            "apply_patch": "应用补丁",
            "image": "分析图片",
            "memory_search": "搜索记忆",
            "memory_get": "读取记忆",
            "browser_navigate": "打开网页",
            "browser_snapshot": "查看页面",
            "browser_click": "点击页面",
            "browser_type": "输入文字",
            "cron": "设置提醒",
            "skill_workshop": "技能工坊",
            "sessions_spawn": "创建子任务",
            "sessions_send": "发送消息",
        ]
        return map[name] ?? name.replacingOccurrences(of: "_", with: " ").capitalized
    }
    
    /// 工具参数摘要（截取关键参数）
    private func toolArgsSummary(_ args: [String: Any]?) -> String {
        guard let args = args, !args.isEmpty else { return "" }
        // 优先显示关键字段
        let priorities = ["query", "url", "path", "name", "message", "command", "question", "text"]
        for key in priorities {
            if let val = args[key] as? String {
                let truncated = val.count > 60 ? String(val.prefix(60)) + "…" : val
                return truncated
            }
        }
        // 没有关键字段，显示第一个参数名
        if let firstKey = args.keys.first, let val = args[firstKey] as? String {
            let truncated = val.count > 40 ? String(val.prefix(40)) + "…" : val
            return truncated
        }
        return ""
    }
    
    private func processResponsesEvent(event: String, data: String) {
        guard !data.isEmpty else { return }
        
        guard let d = data.data(using: .utf8) else {
            print("[SSE Error] 无法将 event data 转为 Data")
            return
        }
        
        guard let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            print("[SSE Error] JSON 解析失败: \(data.prefix(200))")
            return
        }
        
        guard let type = j["type"] as? String else {
            print("[SSE Warning] 事件缺少 type 字段: \(data.prefix(200))")
            return
        }
        
        switch type {
        case "response.created":
            activeToolStack = []
            DispatchQueue.main.async {
                self.setStatusBarColor(.systemBlue, alpha: 0.08)
                self.statusLabel.stringValue = "🤖 启动..."
            }
            
        case "response.in_progress":
            DispatchQueue.main.async {
                self.setStatusBarColor(.systemBlue, alpha: 0.12)
                self.statusLabel.stringValue = "🤖 思考中..."
            }
            
        case "response.output_item.added":
            if let item = j["item"] as? [String: Any], item["type"] as? String == "function_call" {
                let name = item["name"] as? String ?? ""
                let args = item["arguments"] as? [String: Any]
                let friendlyName = self.friendlyToolName(name)
                let summary = self.toolArgsSummary(args)
                self.activeToolStack.append(name)
                
                DispatchQueue.main.async {
                    self.setStatusBarColor(.systemOrange, alpha: 0.12)
                    if !summary.isEmpty {
                        self.statusLabel.stringValue = "🔧 \(friendlyName): \(summary)"
                    } else {
                        self.statusLabel.stringValue = "🔧 调用工具: \(friendlyName)"
                    }
                }
            } else if let item = j["item"] as? [String: Any], item["type"] as? String == "reasoning" {
                DispatchQueue.main.async {
                    self.setStatusBarColor(.systemPurple, alpha: 0.10)
                    self.statusLabel.stringValue = "🧠 深度思考..."
                }
            } else {
                DispatchQueue.main.async {
                    self.setStatusBarColor(.systemBlue, alpha: 0.12)
                    self.statusLabel.stringValue = "🤖 思考中..."
                }
            }
            
        case "response.content_part.added":
            // 内容块开始生成（比如开始输出文本前）
            if let part = j["part"] as? [String: Any], part["type"] as? String == "text" {
                DispatchQueue.main.async {
                    self.setStatusBarColor(.systemGreen, alpha: 0.10)
                    self.statusLabel.stringValue = "✍️ 准备输出..."
                }
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
            } else {
                print("[SSE Warning] output_text.delta 缺少 delta 字段")
            }
            
        case "response.output_text.done":
            // 文本输出完成
            DispatchQueue.main.async {
                self.setStatusBarColor(.systemGreen, alpha: 0.08)
                self.statusLabel.stringValue = "✅ 输出完成"
            }
            
        case "response.content_part.done":
            // 内容块完成
            if let part = j["part"] as? [String: Any] {
                if part["type"] as? String == "function_call" {
                    let name = part["name"] as? String ?? ""
                    let friendlyName = self.friendlyToolName(name)
                    DispatchQueue.main.async {
                        self.setStatusBarColor(.systemOrange, alpha: 0.08)
                        self.statusLabel.stringValue = "✅ 工具完成: \(friendlyName)"
                    }
                } else {
                    DispatchQueue.main.async {
                        self.setStatusBarColor(.systemGreen, alpha: 0.06)
                        self.statusLabel.stringValue = "✅ 内容块完成"
                    }
                }
            }
            
        case "response.output_item.done":
            // 输出项完成
            if let item = j["item"] as? [String: Any] {
                if item["type"] as? String == "function_call" {
                    let name = item["name"] as? String ?? ""
                    let friendlyName = self.friendlyToolName(name)
                    // 从工具栈中移除
                    if !self.activeToolStack.isEmpty {
                        self.activeToolStack.removeLast()
                    }
                    let remaining = self.activeToolStack.count
                    DispatchQueue.main.async {
                        if remaining > 0 {
                            self.statusLabel.stringValue = "🔧 等待工具返回: \(friendlyName)"
                        } else {
                            self.setStatusBarColor(.systemBlue, alpha: 0.08)
                            self.statusLabel.stringValue = "🔧 工具已调用: \(friendlyName)"
                        }
                    }
                } else if item["type"] as? String == "reasoning" {
                    DispatchQueue.main.async {
                        self.setStatusBarColor(.systemBlue, alpha: 0.10)
                        self.statusLabel.stringValue = "🤖 思考完成，准备回复..."
                    }
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
            DispatchQueue.main.async {
                self.resetStatusBarColor()
                self.statusLabel.stringValue = "🤖 就绪"
            }
            // 收到 completed 事件，需要 finalize 来结束流式状态
            // 延迟一小段时间确保 JS DOM 已渲染完
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.finalizeAndUpdateStats() }
            
        case "response.failed":
            if let err = j["error"] as? [String: Any], let msg = err["message"] as? String {
                DispatchQueue.main.async {
                    self.js("addMessage('assistant','❌ 错误: \(self.escJS(msg))')")
                }
            }
            DispatchQueue.main.async {
                self.resetStatusBarColor()
                self.statusLabel.stringValue = "❌ 请求失败"
            }
            // 失败也需要结束
            DispatchQueue.main.async { self.finalizeAndUpdateStats() }
            
        default:
            print("[SSE] 未处理事件类型: \(type)")
            break
        }
    }
    
    private func finalizeAndUpdateStats() {
        // 幂等锁：防止重复调用（response.completed + [DONE] 双重触发）
        guard !isFinalizing else { return }
        isFinalizing = true
        
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
            } else if error == nil && self.isGenerating {
                // 连接正常关闭但还没 finalize（兜底：防止 pending 卡死）
                self.finalizeAndUpdateStats()
            }
        }
    }
    
    // MARK: - 文件发送
    private func sendFile(data: Data, filename: String, mimeType: String) {
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isGenerating else { return }
        
        // 判断是否为图片类型
        let isImage = mimeType.hasPrefix("image/")
        
        // 拼消息
        let base64 = data.base64EncodedString()
        
        if isImage {
            // 图片：存缓存 + 渲染预览 + 发送
            let fileId = saveFileToCache(data: data, filename: filename)
            let dataUrl = "data:\(mimeType);base64,\(base64)"
            currentMessages.append(["role": "user", "content": "[图片] \(filename)", "type": "image", "fileId": fileId])
            js("addImageMessage('user','\(dataUrl)','\(escJS(filename))')")
            // 发送图片到 Gateway
            sendImageToGateway(imageData: dataUrl, filename: filename, text: text)
        } else {
            // 文件：存缓存 + 渲染卡片 + 发送
            let fileId = saveFileToCache(data: data, filename: filename)
            let ext = fileExtension(filename)
            let fileSizeStr = formatFileSize(data.count)
            currentMessages.append(["role": "user", "content": "[文件] \(filename)", "type": "file", "fileId": fileId, "fileSize": "\(data.count)"])
            js("addFileCard('user','\(escJS(filename))','\(fileSizeStr)','\(fileId)','\(ext)')")
            // 发送文件到 Gateway
            sendFileToGateway(fileData: base64, filename: filename, mimeType: mimeType, text: text)
        }
        
        textView.string = ""
    }
    
    private func sendImageToGateway(imageData: String, filename: String, text: String) {
        isGenerating = true
        isFinalizing = false
        sendButton.isHidden = true; stopButton.isHidden = false
        statusBar.layer?.backgroundColor = NSColor(calibratedRed: 0.1, green: 0.45, blue: 0.9, alpha: 0.08).cgColor
        js("at()")
        resetSafetyTimer()
        sseBuffer = ""
        
        var req = URLRequest(url: URL(string: "\(AppConfig.gatewayURL)/v1/responses")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(AppConfig.gatewayToken)", forHTTPHeaderField: "Authorization")
        req.setValue(currentAgentId, forHTTPHeaderField: "x-openclaw-agent-id")
        
        let mappedModel = availableModels.first(where: { $0.displayName == currentModel })?.apiModelId ?? "deepseek/deepseek-v4-flash"
        req.setValue(mappedModel, forHTTPHeaderField: "x-openclaw-model")
        
        // 构建带图片的消息
        var contentParts: [[String: Any]] = []
        
        // 图片内容
        contentParts.append([
            "type": "input_image",
            "image_url": imageData,
            "detail": "high"
        ])
        
        // 如果有文字，加文字
        if !text.isEmpty {
            contentParts.append([
                "type": "input_text",
                "text": text
            ])
        }
        
        let inputItems: [[String: Any]] = [
            [
                "type": "message",
                "role": "user",
                "content": contentParts
            ]
        ]
        
        let temperature: Double = mappedModel.contains("kimi") ? 0.6 : 0.7
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": "openclaw",
                "input": inputItems,
                "max_output_tokens": 16384, "temperature": temperature,
                "stream": true
            ] as [String : Any])
        } catch {
            DispatchQueue.main.async {
                self.js("addMessage('assistant','❌ 图片请求构造失败')")
                self.stopGenerating()
            }
            return
        }
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 310
        config.timeoutIntervalForResource = 600
        let task = URLSession(configuration: config, delegate: self, delegateQueue: nil).dataTask(with: req)
        currentStreamTask = task; task.resume()
    }
    
    private func sendFileToGateway(fileData: String, filename: String, mimeType: String, text: String) {
        isGenerating = true
        isFinalizing = false
        sendButton.isHidden = true; stopButton.isHidden = false
        statusBar.layer?.backgroundColor = NSColor(calibratedRed: 0.1, green: 0.45, blue: 0.9, alpha: 0.08).cgColor
        js("at()")
        resetSafetyTimer()
        sseBuffer = ""
        
        var req = URLRequest(url: URL(string: "\(AppConfig.gatewayURL)/v1/responses")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(AppConfig.gatewayToken)", forHTTPHeaderField: "Authorization")
        req.setValue(currentAgentId, forHTTPHeaderField: "x-openclaw-agent-id")
        
        let mappedModel = availableModels.first(where: { $0.displayName == currentModel })?.apiModelId ?? "deepseek/deepseek-v4-flash"
        req.setValue(mappedModel, forHTTPHeaderField: "x-openclaw-model")
        
        // 构建文件消息
        var contentParts: [[String: Any]] = []
        
        contentParts.append([
            "type": "input_file",
            "file_data": fileData,
            "filename": filename
        ])
        
        if !text.isEmpty {
            contentParts.append([
                "type": "input_text",
                "text": text
            ])
        }
        
        let inputItems: [[String: Any]] = [
            [
                "type": "message",
                "role": "user",
                "content": contentParts
            ]
        ]
        
        let temperature: Double = mappedModel.contains("kimi") ? 0.6 : 0.7
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": "openclaw",
                "input": inputItems,
                "max_output_tokens": 16384, "temperature": temperature,
                "stream": true
            ] as [String : Any])
        } catch {
            DispatchQueue.main.async {
                self.js("addMessage('assistant','❌ 文件请求构造失败')")
                self.stopGenerating()
            }
            return
        }
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 310
        config.timeoutIntervalForResource = 600
        let task = URLSession(configuration: config, delegate: self, delegateQueue: nil).dataTask(with: req)
        currentStreamTask = task; task.resume()
    }
    
    private func switchToConversation(_ index: Int) {
        guard !conversations.isEmpty else {
            print("[Error] switchToConversation: 无可用会话")
            return
        }
        guard conversations.indices.contains(index) else {
            print("[Error] switchToConversation: index \(index) out of range (count: \(conversations.count))")
            // 自动回退到第一个可用会话
            if conversations.indices.contains(0) {
                currentConversationIndex = 0
                conversationTableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            }
            return
        }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self = self else { return }
            for (msgIndex, msg) in conv.messages.enumerated() {
                let role = msg["role"] ?? "user"
                let content = msg["content"] ?? ""
                let type = msg["type"] ?? ""
                guard !content.isEmpty else {
                    print("[Warning] Message \(msgIndex) has empty content, skipping")
                    continue
                }
                if type == "image", let fileId = msg["fileId"] {
                    // 恢复图片消息：从缓存读文件，生成 data URL 渲染
                    let fileURL = self.cachedFileURL(fileId: fileId)
                    if let imageData = try? Data(contentsOf: fileURL) {
                        let mimeType = self.mimeTypeForFile(fileId)
                        let dataUrl = "data:\(mimeType);base64,\(imageData.base64EncodedString())"
                        self.js("addImageMessage('\(self.escJS(role))','\(dataUrl)','\(self.escJS(content))')")
                    } else {
                        self.js("addMessage('\(self.escJS(role))','\(self.escJS(content)) [缓存丢失]')")
                    }
                } else if type == "file", let fileId = msg["fileId"] {
                    // 恢复文件消息：渲染文件卡片
                    let fileURL = self.cachedFileURL(fileId: fileId)
                    let fileSize = Int(msg["fileSize"] ?? "0") ?? 0
                    let fileSizeStr = self.formatFileSize(fileSize)
                    let ext = self.fileExtension(fileId)
                    if FileManager.default.fileExists(atPath: fileURL.path) {
                        self.js("addFileCard('\(self.escJS(role))','\(self.escJS(content))','\(fileSizeStr)','\(fileId)','\(ext)')")
                    } else {
                        self.js("addMessage('\(self.escJS(role))','\(self.escJS(content)) [缓存丢失]')")
                    }
                } else {
                    self.js("addMessage('\(self.escJS(role))','\(self.escJS(content))')")
                }
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

// MARK: - 拖放目标视图
class DropTargetView: NSView {
    var onDragEnter: (() -> Void)?
    var onDragExit: (() -> Void)?
    var onFileDrop: ((URL) -> Void)?
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }
    
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil) {
            onDragEnter?()
            return .copy
        }
        return []
    }
    
    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragExit?()
    }
    
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              let url = urls.first else {
            return false
        }
        onFileDrop?(url)
        return true
    }
}

// MARK: - 文件拖拽处理
extension ChatViewController {
    
    private func handleDroppedFile(url: URL) {
        guard url.isFileURL else { return }
        
        do {
            let data = try Data(contentsOf: url)
            let filename = url.lastPathComponent
            
            // 获取 UTI 并映射到 MIME type
            var mimeType = "application/octet-stream"
            if let uti = try? url.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier,
               let utType = UTType(uti),
               let preferredMIME = utType.preferredMIMEType {
                mimeType = preferredMIME
            }
            
            // 限制文件大小 (50MB)
            let maxSize: UInt64 = 50 * 1024 * 1024
            let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? data.count
            guard UInt64(fileSize) <= maxSize else {
                DispatchQueue.main.async {
                    self.js("addMessage('assistant','⚠️ 文件超过 50MB 限制，请压缩后重试')")
                }
                return
            }
            
            DispatchQueue.main.async {
                self.sendFile(data: data, filename: filename, mimeType: mimeType)
            }
        } catch {
            print("[File Drop] 读取文件失败: \(error)")
            DispatchQueue.main.async {
                self.js("addMessage('assistant','❌ 读取文件失败: \(self.escJS(error.localizedDescription))')")
            }
        }
    }
}

// MARK: - WKUIDelegate (拦截文件拖拽到 WKWebView)
extension ChatViewController: WKUIDelegate {
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        // 文件选择面板（从网页触发）
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { result in
            if result == .OK, let url = panel.url {
                completionHandler([url])
                self.handleDroppedFile(url: url)
            } else {
                completionHandler(nil)
            }
        }
    }
}

// MARK: - WKScriptMessageHandler (JS → Native 消息)
extension ChatViewController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "fileOpen", let fileId = message.body as? String {
            openCachedFile(fileId: fileId)
        }
    }
    
    private func openCachedFile(fileId: String) {
        let fileURL = cachedFileURL(fileId: fileId)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            print("[File Open] 文件不存在: \(fileId)")
            return
        }
        NSWorkspace.shared.open(fileURL)
    }
    
    private func cachedFileURL(fileId: String) -> URL {
        let dir = filesCacheDir()
        return dir.appendingPathComponent(fileId)
    }
    
    private func filesCacheDir() -> URL {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = supportDir.appendingPathComponent("WangEr/files", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    
    private func saveFileToCache(data: Data, filename: String) -> String {
        let dir = filesCacheDir()
        let fileId = UUID().uuidString + "_" + filename
        let url = dir.appendingPathComponent(fileId)
        try? data.write(to: url)
        return fileId
    }
    
    private func formatFileSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024*1024 { return String(format: "%.1f KB", Double(bytes)/1024.0) }
        if bytes < 1024*1024*1024 { return String(format: "%.1f MB", Double(bytes)/(1024.0*1024.0)) }
        return String(format: "%.1f GB", Double(bytes)/(1024.0*1024.0*1024.0))
    }
    
    private func fileExtension(_ filename: String) -> String {
        return (filename as NSString).pathExtension.lowercased()
    }
    
    private func mimeTypeForFile(_ filename: String) -> String {
        let ext = fileExtension(filename)
        let mimeMap: [String: String] = [
            "jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png",
            "gif": "image/gif", "webp": "image/webp", "heic": "image/heic",
            "svg": "image/svg+xml", "bmp": "image/bmp"
        ]
        return mimeMap[ext] ?? "application/octet-stream"
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
