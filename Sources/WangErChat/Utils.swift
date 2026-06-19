import Foundation

// MARK: - 工具函数

/// 数字格式化（1000 → 1.0K）
func formatNumber(_ n: Int) -> String {
    return n >= 1000 ? String(format: "%.1fK", Double(n)/1000) : "\(n)"
}

/// 文件大小格式化
func formatFileSize(_ bytes: Int) -> String {
    if bytes < 1024 { return "\(bytes) B" }
    if bytes < 1024*1024 { return String(format: "%.1f KB", Double(bytes)/1024.0) }
    if bytes < 1024*1024*1024 { return String(format: "%.1f MB", Double(bytes)/(1024.0*1024.0)) }
    return String(format: "%.1f GB", Double(bytes)/(1024.0*1024.0*1024.0))
}

/// 获取文件扩展名（小写）
func fileExtension(_ filename: String) -> String {
    return (filename as NSString).pathExtension.lowercased()
}

/// 根据文件名获取 MIME 类型
func mimeTypeForFile(_ filename: String) -> String {
    let ext = fileExtension(filename)
    let mimeMap: [String: String] = [
        "jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png",
        "gif": "image/gif", "webp": "image/webp", "heic": "image/heic",
        "svg": "image/svg+xml", "bmp": "image/bmp"
    ]
    return mimeMap[ext] ?? "application/octet-stream"
}

/// 工具名称转友好显示
func friendlyToolName(_ name: String) -> String {
    let map: [String: String] = [
        "web_search": "搜索网页",
        "web_fetch": "读取网页",
        "exec": "执行命令",
        "read": "读取文件",
        "write": "写入文件",
        "edit": "编辑文件",
        "apply_patch": "应用补丁",
        "image": "分析图片",
        "memory_search": "搜索记忆",
        "memory_get": "读取记忆",
        "browser_navigate": "打开网页",
        "browser_snapshot": "查看页面",
        "browser_click": "点击页面",
        "browser_type": "输入文字",
        "cron": "设置提醒",
        "skill_workshop": "技能工坊",
        "sessions_spawn": "创建子任务",
        "sessions_send": "发送消息",
    ]
    return map[name] ?? name.replacingOccurrences(of: "_", with: " ").capitalized
}

/// 工具参数摘要（截取关键参数）
func toolArgsSummary(_ args: [String: Any]?) -> String {
    guard let args = args, !args.isEmpty else { return "" }
    // 优先显示关键字段
    let priorities = ["query", "url", "path", "name", "message", "command", "question", "text"]
    for key in priorities {
        if let val = args[key] as? String {
            let truncated = val.count > 60 ? String(val.prefix(60)) + "…" : val
            return truncated
        }
    }
    // 没有关键字段，显示第一个参数名
    if let firstKey = args.keys.first, let val = args[firstKey] as? String {
        let truncated = val.count > 40 ? String(val.prefix(40)) + "…" : val
        return truncated
    }
    return ""
}
