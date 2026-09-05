import AppKit
import UniformTypeIdentifiers

// MARK: - Key handling via NSTextView subclass
class SendTextView: NSTextView {
    var onCommandEnter: (() -> Void)?
    /// 剪贴板含图片时回调 (data, filename, mimeType)
    var onPasteImage: ((Data, String, String) -> Void)?
    
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) && event.keyCode == 36 { // enter
            onCommandEnter?()
            return
        }
        super.keyDown(with: event)
    }
    
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        
        guard let chars = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        
        switch chars {
        case "a":
            selectAll(nil)
            return true
        case "c":
            if selectedRange().length > 0 {
                copy(self)
            }
            return true
        case "v":
            // 优先处理剪贴板中的图片
            if handlePasteImage() {
                return true
            }
            paste(self)
            return true
        case "x":
            if selectedRange().length > 0 {
                cut(self)
            }
            return true
        case "z":
            if event.modifierFlags.contains(.shift) {
                undoManager?.redo()
            } else {
                undoManager?.undo()
            }
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
    
    /// 检查剪贴板是否有图片, 有则提取并回调发送
    private func handlePasteImage() -> Bool {
        let pb = NSPasteboard.general
        guard let onPasteImage = onPasteImage else { return false }
        
        // 优先 TIFF → PNG
        if let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            onPasteImage(png, "粘贴图片.png", "image/png")
            return true
        }
        // PNG
        if let png = pb.data(forType: .png) {
            onPasteImage(png, "粘贴图片.png", "image/png")
            return true
        }
        // 其他图片类型
        let imageTypes: [NSPasteboard.PasteboardType] = NSImage.imageTypes.map { NSPasteboard.PasteboardType($0) }
        if let imgType = pb.availableType(from: imageTypes), let data = pb.data(forType: imgType) {
            let ext = imgType.rawValue.components(separatedBy: ".").last ?? "png"
            let mime = "image/\(ext)"
            onPasteImage(data, "粘贴图片.\(ext)", mime)
            return true
        }
        // 文件 URL (如从 Finder 复制的图片文件)
        if let fileURL = pb.string(forType: .fileURL), let url = URL(string: fileURL), url.isFileURL {
            if let uti = try? url.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier,
               let utType = UTType(uti),
               utType.conforms(to: .image),
               let data = try? Data(contentsOf: url) {
                let mime = utType.preferredMIMEType ?? "image/png"
                onPasteImage(data, url.lastPathComponent, mime)
                return true
            }
        }
        return false
    }
}
