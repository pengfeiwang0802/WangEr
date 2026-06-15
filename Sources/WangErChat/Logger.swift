import Foundation

class AppLogger {
    static let shared = AppLogger()
    
    private let logDir: URL
    private let logFile: URL
    private let queue = DispatchQueue(label: "com.wanger.logger", qos: .utility)
    private let maxFileSize: UInt64 = 5 * 1024 * 1024
    private let truncateKeep: UInt64 = 2 * 1024 * 1024
    
    private init() {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        logDir = supportDir.appendingPathComponent("WangEr/logs", isDirectory: true)
        logFile = logDir.appendingPathComponent("wanger.log")
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        log("[App] 🚀 王二助手启动 (\(AppDelegate.appVersion))")
    }
    
    func log(_ message: String, file: String = #file, line: Int = #line, function: String = #function) {
        let filename = (file as NSString).lastPathComponent
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let formatted = "[\(timestamp)] [\(filename):\(line):\(function)] \(message)"
        
        queue.async { [weak self] in
            guard let self = self else { return }
            self.write(formatted)
        }
    }
    
    private func write(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        
        if let attrs = try? FileManager.default.attributesOfItem(atPath: logFile.path),
           let size = attrs[.size] as? UInt64,
           size > maxFileSize {
            truncate()
        }
        
        if FileManager.default.fileExists(atPath: logFile.path) {
            if let handle = try? FileHandle(forWritingTo: logFile) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        } else {
            try? data.write(to: logFile, options: .atomic)
        }
        
        NSLog("[WangEr] \(line)")
    }
    
    private func truncate() {
        guard let handle = try? FileHandle(forReadingFrom: logFile) else { return }
        defer { try? handle.close() }
        
        let fileSize = handle.seekToEndOfFile()
        if fileSize <= truncateKeep { return }
        
        handle.seek(toFileOffset: fileSize - truncateKeep)
        let keepData = handle.readDataToEndOfFile()
        try? keepData.write(to: logFile, options: .atomic)
        
        log("[Logger] ⚠️ 日志文件超过 5MB，已截断保留最后 2MB")
    }
    
    static func logFilePath() -> String {
        return AppLogger.shared.logFile.path
    }
}
