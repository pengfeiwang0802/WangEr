import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    
    /// 从 Info.plist 读取版本号，单点维护
    static var appVersion: String {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            return "v\(version)"
        }
        return "v?.?.?"
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
