import AppKit
import WebKit
import SWS

// MARK: - 模板管理器窗口

class TemplateManagerWindow: NSObject {
    static let shared = TemplateManagerWindow()

    var onApplyTemplate: ((FormatTemplate) -> Void)?

    private var window: NSWindow?
    private var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private var applyButton: NSButton!
    private var editButton: NSButton!
    private var deleteButton: NSButton!

    /// 预设模板名称集合（不可编辑/删除）
    private let presetNames = Set(DisplayStyle.presets.map(\.name))

    private struct TemplateRow {
        let style: DisplayStyle?       // 预设模板才有
        let customTemplate: FormatTemplate?  // 自定义模板才有
        let isCustom: Bool
    }

    private var rows: [TemplateRow] = []

    private override init() {}

    func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            reloadData()
            return
        }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "📋 模板管理"
        win.isReleasedWhenClosed = false
        win.center()

        guard let contentView = win.contentView else { return }

        // === 预设模板标签 ===
        let presetLabel = NSTextField(labelWithString: "预设模板")
        presetLabel.font = NSFont.boldSystemFont(ofSize: 12)
        presetLabel.textColor = NSColor.secondaryLabelColor
        presetLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(presetLabel)

        // === 列表 ===
        scrollView = NSScrollView(frame: .zero)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        tableView = NSTableView(frame: .zero)
        tableView.delegate = self
        tableView.dataSource = self
        tableView.headerView = nil
        tableView.rowHeight = 28
        tableView.allowsMultipleSelection = false
        tableView.target = self
        tableView.doubleAction = #selector(tableViewDoubleClicked)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("template"))
        column.width = 420
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        contentView.addSubview(scrollView)

        // === 操作按钮 ===
        deleteButton = NSButton(title: "删除", target: self, action: #selector(deleteTemplate(_:)))
        deleteButton.bezelStyle = .rounded
        deleteButton.isEnabled = false
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(deleteButton)

        applyButton = NSButton(title: "应用", target: self, action: #selector(applyTemplate(_:)))
        applyButton.bezelStyle = .rounded
        applyButton.isEnabled = false
        applyButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(applyButton)

        editButton = NSButton(title: "编辑", target: self, action: #selector(editTemplate(_:)))
        editButton.bezelStyle = .rounded
        editButton.isEnabled = false
        editButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(editButton)

        let newButton = NSButton(title: "+ 新建模板", target: self, action: #selector(newTemplate(_:)))
        newButton.bezelStyle = .rounded
        newButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(newButton)

        let doneButton = NSButton(title: "完成", target: self, action: #selector(closeWindow(_:)))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(doneButton)

        NSLayoutConstraint.activate([
            presetLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            presetLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),

            scrollView.topAnchor.constraint(equalTo: presetLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            scrollView.bottomAnchor.constraint(equalTo: editButton.topAnchor, constant: -12),

            deleteButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            deleteButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            deleteButton.widthAnchor.constraint(equalToConstant: 60),

            applyButton.leadingAnchor.constraint(equalTo: deleteButton.trailingAnchor, constant: 8),
            applyButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            applyButton.widthAnchor.constraint(equalToConstant: 60),

            editButton.leadingAnchor.constraint(equalTo: applyButton.trailingAnchor, constant: 8),
            editButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            editButton.widthAnchor.constraint(equalToConstant: 60),

            newButton.leadingAnchor.constraint(equalTo: editButton.trailingAnchor, constant: 12),
            newButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),

            doneButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            doneButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
        ])

        reloadData()
        window = win
        win.makeKeyAndOrderFront(nil)
    }

    private func reloadData() {
        let presets = DisplayStyle.presets.map { TemplateRow(style: $0, customTemplate: nil, isCustom: false) }
        let customs = FormatTemplate.loadAll().map { TemplateRow(style: nil, customTemplate: $0, isCustom: true) }
        rows = presets + customs
        tableView?.reloadData()
        updateButtonStates()
    }

    private func updateButtonStates() {
        let selectedRow = tableView?.selectedRow ?? -1
        guard selectedRow >= 0, selectedRow < rows.count else {
            applyButton?.isEnabled = false
            editButton?.isEnabled = false
            deleteButton?.isEnabled = false
            return
        }
        let isCustom = rows[selectedRow].isCustom
        applyButton?.isEnabled = true
        editButton?.isEnabled = isCustom
        deleteButton?.isEnabled = isCustom
    }

    @objc private func tableViewDoubleClicked() {
        editTemplate(nil)
    }

    @objc private func applyTemplate(_ sender: Any?) {
        let selectedRow = tableView.selectedRow
        guard selectedRow >= 0, selectedRow < rows.count else { return }
        let row = rows[selectedRow]
        let template = row.isCustom ? row.customTemplate : nil
        // 先关窗口（触发 observer 刷新菜单），再回调应用样式
        window?.close()
        if let template {
            DispatchQueue.main.async { [weak self] in
                self?.onApplyTemplate?(template)
            }
        }
    }

    @objc private func newTemplate(_ sender: Any?) {
        TemplateEditorWindow.shared.showNew { [weak self] template in
            try? template.save()
            self?.reloadData()
        }
    }

    @objc private func editTemplate(_ sender: Any?) {
        let selectedRow = tableView.selectedRow
        guard selectedRow >= 0, selectedRow < rows.count, rows[selectedRow].isCustom,
              let template = rows[selectedRow].customTemplate else { return }

        TemplateEditorWindow.shared.showEdit(template: template) { [weak self] updated in
            try? updated.save()
            self?.reloadData()
        }
    }

    @objc private func deleteTemplate(_ sender: Any?) {
        let selectedRow = tableView.selectedRow
        guard selectedRow >= 0, selectedRow < rows.count, rows[selectedRow].isCustom,
              let template = rows[selectedRow].customTemplate else { return }

        let alert = NSAlert()
        alert.messageText = "删除模板「\(template.name)」？"
        alert.informativeText = "此操作不可撤销。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window!) { [weak self] response in
            if response == .alertFirstButtonReturn {
                try? template.delete()
                self?.reloadData()
            }
        }
    }

    @objc private func closeWindow(_ sender: Any?) {
        window?.close()
    }
}

// MARK: - NSTableViewDataSource / Delegate

extension TemplateManagerWindow: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let rowData = rows[row]
        let identifier = NSUserInterfaceItemIdentifier("TemplateCell")
        var cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView
        if cell == nil {
            cell = NSTableCellView()
            cell!.identifier = identifier

            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.lineBreakMode = .byTruncatingTail
            cell!.addSubview(tf)
            cell!.textField = tf

            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell!.leadingAnchor, constant: 8),
                tf.centerYAnchor.constraint(equalTo: cell!.centerYAnchor),
                tf.trailingAnchor.constraint(equalTo: cell!.trailingAnchor, constant: -8),
            ])
        }

        if rowData.isCustom {
            cell?.textField?.stringValue = "⭐️ " + (rowData.customTemplate?.name ?? "")
            cell?.textField?.textColor = NSColor.labelColor
        } else {
            cell?.textField?.stringValue = rowData.style?.displayName ?? ""
            cell?.textField?.textColor = NSColor.disabledControlTextColor
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        return true
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtonStates()
    }
}

