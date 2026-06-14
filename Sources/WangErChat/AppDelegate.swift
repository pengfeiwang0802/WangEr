import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    
    static let appVersion = "v0.2.2"

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
