import Foundation

// MARK: - SWS Formatter

/// SWS 序列化器 —— .sws 文本 ↔ SWSModel 双向转换的桥梁。
///
/// 数据流：
/// ```
/// .sws 文本 ←→ SWSFormatter ←→ SWSDocument
///                ↑
///           DialogueFormat 控制写出时用哪种对白格式
/// ```
///
/// 设计要点：
/// - 序列化不丢信息：round-trip invariant = deserialize(serialize(doc)) == doc
/// - 两种对白写出格式，读入时自动识别
/// - 空行在对白块内保留为台词间的停顿（spec 4.3 节），不被拆成 .emptyLine
public struct SWSFormatter {
    // MARK: - Types

    /// 对白序列化格式
public enum DialogueFormat: String, CaseIterable {
        /// `[角色名]` 独占一行，台词在下方，空行结束
        /// ```
        /// [郑希远]
        /// 走吧。
        /// 别磨蹭了。
        /// ```
        case nameAbove

        /// `[角色名]：台词` 同行
        /// ```
        /// [郑希远]：走吧。
        /// [郑希远]：别磨蹭了。
        /// ```
        case inline
    }

    /// 反序列化过程中遇到的警告（不阻断解析）
    public struct Warning: Equatable, CustomStringConvertible {
        let line: Int
        let message: String
        public var description: String { "L\(line): \(message)" }
    }

    // MARK: - Properties

    public let dialogueFormat: DialogueFormat
    private var warnings: [Warning] = []

    // MARK: - Init

    public init(dialogueFormat: DialogueFormat = .nameAbove) {
        self.dialogueFormat = dialogueFormat
    }

    // MARK: - Serialize (SWSDocument → .sws text)

