import Foundation

struct AppConfig {
    /// 从本地 openclaw.json 读取 Gateway Token
    static var gatewayToken: String {
        let path = "\(NSHomeDirectory())/.openclaw/openclaw.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let gateway = json["gateway"] as? [String: Any],
              let auth = gateway["auth"] as? [String: Any],
              let token = auth["token"] as? String else {
            return ""
        }
        return token
    }
    
    /// DeepSeek API Key — 从本地文件读取，不硬编码
    static var deepseekAPIKey: String {
        let path = "\(NSHomeDirectory())/.openclaw/workspace/deepseek_api_key_backup.md"
        if let key = try? String(contentsOfFile: path).trimmingCharacters(in: .whitespacesAndNewlines),
           key.hasPrefix("sk-") {
            return key
        }
        return ""
    }
    
    /// Moonshot (Kimi) API Key — 从本地文件读取
    static var moonshotAPIKey: String {
        let path = "\(NSHomeDirectory())/.openclaw/workspace/moonshot_api_key_backup.md"
        if let key = try? String(contentsOfFile: path).trimmingCharacters(in: .whitespacesAndNewlines),
           key.hasPrefix("sk-") {
            return key
        }
        return ""
    }
    
    static let gatewayURL = "http://127.0.0.1:18789"
}
