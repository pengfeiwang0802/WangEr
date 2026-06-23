import Foundation

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

// MARK: - 模型选项

enum Models {
    struct ModelOption {
        let displayName: String
        let apiModelId: String  // 格式: providerName/modelId
    }
}
