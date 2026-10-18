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
    private lazy var avatarManager: AvatarManager = {
        return AvatarManager(containerView: avatarContainer)
    }()

    // Agent 参数面板

    // 聊天区
    private let webView: WKWebView = {
        let config = WKWebViewConfiguration()
        let userController = WKUserContentController()
        config.userContentController = userController
        return WKWebView(frame: .zero, configuration: config)
    }()
    /// 待执行的会话恢复逻辑:等 WebView 真正加载完成后(didFinish)才注入历史消息,
    /// 避免 loadHTMLString 异步加载竞态导致注入丢失 / 滚动被重置到顶部
    var pendingRestore: (() -> Void)?
    /// 供 WebKit 扩展访问聊天 WebView(区分虚拟形象 WebView)
    var chatWebView: WKWebView { webView }
    private let textView = SendTextView()

    // 文件拖拽
    private let dropTargetView = DropTargetView()
    private let dropIndicator = NSView()
    private let dropLabel = NSTextField()
    private let textScrollView = NSScrollView()
    private let inputResizeHandle = InputResizeHandle()
    /// 输入框高度约束（可通过拖动顶部分隔条调整）
    private var inputHeightConstraint: NSLayoutConstraint?
    private static let defaultInputHeight: CGFloat = 72
    private static let minInputHeight: CGFloat = 72
    private static let inputHeightDefaultsKey = "inputAreaHeight"
    private let sendButton = NSButton()
    private let stopButton = NSButton()
    private let attachButton = NSButton()

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

    // === 会话管理 ===
    let sessionManager = ChatSessionManager()

    // === 状态 ===
    private var isGenerating = false
    private var isFinalizing = false // 幂等锁:防止 finalize 被多次调用
    private var streamSession: StreamSession?
    private var safetyTimer: Timer?
    private var jsErrorWindow: [Bool] = []  // 滑动窗口: true=成功, false=失败; 最近20次, ≥5失败触发reload
    let responseEventHandler = ResponseEventHandler()  // SSE 事件处理(流式文本累积+状态转换)

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
    /// 当前会话正在使用的模型(apiModelId 格式,如 "openai/gpt-5.5")
    /// 这是唯一权威来源:下拉菜单、底栏、请求头都从它读取
    private var currentModelId: String = Models.normalize(
        UserDefaults.standard.string(forKey: "selectedModelId") ?? "deepseek/deepseek-flash"
    )
    /// 当前模型的显示名(用于 UI)
    private var currentModel: String { Models.prettyName(for: currentModelId) }
    private let balanceService = BalanceService()
    private var dsBalance: String = "--"
    private var moonshotBalance: String = "--"
    var currentAgentId = "main"

    private var currentMessages: [[String: String]] {
        get { sessionManager.currentMessages }
        set { sessionManager.currentMessages = newValue }
    }

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
        if sessionManager.conversations.isEmpty {
            sessionManager.conversations = [Conversation(title: "💬 新对话 1")]
        }
        webView.navigationDelegate = self
        // 注册 JS 消息处理
        webView.configuration.userContentController.add(self, name: "fileOpen")
        // 同步模型 UI(下拉菜单 + 底栏):此时 availableModels 已加载
        refreshModelUI()
        updateUsageDisplay()
        fetchBalance()
        conversationTableView.reloadData()
        let lastIndex = min(sessionManager.conversations.count - 1, 0)
        conversationTableView.selectRowIndexes(IndexSet(integer: lastIndex), byExtendingSelection: false)
        // 只加载一次 HTML:有历史就走 switchToConversation(内部会 loadChatHTML(then:) 注入消息),
        // 否则空会话直接加载。避免连续两次 loadHTMLString 导致恢复竞态 / 消息丢失。
        if sessionManager.conversations.count > 1 || !sessionManager.conversations[0].messages.isEmpty {
            switchToConversation(lastIndex)
        } else {
            loadChatHTML()
        }

        avatarManager.setup()
        responseEventHandler.delegate = self
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
        guard !avatarManager.userExpressionActive else {
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
        avatarManager.setExpression(expression)
        // 同步状态文本（去掉 emoji 前缀，保留文字部分）
        let statusText = statusLabel.stringValue
        if let range = statusText.range(of: " ") {
            avatarManager.setStatus(String(statusText[range.upperBound...]))
        } else {
            avatarManager.setStatus(statusText)
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
        // 让文本宽度跟随滚动视图，纵向可增长，避免调整高度后换行/留白异常
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = self
        textView.onCommandEnter = { [weak self] in self?.send() }
        textView.onPasteImage = { [weak self] data, filename, mimeType in
            self?.sendFile(data: data, filename: filename, mimeType: mimeType)
        }

        // Focus input on launch
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.textView.window?.makeFirstResponder(self?.textView)
        }
        textScrollView.documentView = textView
        chatContainer.addSubview(textScrollView)

        // 输入框顶部的拖拽条（上下拖动改高度，双击复位）
        inputResizeHandle.translatesAutoresizingMaskIntoConstraints = false
        inputResizeHandle.onDrag = { [weak self] delta in
            self?.adjustInputHeight(by: delta)
        }
        inputResizeHandle.onReset = { [weak self] in
            self?.setInputHeight(ChatViewController.defaultInputHeight)
        }
        chatContainer.addSubview(inputResizeHandle)

        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.title = "发送"; sendButton.bezelStyle = .rounded
        sendButton.action = #selector(sendMessage); sendButton.target = self
        chatContainer.addSubview(sendButton)

        attachButton.translatesAutoresizingMaskIntoConstraints = false
        attachButton.title = "📎"; attachButton.bezelStyle = .rounded
        attachButton.toolTip = "添加附件(图片/文件)"
        attachButton.action = #selector(pickAttachment); attachButton.target = self
        chatContainer.addSubview(attachButton)

        stopButton.translatesAutoresizingMaskIntoConstraints = false
        stopButton.title = "⏹ 停止"; stopButton.bezelStyle = .rounded
        stopButton.action = #selector(stopGeneration); stopButton.target = self
        stopButton.isHidden = true
        chatContainer.addSubview(stopButton)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: toolbarView.bottomAnchor, constant: 4),
            webView.leadingAnchor.constraint(equalTo: chatContainer.leadingAnchor, constant: 8),
            webView.trailingAnchor.constraint(equalTo: chatContainer.trailingAnchor, constant: -8),
            webView.bottomAnchor.constraint(equalTo: inputResizeHandle.topAnchor, constant: -4),
            // 输入框拖得再高，也保证聊天区还有可用高度
            webView.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),

            // Input area at bottom, full width. Height is user-adjustable via the handle above it.
            textScrollView.leadingAnchor.constraint(equalTo: chatContainer.leadingAnchor, constant: 8),
            textScrollView.trailingAnchor.constraint(equalTo: chatContainer.trailingAnchor, constant: -76),
            textScrollView.bottomAnchor.constraint(equalTo: statusBar.topAnchor, constant: -8),

            inputResizeHandle.leadingAnchor.constraint(equalTo: textScrollView.leadingAnchor),
            inputResizeHandle.trailingAnchor.constraint(equalTo: textScrollView.trailingAnchor),
            inputResizeHandle.bottomAnchor.constraint(equalTo: textScrollView.topAnchor),
            inputResizeHandle.heightAnchor.constraint(equalToConstant: 8),

            // Send button to the right of the input, bottom-aligned with the input bottom
            sendButton.leadingAnchor.constraint(equalTo: textScrollView.trailingAnchor, constant: 8),
            sendButton.trailingAnchor.constraint(equalTo: chatContainer.trailingAnchor, constant: -8),
            sendButton.bottomAnchor.constraint(equalTo: textScrollView.bottomAnchor),
            sendButton.widthAnchor.constraint(equalToConstant: 60),
            sendButton.heightAnchor.constraint(equalToConstant: 32),

            // Stop button same position as send
            stopButton.leadingAnchor.constraint(equalTo: textScrollView.trailingAnchor, constant: 8),
            stopButton.trailingAnchor.constraint(equalTo: chatContainer.trailingAnchor, constant: -8),
            stopButton.bottomAnchor.constraint(equalTo: textScrollView.bottomAnchor),
            stopButton.widthAnchor.constraint(equalToConstant: 60),
            stopButton.heightAnchor.constraint(equalToConstant: 32),

            // Attach button: 锚定在输入框【顶边】，随输入框高度变化一起上下移动
            attachButton.trailingAnchor.constraint(equalTo: chatContainer.trailingAnchor, constant: -8),
            attachButton.topAnchor.constraint(equalTo: textScrollView.topAnchor),
            attachButton.widthAnchor.constraint(equalToConstant: 60),
            attachButton.heightAnchor.constraint(equalToConstant: 32),
        ])

        // 输入框高度：可由拖拽条调整，并记住上次的高度
        let saved = UserDefaults.standard.double(forKey: ChatViewController.inputHeightDefaultsKey)
        let initialHeight = saved > 0 ? min(CGFloat(saved), 400) : ChatViewController.defaultInputHeight
        let heightConstraint = textScrollView.heightAnchor.constraint(equalToConstant: initialHeight)
        heightConstraint.priority = .defaultHigh
        heightConstraint.isActive = true
        inputHeightConstraint = heightConstraint
    }

    // MARK: - 输入框高度调整
    private func adjustInputHeight(by delta: CGFloat) {
        let current = inputHeightConstraint?.constant ?? ChatViewController.defaultInputHeight
        setInputHeight(current + delta)
    }

    private func setInputHeight(_ height: CGFloat) {
        let maxHeight = max(ChatViewController.minInputHeight,
                            (chatContainer.bounds.height * 0.65).rounded())
        let clamped = min(max(height, ChatViewController.minInputHeight), maxHeight)
        guard clamped != inputHeightConstraint?.constant else { return }
        inputHeightConstraint?.constant = clamped
        UserDefaults.standard.set(Double(clamped), forKey: ChatViewController.inputHeightDefaultsKey)
        // 拖动过程中立即重排，保证聊天区底边与输入框顶边同步上下移动（不等到 mouseUp 才刷新）
        chatContainer.needsLayout = true
        chatContainer.layoutSubtreeIfNeeded()
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
        let total = sessionManager.totalPromptTokens + sessionManager.totalCompletionTokens
        tokenLabel.stringValue = "⚡ \(formatNumber(sessionManager.totalPromptTokens)) + \(formatNumber(sessionManager.totalCompletionTokens)) = \(formatNumber(total)) tok"
    }

    /// 把当前模型同步到所有 UI 位置(下拉菜单按钮 + 底栏标签)
    private func refreshModelUI() {
        modelButton.title = "🧠 \(currentModel) ▾"
        modelLabel.stringValue = "🤖 \(currentModel)"
        // 同步菜单勾选状态
        for item in modelMenu.items {
            item.state = (item.representedObject as? String) == currentModelId ? .on : .off
        }
    }

    /// 切换当前模型(唯一入口):更新状态 + UI + 持久化 + 写回当前会话
    private func setCurrentModel(_ apiModelId: String, persistToConversation: Bool = true) {
        currentModelId = apiModelId
        UserDefaults.standard.set(apiModelId, forKey: "selectedModelId")
        refreshModelUI()
        if persistToConversation {
            sessionManager.setModel(apiModelId)
        }
        AppLogger.shared.log("[Model] 当前模型切换为 \(apiModelId) (\(currentModel))")
    }





    private func fetchBalance() {
        balanceService.fetchBalances(
            deepseekKey: AppConfig.deepseekAPIKey,
            kimiKey: AppConfig.moonshotAPIKey
        ) { [weak self] balances in
            guard let self = self else { return }
            self.dsBalance = balances.deepseek
            self.moonshotBalance = balances.kimi
            self.updateBalanceDisplay()
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
            availableModels = [Models.ModelOption(displayName: "DeepSeek V4 Flash", apiModelId: "deepseek/deepseek-flash")]
            return
        }
        do {
            let data = try Data(contentsOf: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [String: Any],
                  let providers = models["providers"] as? [String: Any] else {
AppLogger.shared.log("[loadAvailableModels] 解析 openclaw.json 结构失败")
                availableModels = [Models.ModelOption(displayName: "DeepSeek V4 Flash", apiModelId: "deepseek/deepseek-flash")]
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
                    let displayName = model["displayName"] as? String ?? model["name"] as? String ?? modelId
                    result.append(Models.ModelOption(displayName: displayName, apiModelId: "\(providerName)/\(modelId)"))
                }
            }

            if result.isEmpty {
                // 兜底
                result = [Models.ModelOption(displayName: "DeepSeek V4 Flash", apiModelId: "deepseek/deepseek-flash")]
            }

            // 去重:同一 apiModelId 只保留一个(不同别名可能重复注册)
            var seen = Set<String>()
            result = result.filter { seen.insert($0.apiModelId).inserted }

            availableModels = result
            // 如果当前选中模型不在可用列表中,优先回退到 agents.defaults.model.primary,
            // 其次才是列表第一个(避免因为 provider 遍历顺序意外切到 Kimi)
            if !result.contains(where: { $0.apiModelId == currentModelId }) {
                var defaultPrimary: String?
                if let agents = json["agents"] as? [String: Any],
                   let defaults = agents["defaults"] as? [String: Any],
                   let model = defaults["model"] as? [String: Any],
                   let primary = model["primary"] as? String {
                    defaultPrimary = primary
                }
                if let primary = defaultPrimary, result.contains(where: { $0.apiModelId == primary }) {
                    currentModelId = primary
                } else {
                    currentModelId = result.first?.apiModelId ?? "deepseek/deepseek-flash"
                }
                UserDefaults.standard.set(currentModelId, forKey: "selectedModelId")
            }
        } catch {
AppLogger.shared.log("[loadAvailableModels] 读取 openclaw.json 失败: \(error)")
            availableModels = [Models.ModelOption(displayName: "DeepSeek V4 Flash", apiModelId: "deepseek/deepseek-flash")]
            DispatchQueue.main.async { [weak self] in
                self?.statusLabel.stringValue = "⚠️ 模型配置读取失败"
            }
        }
    }

    private func setupModelMenu() {
        modelMenu.removeAllItems()
        for opt in availableModels {
            let item = NSMenuItem(title: opt.displayName, action: #selector(selectModel(_:)), keyEquivalent: "")
            item.target = self
            // 用 representedObject 存 apiModelId:显示名可能重复/改名,id 才是稳定标识
            item.representedObject = opt.apiModelId
            item.state = opt.apiModelId == currentModelId ? .on : .off
            modelMenu.addItem(item)
        }
    }
    @objc func showModelMenu() {
        // 每次弹出前重建,保证勾选状态与当前模型一致
        setupModelMenu()
        let buttonBounds = modelButton.bounds
        let menuOrigin = NSPoint(x: buttonBounds.minX, y: buttonBounds.minY)
        modelMenu.popUp(positioning: nil, at: menuOrigin, in: modelButton)
    }
    @objc func selectModel(_ sender: NSMenuItem) {
        guard let apiModelId = sender.representedObject as? String else { return }
        setCurrentModel(apiModelId)
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

    func saveConversations() { sessionManager.save() }

    private func loadConversations() { sessionManager.load() }

    @objc func doubleClickConversation() {
        let row = conversationTableView.clickedRow
        guard row >= 0, row < sessionManager.conversations.count else { return }
        let view = conversationTableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView
        guard let cell = view?.textField else { return }
        cell.isEditable = true
        cell.becomeFirstResponder()
        cell.delegate = self
    }

    @objc func newConversation() {
        sessionManager.newConversation()
        conversationTableView.reloadData()
        let newIndex = sessionManager.conversations.count - 1
        conversationTableView.selectRowIndexes(IndexSet(integer: newIndex), byExtendingSelection: false)
        switchToConversation(newIndex)
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

    /// 加载聊天 HTML 并在加载完成后执行 restore(注入历史消息 + 定位到底部)
    private func loadChatHTML(then restore: (() -> Void)?) {
        pendingRestore = restore
        webView.loadHTMLString(chatHTML(), baseURL: nil)
    }
    private func chatHTML() -> String { return """
        <!DOCTYPE html><html><head><meta charset="utf-8"><meta name="color-scheme" content="light dark">
        <style>*{margin:0;padding:0;box-sizing:border-box}body{font-family:-apple-system,"SF Pro","PingFang SC",sans-serif;font-size:14px;line-height:1.6;padding:16px;color:#1d1d1f;overflow-y:auto;-webkit-user-select:text;user-select:text}@media(prefers-color-scheme:dark){body{color:#f5f5f7}}.message{margin-bottom:16px;padding:10px 14px;border-radius:12px;max-width:85%;word-wrap:break-word;white-space:pre-wrap}.user{background:#007aff;color:white;margin-left:auto;border-bottom-right-radius:4px}.assistant{background:#e9e9eb;margin-right:auto;border-bottom-left-radius:4px}@media(prefers-color-scheme:dark){.assistant{background:#2c2c2e}}.message code{font-family:"SF Mono",Menlo,monospace;font-size:13px}.typing{opacity:.5;animation:blink 1s ease-in-out infinite}@keyframes blink{50%{opacity:.2}}.time{font-size:11px;opacity:.5;margin-top:4px}#messages{padding-bottom:8px}.welcome{text-align:center;margin-top:40%;opacity:.4}.welcome h2{font-size:24px;margin-bottom:8px}.welcome p{font-size:14px}.file-card{display:flex;align-items:center;gap:10px;padding:10px 14px;background:rgba(0,122,255,0.08);border-radius:10px;border:1px solid rgba(0,122,255,0.15);margin-top:6px;cursor:pointer;transition:background 0.15s}.file-card:hover{background:rgba(0,122,255,0.14)}.file-icon{font-size:28px;flex-shrink:0}.file-info{flex:1;min-width:0}.file-name{font-weight:600;font-size:13px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.file-size{font-size:11px;opacity:.6;margin-top:1px}.file-badge{font-size:11px;padding:2px 8px;border-radius:4px;background:rgba(0,122,255,0.12);color:#007aff;font-weight:500}.image-preview{max-width:min(100%,400px);max-height:320px;border-radius:10px;margin-top:6px;cursor:pointer;transition:opacity 0.15s;display:block;object-fit:contain}.image-preview:hover{opacity:0.85}.user .file-card,.user .file-badge{background:rgba(255,255,255,0.15);border-color:rgba(255,255,255,0.2)}.user .file-badge{color:rgba(255,255,255,0.9)}@media(prefers-color-scheme:dark){.file-card{background:rgba(0,122,255,0.12);border-color:rgba(0,122,255,0.2)}.file-card:hover{background:rgba(0,122,255,0.2)}}.img-grid{display:flex;flex-wrap:wrap;gap:6px;margin-top:6px}.img-grid .image-preview{max-width:200px;max-height:200px;margin-top:0}.code-preview{margin-top:6px;border-radius:8px;overflow:hidden;border:1px solid rgba(128,128,128,0.2)}.code-preview pre{margin:0;padding:10px 14px;font-family:"SF Mono",Menlo,monospace;font-size:12px;line-height:1.5;overflow-x:auto;background:rgba(128,128,128,0.06);white-space:pre-wrap;word-break:break-word}.code-preview .code-header{display:flex;justify-content:space-between;align-items:center;padding:4px 10px;font-size:11px;background:rgba(128,128,128,0.08);color:rgba(128,128,128,0.7)}.code-preview .code-header .lang{font-weight:600;text-transform:uppercase}</style></head><body>
        <div id="messages"><div class="welcome"><h2>👋 你好,王鹏飞</h2><p>发送消息开始对话</p></div></div>
        <script>
        // 注意:文档是 standards mode(<!DOCTYPE html>),body{overflow-y:auto} 会把滚动
        // 传播到 viewport,真正的滚动元素是 document.scrollingElement(=documentElement),
        // 不是 document.body。对 body 写 scrollTop 是无效操作(永远为 0)。
        function scroller(){return document.scrollingElement||document.documentElement||document.body}
        function isAtBottom(){try{var b=scroller();return (b.scrollHeight-b.scrollTop-b.clientHeight)<=48}catch(e){return true}}
        function doScroll(smooth){try{var b=scroller();b.scrollTo({top:b.scrollHeight,behavior:smooth?'smooth':'auto'})}catch(e){}}
        var restoring=false;
        // 「用户是否主动离开底部」意图标记：只在用户向上滚动时置 true，回到底部时置 false。
        // 注意：视口变矮（拖动输入框）会让 isAtBottom() 变成 false，但那不是用户意图，
        // 所以不能用 isAtBottom() 直接当跟随条件，否则一拖输入框就停止跟随/内容被挤出可视区。
        var scrolledAway=false;
        var lastScrollTop=0;
        function onScrollEvent(){try{var b=scroller();
          if(b.scrollTop < lastScrollTop - 2){ if(!isAtBottom()) scrolledAway=true; }
          else if(isAtBottom()){ scrolledAway=false; }
          lastScrollTop=b.scrollTop;
        }catch(e){}}
        window.addEventListener('scroll',onScrollEvent,true);
        function scrollToEnd(force){try{if(restoring)return;if(force){scrolledAway=false;doScroll(true);return}if(!scrolledAway)doScroll(true)}catch(e){}}
        function jumpToEnd(){try{var b=scroller();b.scrollTop=b.scrollHeight;lastScrollTop=b.scrollTop}catch(e){}}
        // 聊天区高度变化（拖动输入框、窗口缩放）时，如果用户没有主动离开底部，就重新贴底，
        // 保证「输入框变高后，输出框底部上移但最后一条消息依然可见」。
        window.addEventListener('resize',function(){try{if(restoring)return;if(scrolledAway)return;jumpToEnd();requestAnimationFrame(jumpToEnd)}catch(e){}});
        function beginRestore(){restoring=true}
        function endRestore(){restoring=false;scrolledAway=false;jumpToEnd();requestAnimationFrame(function(){jumpToEnd()});setTimeout(function(){jumpToEnd()},50);setTimeout(function(){jumpToEnd()},250)}
        function addMessage(r,c){try{removeWelcome();var m=document.getElementById('messages');if(!m)return null;var d=document.createElement('div');d.className='message '+r;d.innerHTML='<p>'+esc(c)+'</p>';var t=document.createElement('div');t.className='time';t.textContent=new Date().toLocaleTimeString();d.appendChild(t);m.appendChild(d);scrollToEnd(true);return d}catch(e){console.error('addMessage:',e);return null}}
        function apd(t){try{removeWelcome();var m=document.getElementById('messages');if(!m)return;var l=document.getElementById('s');if(!l){var d=document.createElement('div');d.className='message assistant';d.id='s';d.innerHTML='<p></p>';d.appendChild(document.createElement('div')).className='time';m.appendChild(d);l=d}var p=l.querySelector('p');if(p)p.textContent+=t;scrollToEnd(false)}catch(e){console.error('apd:',e)}}
        function fin(){try{var e=document.getElementById('s');if(e){var t=e.querySelector('.time');if(t)t.textContent=new Date().toLocaleTimeString();e.id=''}}catch(ex){console.error('fin:',ex)}rt()}
        function esc(t){return t.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')}
        function removeWelcome(){var e=document.querySelector('.welcome');if(e)e.remove()}
        function at(){var m=document.getElementById('messages'),d=document.createElement('div');d.className='message assistant typing';d.id='t';d.innerHTML='<p>🤔 思考中...</p>';m.appendChild(d);scrollToEnd(true)}
        function rt(){var e=document.getElementById('t');if(e)e.remove()}
        function addImageMessage(r,dataUrl,filename){try{removeWelcome();var m=document.getElementById('messages');if(!m)return;var d=document.createElement('div');d.className='message '+r;var p=document.createElement('p');p.textContent='📷 '+filename;d.appendChild(p);var img=document.createElement('img');img.className='image-preview';img.src=dataUrl;img.alt=filename;img.loading='lazy';img.onclick=function(){window.open(dataUrl,'_blank')};d.appendChild(img);var t=document.createElement('div');t.className='time';t.textContent=new Date().toLocaleTimeString();d.appendChild(t);m.appendChild(d);scrollToEnd(true)}catch(e){console.error('addImageMessage:',e)}}
        function addFileCard(r,filename,fileSize,fileId,ext){try{removeWelcome();var m=document.getElementById('messages');if(!m)return;var d=document.createElement('div');d.className='message '+r;var p=document.createElement('p');p.textContent='📎 '+filename;d.appendChild(p);var card=document.createElement('div');card.className='file-card';var icons={'pdf':'📕','doc':'📘','docx':'📘','xls':'📗','xlsx':'📗','ppt':'📙','pptx':'📙','zip':'📦','gz':'📦','tar':'📦','js':'📄','ts':'📄','py':'📄','swift':'📄','java':'📄','cpp':'📄','txt':'📄','md':'📄','json':'📄','yaml':'📄','yml':'📄','xml':'📄','html':'📄','css':'📄','default':'📄'};var icon=icons[ext]||icons['default'];card.innerHTML='<span class="file-icon">'+icon+'</span><div class="file-info"><div class="file-name">'+esc(filename)+'</div><div class="file-size">'+fileSize+'</div></div><span class="file-badge">打开</span>';card.onclick=function(){try{window.webkit.messageHandlers.fileOpen.postMessage(fileId)}catch(e){}};d.appendChild(card);var t=document.createElement('div');t.className='time';t.textContent=new Date().toLocaleTimeString();d.appendChild(t);m.appendChild(d);scrollToEnd(true)}catch(e){console.error('addFileCard:',e)}}
        function addCodeBlock(r,code,lang){try{removeWelcome();var m=document.getElementById('messages');if(!m)return;var d=document.createElement('div');d.className='message '+r;var pre=document.createElement('div');pre.className='code-preview';var h=document.createElement('div');h.className='code-header';h.innerHTML='<span class="lang">'+(lang||'code')+'</span>';pre.appendChild(h);var c=document.createElement('pre');c.textContent=code;pre.appendChild(c);d.appendChild(pre);var t=document.createElement('div');t.className='time';t.textContent=new Date().toLocaleTimeString();d.appendChild(t);m.appendChild(d);scrollToEnd(true)}catch(e){console.error('addCodeBlock:',e)}}
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
        avatarManager.userExpressionActive = false  // 新消息发送时重置，允许下次 .ready 恢复默认表情

        // 解析用户输入中的表情关键词，立即触发 avatar 表情变化
        if let expression = AvatarManager.parseExpression(from: text) {
            AppLogger.shared.log("[Avatar] 用户关键词触发表情: \(expression)")
            avatarManager.setExpression(expression, userInitiated: true)
        }

        currentMessages.append(["role": "user", "content": text])
        js("addMessage('user','\(text.escapedForJS)')")
        sendStreamToGateway(text)
    }

    @objc func sendMessage() { send() }

    /// 附件按钮: 打开文件选择面板
    @objc func pickAttachment() {
        guard !isGenerating else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "选择图片或文件发送"
        panel.begin { [weak self] result in
            guard let self = self, result == .OK, let url = panel.url else { return }
            self.handleDroppedFile(url: url)
        }
    }

    @objc func stopGeneration() {
        streamSession?.cancel()
        streamSession = nil
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
                self.streamSession?.cancel()
                self.streamSession = nil
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

        let mappedModel = currentModelId
AppLogger.shared.log("[DEBUG] currentModel=\(currentModel) mappedModel=\(mappedModel)")

        let session = StreamSession()
        session.delegate = self
        session.start(body: body, gatewayURL: AppConfig.gatewayURL, token: AppConfig.gatewayToken, agentId: currentAgentId, model: mappedModel)
        streamSession = session
    }

    private func sendStreamToGateway(_ text: String) {
        responseEventHandler.reset()  // 新请求前清空累积缓冲
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

        let mappedModel = currentModelId
        let temperature: Double = mappedModel.contains("kimi") ? 0.6 : 0.7

        startStreamingRequest(
            body: [
                "model": "openclaw",
                "input": inputItems,
                "max_output_tokens": 16384, "temperature": temperature,
                "stream": true
            ] as [String: Any],
            statusText: "🚀 正在启动请求...",
            statusIcon: "🚀"
        )
    }

    private func stopGenerating() {
        responseEventHandler.reset()
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
                // 滑动窗口记录
                self.jsErrorWindow.append(false)
                if self.jsErrorWindow.count > 20 { self.jsErrorWindow.removeFirst() }
                let failures = self.jsErrorWindow.filter { !$0 }.count
                if failures >= 5 {
                    AppLogger.shared.log("[WebView] JS 最近20次调用中失败 \(failures) 次,重新加载 WebView")
                    // 保存当前输入框文字，reload后恢复
                    let savedText = self.textView.string
                    self.jsErrorWindow.removeAll()
                    DispatchQueue.main.async {
                        let html = self.chatHTML()
                        self.webView.loadHTMLString(html, baseURL: nil)
                        // reload完成后恢复输入框
                        if !savedText.isEmpty {
                            self.textView.string = savedText
                        }
                    }
                }
            } else {
                self.jsErrorWindow.append(true)
                if self.jsErrorWindow.count > 20 { self.jsErrorWindow.removeFirst() }
            }
        }
    }

}

// MARK: - SSE 事件处理（委托给 ResponseEventHandler）
extension ChatViewController {

    /// 设置状态栏颜色
    private func setStatusBarColor(_ color: NSColor, alpha: CGFloat = 0.12) {
        statusBar.layer?.backgroundColor = color.withAlphaComponent(alpha).cgColor
    }

    /// 重置状态栏颜色
    private func resetStatusBarColor() {
        statusBar.layer?.backgroundColor = nil
    }

    private func finalizeAndUpdateStats() {
        // 幂等锁:防止重复调用(response.completed + [DONE] 双重触发)
        guard !isFinalizing else { return }
        isFinalizing = true

        // 停止 typing 动画 + 标记流式消息完成
        js("fin()")

        let text = responseEventHandler.streamedTextBuffer
        responseEventHandler.streamedTextBuffer = ""
        let charCount = responseEventHandler.streamCharCount

        if !text.isEmpty {
            currentMessages.append(["role": "assistant", "content": text])
            let compTok = max(1, charCount / 3)
            let promptTok = max(1, (currentMessages.filter { $0["role"] == "user" }.last?["content"] ?? "").count / 3)
            sessionManager.totalPromptTokens += promptTok
            sessionManager.totalCompletionTokens += compTok
            updateUsageDisplay()
        }
        fetchBalance()
        stopGenerating()
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
            js("addImageMessage('user','\(dataUrl)','\(filename.escapedForJS)')")
            // 发送图片到 Gateway
            sendImageToGateway(imageData: dataUrl, filename: filename, text: text)
        } else {
            // 文件:存缓存 + 渲染卡片 + 发送
            let fileId = saveFileToCache(data: data, filename: filename)
            let ext = fileExtension(filename)
            let fileSizeStr = formatFileSize(data.count)
            currentMessages.append(["role": "user", "content": "[文件] \(filename)", "type": "file", "fileId": fileId, "fileSize": "\(data.count)"])
            js("addFileCard('user','\(filename.escapedForJS)','\(fileSizeStr)','\(fileId)','\(ext)')")
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

        let mappedModel = currentModelId
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

        let mappedModel = currentModelId
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
        guard sessionManager.switchToConversation(index) else {
            if sessionManager.conversations.indices.contains(0) {
                sessionManager.currentConversationIndex = 0
                conversationTableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            }
            return
        }
        // 恢复该会话自己的模型(旧会话无记录则沿用当前全局选择)
        // 旧会话可能存着已下线的模型 id:先归一,再校验是否在可用列表里,
        // 不在则沿用全局选择,避免把 Gateway 打 400。
        if let convModel = sessionManager.modelForCurrentConversation() {
            let normalized = Models.normalize(convModel)
            if availableModels.contains(where: { $0.apiModelId == normalized }) {
                currentModelId = normalized
                UserDefaults.standard.set(normalized, forKey: "selectedModelId")
            }
        }
        refreshModelUI()
        updateUsageDisplay()
        // Re-render messages
        let conv = sessionManager.conversations[index]
        // 把恢复逻辑挂到 didFinish 后执行(loadHTMLString 是异步的,固定延时会有竞态)
        loadChatHTML {
            self.js("beginRestore()")
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
                        self.js("addImageMessage('\(role.escapedForJS)','\(dataUrl)','\(content.escapedForJS)')")
                    } else {
                        self.js("addMessage('\(role.escapedForJS)','\(content.escapedForJS) [缓存丢失]')")
                    }
                } else if type == "file", let fileId = msg["fileId"] {
                    // 恢复文件消息:渲染文件卡片
                    let fileURL = self.cachedFileURL(fileId: fileId)
                    let fileSize = Int(msg["fileSize"] ?? "0") ?? 0
                    let fileSizeStr = formatFileSize(fileSize)
                    let ext = fileExtension(fileId)
                    if FileManager.default.fileExists(atPath: fileURL.path) {
                        self.js("addFileCard('\(role.escapedForJS)','\(content.escapedForJS)','\(fileSizeStr)','\(fileId)','\(ext)')")
                    } else {
                        self.js("addMessage('\(role.escapedForJS)','\(content.escapedForJS) [缓存丢失]')")
                    }
                } else {
                    self.js("addMessage('\(role.escapedForJS)','\(content.escapedForJS)')")
                }
            }
            // 历史恢复完成后瞬时滚到底部(避免逐条 smooth 滚动互相取消导致停在顶部)
            self.js("endRestore()")
            // 图片/布局可能稍后完成导致高度变化,再补一次瞬时定位
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.js("jumpToEnd()")
            }
        }
    }

}

// MARK: - StreamSessionDelegate
extension ChatViewController: StreamSessionDelegate {
    func streamSession(_ session: StreamSession, didReceiveEvent event: String, data: [String: Any]) {
        responseEventHandler.process(event: event, json: data, sessionManager: sessionManager)
    }

    func streamSessionDidReceiveDone(_ session: StreamSession) {
        finalizeAndUpdateStats()
    }

    func streamSession(_ session: StreamSession, didEncounterHTTPError code: Int) {
        setStatusForce("❌ HTTP \(code)", priority: .ready)
        hideStepIndicator()
        let errorMsg = "⚠️ Gateway 返回 HTTP \(code)\n模型可能未在 Gateway 中注册,或 API Key 无效。"
        js("addMessage('assistant','\(errorMsg.escapedForJS)')")
    }

    func streamSession(_ session: StreamSession, didCompleteWithError error: Error?) {
        if let e = error as NSError? {
            if e.code == NSURLErrorCancelled {
                AppLogger.shared.log("[Stream] 手动取消 (NSURLErrorCancelled)")
                return
            }
            AppLogger.shared.log("[Stream Error] 流中断: \(e.domain) code=\(e.code) \(e.localizedDescription)")
            if isGenerating && !isFinalizing {
                js("addMessage('assistant','⚠️ 连接中断: \(e.localizedDescription.escapedForJS)')")
                js("rt()")
                finalizeAndUpdateStats()
            } else {
                AppLogger.shared.log("[Stream] 强制复位 (isGenerating=\(isGenerating) isFinalizing=\(isFinalizing))")
                stopGenerating()
            }
        } else if error == nil && isGenerating {
            AppLogger.shared.log("[Stream] 连接正常关闭,执行兜底 finalize")
            if !isFinalizing {
                finalizeAndUpdateStats()
            } else {
                AppLogger.shared.log("[Stream] isFinalizing=true,直接 stopGenerating")
                stopGenerating()
            }
        }
    }

    func streamSession(_ session: StreamSession, didEncounterDecodeError message: String) {
        js("addMessage('assistant','❌ \(message.escapedForJS)')")
        finalizeAndUpdateStats()
    }
}

// MARK: - ResponseEventHandlerDelegate
extension ChatViewController: ResponseEventHandlerDelegate {
    func eventHandler(_ handler: ResponseEventHandler, setStatusAdvanced text: String, priority: StatusPriority, color: NSColor, alpha: CGFloat) {
        setStatusAdvanced(text, priority: priority, color: color, alpha: alpha)
    }

    func eventHandler(_ handler: ResponseEventHandler, setStatusForce text: String, priority: StatusPriority, color: NSColor, alpha: CGFloat) {
        setStatusForce(text, priority: priority, color: color, alpha: alpha)
    }

    func eventHandler(_ handler: ResponseEventHandler, showStep icon: String, text: String, progress: Double) {
        showStepIndicator(icon: icon, text: text, progress: progress)
    }

    func eventHandler(_ handler: ResponseEventHandler, hideStep: ()) {
        hideStepIndicator()
    }

    func eventHandler(_ handler: ResponseEventHandler, animateIcons: [String]) {
        startStatusIconAnimation(icons: animateIcons)
    }

    func eventHandler(_ handler: ResponseEventHandler, stopAnimation: ()) {
        stopStatusIconAnimation()
    }

    func eventHandler(_ handler: ResponseEventHandler, executeJS: String) {
        js(executeJS)
    }

    func eventHandler(_ handler: ResponseEventHandler, updateLiveTokenDisplay input: Int, output: Int, streamCharCount: Int) {
        let compTok = output + streamCharCount / 3
        let total = input + compTok
        tokenLabel.stringValue = "⚡ \(formatNumber(input)) + \(formatNumber(compTok)) = \(formatNumber(total)) tok"
    }

    func eventHandler(_ handler: ResponseEventHandler, finalizeStream: ()) {
        if !isFinalizing {
            finalizeAndUpdateStats()
        }
    }
}
