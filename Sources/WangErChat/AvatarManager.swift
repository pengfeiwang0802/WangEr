import AppKit
import WebKit

/// 虚拟形象管理器
/// 封装 Live2D WKWebView、JS 桥接、表情控制、状态同步
class AvatarManager: NSObject {
    // MARK: - 公开属性
    let containerView: NSView
    private(set) var webView: WKWebView?
    private(set) var isReady = false

    /// 用户命令表情激活标志（防止 .ready 状态覆盖用户命令的表情）
    var userExpressionActive = false

    /// 表达式防抖：同一表达式 3 秒内不重复发送
    private var lastSentExpression: String?
    private var lastSentExpressionTime: Date = .distantPast

    // MARK: - 初始化
    init(containerView: NSView) {
        self.containerView = containerView
        super.init()
    }

    // MARK: - 设置
    func setup() {
        guard let live2dDir = live2dDirectory() else {
            AppLogger.shared.log("[Avatar] 错误: 找不到 live2d 目录，回退 SVG")
            fallbackToSVG()
            return
        }

        let config = WKWebViewConfiguration()

        // 注册 JS → Swift 消息处理器
        config.userContentController.add(self, name: "avatarReady")
        config.userContentController.add(self, name: "log")  // console.log 桥接

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

        // 用 loadFileURL 加载 HTML（支持 <script src> 和 <img src> 同目录加载）
        // 所有 fetch() 已替换为 window.__loadFile()，数据由 Swift 注入
        wv.loadFileURL(live2dDir.appendingPathComponent("index.html"), allowingReadAccessTo: live2dDir)
        AppLogger.shared.log("[Avatar] 加载 Live2D HTML via loadFileURL")
    }

    private func fallbackToSVG() {
        let fallback = WKWebView()
        fallback.translatesAutoresizingMaskIntoConstraints = false
        fallback.setValue(false, forKey: "drawsBackground")
        fallback.loadHTMLString(AvatarHTML.template, baseURL: nil)
        containerView.addSubview(fallback)
        NSLayoutConstraint.activate([
            fallback.topAnchor.constraint(equalTo: containerView.topAnchor),
            fallback.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            fallback.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            fallback.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])
        webView = fallback
        isReady = true
    }

    // MARK: - 表情控制（JS 桥接）

