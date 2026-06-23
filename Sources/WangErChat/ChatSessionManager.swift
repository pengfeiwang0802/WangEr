import Foundation

/// 会话持久化管理器
/// 职责：会话数据、增删改查、磁盘持久化、token 统计
/// 与 UI 无关，纯数据层
class ChatSessionManager {
    // MARK: - Data
    var conversations: [Conversation] = []
    var currentConversationIndex: Int = 0
    var totalPromptTokens: Int = 0
    var totalCompletionTokens: Int = 0
    var streamCharCount: Int = 0

    var currentMessages: [[String: String]] {
        get {
            guard conversations.indices.contains(currentConversationIndex) else { return [] }
            return conversations[currentConversationIndex].messages
        }
        set {
            guard conversations.indices.contains(currentConversationIndex) else { return }
            conversations[currentConversationIndex].messages = newValue
            save()
        }
    }

    // MARK: - Path
    private let savePath = "\(NSHomeDirectory())/.openclaw/workspace/WangErChat/conversations.json"

    // MARK: - Persistence
    func save() {
        do {
            let data = try JSONEncoder().encode(conversations)
            let url = URL(fileURLWithPath: savePath)
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: url)
        } catch {
            AppLogger.shared.log("[Error] saveConversations failed: \(error)")
        }
    }

    func load() {
        let url = URL(fileURLWithPath: savePath)
        guard FileManager.default.fileExists(atPath: savePath) else {
            AppLogger.shared.log("[loadConversations] 会话文件不存在: \(savePath)")
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let loaded = try JSONDecoder().decode([Conversation].self, from: data)
            conversations = loaded
            AppLogger.shared.log("[loadConversations] 已加载 \(conversations.count) 个会话")
        } catch let error as DecodingError {
            AppLogger.shared.log("[loadConversations] 解析失败: \(error)")
            let backupPath = savePath + ".backup.\(Int(Date().timeIntervalSince1970))"
            try? FileManager.default.copyItem(atPath: savePath, toPath: backupPath)
            AppLogger.shared.log("[loadConversations] 已备份: \(backupPath)")
        } catch {
            AppLogger.shared.log("[loadConversations] 读取失败: \(error)")
        }
    }

    // MARK: - CRUD
    @discardableResult
    func newConversation() -> Conversation {
        let conv = Conversation(title: "💬 新对话 \(conversations.count + 1)")
        conversations.append(conv)
        save()
        return conv
    }

    func switchToConversation(_ index: Int) -> Bool {
        guard !conversations.isEmpty else {
            AppLogger.shared.log("[Error] switchToConversation: 无可用会话")
            return false
        }
        guard conversations.indices.contains(index) else {
            AppLogger.shared.log("[Error] switchToConversation: index \(index) out of range (count: \(conversations.count))")
            return false
        }
        currentConversationIndex = index
        totalPromptTokens = 0
        totalCompletionTokens = 0
        streamCharCount = 0
        return true
    }

    func renameConversation(at index: Int, title: String) {
        guard conversations.indices.contains(index) else { return }
        conversations[index].title = title
        save()
    }
}
