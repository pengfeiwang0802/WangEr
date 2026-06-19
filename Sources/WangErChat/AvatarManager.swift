import AppKit
import WebKit

/// 虚拟形象管理器
/// 封装 avatar WKWebView、JS 桥接、表情控制、状态同步
/// 后续 Live2D 替换时只需修改此类
class AvatarManager: NSObject {
    // MARK: - 公开属性
    let containerView: NSView
    private(set) var webView: WKWebView?
    private(set) var isReady = false

    /// 用户命令表情激活标志（防止 .ready 状态覆盖用户命令的表情）
    var userExpressionActive = false

    // MARK: - 初始化
    init(containerView: NSView) {
        self.containerView = containerView
        super.init()
    }

    // MARK: - 设置
    func setup() {
        let config = WKWebViewConfiguration()
        let userContent = WKUserContentController()
        config.userContentController = userContent
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.translatesAutoresizingMaskIntoConstraints = false
        wv.setValue(false, forKey: "drawsBackground")
        wv.navigationDelegate = self
        containerView.addSubview(wv)
        NSLayoutConstraint.activate([
            wv.topAnchor.constraint(equalTo: containerView.topAnchor),
            wv.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            wv.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])
        webView = wv
        isReady = false
        wv.loadHTMLString(AvatarHTML.template, baseURL: nil)
    }

    // MARK: - 表情控制（JS 桥接）

    /// 设置表情：neutral / happy / thinking / sad / surprised
    func setExpression(_ expr: String, userInitiated: Bool = false) {
        AppLogger.shared.log("[Avatar] setExpression 被调用: \(expr), isReady=\(isReady), userInitiated=\(userInitiated)")
        guard isReady else { AppLogger.shared.log("[Avatar] isReady=false, 跳过"); return }
        let js = "setExpression('\(escJS(expr))')"
        AppLogger.shared.log("[Avatar] 执行 JS: \(js)")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // 用户表情激活中，跳过所有非用户触发的覆盖（在主线程检查，消除竞态）
            if self.userExpressionActive && !userInitiated {
                AppLogger.shared.log("[Avatar] 用户表情激活中，主线程跳过覆盖: \(expr)")
                return
            }
            if userInitiated {
                self.userExpressionActive = true  // 在主线程设置 flag
            }
            self.webView?.evaluateJavaScript(js) { result, error in
                if let error = error {
                    AppLogger.shared.log("[Avatar] JS 执行错误: \(error.localizedDescription)")
                } else {
                    AppLogger.shared.log("[Avatar] JS 执行成功, setExpression('\(expr)')")
                    // 验证 SVG 状态
                    self.webView?.evaluateJavaScript("document.getElementById('eyes')?.querySelector('ellipse')?.getAttribute('fill') ?? 'NOT_FOUND'") { eyes, _ in
                        AppLogger.shared.log("[Avatar] 验证 - eyes fill: \(eyes ?? "nil")")
                    }
                    self.webView?.evaluateJavaScript("document.getElementById('mouth')?.getAttribute('d') ?? 'NOT_FOUND'") { mouth, _ in
                        AppLogger.shared.log("[Avatar] 验证 - mouth path: \(mouth ?? "nil")")
                    }
                }
            }
        }
    }

    /// 设置状态文本（底部标签）
    func setStatus(_ text: String) {
        guard isReady else { return }
        let js = "setStatus('\(escJS(text))')"
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(js)
        }
    }

    /// 替换整个 SVG 内容（用于 AI 生成或模板切换）
    func loadSVG(_ svgContent: String) {
        guard isReady else { return }
        let escaped = svgContent
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "")
        let js = "loadSVG('\(escaped)')"
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(js)
        }
    }

    // MARK: - 关键词表情解析（静态方法）

    /// 从用户输入中解析表情关键词，返回对应的表情名
    static func parseExpression(from text: String) -> String? {
        let lower = text.lowercased()
        if lower.contains("笑") || lower.contains("开心") || lower.contains("高兴") || lower.contains("乐") || lower.contains("😊") || lower.contains("😄") { return "happy" }
        if lower.contains("哭") || lower.contains("委屈") || lower.contains("沮丧") || lower.contains("难过") || lower.contains("伤心") || lower.contains("😢") || lower.contains("😞") { return "sad" }
        if lower.contains("惊讶") || lower.contains("吓") || lower.contains("震惊") || lower.contains("😲") || lower.contains("😮") { return "surprised" }
        if lower.contains("想你") || lower.contains("思考") || lower.contains("琢磨") || lower.contains("🤔") { return "thinking" }
        if lower.contains("平静") || lower.contains("淡定") || lower.contains("面无表情") || lower.contains("无表情") || lower.contains("😐") { return "neutral" }
        return nil
    }

    // MARK: - 私有辅助

    private func escJS(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "'", with: "\\'")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: "\\n")
         .replacingOccurrences(of: "\r", with: "\\r")
         .replacingOccurrences(of: "\t", with: "\\t")
    }
}

// MARK: - WKNavigationDelegate
extension AvatarManager: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 只处理自己的 webView
        guard webView == self.webView else { return }
        isReady = true
        AppLogger.shared.log("[Avatar] avatarDidLoad — WKWebView 加载完成")
        // 验证 SVG 结构
        webView.evaluateJavaScript("document.getElementById('eyes')?.getAttribute('d') ?? 'NOT_FOUND'") { eyes, _ in
            AppLogger.shared.log("[Avatar] 初始 - eyes path: \(eyes ?? "nil")")
        }
        webView.evaluateJavaScript("document.getElementById('mouth')?.getAttribute('d') ?? 'NOT_FOUND'") { mouth, _ in
            AppLogger.shared.log("[Avatar] 初始 - mouth path: \(mouth ?? "nil")")
        }
        // 设置默认表情
        webView.evaluateJavaScript("setExpression('neutral')")
    }
}
