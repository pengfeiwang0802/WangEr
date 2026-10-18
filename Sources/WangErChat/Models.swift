import Foundation

// MARK: - 数据模型

struct Conversation: Codable {
    var id = UUID()
    var title: String
    var messages: [[String: String]] = []
    var createdAt = Date()
    /// 该会话当前使用的模型(apiModelId 格式,如 "openai/gpt-5.5")。
    /// 旧数据没有这个字段,解码时为 nil,由 ChatViewController 回退到全局默认。
    var model: String?
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

    /// 已下线/改名的模型 id → 当前 id。
    /// 旧会话、旧 UserDefaults 里可能存着老 id,Gateway 会直接 400。
    static let retiredAliases: [String: String] = [
        "deepseek/deepseek-v4-flash": "deepseek/deepseek-flash",
    ]

    /// 把历史遗留的模型 id 归一到当前可用 id
    static func normalize(_ apiModelId: String) -> String {
        retiredAliases[apiModelId] ?? apiModelId
    }

    /// apiModelId → 人类可读显示名(如 "openai/gpt-5.5" → "GPT-5.5")
    /// 仅用于界面展示;找不到映射时返回原始 id。
    static func prettyName(for apiModelId: String) -> String {
        let known: [String: String] = [
            "deepseek/deepseek-flash": "DeepSeek V4 Flash",
            "deepseek/deepseek-v4-flash": "DeepSeek V4 Flash",
            "deepseek/deepseek-v4-pro": "DeepSeek V4 Pro",
            "deepseek/deepseek-v4-flash-vision-exp": "DeepSeek V4 Flash Vision",
            "moonshot/kimi-k2.6": "Kimi K2.6",
            "moonshot/kimi-k3": "Kimi K3",
            "openai/gpt-5.5": "GPT-5.5",
        ]
        if let name = known[apiModelId] { return name }
        // 兜底:取 "/" 后半段,把 - 换成空格并首字母大写
        let raw = apiModelId.split(separator: "/").last.map(String.init) ?? apiModelId
        return raw.replacingOccurrences(of: "-", with: " ").capitalized
    }
}