    /// 将 SWSDocument 序列化为 .sws 文本
    public func serialize(_ document: SWSDocument) -> String {
        var lines: [String] = []

        // ── YAML front matter ──
        let meta = document.metadata
        if meta.title != nil || meta.author != nil || meta.created != nil
            || meta.sourceFormat != nil || !meta.extra.isEmpty
        {
            lines.append("---")
            lines.append("sws: \(meta.sws)")
            if let v = meta.title       { lines.append("title: \(v)") }
            if let v = meta.author      { lines.append("author: \(v)") }
            if let v = meta.created     { lines.append("created: \(v)") }
            if let v = meta.sourceFormat { lines.append("source_format: \(v)") }
            for (k, v) in meta.extra.sorted(by: { $0.key < $1.key }) {
                lines.append("\(k): \(v)")
            }
            lines.append("---")
            lines.append("")
        }

        // ── Scenes ──
        for (i, scene) in document.scenes.enumerated() {
            if i > 0 { lines.append(""); lines.append("") }

            if let h = scene.heading {
                lines.append(h.swsText)
            }

            for block in scene.blocks {
                switch block {
                case .dialogue(let d):   writeDialogue(d, to: &lines)
                case .action(let a):     lines.append(a.text)
                case .unattributed(let u): writeUnattributed(u, to: &lines)
                case .emptyLine:         lines.append("")
                }
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private func writeDialogue(_ d: SWSDialogueBlock, to lines: inout [String]) {
        switch dialogueFormat {
        case .nameAbove:
            let header = d.modifier.map { "[\(d.character) | \($0)]" } ?? "[\(d.character)]"
            lines.append(header)
            for line in d.lines { lines.append(line) }

        case .inline:
            let prefix = d.modifier.map { "[\(d.character) | \($0)]：" } ?? "[\(d.character)]："
            if d.lines.isEmpty {
                lines.append(prefix)
            } else {
                for line in d.lines {
                    if line.isEmpty {
                        lines.append("")
                    } else {
                        lines.append("\(prefix)\(line)")
                    }
                }
            }
        }
    }

    private func writeUnattributed(_ u: SWSUnattributedBlock, to lines: inout [String]) {
        for line in u.lines {
            lines.append(line.isEmpty ? ">" : "> \(line)")
        }
    }

    // MARK: - Deserialize (.sws text → SWSDocument)

    /// 将 .sws 文本反序列化为 SWSDocument
    public mutating func deserialize(_ text: String) -> SWSDocument {
        warnings = []
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return SWSDocument()
        }
        let rawLines = text.components(separatedBy: "\n")
        var parser = Parser(lines: rawLines)
        let result = parser.parse()
        warnings = parser.warnings
        return result
    }

    /// 上次反序列化产生的警告
    public var lastWarnings: [Warning] { warnings }
}

// MARK: - Parser (内部状态机)

private struct Parser {
    public let lines: [String]
    public var warnings: [SWSFormatter.Warning] = []
    private var idx = 0

    public init(lines: [String]) {
        self.lines = lines
    }

    mutating func parse() -> SWSDocument {
        var meta = SWSMetadata()
        var scenes: [SWSScene] = []
        var currentBlocks: [SWSBlock] = []
        var currentHeading: SWSSceneHeading? = nil
        var dialogueBlock: (character: String, modifier: String?, lines: [String])? = nil
        var unattributedLines: [String]? = nil


        // ── YAML front matter ──
        if !eof && line == "---" {
            advance()
            while !eof && line != "---" {
                parseFrontMatter(line, into: &meta)
                advance()
            }
            if !eof { advance() } // skip closing ---
        }

        // ── Skip leading empty lines after front matter ──
        while !eof && line.isEmpty { advance() }

        // ── Body ──
        while !eof {
            let ln = line
            advance()

            // Scene heading
            if ln.hasPrefix("## ") {
                flushDialogue(&dialogueBlock, into: &currentBlocks)
                flushUnattributed(&unattributedLines, into: &currentBlocks)
                if !currentBlocks.isEmpty || currentHeading != nil {
                    scenes.append(SWSScene(heading: currentHeading, blocks: currentBlocks))
                    currentBlocks = []
                }
                currentHeading = parseSceneHeading(ln)
                continue
            }

            // Unattributed (leading lines can continue)
            if ln.hasPrefix("> ") || ln == ">" {
                flushDialogue(&dialogueBlock, into: &currentBlocks)
                let text = ln.hasPrefix("> ") ? String(ln.dropFirst(2)) : ""
                if unattributedLines == nil { unattributedLines = [] }
                unattributedLines?.append(text)
                continue
            }

            // Inline dialogue: [name]：text  or [name | mod]：text
            if let (ch, mod, text) = parseInlineDialogue(ln) {
                flushDialogue(&dialogueBlock, into: &currentBlocks)
                flushUnattributed(&unattributedLines, into: &currentBlocks)
                currentBlocks.append(.dialogue(SWSDialogueBlock(character: ch, modifier: mod, lines: [text])))
                continue
            }

            // Name-above header: [name] or [name | mod]
            if let (ch, mod) = parseNameAboveHeader(ln) {
                flushDialogue(&dialogueBlock, into: &currentBlocks)
                flushUnattributed(&unattributedLines, into: &currentBlocks)
                dialogueBlock = (character: ch, modifier: mod, lines: [])
                continue
            }

            // ── Inside dialogue block ──
            if var db = dialogueBlock {
                if ln.isEmpty {
                    // Empty line in dialogue = internal pause (spec 4.3)
                    db.lines.append("")
                    dialogueBlock = db
                } else if isNewBlockStart(ln) {
                    // New dialogue/scene/action → end this block, re-process
                    flushDialogue(&dialogueBlock, into: &currentBlocks)
                    idx -= 1 // backtrack
                } else {
                    db.lines.append(ln)
                    dialogueBlock = db
                }
                continue
            }

            // ── Inside unattributed block ──
            if var ul = unattributedLines {
                if ln.isEmpty {
                    ul.append("")
                    unattributedLines = ul
                } else if isNewBlockStart(ln) {
                    flushUnattributed(&unattributedLines, into: &currentBlocks)
                    idx -= 1
                } else if ln.hasPrefix("> ") || ln == ">" {
                    let text = ln.hasPrefix("> ") ? String(ln.dropFirst(2)) : ""
                    ul.append(text)
                    unattributedLines = ul
                } else {
                    flushUnattributed(&unattributedLines, into: &currentBlocks)
                    currentBlocks.append(.action(SWSActionBlock(text: ln)))
                }
                continue
            }

            // ── Plain line ──
            if ln.isEmpty {
                currentBlocks.append(.emptyLine)
            } else {
                currentBlocks.append(.action(SWSActionBlock(text: ln)))
            }
        }

        // ── Flush pending ──
        flushDialogue(&dialogueBlock, into: &currentBlocks)
        flushUnattributed(&unattributedLines, into: &currentBlocks)
        // Strip trailing empty lines (artifact of serialize's trailing \n)
        while let last = currentBlocks.last, case .emptyLine = last {
            currentBlocks.removeLast()
        }
        if !currentBlocks.isEmpty || currentHeading != nil {
            scenes.append(SWSScene(heading: currentHeading, blocks: currentBlocks))
        }

        return SWSDocument(metadata: meta, scenes: scenes)
    }

    // MARK: - Helpers

    private var line: String { lines[idx] }
    private var eof: Bool { idx >= lines.count }
    private mutating func advance() { idx += 1 }

    /// 触发新 block 的行（结束当前对白/未标注块）
    ///
    /// 对白块只在遇到显式标记时结束：场景头、新角色、引号对白。
    /// 普通文本行在对白块内视为台词延续（spec 4.3），
    /// 如有需要，用户可通过编辑器右键修正拆分为动作块。
    private func isNewBlockStart(_ ln: String) -> Bool {
        ln.hasPrefix("## ") || ln.hasPrefix("> ") || ln == ">"
            || parseInlineDialogue(ln) != nil
            || parseNameAboveHeader(ln) != nil
    }

    private mutating func flushDialogue(
        _ db: inout (character: String, modifier: String?, lines: [String])?,
        into blocks: inout [SWSBlock]
    ) {
        guard let b = db else { return }
        // Trim trailing empty lines — they're block separators, not content
        var lines = b.lines
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        guard !lines.isEmpty else { db = nil; return }
        blocks.append(.dialogue(SWSDialogueBlock(character: b.character, modifier: b.modifier, lines: lines)))
        db = nil
    }

    private mutating func flushUnattributed(
        _ ul: inout [String]?,
        into blocks: inout [SWSBlock]
    ) {
        guard let l = ul else { ul = nil; return }
        var lines = l
        // Trim trailing empty lines (serialize artifact) but keep single bare empty
        while lines.count > 1, let last = lines.last, last.isEmpty { lines.removeLast() }
        guard !lines.isEmpty else { ul = nil; return }
        blocks.append(.unattributed(SWSUnattributedBlock(lines: lines)))
        ul = nil
    }

    // MARK: - Front matter

    private mutating func parseFrontMatter(_ ln: String, into meta: inout SWSMetadata) {
        let parts = ln.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { warn("无法解析 YAML 行: \(ln)"); return }
        switch parts[0] {
        case "sws":           meta.sws = parts[1]
        case "title":         meta.title = parts[1]
        case "author":        meta.author = parts[1]
        case "created":       meta.created = parts[1]
        case "source_format": meta.sourceFormat = parts[1]
        default:              meta.extra[parts[0]] = parts[1]
        }
    }

    // MARK: - Scene heading

    private mutating func parseSceneHeading(_ ln: String) -> SWSSceneHeading {
        let content = String(ln.dropFirst(3))
        // Try known separators in priority order
        for sep in [" · ", " - ", "  ", " "] {
            let parts = content.components(separatedBy: sep)
            guard parts.count >= 2 else { continue }
            let number = extractNumber(parts[0])

            if parts.count == 2 {
                if let ie = detectIE(parts[1]) {
                    return SWSSceneHeading(number: number, interiorExterior: ie, separator: sep)
                }
                return SWSSceneHeading(number: number, location: parts[1], separator: sep)
            }
            if parts.count == 3 {
                if let ie = detectIE(parts[1]) {
                    return SWSSceneHeading(number: number, interiorExterior: ie, location: parts[2], separator: sep)
                }
                return SWSSceneHeading(number: number, location: parts[1], time: parts[2], separator: sep)
            }
            // 4 parts: number / IE / location / time
            return SWSSceneHeading(
                number: number,
                interiorExterior: detectIE(parts[1]),
                location: parts.count > 2 ? parts[2] : nil,
                time: parts.count > 3 ? parts[3] : nil,
                separator: sep
            )
        }

        // Fallback: bare heading
        let number = extractNumber(content)
        return SWSSceneHeading(number: number, separator: " · ")
    }

    private func extractNumber(_ text: String) -> String {
        var s = text
        for t in ["第", "场", "章", "Scene", "scene", "Act", "act"] {
            s = s.replacingOccurrences(of: t, with: "")
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private func detectIE(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.contains("内景") || t == "内" { return "内景" }
        if t.contains("外景") || t == "外" { return "外景" }
        if t.uppercased() == "INT." || t.uppercased() == "INT" { return "内景" }
        if t.uppercased() == "EXT." || t.uppercased() == "EXT" { return "外景" }
        if t.uppercased().contains("I/E.") || t.uppercased().contains("INT/EXT") { return "内景/外景" }
        return nil
    }

    // MARK: - Inline dialogue: [name]：text  or [name | mod]：text

    private func parseInlineDialogue(_ ln: String) -> (character: String, modifier: String?, text: String)? {
        guard ln.hasPrefix("[") else { return nil }
        guard let close = ln.firstIndex(of: "]") else { return nil }
        let inside = String(ln[ln.index(after: ln.startIndex)..<close])
        let after = String(ln[ln.index(after: close)...])

        // Must be followed by ： (fullwidth colon)
        guard after.hasPrefix("：") else { return nil }

        let text = String(after.dropFirst()).trimmingCharacters(in: .whitespaces)

        if let pipe = inside.firstIndex(of: "|") {
            let name = inside[..<pipe].trimmingCharacters(in: .whitespaces)
            let mod = inside[inside.index(after: pipe)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            return (name, mod.isEmpty ? nil : mod, text)
        }
        let name = inside.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return (name, nil, text)
    }

    // MARK: - Name-above header: [name] or [name | mod]

    private func parseNameAboveHeader(_ ln: String) -> (character: String, modifier: String?)? {
        guard ln.hasPrefix("[") && ln.hasSuffix("]") else { return nil }
        let inside = String(ln.dropFirst().dropLast())
        guard !inside.contains("：") && !inside.contains(":") else { return nil }

        if let pipe = inside.firstIndex(of: "|") {
            let name = inside[..<pipe].trimmingCharacters(in: .whitespaces)
            let mod = inside[inside.index(after: pipe)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            return (name, mod.isEmpty ? nil : mod)
        }
        let name = inside.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return (name, nil)
    }

    // MARK: - Warning

    private mutating func warn(_ msg: String) {
        warnings.append(SWSFormatter.Warning(line: idx + 1, message: msg))
    }
}
