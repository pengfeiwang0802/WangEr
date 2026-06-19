import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    
    /// 版本号：Info.plist 优先（release build），硬编码兜底（debug build）
    static var appVersion: String {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            return "v\(version)"
        }
        return "v0.3.1"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let viewController = ChatViewController()
        
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "王二助手 \(Self.appVersion)"
        window.contentViewController = viewController
        window.makeKeyAndOrderFront(nil)
        window.delegate = self
        
        NSApp.setActivationPolicy(.regular)
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }
}
