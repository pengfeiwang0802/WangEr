import AppKit
import WebKit

// MARK: - 文件缓存配置
private let maxCacheSize: UInt64 = 100 * 1024 * 1024
private let maxCacheFiles = 100

// MARK: - 文件缓存管理
extension ChatViewController {
    
    func cachedFileURL(fileId: String) -> URL {
        let dir = filesCacheDir()
        return dir.appendingPathComponent(fileId)
    }
    
    func filesCacheDir() -> URL {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = supportDir.appendingPathComponent("WangEr/files", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    
    func saveFileToCache(data: Data, filename: String) -> String {
        let dir = filesCacheDir()
        let fileId = UUID().uuidString + "_" + filename
        let url = dir.appendingPathComponent(fileId)
        try? data.write(to: url)
        
        // 异步清理旧缓存
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.cleanupOldCacheFiles()
        }
        
        return fileId
    }
    
    /// 清理旧缓存文件：限制总大小和文件数量
    func cleanupOldCacheFiles() {
        let dir = filesCacheDir()
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: []) else { return }
        
        // 按修改时间排序（最旧的在前）
        let sortedFiles = files.compactMap { url -> (URL, Date, UInt64)? in
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let modDate = attrs[.modificationDate] as? Date,
                  let fileSize = attrs[.size] as? UInt64 else { return nil }
            return (url, modDate, fileSize)
        }.sorted { $0.1 < $1.1 }
        
        var totalSize: UInt64 = sortedFiles.reduce(0) { $0 + $1.2 }
        var fileCount = sortedFiles.count
        
        // 如果超过限制，删除最旧的文件
        for (url, _, size) in sortedFiles {
            if totalSize <= maxCacheSize && fileCount <= maxCacheFiles { break }
            try? FileManager.default.removeItem(at: url)
            totalSize -= size
            fileCount -= 1
        }
    }
}

// MARK: - WKUIDelegate (拦截文件拖拽到 WKWebView)
extension ChatViewController: WKUIDelegate {
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        // 文件选择面板（从网页触发）
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { result in
            if result == .OK, let url = panel.url {
                completionHandler([url])
                self.handleDroppedFile(url: url)
            } else {
                completionHandler(nil)
            }
        }
    }
}

// MARK: - WKScriptMessageHandler (JS → Native 消息)
extension ChatViewController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "fileOpen", let fileId = message.body as? String {
            openCachedFile(fileId: fileId)
        }
    }
    
    private func openCachedFile(fileId: String) {
        let fileURL = cachedFileURL(fileId: fileId)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            AppLogger.shared.log("[File Open] 文件不存在: \(fileId)")
            return
        }
        NSWorkspace.shared.open(fileURL)
    }
}

// MARK: - 虚拟形象 WKNavigationDelegate

extension ChatViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView == avatarWebView {
            avatarDidLoad()
        }
    }
}
