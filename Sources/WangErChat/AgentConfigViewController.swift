import AppKit

// MARK: - Agent 数据模型
struct Agent: Codable {
    var id = UUID()
    var name: String
    var model: String
    var gatewayAgentId: String
    var systemPrompt: String = ""
    var createdAt = Date()
}

// MARK: - Agent 配置面板（第三栏）
class AgentConfigViewController: NSViewController {
    // 当前编辑的 Agent
    var currentAgent: Agent? {
        didSet { refreshUI() }
    }
    var onSave: ((Agent) -> Void)?
    var onDelete: ((Agent) -> Void)?
    
    // UI 组件
    private let scrollView = NSScrollView()
    private let contentView = NSView()
    
    private let nameLabel = NSTextField(labelWithString: "名称")
    private let nameField = NSTextField()
    
    private let modelLabel = NSTextField(labelWithString: "模型")
    private let modelPopUp = NSPopUpButton()
    
    private let agentIdLabel = NSTextField(labelWithString: "Agent ID")
    private let agentIdField = NSTextField()
    
    private let systemPromptLabel = NSTextField(labelWithString: "系统指令（可选）")
    private let systemPromptView = NSTextView()
    private let systemPromptScroll = NSScrollView()
    
    private let saveButton = NSButton(title: "💾 保存", target: nil, action: nil)
    private let deleteButton = NSButton(title: "🗑 删除", target: nil, action: nil)
    
