import AppKit
import UniformTypeIdentifiers

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

// MARK: - 文件拖拽处理
extension ChatViewController {

    func handleDroppedFile(url: URL) {
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
                    self.js("addMessage('assistant','⚠️ 文件超过 50MB 限制,请压缩后重试')")
                }
                return
            }

            DispatchQueue.main.async {
                self.sendFile(data: data, filename: filename, mimeType: mimeType)
            }
        } catch {
AppLogger.shared.log("[File Drop] 读取文件失败: \(error)")
            DispatchQueue.main.async {
                self.js("addMessage('assistant','❌ 读取文件失败: \(self.escJS(error.localizedDescription))')")
            }
        }
    }
}

// MARK: - NSTableView
extension ChatViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return conversations.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("c")
        var cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView
        if cell == nil {
            cell = NSTableCellView(); cell?.identifier = id
            let tf = NSTextField(); tf.isBezeled = false; tf.drawsBackground = false; tf.isEditable = false
            tf.font = NSFont.systemFont(ofSize: 12)
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.lineBreakMode = .byTruncatingTail
            cell?.addSubview(tf); cell?.textField = tf
            // 垂直居中
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell!.leadingAnchor, constant: 8),
                tf.trailingAnchor.constraint(equalTo: cell!.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: cell!.centerYAnchor),
            ])
        }
        cell?.textField?.stringValue = conversations[safe: row]?.title ?? "会话"
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tableView = notification.object as? NSTableView else { return }
        let row = tableView.selectedRow
        if tableView == conversationTableView {
            if row >= 0 && row < conversations.count {
                switchToConversation(row)
            }
        }
    }
}
