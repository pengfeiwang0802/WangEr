import Foundation

// MARK: - SWS Formatter

/// SWS 序列化器 —— .sws 文本 ↔ SWSModel 双向转换。
///
/// 设计要点：
/// - 序列化：Timeline → .sws，格式唯一（nameAbove）
/// - 反序列化：只认序列化器产出的格式，不做格式兼容
/// - Round-trip：deserialize(serialize(doc)) == doc
public struct SWSFormatter {
    // MARK: - Types

    /// 反序列化过程中遇到的警告（不阻断解析）
    public struct Warning: Equatable, CustomStringConvertible {
        let line: Int
        let message: String
        public var description: String { "L\(line): \(message)" }
    }

    // MARK: - Properties

    private var warnings: [Warning] = []

    // MARK: - Init

    public init() {}

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
                }
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private func writeDialogue(_ d: SWSDialogueBlock, to lines: inout [String]) {
        let header = d.modifier.map { "[\(d.character) | \($0)]" } ?? "[\(d.character)]"
        lines.append(header)
        lines.append(d.line)
    }

    private func writeUnattributed(_ u: SWSUnattributedBlock, to lines: inout [String]) {
        for line in u.lines {
            lines.append(line.isEmpty ? ">" : "> \(line)")
        }
    }

    // MARK: - Deserialize (.sws text → SWSDocument)

    /// 将序列化器产出的 .sws 文本反序列化为 SWSDocument。
    ///
    /// 只认一种格式——序列化器自己写的格式。
    /// 外部格式的解析留给未来的 ImportParser。
    public mutating func deserialize(_ text: String) -> SWSDocument {
        warnings = []
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return SWSDocument() }

        let rawLines = text.components(separatedBy: "\n")
        var meta = SWSMetadata()
        var scenes: [SWSScene] = []
        var currentBlocks: [SWSBlock] = []
        var currentHeading: SWSSceneHeading? = nil

        // State
        var pendingDialogue: (character: String, modifier: String?)? = nil
        var unattributedLines: [String] = []

        var idx = 0

        // ── YAML front matter ──
        if idx < rawLines.count && rawLines[idx] == "---" {
            idx += 1
            while idx < rawLines.count && rawLines[idx] != "---" {
                parseFrontMatter(rawLines[idx], into: &meta, lineNum: idx + 1)
                idx += 1
            }
            if idx < rawLines.count { idx += 1 } // skip closing ---
        }

        // ── Skip leading empty lines ──
        while idx < rawLines.count && rawLines[idx].isEmpty { idx += 1 }

        // ── Helpers ──
        func flushScene() {
            flushUnattributed()
            if !currentBlocks.isEmpty || currentHeading != nil {
                scenes.append(SWSScene(heading: currentHeading, blocks: currentBlocks))
                currentBlocks = []
                currentHeading = nil
            }
        }

        func flushUnattributed() {
            guard !unattributedLines.isEmpty else { return }
            var lines = unattributedLines
            while lines.count > 1, let last = lines.last, last.isEmpty { lines.removeLast() }
            currentBlocks.append(.unattributed(SWSUnattributedBlock(lines: lines)))
            unattributedLines = []
        }

        func flushPendingDialogue() {
            // Pending dialogue with no text → dropped (shouldn't happen with serializer output)
            pendingDialogue = nil
        }

        // ── Body ──
        while idx < rawLines.count {
            let ln = rawLines[idx]
            idx += 1

            // Scene heading
            if ln.hasPrefix("## ") {
                flushPendingDialogue()
                flushScene()
                currentHeading = parseSceneHeading(ln)
                continue
            }

            // Unattributed
            if ln.hasPrefix("> ") || ln == ">" {
                flushPendingDialogue()
                let text = ln.hasPrefix("> ") ? String(ln.dropFirst(2)) : ""
                unattributedLines.append(text)
                continue
            }

            // Name-above header: [name] or [name | mod]
            if let (ch, mod) = parseHeader(ln) {
                flushPendingDialogue()
                flushUnattributed()
                pendingDialogue = (ch, mod)
                continue
            }

            // Pending dialogue: this line IS the dialogue text
            if let db = pendingDialogue {
                flushUnattributed()
                currentBlocks.append(.dialogue(SWSDialogueBlock(character: db.character, modifier: db.modifier, line: ln)))
                pendingDialogue = nil
                continue
            }

            // Inside unattributed
            if !unattributedLines.isEmpty {
                // Empty line ends unattributed block
                if ln.isEmpty {
                    flushUnattributed()
                } else {
                    // Any non-empty, non-`>` non-header line ends unattributed and starts action
                    flushUnattributed()
                    currentBlocks.append(.action(SWSActionBlock(text: ln)))
                }
                continue
            }

            // Empty line → skip (visual separator)
            if ln.isEmpty { continue }

            // Plain text → action
            currentBlocks.append(.action(SWSActionBlock(text: ln)))
        }

        // ── Flush ──
        flushPendingDialogue()
        flushUnattributed()
        if !currentBlocks.isEmpty || currentHeading != nil {
            scenes.append(SWSScene(heading: currentHeading, blocks: currentBlocks))
        }

        return SWSDocument(metadata: meta, scenes: scenes)
    }

    /// 上次反序列化产生的警告
    public var lastWarnings: [Warning] { warnings }

    // MARK: - YAML front matter

    private mutating func parseFrontMatter(_ ln: String, into meta: inout SWSMetadata, lineNum: Int) {
        let parts = ln.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { warn("无法解析 YAML 行: \(ln)", line: lineNum); return }
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

    /// 解析场景头：`## 第N场 · 内景 · 地点 · 时间`
    public static func parseSceneHeading(_ text: String) -> SWSSceneHeading {
        let ln = text.hasPrefix("##") ? text : "## " + text
        return _parseSceneHeadingImpl(ln)
    }

    public func parseSceneHeadingLine(_ text: String) -> SWSSceneHeading {
        Self.parseSceneHeading(text)
    }

    private static func _parseSceneHeadingImpl(_ ln: String) -> SWSSceneHeading {
        let content = String(ln.dropFirst(3))
        let parts = content.components(separatedBy: " · ")
        let number = _extractNumber(parts[0])
        let ie = parts.count > 1 ? _detectIE(parts[1]) : nil
        let location = parts.count > 2 ? parts[2] : (parts.count > 1 && ie == nil ? parts[1] : nil)
        let time = parts.count > 3 ? parts[3] : (parts.count > 2 && ie != nil ? parts[2] : nil)
        return SWSSceneHeading(number: number, interiorExterior: ie, location: location, time: time, separator: " · ")
    }

    private static func _extractNumber(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "第", with: "")
            .replacingOccurrences(of: "场", with: "")
            .trimmingCharacters(in: .whitespaces)
        if let match = s.range(of: #"^\d+"#, options: .regularExpression) {
            return String(s[match])
        }
        return s
    }

    private static func _detectIE(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.contains("内景") || t == "内" { return "内景" }
        if t.contains("外景") || t == "外" { return "外景" }
        return nil
    }

    private mutating func parseSceneHeading(_ ln: String) -> SWSSceneHeading {
        return Self._parseSceneHeadingImpl(ln)
    }

    // MARK: - Name-above header

    /// 解析角色头：`[name]` 或 `[name | mod]`
    private func parseHeader(_ ln: String) -> (String, String?)? {
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

    private mutating func warn(_ msg: String, line: Int) {
        warnings.append(Warning(line: line, message: msg))
    }
}