// MARK: - 模板编辑器窗口

class TemplateEditorWindow: NSObject {
    static let shared = TemplateEditorWindow()

    private var window: NSWindow?
    private var nameField: NSTextField!
    private var previewWebView: WKWebView!

    // 下拉控件
    private var characterPopup: NSPopUpButton!
    private var modifierPopup: NSPopUpButton!
    private var headingPopup: NSPopUpButton!


    private var onSave: ((FormatTemplate) -> Void)?
    private var editingTemplate: FormatTemplate?

    private override init() {}

    // MARK: - Show

    func showNew(onSave: @escaping (FormatTemplate) -> Void) {
        self.editingTemplate = FormatTemplate(name: "", description: "")
        self.onSave = onSave
        show(title: "✏️ 新建模板")
    }

    func showEdit(template: FormatTemplate, onSave: @escaping (FormatTemplate) -> Void) {
        self.editingTemplate = template
        self.onSave = onSave
        show(title: "✏️ 编辑模板")
    }

    private func show(title: String) {
        if window != nil {
            window?.title = title
            window?.makeKeyAndOrderFront(nil)
            populateFields()
            updatePreview()
            return
        }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 660),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = title
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 480, height: 580)
        win.center()

        guard let contentView = win.contentView else { return }

        // === 模板名称 ===
        let nameLabel = NSTextField(labelWithString: "模板名称:")
        nameLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(nameLabel)

        nameField = NSTextField(frame: .zero)
        nameField.placeholderString = "例如：我的剧本格式"
        nameField.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(nameField)

        // === 格式选项区域 ===
        let optionsLabel = NSTextField(labelWithString: "格式选项")
        optionsLabel.font = NSFont.boldSystemFont(ofSize: 12)
        optionsLabel.textColor = NSColor.secondaryLabelColor
        optionsLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(optionsLabel)

        // 角色名+台词
        let charLabel = NSTextField(labelWithString: "角色名+台词:")
        charLabel.font = NSFont.systemFont(ofSize: 12)
        charLabel.alignment = .right
        charLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(charLabel)
        characterPopup = buildPopup(CharacterLayoutOption.allCases.map { $0.displayName }, action: #selector(optionChanged))
        contentView.addSubview(characterPopup)

        // 修饰语括号
        let modLabel = NSTextField(labelWithString: "修饰语括号:")
        modLabel.font = NSFont.systemFont(ofSize: 12)
        modLabel.alignment = .right
        modLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(modLabel)
        modifierPopup = buildPopup(ModifierBracketChoice.allCases.map { $0.displayName }, action: #selector(optionChanged))
        contentView.addSubview(modifierPopup)

        // 场号格式
        let headLabel = NSTextField(labelWithString: "场号格式:")
        headLabel.font = NSFont.systemFont(ofSize: 12)
        headLabel.alignment = .right
        headLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(headLabel)
        headingPopup = buildPopup(SceneHeadingFormatChoice.allCases.map { $0.displayName }, action: #selector(optionChanged))
        contentView.addSubview(headingPopup)

        // === 预览区域 ===
        let previewLabel = NSTextField(labelWithString: "实时预览")
        previewLabel.font = NSFont.boldSystemFont(ofSize: 12)
        previewLabel.textColor = NSColor.secondaryLabelColor
        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(previewLabel)

        // WKWebView 预览（只读——SWSRenderer 传 editable:false 不输出 contenteditable）
        previewWebView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        previewWebView.translatesAutoresizingMaskIntoConstraints = false
        previewWebView.setValue(false, forKey: "drawsBackground")
        let previewContainer = NSView(frame: .zero)
        previewContainer.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.wantsLayer = true
        previewContainer.layer?.borderColor = NSColor.separatorColor.cgColor
        previewContainer.layer?.borderWidth = 1
        previewContainer.layer?.cornerRadius = 6
        previewContainer.addSubview(previewWebView)
        contentView.addSubview(previewContainer)

        NSLayoutConstraint.activate([
            previewWebView.topAnchor.constraint(equalTo: previewContainer.topAnchor),
            previewWebView.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
            previewWebView.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
            previewWebView.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),
        ])

        // === 按钮 ===
        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancelAction(_:)))
        cancelButton.bezelStyle = .rounded
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(cancelButton)

        let saveButton = NSButton(title: "保存模板", target: self, action: #selector(saveAction(_:)))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(saveButton)

        // === Layout ===
        NSLayoutConstraint.activate([
            // 模板名称
            nameLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            nameLabel.widthAnchor.constraint(equalToConstant: 80),

            nameField.topAnchor.constraint(equalTo: nameLabel.topAnchor),
            nameField.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 8),
            nameField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            // 选项标签
            optionsLabel.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 20),
            optionsLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),

            // 角色名+台词
            charLabel.topAnchor.constraint(equalTo: optionsLabel.bottomAnchor, constant: 10),
            charLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            charLabel.widthAnchor.constraint(equalToConstant: 80),

            characterPopup.topAnchor.constraint(equalTo: charLabel.topAnchor, constant: -2),
            characterPopup.leadingAnchor.constraint(equalTo: charLabel.trailingAnchor, constant: 8),
            characterPopup.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            // 修饰语
            modLabel.topAnchor.constraint(equalTo: characterPopup.bottomAnchor, constant: 8),
            modLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            modLabel.widthAnchor.constraint(equalToConstant: 80),

            modifierPopup.topAnchor.constraint(equalTo: modLabel.topAnchor, constant: -2),
            modifierPopup.leadingAnchor.constraint(equalTo: modLabel.trailingAnchor, constant: 8),
            modifierPopup.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            // 场号
            headLabel.topAnchor.constraint(equalTo: modifierPopup.bottomAnchor, constant: 8),
            headLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            headLabel.widthAnchor.constraint(equalToConstant: 80),

            headingPopup.topAnchor.constraint(equalTo: headLabel.topAnchor, constant: -2),
            headingPopup.leadingAnchor.constraint(equalTo: headLabel.trailingAnchor, constant: 8),
            headingPopup.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            // 预览标签
            previewLabel.topAnchor.constraint(equalTo: headingPopup.bottomAnchor, constant: 20),
            previewLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),

            // 预览区域
            previewContainer.topAnchor.constraint(equalTo: previewLabel.bottomAnchor, constant: 8),
            previewContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            previewContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            previewContainer.bottomAnchor.constraint(equalTo: cancelButton.topAnchor, constant: -12),

            // 按钮
            cancelButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -12),
            cancelButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),

            saveButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            saveButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
        ])

        window = win

        populateFields()
        updatePreview()
        win.makeKeyAndOrderFront(nil)
    }

    // MARK: - Helpers

    private func buildPopup(_ items: [String], action: Selector) -> NSPopUpButton {
        let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        popUp.translatesAutoresizingMaskIntoConstraints = false
        popUp.addItems(withTitles: items)
        popUp.target = self
        popUp.action = action
        return popUp
    }

    private func populateFields() {
        guard let t = editingTemplate else { return }
        nameField?.stringValue = t.name
        characterPopup?.selectItem(at: CharacterLayoutOption.allCases.firstIndex(of: t.characterLayout) ?? 0)
        modifierPopup?.selectItem(at: ModifierBracketChoice.allCases.firstIndex(of: t.modifierBracket) ?? 0)
        headingPopup?.selectItem(at: SceneHeadingFormatChoice.allCases.firstIndex(of: t.sceneHeadingFormat) ?? 0)

    }

    private func buildCurrentTemplate() -> FormatTemplate {
        var t = editingTemplate ?? FormatTemplate(name: "")
        t.name = nameField?.stringValue.trimmingCharacters(in: .whitespaces) ?? ""
        let charIdx = max(0, characterPopup?.indexOfSelectedItem ?? 0)
        t.characterLayout = CharacterLayoutOption.allCases[charIdx]
        let modIdx = max(0, modifierPopup?.indexOfSelectedItem ?? 0)
        t.modifierBracket = ModifierBracketChoice.allCases[modIdx]
        let headIdx = max(0, headingPopup?.indexOfSelectedItem ?? 0)
        t.sceneHeadingFormat = SceneHeadingFormatChoice.allCases[headIdx]
        return t
    }

    private func updatePreview() {
        let template = buildCurrentTemplate()
        let style = template.toDisplayStyle()
        // 样例文档的 block 已是完整的一对一绑定（每行一个 block），
        // 无需额外变换——直接渲染。
        let html = SWSRenderer.render(
            document: FormatTemplate.sampleDocument,
            style: style,
            editable: false
        )
        previewWebView?.loadHTMLString(html, baseURL: nil)
    }

    @objc private func optionChanged(_ sender: Any?) {
        updatePreview()
    }

    @objc private func cancelAction(_ sender: Any?) {
        window?.close()
    }

// MARK: - Actions

    @objc private func saveAction(_ sender: Any?) {
        let template = buildCurrentTemplate()
        guard !template.name.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "请输入模板名称"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "好")
            alert.beginSheetModal(for: window!, completionHandler: nil)
            return
        }

        onSave?(template)
        window?.close()
    }
}
