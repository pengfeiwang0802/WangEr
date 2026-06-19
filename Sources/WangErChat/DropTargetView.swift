import AppKit

// MARK: - 拖放目标视图
class DropTargetView: NSView {
    var onDragEnter: (() -> Void)?
    var onDragExit: (() -> Void)?
    var onFileDrop: ((URL) -> Void)?
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }
    
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil) {
            onDragEnter?()
            return .copy
        }
        return []
    }
    
    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragExit?()
    }
    
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              let url = urls.first else {
            return false
        }
        onFileDrop?(url)
        return true
    }
}
