import AppKit
import WebKit
import UniformTypeIdentifiers

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
    let conversationTableView = NSTableView()
    private let conversationScrollView = NSScrollView()
    private let sidebarDivider = NSBox()
    let avatarContainer = NSView()
    var avatarWebView: WKWebView?
    var avatarReady = false

    // Agent 参数面板

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
    /// 状态标签
    let statusLabel = NSTextField()
    private let tokenLabel = NSTextField()
    private let balanceLabel = NSTextField()

    // 模型选择
    private let modelMenu = NSMenu()

    // 可用模型列表(从 openclaw.json 读取)
    private var availableModels: [Models.ModelOption] = []

    // === 状态 ===
    var conversations: [Conversation] = []
    private var currentConversationIndex = 0
    private var isGenerating = false
    private var isFinalizing = false // 幂等锁:防止 finalize 被多次调用
    private var currentStreamTask: URLSessionDataTask?
    private var currentURLSession: URLSession?  // 用于复用和清理
    private var safetyTimer: Timer?
    private var totalPromptTokens = 0
    private var totalCompletionTokens = 0
    private var streamCharCount = 0
    private var jsErrorCount = 0  // JS 连续异常计数,超阈值触发 WebView 重新加载

    // SSE 累积缓冲区:防止 TCP 分片截断事件
    private var sseBuffer = ""
    // 表情标记累积缓冲区(处理流式拆分)
    private var expressionTagBuffer = ""
    // 用户命令表情激活标志（防止 .ready 状态覆盖用户命令的表情）
    private var userExpressionActive = false

    /// 当前活跃的工具调用链(用于显示嵌套工具调用)
    private var activeToolStack: [String] = []

    // MARK: - 方案1&3: 增强状态管理
    /// 状态优先级(数字越大优先级越高)
    private enum StatusPriority: Int {
        case ready = 0
        case generating = 1
        case thinking = 2
        case toolCall = 3
        case reasoning = 4
    }

    /// 当前状态优先级(用于延迟覆盖逻辑)
    private var currentStatusPriority: StatusPriority = .ready
    /// 当前状态开始时间(用于延迟覆盖)
    private var currentStatusStartTime: Date = Date()
    /// 状态最小保持时间(秒)
    private let minStatusHoldTime: TimeInterval = 1.5
    /// 待处理的状态更新队列
    private var pendingStatusUpdate: (text: String, priority: StatusPriority, color: NSColor, alpha: CGFloat)?

    /// 状态图标动画定时器
    private var statusIconTimer: Timer?
    /// 当前状态图标索引
    private var statusIconIndex: Int = 0
    /// 思考图标序列
    private let thinkingIcons = ["🤔", "🧠", "💭", "🤔", "🧠", "💭"]
    /// 工具调用图标序列
    private let toolIcons = ["🔧", "⚙️", "🔨", "🔧", "⚙️", "🔨"]

    // MARK: - 方案2: 步骤指示器
    /// 步骤指示器容器
    private let stepIndicatorView = NSView()
    /// 步骤指示器图标
    private let stepIconLabel = NSTextField()
    /// 步骤指示器文字
    private let stepTextLabel = NSTextField()
    /// 步骤进度条
    private let stepProgressBar = NSProgressIndicator()
    /// 步骤指示器是否可见
    private var isStepIndicatorVisible = false

    // 文件缓存清理:最大 100MB,最多 100 个文件
    private var currentModel = "DeepSeek V4 Flash"
    private var dsBalance: String = "--"
    private var moonshotBalance: String = "--"
    var currentAgentId = "main"

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
        setupStepIndicator()
        // 加载持久化的会话,没有则创建默认
        loadConversations()
        if conversations.isEmpty {
            conversations = [Conversation(title: "💬 新对话 1")]
        }
        loadChatHTML()
        // 注册 JS 消息处理
        webView.configuration.userContentController.add(self, name: "fileOpen")
        updateUsageDisplay()
        fetchBalance()
        conversationTableView.reloadData()
        let lastIndex = min(conversations.count - 1, 0)
        conversationTableView.selectRowIndexes(IndexSet(integer: lastIndex), byExtendingSelection: false)
        if conversations.count > 1 || !conversations[0].messages.isEmpty {
            switchToConversation(lastIndex)
        }

        setupAvatarView()
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
        newChatButton.title = "+"; newChatButton.bezelStyle = .smallSquare
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

        avatarContainer.translatesAutoresizingMaskIntoConstraints = false
        avatarContainer.wantsLayer = true
        avatarContainer.layer?.backgroundColor = NSColor.lightGray.cgColor
        sidebarView.addSubview(avatarContainer)

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
            avatarContainer.topAnchor.constraint(equalTo: sidebarDivider.bottomAnchor, constant: 8),
            avatarContainer.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor, constant: 8),
            avatarContainer.trailingAnchor.constraint(equalTo: sidebarView.trailingAnchor, constant: -8),
            avatarContainer.bottomAnchor.constraint(equalTo: sidebarView.bottomAnchor, constant: -8),
        ])

        conversationTableView.dataSource = self; conversationTableView.delegate = self
        conversationTableView.doubleAction = #selector(doubleClickConversation)
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

    // MARK: - 方案2: 步骤指示器
    private func setupStepIndicator() {
        stepIndicatorView.translatesAutoresizingMaskIntoConstraints = false
        stepIndicatorView.wantsLayer = true
        stepIndicatorView.layer?.cornerRadius = 6
        stepIndicatorView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        stepIndicatorView.isHidden = true
        chatContainer.addSubview(stepIndicatorView, positioned: .above, relativeTo: webView)

        stepIconLabel.translatesAutoresizingMaskIntoConstraints = false
        stepIconLabel.stringValue = "🤔"
        stepIconLabel.font = NSFont.systemFont(ofSize: 14)
        stepIconLabel.isEditable = false
        stepIconLabel.isBordered = false
        stepIconLabel.backgroundColor = .clear
        stepIndicatorView.addSubview(stepIconLabel)

        stepTextLabel.translatesAutoresizingMaskIntoConstraints = false
        stepTextLabel.stringValue = ""
        stepTextLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        stepTextLabel.textColor = .secondaryLabelColor
        stepTextLabel.isEditable = false
        stepTextLabel.isBordered = false
        stepTextLabel.backgroundColor = .clear
        stepIndicatorView.addSubview(stepTextLabel)

        stepProgressBar.translatesAutoresizingMaskIntoConstraints = false
        stepProgressBar.style = .bar
        stepProgressBar.isIndeterminate = false
        stepProgressBar.minValue = 0
        stepProgressBar.maxValue = 100
        stepProgressBar.doubleValue = 0
        stepProgressBar.controlSize = .small
        stepProgressBar.isHidden = false
        stepIndicatorView.addSubview(stepProgressBar)

        NSLayoutConstraint.activate([
            stepIndicatorView.topAnchor.constraint(equalTo: toolbarView.bottomAnchor, constant: 2),
            stepIndicatorView.leadingAnchor.constraint(equalTo: chatContainer.leadingAnchor, constant: 8),
            stepIndicatorView.trailingAnchor.constraint(equalTo: chatContainer.trailingAnchor, constant: -8),
            stepIndicatorView.heightAnchor.constraint(equalToConstant: 28),

            stepIconLabel.leadingAnchor.constraint(equalTo: stepIndicatorView.leadingAnchor, constant: 8),
            stepIconLabel.centerYAnchor.constraint(equalTo: stepIndicatorView.centerYAnchor),
            stepIconLabel.widthAnchor.constraint(equalToConstant: 20),

            stepTextLabel.leadingAnchor.constraint(equalTo: stepIconLabel.trailingAnchor, constant: 4),
            stepTextLabel.centerYAnchor.constraint(equalTo: stepIndicatorView.centerYAnchor),
            stepTextLabel.trailingAnchor.constraint(lessThanOrEqualTo: stepProgressBar.leadingAnchor, constant: -8),

            stepProgressBar.trailingAnchor.constraint(equalTo: stepIndicatorView.trailingAnchor, constant: -8),
            stepProgressBar.centerYAnchor.constraint(equalTo: stepIndicatorView.centerYAnchor),
            stepProgressBar.widthAnchor.constraint(equalToConstant: 80),
            stepProgressBar.heightAnchor.constraint(equalToConstant: 8),
        ])
    }

    /// 显示步骤指示器
    private func showStepIndicator(icon: String, text: String, progress: Double) {
        stepIconLabel.stringValue = icon
        stepTextLabel.stringValue = text
        stepProgressBar.doubleValue = min(progress, 100)
        stepProgressBar.isHidden = false

        if !isStepIndicatorVisible {
            isStepIndicatorVisible = true
            stepIndicatorView.isHidden = false
            stepIndicatorView.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                stepIndicatorView.animator().alphaValue = 1
            }
        }
    }

    /// 隐藏步骤指示器
    private func hideStepIndicator() {
        guard isStepIndicatorVisible else { return }
        isStepIndicatorVisible = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            stepIndicatorView.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.stepIndicatorView.isHidden = true
        }
    }

    // MARK: - 方案1&3: 增强状态管理方法
    /// 启动状态图标动画
    private func startStatusIconAnimation(icons: [String]) {
        stopStatusIconAnimation()
        statusIconIndex = 0
        statusIconTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.statusIconIndex = (self.statusIconIndex + 1) % icons.count
            let icon = icons[self.statusIconIndex]
            // 更新状态标签中的图标(保留文字部分)
            let currentText = self.statusLabel.stringValue
            if let range = currentText.range(of: " ") {
                let textPart = currentText[range.upperBound...]
                self.statusLabel.stringValue = "\(icon) \(textPart)"
            }
        }
    }

    /// 停止状态图标动画
    private func stopStatusIconAnimation() {
        statusIconTimer?.invalidate()
        statusIconTimer = nil
    }

    /// 设置状态(带优先级和延迟覆盖)
    private func setStatusAdvanced(_ text: String, priority: StatusPriority, color: NSColor, alpha: CGFloat) {
        let now = Date()
        let elapsed = now.timeIntervalSince(currentStatusStartTime)

        // 如果新状态优先级 >= 当前状态优先级,或者当前状态已超过最小保持时间,则立即更新
        if priority.rawValue >= currentStatusPriority.rawValue || elapsed >= minStatusHoldTime {
            applyStatusUpdate(text: text, priority: priority, color: color, alpha: alpha)
            // 清除待处理更新
            pendingStatusUpdate = nil
        } else {
            // 否则排队等待
            pendingStatusUpdate = (text: text, priority: priority, color: color, alpha: alpha)
        }
    }

    /// 强制立即更新状态(用于最终状态:就绪/错误)
    private func setStatusForce(_ text: String, priority: StatusPriority = .ready, color: NSColor = .controlBackgroundColor, alpha: CGFloat = 0) {
        applyStatusUpdate(text: text, priority: priority, color: color, alpha: alpha)
        pendingStatusUpdate = nil
        stopStatusIconAnimation()
    }

    /// 实际应用状态更新
    private func applyStatusUpdate(text: String, priority: StatusPriority, color: NSColor, alpha: CGFloat) {
        currentStatusPriority = priority
        currentStatusStartTime = Date()

        // 更新状态栏
        statusLabel.stringValue = text
        statusLabel.needsDisplay = true

        // 设置状态栏颜色
        if alpha > 0 {
            statusBar.layer?.backgroundColor = color.withAlphaComponent(alpha).cgColor
        } else {
            statusBar.layer?.backgroundColor = nil
        }

        // 更新步骤指示器
        updateStepIndicator(for: priority, text: text)

        // 同步更新虚拟形象表情
        updateAvatarExpression(for: priority)
    }

    /// 根据状态优先级更新虚拟形象表情
    private func updateAvatarExpression(for priority: StatusPriority) {
        // 用户命令激活时，跳过所有自动表情（保留用户命令的表情）
        guard !userExpressionActive else {
            AppLogger.shared.log("[Avatar] 用户表情激活中，跳过 .\\(priority) 覆盖")
            return
        }
        let expression: String
        switch priority {
        case .ready:
            expression = "happy"
        case .generating:
            expression = "happy"
        case .thinking:
            expression = "thinking"
        case .toolCall:
            expression = "thinking"
        case .reasoning:
            expression = "thinking"
        }
        setAvatarExpression(expression)
        // 同步状态文本（去掉 emoji 前缀，保留文字部分）
        let statusText = statusLabel.stringValue
        if let range = statusText.range(of: " ") {
            setAvatarStatus(String(statusText[range.upperBound...]))
        } else {
            setAvatarStatus(statusText)
        }
    }

    /// 根据优先级更新步骤指示器
    private func updateStepIndicator(for priority: StatusPriority, text: String) {
        switch priority {
        case .ready:
            hideStepIndicator()
        case .generating:
            showStepIndicator(icon: "🚀", text: "正在启动请求...", progress: 10)
        case .thinking:
            showStepIndicator(icon: "🤔", text: "正在思考...", progress: 30)
        case .toolCall:
            showStepIndicator(icon: "🔧", text: text.replacingOccurrences(of: "🔧 ", with: ""), progress: 50)
        case .reasoning:
            showStepIndicator(icon: "🧠", text: "深度推理中...", progress: 40)
        }
    }

    /// 检查并应用待处理状态更新
    private func flushPendingStatus() {
        guard let pending = pendingStatusUpdate else { return }
        let elapsed = Date().timeIntervalSince(currentStatusStartTime)
        if elapsed >= minStatusHoldTime {
            applyStatusUpdate(text: pending.text, priority: pending.priority, color: pending.color, alpha: pending.alpha)
            pendingStatusUpdate = nil
        }
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
AppLogger.shared.log("[Balance] DeepSeek 查询错误: \(error)")
                    DispatchQueue.main.async {
                        self.dsBalance = "错误"
                        self.updateBalanceDisplay()
                    }
                    return
                }
                guard let httpResponse = response as? HTTPURLResponse else {
AppLogger.shared.log("[Balance] DeepSeek 无 HTTP 响应")
                    DispatchQueue.main.async {
                        self.dsBalance = "无响应"
                        self.updateBalanceDisplay()
                    }
                    return
                }
                guard httpResponse.statusCode == 200 else {
AppLogger.shared.log("[Balance] DeepSeek HTTP \(httpResponse.statusCode)")
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
AppLogger.shared.log("[Balance] DeepSeek 响应结构异常: \(String(data: data, encoding: .utf8)?.prefix(200) ?? "N/A")")
                        DispatchQueue.main.async {
                            self.dsBalance = "解析失败"
                            self.updateBalanceDisplay()
                        }
                    }
                } catch {
AppLogger.shared.log("[Balance] DeepSeek JSON 解析错误: \(error)")
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
AppLogger.shared.log("[Balance] Kimi 查询错误: \(error)")
                    DispatchQueue.main.async {
                        self.moonshotBalance = "错误"
                        self.updateBalanceDisplay()
                    }
                    return
                }
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
AppLogger.shared.log("[Balance] Kimi HTTP \(code)")
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
AppLogger.shared.log("[Balance] Kimi 响应结构异常")
                        DispatchQueue.main.async {
                            self.moonshotBalance = "解析失败"
                            self.updateBalanceDisplay()
                        }
                    }
                } catch {
AppLogger.shared.log("[Balance] Kimi JSON 解析错误: \(error)")
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
AppLogger.shared.log("[loadAvailableModels] openclaw.json 不存在,使用默认模型")
            availableModels = [Models.ModelOption(displayName: "DeepSeek V4 Flash", apiModelId: "deepseek/deepseek-v4-flash")]
            return
        }

        do {
            let data = try Data(contentsOf: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [String: Any],
                  let providers = models["providers"] as? [String: Any] else {
AppLogger.shared.log("[loadAvailableModels] 解析 openclaw.json 结构失败")
                availableModels = [Models.ModelOption(displayName: "DeepSeek V4 Flash", apiModelId: "deepseek/deepseek-v4-flash")]
                return
            }

            var result: [Models.ModelOption] = []
            for (providerName, providerConfig) in providers {
                guard let config = providerConfig as? [String: Any] else { continue }
                // 只显示配置了 API Key 的 provider 的模型
                guard let apiKey = config["apiKey"] as? String, !apiKey.isEmpty else { continue }
                guard let modelList = config["models"] as? [[String: Any]] else { continue }
                for model in modelList {
                    guard let modelId = model["id"] as? String else { continue }
                    let displayName = model["name"] as? String ?? modelId
                    result.append(Models.ModelOption(displayName: displayName, apiModelId: "\(providerName)/\(modelId)"))
                }
            }

            if result.isEmpty {
                // 兜底
                result = [Models.ModelOption(displayName: "DeepSeek V4 Flash", apiModelId: "deepseek/deepseek-v4-flash")]
            }

            availableModels = result
            // 如果当前选中模型不在可用列表中,切到第一个
            if !result.contains(where: { $0.displayName == currentModel }) {
                currentModel = result.first?.displayName ?? "DeepSeek V4 Flash"
            }
        } catch {
AppLogger.shared.log("[loadAvailableModels] 读取 openclaw.json 失败: \(error)")
            availableModels = [Models.ModelOption(displayName: "DeepSeek V4 Flash", apiModelId: "deepseek/deepseek-v4-flash")]
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

    func saveConversations() {
        do {
            let data = try JSONEncoder().encode(conversations)
            let url = URL(fileURLWithPath: savePath)
            // 确保目录存在
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: url)
        } catch {
AppLogger.shared.log("[Error] saveConversations failed: \(error)")
            DispatchQueue.main.async { [weak self] in
                self?.statusLabel.stringValue = "⚠️ 保存失败"
            }
        }
    }

    private func loadConversations() {
        let url = URL(fileURLWithPath: savePath)
        guard FileManager.default.fileExists(atPath: savePath) else {
AppLogger.shared.log("[loadConversations] 会话文件不存在,将创建新文件: \(savePath)")
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let loaded = try JSONDecoder().decode([Conversation].self, from: data)
            conversations = loaded
AppLogger.shared.log("[loadConversations] 已加载 \(conversations.count) 个会话")
        } catch let error as DecodingError {
AppLogger.shared.log("[loadConversations] 解析会话文件失败: \(error)")
            // 备份损坏的文件
            let backupPath = savePath + ".backup.\(Int(Date().timeIntervalSince1970))"
            try? FileManager.default.copyItem(atPath: savePath, toPath: backupPath)
AppLogger.shared.log("[loadConversations] 已备份损坏文件到: \(backupPath)")
        } catch {
AppLogger.shared.log("[loadConversations] 读取会话文件失败: \(error)")
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

    @objc func showSettings() {
        let alert = NSAlert()
        alert.messageText = "设置"
        alert.informativeText = "设置页面尚未实现,敬请期待。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "确定")
        alert.runModal()
    }

    // MARK: - Chat HTML
    private func loadChatHTML() { webView.loadHTMLString(chatHTML(), baseURL: nil) }
    private func chatHTML() -> String { return """
        <!DOCTYPE html><html><head><meta charset="utf-8"><meta name="color-scheme" content="light dark">
        <style>*{margin:0;padding:0;box-sizing:border-box}body{font-family:-apple-system,"SF Pro","PingFang SC",sans-serif;font-size:14px;line-height:1.6;padding:16px;color:#1d1d1f;overflow-y:auto;-webkit-user-select:text;user-select:text}@media(prefers-color-scheme:dark){body{color:#f5f5f7}}.message{margin-bottom:16px;padding:10px 14px;border-radius:12px;max-width:85%;word-wrap:break-word;white-space:pre-wrap}.user{background:#007aff;color:white;margin-left:auto;border-bottom-right-radius:4px}.assistant{background:#e9e9eb;margin-right:auto;border-bottom-left-radius:4px}@media(prefers-color-scheme:dark){.assistant{background:#2c2c2e}}.message code{font-family:"SF Mono",Menlo,monospace;font-size:13px}.typing{opacity:.5;animation:blink 1s ease-in-out infinite}@keyframes blink{50%{opacity:.2}}.time{font-size:11px;opacity:.5;margin-top:4px}#messages{padding-bottom:8px}.welcome{text-align:center;margin-top:40%;opacity:.4}.welcome h2{font-size:24px;margin-bottom:8px}.welcome p{font-size:14px}.file-card{display:flex;align-items:center;gap:10px;padding:10px 14px;background:rgba(0,122,255,0.08);border-radius:10px;border:1px solid rgba(0,122,255,0.15);margin-top:6px;cursor:pointer;transition:background 0.15s}.file-card:hover{background:rgba(0,122,255,0.14)}.file-icon{font-size:28px;flex-shrink:0}.file-info{flex:1;min-width:0}.file-name{font-weight:600;font-size:13px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.file-size{font-size:11px;opacity:.6;margin-top:1px}.file-badge{font-size:11px;padding:2px 8px;border-radius:4px;background:rgba(0,122,255,0.12);color:#007aff;font-weight:500}.image-preview{max-width:min(100%,400px);max-height:320px;border-radius:10px;margin-top:6px;cursor:pointer;transition:opacity 0.15s;display:block;object-fit:contain}.image-preview:hover{opacity:0.85}.user .file-card,.user .file-badge{background:rgba(255,255,255,0.15);border-color:rgba(255,255,255,0.2)}.user .file-badge{color:rgba(255,255,255,0.9)}@media(prefers-color-scheme:dark){.file-card{background:rgba(0,122,255,0.12);border-color:rgba(0,122,255,0.2)}.file-card:hover{background:rgba(0,122,255,0.2)}}.img-grid{display:flex;flex-wrap:wrap;gap:6px;margin-top:6px}.img-grid .image-preview{max-width:200px;max-height:200px;margin-top:0}.code-preview{margin-top:6px;border-radius:8px;overflow:hidden;border:1px solid rgba(128,128,128,0.2)}.code-preview pre{margin:0;padding:10px 14px;font-family:"SF Mono",Menlo,monospace;font-size:12px;line-height:1.5;overflow-x:auto;background:rgba(128,128,128,0.06);white-space:pre-wrap;word-break:break-word}.code-preview .code-header{display:flex;justify-content:space-between;align-items:center;padding:4px 10px;font-size:11px;background:rgba(128,128,128,0.08);color:rgba(128,128,128,0.7)}.code-preview .code-header .lang{font-weight:600;text-transform:uppercase}</style></head><body>
        <div id="messages"><div class="welcome"><h2>👋 你好,王鹏飞</h2><p>发送消息开始对话</p></div></div>
        <script>
        function scrollToEnd(){try{var m=document.getElementById('messages');if(m)m.scrollIntoView({block:'end',behavior:'smooth'})}catch(e){}}function addMessage(r,c){try{removeWelcome();var m=document.getElementById('messages');if(!m)return null;var d=document.createElement('div');d.className='message '+r;d.innerHTML='<p>'+esc(c)+'</p>';var t=document.createElement('div');t.className='time';t.textContent=new Date().toLocaleTimeString();d.appendChild(t);m.appendChild(d);scrollToEnd();return d}catch(e){console.error('addMessage:',e);return null}}
        function apd(t){try{removeWelcome();var m=document.getElementById('messages');if(!m)return;var l=document.getElementById('s');if(!l){var d=document.createElement('div');d.className='message assistant';d.id='s';d.innerHTML='<p></p>';d.appendChild(document.createElement('div')).className='time';m.appendChild(d);l=d}var p=l.querySelector('p');if(p)p.textContent+=t;scrollToEnd()}catch(e){console.error('apd:',e)}}
        function fin(){try{var e=document.getElementById('s');if(e){var t=e.querySelector('.time');if(t)t.textContent=new Date().toLocaleTimeString();e.id=''}}catch(ex){console.error('fin:',ex)}rt()}
        function esc(t){return t.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')}
        function removeWelcome(){var e=document.querySelector('.welcome');if(e)e.remove()}
        function at(){var m=document.getElementById('messages'),d=document.createElement('div');d.className='message assistant typing';d.id='t';d.innerHTML='<p>🤔 思考中...</p>';m.appendChild(d);scrollToEnd()}
        function rt(){var e=document.getElementById('t');if(e)e.remove()}
        function addImageMessage(r,dataUrl,filename){try{removeWelcome();var m=document.getElementById('messages');if(!m)return;var d=document.createElement('div');d.className='message '+r;var p=document.createElement('p');p.textContent='📷 '+filename;d.appendChild(p);var img=document.createElement('img');img.className='image-preview';img.src=dataUrl;img.alt=filename;img.loading='lazy';img.onclick=function(){window.open(dataUrl,'_blank')};d.appendChild(img);var t=document.createElement('div');t.className='time';t.textContent=new Date().toLocaleTimeString();d.appendChild(t);m.appendChild(d);scrollToEnd()}catch(e){console.error('addImageMessage:',e)}}
        function addFileCard(r,filename,fileSize,fileId,ext){try{removeWelcome();var m=document.getElementById('messages');if(!m)return;var d=document.createElement('div');d.className='message '+r;var p=document.createElement('p');p.textContent='📎 '+filename;d.appendChild(p);var card=document.createElement('div');card.className='file-card';var icons={'pdf':'📕','doc':'📘','docx':'📘','xls':'📗','xlsx':'📗','ppt':'📙','pptx':'📙','zip':'📦','gz':'📦','tar':'📦','js':'📄','ts':'📄','py':'📄','swift':'📄','java':'📄','cpp':'📄','txt':'📄','md':'📄','json':'📄','yaml':'📄','yml':'📄','xml':'📄','html':'📄','css':'📄','default':'📄'};var icon=icons[ext]||icons['default'];card.innerHTML='<span class="file-icon">'+icon+'</span><div class="file-info"><div class="file-name">'+esc(filename)+'</div><div class="file-size">'+fileSize+'</div></div><span class="file-badge">打开</span>';card.onclick=function(){try{window.webkit.messageHandlers.fileOpen.postMessage(fileId)}catch(e){}};d.appendChild(card);var t=document.createElement('div');t.className='time';t.textContent=new Date().toLocaleTimeString();d.appendChild(t);m.appendChild(d);scrollToEnd()}catch(e){console.error('addFileCard:',e)}}
        function addCodeBlock(r,code,lang){try{removeWelcome();var m=document.getElementById('messages');if(!m)return;var d=document.createElement('div');d.className='message '+r;var pre=document.createElement('div');pre.className='code-preview';var h=document.createElement('div');h.className='code-header';h.innerHTML='<span class="lang">'+(lang||'code')+'</span>';pre.appendChild(h);var c=document.createElement('pre');c.textContent=code;pre.appendChild(c);d.appendChild(pre);var t=document.createElement('div');t.className='time';t.textContent=new Date().toLocaleTimeString();d.appendChild(t);m.appendChild(d);scrollToEnd()}catch(e){console.error('addCodeBlock:',e)}}
        </script></body></html>
        """}
}

extension ChatViewController: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        // no-op: just to keep delegate wired
    }

    private func send() {
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isGenerating else { return }
        textView.string = ""
        userExpressionActive = false  // 新消息发送时重置，允许下次 .ready 恢复默认表情
        currentMessages.append(["role": "user", "content": text])
        js("addMessage('user','\(escJS(text))')")
        sendStreamToGateway(text)
    }

    @objc func sendMessage() { send() }

    @objc func stopGeneration() {
        currentStreamTask?.cancel(); currentStreamTask = nil
        currentURLSession?.invalidateAndCancel(); currentURLSession = nil
        if isGenerating && !isFinalizing {
            js("fin()")
            finalizeAndUpdateStats()
        }
    }

    private func resetSafetyTimer() {
        safetyTimer?.invalidate()
        DispatchQueue.main.async {
            self.safetyTimer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: false) { [weak self] _ in
                guard let self = self, self.isGenerating else { return }
                self.currentStreamTask?.cancel()
                self.currentStreamTask = nil
                self.js("rt()")
                self.js("addMessage('assistant','⚠️ 生成超时(30分钟),已自动中断')")
                self.stopGenerating()
            }
        }
    }

    /// 启动流式请求的公共方法(提取三个 sendXxxToGateway 中的重复逻辑)
    private func startStreamingRequest(body: [String: Any], statusText: String, statusIcon: String) {
        guard !AppConfig.gatewayToken.isEmpty else {
            js("addMessage('assistant','❌ Gateway Token 未配置,请检查 openclaw.json')")
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
        setStatusAdvanced(statusText, priority: .generating, color: .systemBlue, alpha: 0.30)
        showStepIndicator(icon: statusIcon, text: statusText, progress: 10)
        js("at()")
        resetSafetyTimer()
        sseBuffer = ""

        var req = URLRequest(url: URL(string: "\(AppConfig.gatewayURL)/v1/responses")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(AppConfig.gatewayToken)", forHTTPHeaderField: "Authorization")
        req.setValue(currentAgentId, forHTTPHeaderField: "x-openclaw-agent-id")

        let mappedModel = availableModels.first(where: { $0.displayName == currentModel })?.apiModelId ?? "deepseek/deepseek-v4-flash"
AppLogger.shared.log("[DEBUG] currentModel=\(currentModel) mappedModel=\(mappedModel)")
        req.setValue(mappedModel, forHTTPHeaderField: "x-openclaw-model")

        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            DispatchQueue.main.async {
                self.js("addMessage('assistant','❌ 请求构造失败')")
                self.stopGenerating()
            }
            return
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 1860
        config.timeoutIntervalForResource = 3600

        currentURLSession?.invalidateAndCancel()
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        currentURLSession = session
        let task = session.dataTask(with: req)
        currentStreamTask = task; task.resume()
    }

    private func sendStreamToGateway(_ text: String) {
        guard !text.isEmpty else {
            statusLabel.stringValue = "⚠️ 消息不能为空"
            return
        }

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

        let mappedModel = availableModels.first(where: { $0.displayName == currentModel })?.apiModelId ?? "deepseek/deepseek-v4-flash"
        let temperature: Double = mappedModel.contains("kimi") ? 0.6 : 0.7

        // 虚拟形象控制指令 — 告诉大模型它有虚拟形象，可以控制表情
        let avatarInstruction = "你有一个虚拟形象（二次元风格、大眼睛、双马尾的女生），它代表你的视觉呈现。" +
            "当用户想让你做表情时（例如「你笑一下」「做个鬼脸」「委屈」「开心」等），" +
            "请在回复中嵌入一个表情标记来控制形象表情。" +
            "支持的标记格式为 [表情:xxx]，其中 xxx 可以是：" +
            "neutral（平静）、happy（微笑/开心）、thinking（思考）、sad（难过/委屈）、surprised（惊讶）。" +
            "例如用户说「你笑一下」，你可以在回复中写「好的 [表情:happy]」" +
            "标记不会显示给用户，仅用于控制形象。" +
            "如果用户没有提到表情相关的内容，不要输出标记。"

        startStreamingRequest(
            body: [
                "model": "openclaw",
                "input": inputItems,
                "instructions": avatarInstruction,
                "max_output_tokens": 16384, "temperature": temperature,
                "stream": true
            ] as [String: Any],
            statusText: "🚀 正在启动请求...",
            statusIcon: "🚀"
        )
    }

    private func stopGenerating() {
        isGenerating = false; isFinalizing = false; sendButton.isHidden = false; stopButton.isHidden = true
        // 方案1&3: 使用增强状态系统
        setStatusForce("🤖 就绪", priority: .ready)
        hideStepIndicator()
        stopStatusIconAnimation()
        setStatusBarColor(.clear, alpha: 0)
        safetyTimer?.invalidate()
    }

    func js(_ code: String) {
        webView.evaluateJavaScript(code) { [weak self] _, error in
            guard let self = self else { return }
            if let error = error {
                let nsError = error as NSError
                if nsError.domain == "WKErrorDomain" && nsError.code == 5 {
                    return
                }
                AppLogger.shared.log("[JS Error] \(nsError.domain) \(nsError.code): \(nsError.localizedDescription) code=\(code.prefix(80))")
                if let line = nsError.userInfo["WKJavaScriptExceptionLineNumber"] as? Int {
                    AppLogger.shared.log("[JS Error]  Line: \(line)")
                }
                if let col = nsError.userInfo["WKJavaScriptExceptionColumnNumber"] as? Int {
                    AppLogger.shared.log("[JS Error]  Col: \(col)")
                }
                self.jsErrorCount += 1
                if self.jsErrorCount >= 5 {
                    AppLogger.shared.log("[WebView] JS 连续崩溃 \(self.jsErrorCount) 次,重新加载 WebView")
                    self.jsErrorCount = 0
                    DispatchQueue.main.async {
                        let html = self.chatHTML()
                        self.webView.loadHTMLString(html, baseURL: nil)
                    }
                }
            } else {
                self.jsErrorCount = 0
            }
        }
    }
    func escJS(_ s: String) -> String {
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
    // MARK: - HTTP 响应检查
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let httpResponse = response as? HTTPURLResponse else {
            completionHandler(.allow)
            return
        }

        if httpResponse.statusCode != 200 {
            AppLogger.shared.log("[HTTP Error] 状态码: \(httpResponse.statusCode)")
            // 不阻止接收,但标记错误状态,后续 didReceive data 中会检查
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                // 显示错误状态
                self.setStatusForce("❌ HTTP \(httpResponse.statusCode)", priority: .ready)
                self.hideStepIndicator()

                // 在聊天区显示错误
                let errorMsg = "⚠️ Gateway 返回 HTTP \(httpResponse.statusCode)\n模型可能未在 Gateway 中注册,或 API Key 无效。"
                self.js("addMessage('assistant','\(self.escJS(errorMsg))')")
            }
        }

        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !data.isEmpty else { return }
        guard let chunk = String(data: data, encoding: .utf8) else {
AppLogger.shared.log("[SSE Error] 无法将数据解码为 UTF-8")
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
        // 最后一段可能是不完整的,留在缓冲区等待下一批
        if sseBuffer.hasSuffix("\n\n") {
            sseBuffer = ""
        } else {
            sseBuffer = blocks.last ?? ""
        }

        // 处理完整的块(排除最后一个不完整的)
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

    /// 检测并处理 [表情:xxx] 标记
    /// - Returns: (移除标记后的文本, 是否匹配到标记)
    private func processExpressionTag(_ text: String) -> (String, Bool) {
        let pattern = #"\[表情:([a-zA-Z]+)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return (text, false)
        }
        let expression = String(text[Range(match.range(at: 1), in: text)!])
        AppLogger.shared.log("[Avatar] 检测到表情标记: \(expression)，缓冲区内容: \(text)")
        self.setAvatarExpression(expression, userInitiated: true)
        // 移除标记，保留其他内容
        var cleaned = text
        if let range = Range(match.range, in: cleaned) {
            cleaned.removeSubrange(range)
        }
        return (cleaned, true)
    }

    /// 线程安全的 activeToolStack 操作
    private func pushTool(_ name: String) {
        activeToolStack.append(name)
    }

    private func popTool() {
        if !activeToolStack.isEmpty {
            activeToolStack.removeLast()
        }
    }

    private func resetToolStack() {
        activeToolStack = []
    }

    /// 安全设置状态文本
    private func setStatus(_ text: String) {
        // 直接赋值
        statusLabel.stringValue = text
        statusLabel.needsDisplay = true
    }

    private func processResponsesEvent(event: String, data: String) {
        guard !data.isEmpty else { return }

        guard let d = data.data(using: .utf8) else {
AppLogger.shared.log("[SSE Error] 无法将 event data 转为 Data")
            return
        }

        guard let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
AppLogger.shared.log("[SSE Error] JSON 解析失败: \(data.prefix(200))")
            return
        }

        guard let type = j["type"] as? String else {
AppLogger.shared.log("[SSE Warning] 事件缺少 type 字段: \(data.prefix(200))")
            return
        }

        // 整个事件处理必须在主线程,确保数据安全
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // 方案1&3: 使用增强状态系统
            switch type {
            case "response.created":
                self.resetToolStack()
                self.setStatusAdvanced("🤖 启动...", priority: .thinking, color: .systemBlue, alpha: 0.30)
                self.showStepIndicator(icon: "🚀", text: "正在启动请求...", progress: 10)

            case "response.in_progress":
                self.setStatusAdvanced("🤖 思考中...", priority: .thinking, color: .systemBlue, alpha: 0.35)
                self.showStepIndicator(icon: "🤔", text: "正在思考...", progress: 30)
                self.startStatusIconAnimation(icons: self.thinkingIcons)

            case "response.output_item.added":
                if let item = j["item"] as? [String: Any], item["type"] as? String == "function_call" {
                    let name = item["name"] as? String ?? ""
                    let args = item["arguments"] as? [String: Any]
                    let friendlyName = friendlyToolName(name)
                    let summary = toolArgsSummary(args)
                    self.pushTool(name)

                    let statusText: String
                    if !summary.isEmpty {
                        statusText = "🔧 \(friendlyName): \(summary)"
                    } else {
                        statusText = "🔧 调用工具: \(friendlyName)"
                    }
                    self.setStatusAdvanced(statusText, priority: .toolCall, color: .systemOrange, alpha: 0.50)
                    self.showStepIndicator(icon: "🔧", text: "正在调用 \(friendlyName)...", progress: 50)
                    self.startStatusIconAnimation(icons: self.toolIcons)
                } else if let item = j["item"] as? [String: Any], item["type"] as? String == "reasoning" {
                    self.setStatusAdvanced("🧠 深度思考...", priority: .reasoning, color: .systemPurple, alpha: 0.45)
                    self.showStepIndicator(icon: "🧠", text: "深度推理中...", progress: 40)
                } else {
                    self.setStatusAdvanced("🤖 思考中...", priority: .thinking, color: .systemBlue, alpha: 0.35)
                    self.showStepIndicator(icon: "🤔", text: "正在思考...", progress: 30)
                }

            case "response.content_part.added":
                if let part = j["part"] as? [String: Any], part["type"] as? String == "text" {
                    self.setStatusAdvanced("✍️ 准备输出...", priority: .generating, color: .systemGreen, alpha: 0.35)
                    self.showStepIndicator(icon: "✍️", text: "准备输出内容...", progress: 60)
                }

            case "response.function_call_arguments.delta":
                if let delta = j["delta"] as? String, !delta.isEmpty {
                    self.setStatusAdvanced("🔧 参数输入中...", priority: .toolCall, color: .systemOrange, alpha: 0.50)
                }

            case "response.function_call_arguments.done":
                if let name = j["name"] as? String {
                    let friendlyName = friendlyToolName(name)
                    self.setStatusAdvanced("✅ 参数就绪: \(friendlyName)", priority: .toolCall, color: .systemOrange, alpha: 0.35)
                }

            case "response.reasoning_text.delta":
                self.setStatusAdvanced("🧠 深度思考...", priority: .reasoning, color: .systemPurple, alpha: 0.50)
                self.showStepIndicator(icon: "🧠", text: "深度推理中...", progress: 40)

            case "response.reasoning_summary_text.delta":
                self.setStatusAdvanced("🧠 推理总结中...", priority: .reasoning, color: .systemPurple, alpha: 0.40)

            case "response.output_text.delta":
                if let content = j["delta"] as? String {
                    // 累积到缓冲区，处理流式拆分
                    self.expressionTagBuffer += content
                    // 对整个缓冲区检测 [表情:xxx] 标记
                    let (cleaned, matched) = self.processExpressionTag(self.expressionTagBuffer)
                    if matched {
                        // 匹配成功，更新缓冲区为清理后的内容
                        self.expressionTagBuffer = cleaned
                        // 把清理后的内容追加到 UI
                        if !cleaned.isEmpty {
                            self.js("apd('\(self.escJS(cleaned))')")
                        }
                    } else {
                        // 没匹配到完整标记，检查是否有不完整标记的开头
                        // 从后往前找 [，判断是否是 [表情: 的前缀
                        let tagPrefix = "[表情:"
                        var safePrefix = self.expressionTagBuffer
                        var holdPrefix = ""
                        if let lastBracket = self.expressionTagBuffer.range(of: "[", options: .backwards) {
                            let suffix = String(self.expressionTagBuffer[lastBracket.lowerBound...])
                            // suffix 以 tagPrefix 开头 或 tagPrefix 以 suffix 开头 → 不完整标记
                            if suffix.hasPrefix(tagPrefix) || tagPrefix.hasPrefix(suffix) {
                                safePrefix = String(self.expressionTagBuffer[..<lastBracket.lowerBound])
                                holdPrefix = suffix
                            }
                        }
                        // 把安全部分推到 UI，保留不完整前缀在缓冲区
                        if !safePrefix.isEmpty {
                            self.js("apd('\(self.escJS(safePrefix))')")
                        }
                        self.expressionTagBuffer = holdPrefix
                    }
                    self.streamCharCount += content.count
                    let liveTotal = self.totalPromptTokens + self.totalCompletionTokens + self.streamCharCount / 3
                    self.tokenLabel.stringValue = "⚡ \(formatNumber(self.totalPromptTokens)) + \(formatNumber(self.totalCompletionTokens + self.streamCharCount / 3)) = \(formatNumber(liveTotal)) tok"
                    self.setStatusAdvanced("📝 生成回复...", priority: .generating, color: .systemGreen, alpha: 0.40)
                    self.showStepIndicator(icon: "📝", text: "正在生成回复...", progress: 75)
                    self.stopStatusIconAnimation()
                } else {
AppLogger.shared.log("[SSE Warning] output_text.delta 缺少 delta 字段")
                }

            case "response.output_text.done":
                self.setStatusAdvanced("✅ 输出完成", priority: .generating, color: .systemGreen, alpha: 0.30)
                self.showStepIndicator(icon: "✅", text: "回复生成完成", progress: 100)

            case "response.content_part.done":
                if let part = j["part"] as? [String: Any] {
                    if part["type"] as? String == "function_call" {
                        let name = part["name"] as? String ?? ""
                        let friendlyName = friendlyToolName(name)
                        self.setStatusAdvanced("✅ 工具完成: \(friendlyName)", priority: .toolCall, color: .systemOrange, alpha: 0.30)
                        self.showStepIndicator(icon: "✅", text: "工具执行完成: \(friendlyName)", progress: 65)
                    } else {
                        self.setStatusAdvanced("✅ 内容块完成", priority: .generating, color: .systemGreen, alpha: 0.25)
                    }
                }

            case "response.output_item.done":
                if let item = j["item"] as? [String: Any] {
                    if item["type"] as? String == "function_call" {
                        let name = item["name"] as? String ?? ""
                        let friendlyName = friendlyToolName(name)
                        self.popTool()
                        let remaining = self.activeToolStack.count
                        if remaining > 0 {
                            self.setStatusAdvanced("🔧 等待工具返回: \(friendlyName)", priority: .toolCall, color: .systemOrange, alpha: 0.35)
                        } else {
                            self.setStatusAdvanced("🔧 工具已调用: \(friendlyName)", priority: .toolCall, color: .systemBlue, alpha: 0.30)
                            self.showStepIndicator(icon: "🔧", text: "工具已调用: \(friendlyName)", progress: 55)
                        }
                    } else if item["type"] as? String == "reasoning" {
                        self.setStatusAdvanced("🤖 思考完成,准备回复...", priority: .thinking, color: .systemBlue, alpha: 0.30)
                        self.showStepIndicator(icon: "🤔", text: "思考完成,准备回复...", progress: 60)
                    }
                }

            case "response.completed":
                if let resp = j["response"] as? [String: Any], let usage = resp["usage"] as? [String: Any] {
                    if let inputTokens = usage["input_tokens"] as? Int {
                        self.totalPromptTokens = inputTokens
                    }
                    if let outputTokens = usage["output_tokens"] as? Int {
                        self.totalCompletionTokens = outputTokens
                    }
                    self.updateUsageDisplay()
                }
                self.setStatusForce("🤖 就绪", priority: .ready, color: .clear, alpha: 0)
                self.hideStepIndicator()
                self.stopStatusIconAnimation()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.finalizeAndUpdateStats() }

            case "response.failed":
                if let err = j["error"] as? [String: Any], let msg = err["message"] as? String {
                    self.js("addMessage('assistant','❌ 错误: \(self.escJS(msg))')")
                }
                self.setStatusForce("❌ 请求失败", priority: .ready, color: .systemRed, alpha: 0.35)
                self.hideStepIndicator()
                self.stopStatusIconAnimation()
                DispatchQueue.main.async { self.finalizeAndUpdateStats() }

            default:
AppLogger.shared.log("[SSE] 未处理事件类型: \(type)")
                break
            }
        }
    }

    private func finalizeAndUpdateStats() {
        // 幂等锁:防止重复调用(response.completed + [DONE] 双重触发)
        guard !isFinalizing else { return }
        isFinalizing = true

        // 先停止 typing 动画
        js("rt()")

        // Flush 表情标记缓冲区残留（流结束时还有未处理的内容）
        if !expressionTagBuffer.isEmpty {
            // 最后尝试匹配一次完整标记
            let (cleaned, _) = processExpressionTag(expressionTagBuffer)
            if !cleaned.isEmpty {
                js("apd('\(escJS(cleaned))')")
            }
            expressionTagBuffer = ""
        }

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

        // 使用弱引用避免循环引用,延迟执行避免 JS race condition
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            self.webView.evaluateJavaScript(getJS) { [weak self] r, error in
                guard let self = self else { return }
                if let error = error {
AppLogger.shared.log("[finalize] JS 执行错误: \(error)")
                }
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
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        DispatchQueue.main.async {
            if let e = error as NSError? {
                if e.code == NSURLErrorCancelled {
                    AppLogger.shared.log("[Stream] 手动取消 (NSURLErrorCancelled)")
                    return
                }
                AppLogger.shared.log("[Stream Error] 流中断: \(e.domain) code=\(e.code) \(e.localizedDescription)")
                if self.isGenerating && !self.isFinalizing {
                    self.js("addMessage('assistant','⚠️ 连接中断: \(self.escJS(e.localizedDescription))')")
                    self.js("rt()")
                    self.finalizeAndUpdateStats()
                } else {
                    AppLogger.shared.log("[Stream] 强制复位 (isGenerating=\(self.isGenerating) isFinalizing=\(self.isFinalizing))")
                    self.stopGenerating()
                }
            } else if error == nil && self.isGenerating {
                AppLogger.shared.log("[Stream] 连接正常关闭,执行兜底 finalize")
                if !self.isFinalizing {
                    self.finalizeAndUpdateStats()
                } else {
                    AppLogger.shared.log("[Stream] isFinalizing=true,直接 stopGenerating")
                    self.stopGenerating()
                }
            }
        }
    }

    // MARK: - 文件发送
    func sendFile(data: Data, filename: String, mimeType: String) {
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isGenerating else { return }

        // 判断是否为图片类型
        let isImage = mimeType.hasPrefix("image/")

        // 拼消息
        let base64 = data.base64EncodedString()

        if isImage {
            // 图片:存缓存 + 渲染预览 + 发送
            let fileId = saveFileToCache(data: data, filename: filename)
            let dataUrl = "data:\(mimeType);base64,\(base64)"
            currentMessages.append(["role": "user", "content": "[图片] \(filename)", "type": "image", "fileId": fileId])
            js("addImageMessage('user','\(dataUrl)','\(escJS(filename))')")
            // 发送图片到 Gateway
            sendImageToGateway(imageData: dataUrl, filename: filename, text: text)
        } else {
            // 文件:存缓存 + 渲染卡片 + 发送
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
        // 构建带图片的消息
        var contentParts: [[String: Any]] = []
        contentParts.append([
            "type": "input_image",
            "image_url": imageData,
            "detail": "high"
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

        let mappedModel = availableModels.first(where: { $0.displayName == currentModel })?.apiModelId ?? "deepseek/deepseek-v4-flash"
        let temperature: Double = mappedModel.contains("kimi") ? 0.6 : 0.7

        startStreamingRequest(
            body: [
                "model": "openclaw",
                "input": inputItems,
                "max_output_tokens": 16384, "temperature": temperature,
                "stream": true
            ] as [String: Any],
            statusText: "🖼️ 发送图片: \(filename)",
            statusIcon: "🖼️"
        )
    }

    private func sendFileToGateway(fileData: String, filename: String, mimeType: String, text: String) {
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

        let mappedModel = availableModels.first(where: { $0.displayName == currentModel })?.apiModelId ?? "deepseek/deepseek-v4-flash"
        let temperature: Double = mappedModel.contains("kimi") ? 0.6 : 0.7

        startStreamingRequest(
            body: [
                "model": "openclaw",
                "input": inputItems,
                "max_output_tokens": 16384, "temperature": temperature,
                "stream": true
            ] as [String: Any],
            statusText: "📎 发送文件: \(filename)",
            statusIcon: "📎"
        )
    }

    func switchToConversation(_ index: Int) {
        guard !conversations.isEmpty else {
AppLogger.shared.log("[Error] switchToConversation: 无可用会话")
            return
        }
        guard conversations.indices.contains(index) else {
AppLogger.shared.log("[Error] switchToConversation: index \(index) out of range (count: \(conversations.count))")
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
AppLogger.shared.log("[Warning] Message \(msgIndex) has empty content, skipping")
                    continue
                }
                if type == "image", let fileId = msg["fileId"] {
                    // 恢复图片消息:从缓存读文件,生成 data URL 渲染
                    let fileURL = self.cachedFileURL(fileId: fileId)
                    if let imageData = try? Data(contentsOf: fileURL) {
                        let mimeType = mimeTypeForFile(fileId)
                        let dataUrl = "data:\(mimeType);base64,\(imageData.base64EncodedString())"
                        self.js("addImageMessage('\(self.escJS(role))','\(dataUrl)','\(self.escJS(content))')")
                    } else {
                        self.js("addMessage('\(self.escJS(role))','\(self.escJS(content)) [缓存丢失]')")
                    }
                } else if type == "file", let fileId = msg["fileId"] {
                    // 恢复文件消息:渲染文件卡片
                    let fileURL = self.cachedFileURL(fileId: fileId)
                    let fileSize = Int(msg["fileSize"] ?? "0") ?? 0
                    let fileSizeStr = formatFileSize(fileSize)
                    let ext = fileExtension(fileId)
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

    // MARK: - 虚拟形象

    private func setupAvatarView() {
        let config = WKWebViewConfiguration()
        let userContent = WKUserContentController()
        config.userContentController = userContent
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self
        avatarContainer.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: avatarContainer.topAnchor),
            webView.leadingAnchor.constraint(equalTo: avatarContainer.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: avatarContainer.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: avatarContainer.bottomAnchor),
        ])
        avatarWebView = webView
        avatarReady = false
        webView.loadHTMLString(AvatarHTML.template, baseURL: nil)
    }

    func avatarDidLoad() {
        avatarReady = true
        AppLogger.shared.log("[Avatar] avatarDidLoad 被调用")
        // 先验证 SVG 结构
        avatarWebView?.evaluateJavaScript("document.getElementById('eyes')?.getAttribute('d') ?? 'NOT_FOUND'") { eyes, _ in
            AppLogger.shared.log("[Avatar] 初始 - eyes path: \(eyes ?? "nil")")
        }
        avatarWebView?.evaluateJavaScript("document.getElementById('mouth')?.getAttribute('d') ?? 'NOT_FOUND'") { mouth, _ in
            AppLogger.shared.log("[Avatar] 初始 - mouth path: \(mouth ?? "nil")")
        }
        // 再设置表情（默认 neutral）
        avatarWebView?.evaluateJavaScript("setExpression('neutral')")
    }

    /// 通过 JS 桥接设置表情
    func setAvatarExpression(_ expr: String, userInitiated: Bool = false) {
        AppLogger.shared.log("[Avatar] setAvatarExpression 被调用: \(expr), avatarReady=\(avatarReady), userInitiated=\(userInitiated)")
        guard avatarReady else { AppLogger.shared.log("[Avatar] avatarReady=false, 跳过"); return }
        let js = "setExpression('\(escJS(expr))')"
        AppLogger.shared.log("[Avatar] 执行 JS: \(js)")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // 用户表情激活中，跳过所有非用户触发的覆盖（在主线程检查，消除竞态）
            if self.userExpressionActive && !userInitiated {
                AppLogger.shared.log("[Avatar] 用户表情激活中，主线程跳过覆盖: \(expr)")
                return
            }
            if userInitiated {
                self.userExpressionActive = true  // 在主线程设置 flag，消除竞态
            }
            self.avatarWebView?.evaluateJavaScript(js) { result, error in
                if let error = error {
                    AppLogger.shared.log("[Avatar] JS 执行错误: \(error.localizedDescription)")
                } else {
                    AppLogger.shared.log("[Avatar] JS 执行成功, 返回值: \(result ?? "nil")")
                    // 验证 SVG 状态 — 使用 SVG 中实际的 id
                    self.avatarWebView?.evaluateJavaScript("document.getElementById('eyes')?.querySelector('ellipse')?.getAttribute('fill') ?? 'NOT_FOUND'") { eyes, _ in
                        AppLogger.shared.log("[Avatar] 验证 - eyes fill: \(eyes ?? "nil")")
                    }
                    self.avatarWebView?.evaluateJavaScript("document.getElementById('mouth')?.getAttribute('d') ?? 'NOT_FOUND'") { mouth, _ in
                        AppLogger.shared.log("[Avatar] 验证 - mouth path: \(mouth ?? "nil")")
                    }
                    self.avatarWebView?.evaluateJavaScript("document.getElementById('brow-l')?.getAttribute('d') ?? 'NOT_FOUND'") { brow, _ in
                        AppLogger.shared.log("[Avatar] 验证 - brow-l path: \(brow ?? "nil")")
                    }
                    self.avatarWebView?.evaluateJavaScript("document.getElementById('brow-r')?.getAttribute('d') ?? 'NOT_FOUND'") { brow, _ in
                        AppLogger.shared.log("[Avatar] 验证 - brow-r path: \(brow ?? "nil")")
                    }
                    self.avatarWebView?.evaluateJavaScript("document.getElementById('blush-l')?.getAttribute('opacity') ?? 'NOT_FOUND'") { blush, _ in
                        AppLogger.shared.log("[Avatar] 验证 - blush-l opacity: \(blush ?? "nil")")
                    }
                    self.avatarWebView?.evaluateJavaScript("document.getElementById('blush-r')?.getAttribute('opacity') ?? 'NOT_FOUND'") { blush, _ in
                        AppLogger.shared.log("[Avatar] 验证 - blush-r opacity: \(blush ?? "nil")")
                    }
                }
            }
        }
    }

    /// 通过 JS 桥接设置状态文本
    func setAvatarStatus(_ text: String) {
        guard avatarReady else { return }
        let js = "setStatus('\(escJS(text))')"
        DispatchQueue.main.async { [weak self] in
            self?.avatarWebView?.evaluateJavaScript(js)
        }
    }

    /// 通过 JS 桥接替换整个 SVG 内容（用于 AI 生成或模板切换）
    func loadAvatarSVG(_ svgContent: String) {
        guard avatarReady else { return }
        let escaped = svgContent
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "")
        let js = "loadSVG('\(escaped)')"
        DispatchQueue.main.async { [weak self] in
            self?.avatarWebView?.evaluateJavaScript(js)
        }
    }
}


