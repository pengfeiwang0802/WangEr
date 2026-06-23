import AppKit

// MARK: - 状态优先级（从 ChatViewController 迁出）
/// 状态优先级(数字越大优先级越高)
public enum StatusPriority: Int {
    case ready = 0
    case generating = 1
    case thinking = 2
    case toolCall = 3
    case reasoning = 4
}

// MARK: - UI 回调协议
protocol ResponseEventHandlerDelegate: AnyObject {
    func eventHandler(_ handler: ResponseEventHandler, setStatusAdvanced text: String, priority: StatusPriority, color: NSColor, alpha: CGFloat)
    func eventHandler(_ handler: ResponseEventHandler, setStatusForce text: String, color: NSColor, alpha: CGFloat)
    func eventHandler(_ handler: ResponseEventHandler, showStep icon: String, text: String, progress: Double)
    func eventHandler(_ handler: ResponseEventHandler, hideStep: Void)
    func eventHandler(_ handler: ResponseEventHandler, animateIcons: [String])   // start animation with icons
    func eventHandler(_ handler: ResponseEventHandler, stopAnimation: Void)
    func eventHandler(_ handler: ResponseEventHandler, executeJS: String)
    func eventHandler(_ handler: ResponseEventHandler, updateLiveTokenDisplay input: Int, output: Int, streamCharCount: Int)
    func eventHandler(_ handler: ResponseEventHandler, finalizeStream: Void)
}

// MARK: - ResponseEventHandler
/// 处理 SSE 流式事件 → 状态转换 + UI 命令分发。
/// ChatViewController 实现 ResponseEventHandlerDelegate 来执行 UI 操作。
class ResponseEventHandler {
    weak var delegate: ResponseEventHandlerDelegate?

    // MARK: Transient processing state
    private(set) var activeToolStack: [String] = []
    var streamedTextBuffer = ""
    var streamCharCount = 0

    let thinkingIcons: [String]
    let toolIcons: [String]

    init(thinkingIcons: [String] = ["🤔", "🧠", "💭", "🤔", "🧠", "💭"],
         toolIcons: [String] = ["🔧", "⚙️", "🔨", "🔧", "⚙️", "🔨"]) {
        self.thinkingIcons = thinkingIcons
        self.toolIcons = toolIcons
    }

    func reset() {
        activeToolStack = []
        streamedTextBuffer = ""
        streamCharCount = 0
    }

