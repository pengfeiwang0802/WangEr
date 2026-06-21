import AppKit
import SWS

// MARK: - 模板管理器窗口

class TemplateManagerWindow: NSObject {
    static let shared = TemplateManagerWindow()

    private var window: NSWindow?
    private var tableView: NSTableView!
    private var scrollView: NSScrollView!

    /// 预设模板名称集合（不可编辑/删除）
    private let presetNames = Set(DisplayStyle.presets.map(\.name))

    private struct TemplateRow {
        let style: DisplayStyle
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
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
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

        // === 列表（TableView）===
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

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("template"))
        column.width = 380
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        contentView.addSubview(scrollView)

        // === 新建按钮 ===
        let newButton = NSButton(title: "+ 新建模板", target: self, action: #selector(newTemplate(_:)))
        newButton.bezelStyle = .rounded
        newButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(newButton)

        // === 完成按钮 ===
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
            scrollView.bottomAnchor.constraint(equalTo: newButton.topAnchor, constant: -12),

            newButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            newButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),

            doneButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            doneButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
        ])

        reloadData()
        window = win
        win.makeKeyAndOrderFront(nil)
    }

    private func reloadData() {
        let presets = DisplayStyle.presets.map { TemplateRow(style: $0, isCustom: false) }
        let customs: [TemplateRow] = [] // TODO: 从持久化加载自定义模板
        rows = presets + customs
        tableView?.reloadData()
    }

    @objc private func newTemplate(_ sender: Any?) {
        TemplateEditorWindow.shared.showNew { [weak self] name in
            // TODO: 保存自定义模板、刷新列表
            print("TemplateManager: 新建模板 '\(name)'")
            self?.reloadData()
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

        cell?.textField?.stringValue = rowData.style.displayName
        if rowData.isCustom {
            cell?.textField?.textColor = NSColor.labelColor
        } else {
            cell?.textField?.textColor = NSColor.disabledControlTextColor
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        // 预设模板不可选
        return rows[row].isCustom
    }
}

// MARK: - 模板编辑器窗口（新建模板）

class TemplateEditorWindow {
    static let shared = TemplateEditorWindow()

    private var window: NSWindow?
    private var nameField: NSTextField!
    private var onSave: ((String) -> Void)?

    private init() {}

    func showNew(onSave: @escaping (String) -> Void) {
        self.onSave = onSave
        show(title: "✏️ 新建模板", name: "")
    }

    private func show(title: String, name: String) {
        if window != nil {
            window?.makeKeyAndOrderFront(nil)
            nameField?.stringValue = name
            return
        }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 170),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = title
        win.isReleasedWhenClosed = false
        win.center()

        guard let contentView = win.contentView else { return }

        // 模板名称
        let nameLabel = NSTextField(labelWithString: "模板名称:")
        nameLabel.font = NSFont.systemFont(ofSize: 13)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(nameLabel)

        nameField = NSTextField(frame: .zero)
        nameField.placeholderString = "例如：我的剧本格式"
        nameField.stringValue = name
        nameField.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(nameField)

        // 按钮
        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancelAction(_:)))
        cancelButton.bezelStyle = .rounded
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(cancelButton)

        let saveButton = NSButton(title: "保存", target: self, action: #selector(saveAction(_:)))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(saveButton)

        NSLayoutConstraint.activate([
            nameLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            nameLabel.widthAnchor.constraint(equalToConstant: 80),

            nameField.topAnchor.constraint(equalTo: nameLabel.topAnchor),
            nameField.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 8),
            nameField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            cancelButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -12),
            cancelButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),

            saveButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            saveButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
        ])

        window = win
        win.makeKeyAndOrderFront(nil)
    }

    @objc private func cancelAction(_ sender: Any?) {
        window?.close()
    }

    @objc private func saveAction(_ sender: Any?) {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "请输入模板名称"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "好")
            alert.beginSheetModal(for: window!, completionHandler: nil)
            return
        }

        onSave?(name)
        window?.close()
    }
}
