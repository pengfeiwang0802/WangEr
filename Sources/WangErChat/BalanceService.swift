import Foundation

/// Fetches API balance info for configured model providers.
/// Stateless utility — takes keys in, delivers results via callback on main thread.
struct BalanceService {
    struct Balances {
        var deepseek: String
        var kimi: String
    }

    /// Fetch balances from DeepSeek and Kimi APIs concurrently.
    func fetchBalances(
        deepseekKey: String,
        kimiKey: String,
        completion: @escaping (Balances) -> Void
    ) {
        var dsResult = "--"
        var msResult = "--"
        let group = DispatchGroup()

        if !deepseekKey.isEmpty {
            group.enter()
            fetchDeepSeek(key: deepseekKey) { result in
                dsResult = result
                group.leave()
            }
        }

        if !kimiKey.isEmpty {
            group.enter()
            fetchKimi(key: kimiKey) { result in
                msResult = result
                group.leave()
            }
        }

        group.notify(queue: .main) {
            completion(Balances(deepseek: dsResult, kimi: msResult))
        }
    }

    // MARK: - Private

    private func fetchDeepSeek(key: String, completion: @escaping (String) -> Void) {
        guard let url = URL(string: "https://api.deepseek.com/user/balance") else {
            completion("--")
            return
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10

        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error = error {
                AppLogger.shared.log("[Balance] DeepSeek 查询错误: \(error)")
                completion("错误")
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                AppLogger.shared.log("[Balance] DeepSeek 无 HTTP 响应")
                completion("无响应")
                return
            }
            guard httpResponse.statusCode == 200 else {
                AppLogger.shared.log("[Balance] DeepSeek HTTP \(httpResponse.statusCode)")
                completion("HTTP\(httpResponse.statusCode)")
                return
            }
            guard let data = data else {
                completion("无数据")
                return
            }
            do {
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                if let infos = json?["balance_infos"] as? [[String: Any]],
                   let first = infos.first,
                   let bal = first["total_balance"] as? String {
                    completion(bal)
                } else {
                    AppLogger.shared.log("[Balance] DeepSeek 响应结构异常: \(String(data: data, encoding: .utf8)?.prefix(200) ?? "N/A")")
                    completion("解析失败")
                }
            } catch {
                AppLogger.shared.log("[Balance] DeepSeek JSON 解析错误: \(error)")
                completion("解析错误")
            }
        }.resume()
    }

    private func fetchKimi(key: String, completion: @escaping (String) -> Void) {
        guard let url = URL(string: "https://api.moonshot.cn/v1/users/me/balance") else {
            completion("--")
            return
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10

        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error = error {
                AppLogger.shared.log("[Balance] Kimi 查询错误: \(error)")
                completion("错误")
                return
            }
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                AppLogger.shared.log("[Balance] Kimi HTTP \(code)")
                completion("HTTP\(code)")
                return
            }
            guard let data = data else {
                completion("无数据")
                return
            }
            do {
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                if json?["status"] as? Bool == true,
                   let balData = json?["data"] as? [String: Any],
                   let bal = balData["available_balance"] as? Double {
                    completion(String(format: "%.2f", bal))
                } else {
                    AppLogger.shared.log("[Balance] Kimi 响应结构异常")
                    completion("解析失败")
                }
            } catch {
                AppLogger.shared.log("[Balance] Kimi JSON 解析错误: \(error)")
                completion("解析错误")
            }
        }.resume()
    }
}