    /// 处理单个 SSE 事件（在 StreamSessionDelegate 回调中调用, 已在主线程）
    func process(event: String, json: [String: Any], sessionManager: ChatSessionManager) {
        guard let type = json["type"] as? String,
              let d = delegate else {
            AppLogger.shared.log("[SSE Warning] 事件缺少 type 字段或 delegate 未设置")
            return
        }

        switch type {
        case "response.created":
            activeToolStack = []
            d.eventHandler(self, setStatusAdvanced: "🤖 启动...", priority: .thinking, color: .systemBlue, alpha: 0.30)
            d.eventHandler(self, showStep: "🚀", text: "正在启动请求...", progress: 10)

        case "response.in_progress":
            d.eventHandler(self, setStatusAdvanced: "🤖 思考中...", priority: .thinking, color: .systemBlue, alpha: 0.35)
            d.eventHandler(self, showStep: "🤔", text: "正在思考...", progress: 30)
            d.eventHandler(self, animateIcons: thinkingIcons)

        case "response.output_item.added":
            if let item = json["item"] as? [String: Any], item["type"] as? String == "function_call" {
                let name = item["name"] as? String ?? ""
                let args = item["arguments"] as? [String: Any]
                let friendlyName = friendlyToolName(name)
                let summary = toolArgsSummary(args)
                activeToolStack.append(name)

                let statusText: String
                if !summary.isEmpty {
                    statusText = "🔧 \(friendlyName): \(summary)"
                } else {
                    statusText = "🔧 调用工具: \(friendlyName)"
                }
                d.eventHandler(self, setStatusAdvanced: statusText, priority: .toolCall, color: .systemOrange, alpha: 0.50)
                d.eventHandler(self, showStep: "🔧", text: "正在调用 \(friendlyName)...", progress: 50)
                d.eventHandler(self, animateIcons: toolIcons)
            } else if let item = json["item"] as? [String: Any], item["type"] as? String == "reasoning" {
                d.eventHandler(self, setStatusAdvanced: "🧠 深度思考...", priority: .reasoning, color: .systemPurple, alpha: 0.45)
                d.eventHandler(self, showStep: "🧠", text: "深度推理中...", progress: 40)
            } else {
                d.eventHandler(self, setStatusAdvanced: "🤖 思考中...", priority: .thinking, color: .systemBlue, alpha: 0.35)
                d.eventHandler(self, showStep: "🤔", text: "正在思考...", progress: 30)
            }

        case "response.content_part.added":
            if let part = json["part"] as? [String: Any], part["type"] as? String == "text" {
                d.eventHandler(self, setStatusAdvanced: "✍️ 准备输出...", priority: .generating, color: .systemGreen, alpha: 0.35)
                d.eventHandler(self, showStep: "✍️", text: "准备输出内容...", progress: 60)
            }

        case "response.function_call_arguments.delta":
            if let delta = json["delta"] as? String, !delta.isEmpty {
                d.eventHandler(self, setStatusAdvanced: "🔧 参数输入中...", priority: .toolCall, color: .systemOrange, alpha: 0.50)
            }

        case "response.function_call_arguments.done":
            if let name = json["name"] as? String {
                let friendlyName = friendlyToolName(name)
                d.eventHandler(self, setStatusAdvanced: "✅ 参数就绪: \(friendlyName)", priority: .toolCall, color: .systemOrange, alpha: 0.35)
            }

        case "response.reasoning_text.delta":
            d.eventHandler(self, setStatusAdvanced: "🧠 深度思考...", priority: .reasoning, color: .systemPurple, alpha: 0.50)
            d.eventHandler(self, showStep: "🧠", text: "深度推理中...", progress: 40)

        case "response.reasoning_summary_text.delta":
            d.eventHandler(self, setStatusAdvanced: "🧠 推理总结中...", priority: .reasoning, color: .systemPurple, alpha: 0.40)

        case "response.output_text.delta":
            if let content = json["delta"] as? String {
                d.eventHandler(self, executeJS: "apd('\(content.escapedForJS)')")
                streamedTextBuffer += content
                streamCharCount += content.count
                let input = sessionManager.totalPromptTokens
                let output = sessionManager.totalCompletionTokens
                d.eventHandler(self, updateLiveTokenDisplay: input, output: output, streamCharCount: streamCharCount)
                d.eventHandler(self, setStatusAdvanced: "📝 生成回复...", priority: .generating, color: .systemGreen, alpha: 0.40)
                d.eventHandler(self, showStep: "📝", text: "正在生成回复...", progress: 75)
                d.eventHandler(self, stopAnimation: ())
            } else {
                AppLogger.shared.log("[SSE Warning] output_text.delta 缺少 delta 字段")
            }

        case "response.output_text.done":
            d.eventHandler(self, setStatusAdvanced: "✅ 输出完成", priority: .generating, color: .systemGreen, alpha: 0.30)
            d.eventHandler(self, showStep: "✅", text: "回复生成完成", progress: 100)

        case "response.content_part.done":
            if let part = json["part"] as? [String: Any] {
                if part["type"] as? String == "function_call" {
                    let name = part["name"] as? String ?? ""
                    let friendlyName = friendlyToolName(name)
                    d.eventHandler(self, setStatusAdvanced: "✅ 工具完成: \(friendlyName)", priority: .toolCall, color: .systemOrange, alpha: 0.30)
                    d.eventHandler(self, showStep: "✅", text: "工具执行完成: \(friendlyName)", progress: 65)
                } else {
                    d.eventHandler(self, setStatusAdvanced: "✅ 内容块完成", priority: .generating, color: .systemGreen, alpha: 0.25)
                }
            }

        case "response.output_item.done":
            if let item = json["item"] as? [String: Any] {
                if item["type"] as? String == "function_call" {
                    let name = item["name"] as? String ?? ""
                    let friendlyName = friendlyToolName(name)
                    if !activeToolStack.isEmpty { activeToolStack.removeLast() }
                    let remaining = activeToolStack.count
                    if remaining > 0 {
                        d.eventHandler(self, setStatusAdvanced: "🔧 等待工具返回: \(friendlyName)", priority: .toolCall, color: .systemOrange, alpha: 0.35)
                    } else {
                        d.eventHandler(self, setStatusAdvanced: "🔧 工具已调用: \(friendlyName)", priority: .toolCall, color: .systemBlue, alpha: 0.30)
                        d.eventHandler(self, showStep: "🔧", text: "工具已调用: \(friendlyName)", progress: 55)
                    }
                } else if item["type"] as? String == "reasoning" {
                    d.eventHandler(self, setStatusAdvanced: "🤖 思考完成,准备回复...", priority: .thinking, color: .systemBlue, alpha: 0.30)
                    d.eventHandler(self, showStep: "🤔", text: "思考完成,准备回复...", progress: 60)
                }
            }

        case "response.completed":
            if let resp = json["response"] as? [String: Any], let usage = resp["usage"] as? [String: Any] {
                if let inputTokens = usage["input_tokens"] as? Int {
                    sessionManager.totalPromptTokens = inputTokens
                }
                if let outputTokens = usage["output_tokens"] as? Int {
                    sessionManager.totalCompletionTokens = outputTokens
                }
                // 触发 UI 更新
                d.eventHandler(self, setStatusForce: "🤖 就绪", color: .clear, alpha: 0)
                d.eventHandler(self, hideStep: ())
                d.eventHandler(self, stopAnimation: ())
                // finalize 延迟 50ms 后执行(让最后一个 delta 先渲染)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    d.eventHandler(self, finalizeStream: ())
                }
            } else {
                d.eventHandler(self, setStatusForce: "🤖 就绪", color: .clear, alpha: 0)
                d.eventHandler(self, hideStep: ())
                d.eventHandler(self, stopAnimation: ())
            }

        case "response.failed":
            if let err = json["error"] as? [String: Any], let msg = err["message"] as? String {
                d.eventHandler(self, executeJS: "addMessage('assistant','❌ 错误: \(msg.escapedForJS)')")
            }
            d.eventHandler(self, setStatusForce: "❌ 请求失败", color: .systemRed, alpha: 0.35)
            d.eventHandler(self, hideStep: ())
            d.eventHandler(self, stopAnimation: ())
            DispatchQueue.main.async {
                d.eventHandler(self, finalizeStream: ())
            }

        default:
            AppLogger.shared.log("[SSE] 未处理事件类型: \(type)")
        }
    }
}
