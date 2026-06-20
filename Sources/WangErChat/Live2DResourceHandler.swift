import WebKit
import Foundation

/// 自定义 URL Scheme Handler，为 Live2D 页面提供沙盒内的资源文件访问
/// 解决 WKWebView 中 file:// 协议下 fetch() 被 CORS 阻止的问题
///
/// URL 格式: live2d-local://x/path/to/file
/// 用 url.path 提取相对路径，映射到 rootURL 下的文件
final class Live2DResourceHandler: NSObject, WKURLSchemeHandler {

    static let scheme = "live2d-local"

    private let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL))
            return
        }

        // URL 格式: live2d-local://x/path/to/file
        // url.path = "/path/to/file" → 去掉首字符 "/" 得到相对路径
        var relativePath = requestURL.path
        if relativePath.hasPrefix("/") {
            relativePath = String(relativePath.dropFirst())
        }

        let fileURL = rootURL.appendingPathComponent(relativePath)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            urlSchemeTask.didFailWithError(
                NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist,
                        userInfo: [NSLocalizedDescriptionKey: "\(fileURL.path)"])
            )
            return
        }

        guard let data = try? Data(contentsOf: fileURL) else {
            urlSchemeTask.didFailWithError(
                NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotOpenFile,
                        userInfo: [NSLocalizedDescriptionKey: "\(fileURL.path)"])
            )
            return
        }

        let mime = mimeType(for: fileURL)

        // 必须用 HTTPURLResponse，否则 fetch() 会得到 status=0 且 body 为空
        guard let response = HTTPURLResponse(
            url: requestURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": mime,
                "Content-Length": "\(data.count)",
                "Access-Control-Allow-Origin": "*"
            ]
        ) else {
            urlSchemeTask.didFailWithError(
                NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotParseResponse))
            return
        }

        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "html": return "text/html"
        case "js":   return "text/javascript"
        case "json": return "application/json"
        case "png":  return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "moc3", "cdi3": return "application/octet-stream"
        default:     return "application/octet-stream"
        }
    }
}