    /// 设置表情：neutral / happy / thinking / sad / surprise / sleepy
    func setExpression(_ expr: String, userInitiated: Bool = false) {
        // 防抖：同一表达式 3 秒内不重发
        if !userInitiated && expr == lastSentExpression && Date().timeIntervalSince(lastSentExpressionTime) < 3 {
            // 跳过重复表达式
            return
        }
        AppLogger.shared.log("[Avatar] setExpression: \(expr), isReady=\(isReady), userInitiated=\(userInitiated)")
        guard isReady else { AppLogger.shared.log("[Avatar] isReady=false, 跳过"); return }
        lastSentExpression = expr
        lastSentExpressionTime = Date()

        // 映射 SVG 表情名 → Live2D 表情名
        let l2dExpr = mapExpression(expr)

        let js = "live2d.setExpression('\(escJS(l2dExpr))')"
        AppLogger.shared.log("[Avatar] 执行 JS: \(js)")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.userExpressionActive && !userInitiated {
                AppLogger.shared.log("[Avatar] 用户表情激活中，跳过覆盖: \(expr)")
                return
            }
            if userInitiated {
                self.userExpressionActive = true
            }
            self.webView?.evaluateJavaScript(js) { _, error in
                if let error = error {
                    AppLogger.shared.log("[Avatar] JS 错误: \(error.localizedDescription)")
                } else {
                    AppLogger.shared.log("[Avatar] setExpression('\(l2dExpr)') 成功")
                }
            }
        }
    }

    /// 设置状态文本（底部标签）
    func setStatus(_ text: String) {
        guard isReady else { return }
        let js = "live2d.setStatus('\(escJS(text))')"
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(js)
        }
    }

    /// 播放动作
    func startMotion(_ group: String) {
        guard isReady else { return }
        let js = "live2d.startMotion('\(escJS(group))')"
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

    // MARK: - 公开方法

    /// 资源目录（供 Live2DResourceHandler 使用）
    var resourceDirectory: URL? {
        live2dDirectory()
    }

    /// 读取 JS 侧诊断日志（供调试用）
    func fetchDiag(completion: @escaping (String) -> Void) {
        guard isReady else { completion(""); return }
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript("live2d.getDiag()") { result, err in
                completion((result as? String) ?? (err?.localizedDescription ?? ""))
            }
        }
    }

    // MARK: - 私有辅助

    /// 找到 live2d 资源目录
    private func live2dDirectory() -> URL? {
        // SPM resource bundle: WangErChat_WangErChat.bundle/live2d/
        if let bundlePath = Bundle.main.resourceURL?
            .appendingPathComponent("WangErChat_WangErChat.bundle")
            .appendingPathComponent("live2d") {
            if FileManager.default.fileExists(atPath: bundlePath.path) {
                return bundlePath
            }
        }
        // 直接资源目录（某些 SPM 版本）
        if let bundlePath = Bundle.main.resourceURL?.appendingPathComponent("live2d") {
            if FileManager.default.fileExists(atPath: bundlePath.path) {
                return bundlePath
            }
        }
        // 开发环境：target 目录下的 live2d/
        let devPath = URL(fileURLWithPath: #file)
            .deletingLastPathComponent() // Sources/WangErChat/
            .appendingPathComponent("live2d")
        if FileManager.default.fileExists(atPath: devPath.path) {
            return devPath
        }
        return nil
    }

    /// 映射 SVG 表情名 → Live2D 表情名
    private func mapExpression(_ expr: String) -> String {
        // SVG 用 "surprised"（ed 结尾），Live2D 用 "surprise"
        if expr == "surprised" { return "surprise" }
        return expr
    }

    private func escJS(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "'", with: "\\'")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: "\\n")
         .replacingOccurrences(of: "\r", with: "\\r")
         .replacingOccurrences(of: "\t", with: "\\t")
    }

    // MARK: - 模型数据注入

    /// 预加载所有模型文件（json + moc3），注入 base64 到 JS
    private func injectModelDataAndStart() {
        guard let live2dDir = live2dDirectory(), let wv = webView else { return }

        let modelDir = live2dDir.appendingPathComponent("model")
        let files = findAllFiles(in: modelDir, extensions: ["json", "moc3", "png"])

        var js = "window.__fileData = {\n"
        for fileURL in files {
            let relativePath = fileURL.path.replacingOccurrences(of: live2dDir.path + "/", with: "")
            guard let data = try? Data(contentsOf: fileURL) else {
                AppLogger.shared.log("[Avatar] 跳过无法读取: \(relativePath)")
                continue
            }
            let b64 = data.base64EncodedString()
            let key = escJS(relativePath)
            js += "  '\(key)': '\(b64)',\n"
        }
        js += "};"

        AppLogger.shared.log("[Avatar] 注入 \(files.count) 个模型文件到 JS")

        wv.evaluateJavaScript(js) { _, err in
            if let err = err {
                AppLogger.shared.log("[Avatar] 数据注入失败: \(err.localizedDescription)")
                return
            }
            // main() 是 async 函数，返回 Promise，WKWebView 无法序列化 → 报错是正常的
            // main() 内部的异步代码仍会执行，完成后通过 avatarReady messageHandler 通知 Swift
            wv.evaluateJavaScript("main().catch(function(e){console.error('main error:',e)})") { _, err2 in
                if let err2 = err2 {
                    AppLogger.shared.log("[Avatar] main() 已触发 (WKWebView Promise 序列化警告可忽略): \(err2.localizedDescription)")
                } else {
                    AppLogger.shared.log("[Avatar] main() 已触发")
                }
            }
        }
    }

    /// 递归查找指定扩展名的文件
    private func findAllFiles(in dir: URL, extensions: [String]) -> [URL] {
        var result: [URL] = []
        guard let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return result }
        for case let fileURL as URL in enumerator {
            if extensions.contains(fileURL.pathExtension.lowercased()) {
                result.append(fileURL)
            }
        }
        return result
    }
}

// MARK: - WKScriptMessageHandler
extension AvatarManager: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "log" {
            // JS console.log 桥接
            let body = message.body as? [String: Any] ?? [:]
            let tag = body["tag"] as? String ?? "JS"
            let msg = body["msg"] as? String ?? ""
            AppLogger.shared.log("[JS:\(tag)] \(msg)")
            return
        }
        guard message.name == "avatarReady",
              let body = message.body as? [String: Any] else {
            AppLogger.shared.log("[Avatar] 未知 message: \(message.name)")
            return
        }
        let ready = body["ready"] as? Bool ?? false
        let hits = body["shaderHits"] as? Int ?? 0
        let misses = body["shaderMisses"] as? [String] ?? []
        let err = body["error"] as? String

        if ready {
            isReady = true
            AppLogger.shared.log("[Avatar] ✅ 模型就绪！shaderHits=\(hits) shaderMisses=\(misses)")
        } else {
            AppLogger.shared.log("[Avatar] ❌ 模型加载失败: \(err ?? "未知")")
        }
    }
}

// MARK: - WKNavigationDelegate
extension AvatarManager: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView == self.webView else { return }
        AppLogger.shared.log("[Avatar] HTML 资源加载完成，注入模型数据...")
        // ⚠️ isReady 不在这里设！等 JS main() 完成后通过 avatarReady 回调设置
        injectModelDataAndStart()
    }
}