    private let placeholderLabel = NSTextField(labelWithString: "← 选择一个 Agent\n或点击 ＋ 新建")
    
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        showPlaceholder()
    }
    
    private func setupUI() {
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        
        // Placeholder
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.alignment = .center
        placeholderLabel.font = NSFont.systemFont(ofSize: 13)
        placeholderLabel.textColor = .secondaryLabelColor
        placeholderLabel.isEditable = false
        placeholderLabel.isBordered = false
        placeholderLabel.backgroundColor = .clear
        view.addSubview(placeholderLabel)
        
        // ScrollView for config content
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        view.addSubview(scrollView)
        
        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = contentView
        
        // --- 名称 ---
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = NSFont.boldSystemFont(ofSize: 12)
        contentView.addSubview(nameLabel)
        
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.bezelStyle = .roundedBezel
        nameField.font = NSFont.systemFont(ofSize: 13)
        contentView.addSubview(nameField)
        
        // --- 模型 ---
        modelLabel.translatesAutoresizingMaskIntoConstraints = false
        modelLabel.font = NSFont.boldSystemFont(ofSize: 12)
        contentView.addSubview(modelLabel)
        
        modelPopUp.translatesAutoresizingMaskIntoConstraints = false
        modelPopUp.bezelStyle = .rounded
        modelPopUp.addItems(withTitles: ["DeepSeek V4", "Kimi K2.6", "GPT-4o", "Claude 4 Sonnet"])
        contentView.addSubview(modelPopUp)
        
        // --- Agent ID ---
        agentIdLabel.translatesAutoresizingMaskIntoConstraints = false
        agentIdLabel.font = NSFont.boldSystemFont(ofSize: 12)
        contentView.addSubview(agentIdLabel)
        
        agentIdField.translatesAutoresizingMaskIntoConstraints = false
        agentIdField.bezelStyle = .roundedBezel
        agentIdField.font = NSFont.systemFont(ofSize: 13)
        agentIdField.placeholderString = "main"
        contentView.addSubview(agentIdField)
        
        // --- 系统指令 ---
        systemPromptLabel.translatesAutoresizingMaskIntoConstraints = false
        systemPromptLabel.font = NSFont.boldSystemFont(ofSize: 12)
        contentView.addSubview(systemPromptLabel)
        
        systemPromptScroll.translatesAutoresizingMaskIntoConstraints = false
        systemPromptScroll.borderType = .bezelBorder
        systemPromptScroll.hasVerticalScroller = true
        
        systemPromptView.font = NSFont.systemFont(ofSize: 12)
        systemPromptView.isRichText = false
        systemPromptView.drawsBackground = false
        systemPromptScroll.documentView = systemPromptView
        contentView.addSubview(systemPromptScroll)
        
        // --- 按钮 ---
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(saveAgent)
        contentView.addSubview(saveButton)
        
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.bezelStyle = .rounded
        deleteButton.target = self
        deleteButton.action = #selector(deleteAgent)
        deleteButton.contentTintColor = .red
        contentView.addSubview(deleteButton)
        
        NSLayoutConstraint.activate([
            placeholderLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            placeholderLabel.widthAnchor.constraint(equalToConstant: 180),
            
            scrollView.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            
            contentView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            
            nameLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            nameField.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 4),
            nameField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            nameField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            nameField.heightAnchor.constraint(equalToConstant: 26),
            
            modelLabel.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 12),
            modelLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            modelPopUp.topAnchor.constraint(equalTo: modelLabel.bottomAnchor, constant: 4),
            modelPopUp.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            modelPopUp.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            modelPopUp.heightAnchor.constraint(equalToConstant: 26),
            
            agentIdLabel.topAnchor.constraint(equalTo: modelPopUp.bottomAnchor, constant: 12),
            agentIdLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            agentIdField.topAnchor.constraint(equalTo: agentIdLabel.bottomAnchor, constant: 4),
            agentIdField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            agentIdField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            agentIdField.heightAnchor.constraint(equalToConstant: 26),
            
            systemPromptLabel.topAnchor.constraint(equalTo: agentIdField.bottomAnchor, constant: 12),
            systemPromptLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            systemPromptScroll.topAnchor.constraint(equalTo: systemPromptLabel.bottomAnchor, constant: 4),
            systemPromptScroll.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            systemPromptScroll.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            systemPromptScroll.heightAnchor.constraint(equalToConstant: 120),
            
            saveButton.topAnchor.constraint(equalTo: systemPromptScroll.bottomAnchor, constant: 16),
            saveButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            saveButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            saveButton.heightAnchor.constraint(equalToConstant: 28),
            
            deleteButton.topAnchor.constraint(equalTo: saveButton.bottomAnchor, constant: 8),
            deleteButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            deleteButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            deleteButton.heightAnchor.constraint(equalToConstant: 28),
            deleteButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
        ])
    }
    
    func showPlaceholder() {
        placeholderLabel.isHidden = false
        scrollView.isHidden = true
    }
    
    func showConfig() {
        placeholderLabel.isHidden = true
        scrollView.isHidden = false
    }
    
    private func refreshUI() {
        guard let agent = currentAgent else {
            showPlaceholder()
            return
        }
        showConfig()
        nameField.stringValue = agent.name
        modelPopUp.selectItem(withTitle: agent.model)
        agentIdField.stringValue = agent.gatewayAgentId
        systemPromptView.string = agent.systemPrompt
    }
    
    @objc private func saveAgent() {
        guard var agent = currentAgent else {
            // 新建模式
            let newAgent = Agent(
                name: nameField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty ? "新 Agent" : nameField.stringValue,
                model: modelPopUp.titleOfSelectedItem ?? "DeepSeek V4",
                gatewayAgentId: agentIdField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty ? "main" : agentIdField.stringValue,
                systemPrompt: systemPromptView.string
            )
            onSave?(newAgent)
            return
        }
        agent.name = nameField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty ? "新 Agent" : nameField.stringValue
        agent.model = modelPopUp.titleOfSelectedItem ?? "DeepSeek V4"
        agent.gatewayAgentId = agentIdField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty ? "main" : agentIdField.stringValue
        agent.systemPrompt = systemPromptView.string
        currentAgent = agent
        onSave?(agent)
    }
    
    @objc private func deleteAgent() {
        guard let agent = currentAgent else { return }
        let alert = NSAlert()
        alert.messageText = "删除 Agent"
        alert.informativeText = "确定要删除「\(agent.name)」吗？"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn {
            onDelete?(agent)
        }
    }
}
