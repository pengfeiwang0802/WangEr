import AppKit

/// 输入框顶部的拖拽条：上下拖动可调整输入框高度，双击恢复默认高度。
final class InputResizeHandle: NSView {
    /// 拖动回调，参数为纵向位移（向上为正，单位为点）
    var onDrag: ((CGFloat) -> Void)?
    /// 双击回调（恢复默认高度）
    var onReset: (() -> Void)?

    private var lastMouseY: CGFloat?
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        toolTip = "拖动可调整输入框高度，双击恢复默认"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingArea { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.activeInActiveApp, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.resizeUpDown.set()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onReset?()
            lastMouseY = nil
            return
        }
        // 用屏幕坐标，避免拖动过程中窗口移动导致抖动
        lastMouseY = NSEvent.mouseLocation.y
    }

    override func mouseDragged(with event: NSEvent) {
        guard let last = lastMouseY else { return }
        let current = NSEvent.mouseLocation.y
        let delta = current - last
        if abs(delta) > 0 { onDrag?(delta) }
        lastMouseY = current
    }

    override func mouseUp(with event: NSEvent) {
        lastMouseY = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // 一条淡淡的分隔线，提示这里可以拖
        NSColor.separatorColor.withAlphaComponent(0.6).setFill()
        NSRect(x: 8, y: bounds.midY - 0.5, width: bounds.width - 16, height: 1).fill()
    }
}
