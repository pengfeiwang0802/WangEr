import Foundation

/// 流式会话的代理协议：将 SSE 事件回调给 ChatViewController
protocol StreamSessionDelegate: AnyObject {
    /// 收到一个完整的 SSE 事件（JSON 已解析）
    func streamSession(_ session: StreamSession, didReceiveEvent event: String, data: [String: Any])
    /// 收到 [DONE] 信号
    func streamSessionDidReceiveDone(_ session: StreamSession)
    /// HTTP 错误（非 200）
    func streamSession(_ session: StreamSession, didEncounterHTTPError code: Int)
    /// 流完成（error 为 nil 表示正常关闭）
    func streamSession(_ session: StreamSession, didCompleteWithError error: Error?)
    /// 解码失败
    func streamSession(_ session: StreamSession, didEncounterDecodeError message: String)
}

/// 管理 SSE 流式请求的完整生命周期：会话创建、SSE 协议解析、完成/错误处理
/// 替代原来 ChatViewController 中的 URLSessionDataDelegate 实现
class StreamSession: NSObject, URLSessionDataDelegate {
    weak var delegate: StreamSessionDelegate?

    /// SSE 累积缓冲区：防止 TCP 分片截断事件
    private var sseBuffer = ""
    private var urlSession: URLSession?
    private var dataTask: URLSessionDataTask?

    /// 启动流式请求
    func start(body: [String: Any], gatewayURL: String, token: String, agentId: String, model: String) {
        guard let url = URL(string: "\(gatewayURL)/v1/responses") else {
            delegate?.streamSession(self, didEncounterDecodeError: "Gateway 地址无效")
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(agentId, forHTTPHeaderField: "x-openclaw-agent-id")
        req.setValue(model, forHTTPHeaderField: "x-openclaw-model")

        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            delegate?.streamSession(self, didEncounterDecodeError: "请求构造失败")
            return
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 1860
        config.timeoutIntervalForResource = 3600

        urlSession?.invalidateAndCancel()
        sseBuffer = ""
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        urlSession = session
        let task = session.dataTask(with: req)
        dataTask = task
        task.resume()
    }

    /// 取消当前流
    func cancel() {
        dataTask?.cancel()
        dataTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let httpResponse = response as? HTTPURLResponse else {
            completionHandler(.allow)
            return
        }
        if httpResponse.statusCode != 200 {
            AppLogger.shared.log("[HTTP Error] 状态码: \(httpResponse.statusCode)")
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.streamSession(self, didEncounterHTTPError: httpResponse.statusCode)
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !data.isEmpty else { return }
        guard let chunk = String(data: data, encoding: .utf8) else {
            AppLogger.shared.log("[SSE Error] 无法将数据解码为 UTF-8")
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.streamSession(self, didEncounterDecodeError: "接收数据解码失败")
            }
            return
        }

        // 追加到累积缓冲区
        sseBuffer += chunk

        // 按 \n\n 分割完整事件块
        let blocks = sseBuffer.components(separatedBy: "\n\n")
        // 最后一段可能是不完整的,留在缓冲区等待下一批
        if sseBuffer.hasSuffix("\n\n") {
            sseBuffer = ""
        } else {
            sseBuffer = blocks.last ?? ""
        }

        // 处理完整的块(排除最后一个不完整的)
        let completeBlocks = blocks.dropLast(blocks.count > 1 && !sseBuffer.isEmpty ? 1 : 0)

        var foundDone = false

        for block in completeBlocks {
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let lines = trimmed.components(separatedBy: "\n")
            var currentEvent = ""
            var currentData = ""

            for line in lines {
                if line.hasPrefix("event: ") {
                    currentEvent = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("data: ") {
                    currentData = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                }
            }

            if currentData == "[DONE]" {
                foundDone = true
                break
            }

            if !currentData.isEmpty {
                // 解析 JSON 并将完整事件回调给 delegate
                guard let d = currentData.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
                    AppLogger.shared.log("[SSE Error] JSON 解析失败: \(currentData.prefix(200))")
                    continue
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.streamSession(self, didReceiveEvent: currentEvent, data: json)
                }
            }
        }

        if foundDone {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.streamSessionDidReceiveDone(self)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.streamSession(self, didCompleteWithError: error)
        }
    }
}
