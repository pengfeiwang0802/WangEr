import Foundation

// MARK: - SWS Renderer

/// SWSModel → HTML 字符串渲染器。
///
/// 纯函数设计，不持有状态。一次传入文档 + 显示风格，返回完整 HTML。
/// 输出 HTML 内嵌 CSS，可直接被 WKWebView 加载。
///
/// 用法：
/// ```swift
/// let html = SWSRenderer.render(document: doc, style: .chineseStandard)
/// webView.loadHTMLString(html, baseURL: nil)
/// ```
public enum SWSRenderer {

    // MARK: - 角色颜色

    /// 12 种高对比度角色颜色（色盲友好）
    public static let characterColorPalette: [String] = [
        "#E74C3C", // 红
        "#3498DB", // 蓝
        "#2ECC71", // 绿
        "#F39C12", // 橙
        "#9B59B6", // 紫
        "#1ABC9C", // 青
        "#E67E22", // 橙红
        "#2980B9", // 深蓝
        "#27AE60", // 深绿
        "#D35400", // 橙褐
        "#8E44AD", // 深紫
        "#16A085", // 深青
    ]

    /// 从文档中提取所有角色并分配颜色（全局一致，跨场景）
    public static func buildCharacterColorMap(document: SWSDocument) -> [String: String] {
        let characters = document.allCharacters
        var map: [String: String] = [:]
        for (i, name) in characters.enumerated() {
            map[name] = characterColorPalette[i % characterColorPalette.count]
        }
        return map
    }

    // MARK: - Public API

    /// 渲染完整 HTML 文档
    /// - Parameters:
    ///   - document: 待渲染的剧本
    ///   - style: 显示风格（预设或自定义）
    ///   - extraCSS: 额外的 CSS 规则（可选，用于主题覆盖）
    ///   - characterColors: 角色→颜色映射（可选，用于角色染色）
    ///   - editable: 是否输出 contenteditable="true"（默认 true，编辑器用；false = 只读预览）
    /// - Returns: 完整 HTML 字符串
    public static func render(
        document: SWSDocument,
        style: DisplayStyle = .chineseStandard,
        extraCSS: String? = nil,
        characterColors: [String: String]? = nil,
        editable: Bool = true
    ) -> String {
        let body = renderBody(document: document, style: style, characterColors: characterColors, editable: editable)
        let css = buildCSS(style: style, extraCSS: extraCSS, characterColors: characterColors, editable: editable)
        return """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <style>
        \(css)
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    /// 仅渲染 `<body>` 内部内容（可用于增量更新）
    public static func renderBody(
        document: SWSDocument,
        style: DisplayStyle = .chineseStandard,
        characterColors: [String: String]? = nil,
        editable: Bool = true
    ) -> String {
        var html = ""

        // 标题 / 作者（inline style 确保不依赖外部 CSS）
        if let title = document.metadata.title {
            html += "<div class=\"sws-title\" style=\"font-size:20px;font-weight:bold;text-align:center;margin-bottom:8px\">\(escapeHTML(title))</div>"
        }
        if let author = document.metadata.author {
            html += "<div class=\"sws-author\" style=\"font-size:14px;text-align:center;color:#666;margin-bottom:24px\">\(escapeHTML(author))</div>"
        }

        // 场景
        for (sceneIndex, scene) in document.scenes.enumerated() {
            html += renderScene(scene, index: sceneIndex, style: style, characterColors: characterColors, editable: editable)
        }

        return html
    }

    // MARK: - Scene Rendering

    /// 渲染一场戏
    private static func renderScene(
        _ scene: SWSScene,
        index: Int,
        style: DisplayStyle,
        characterColors: [String: String]? = nil,
        editable: Bool = true
    ) -> String {
        let anchorId = scene.sceneId ?? "scene-idx-\(index)"
        var html = "<div class=\"sws-scene\" id=\"\(anchorId)\" data-scene=\"\(index)\">"

        // 场景头
        if let heading = scene.heading {
            let headingHTML = renderSceneHeading(heading, style: style, editable: editable)
            html += headingHTML
        }

        // 块
        for (blockIndex, block) in scene.blocks.enumerated() {
            html += renderBlock(block, sceneIndex: index, blockIndex: blockIndex, style: style, characterColors: characterColors, editable: editable)
        }

        html += "</div>"

        // 场间分隔
        html += renderSceneSeparator(style: style)

        return html
    }

    // MARK: - Scene Heading

    /// 渲染场景头
    private static func renderSceneHeading(
        _ heading: SWSSceneHeading,
        style: DisplayStyle,
        editable: Bool = true
    ) -> String {
        let sh = style.sceneHeading
        let text = heading.swsText
        let align = sh.alignment
        let fontSize = sh.font.size
        let ce = editable ? " contenteditable=\"true\"" : ""

        return """
        <div\(ce) class="sws-scene-heading" data-sws-type="scene-heading" data-line-type="scene-heading" style="text-align:\(align);font-size:\(fontSize)px;font-weight:\(sh.font.bold ? "bold" : "normal");margin-bottom:\(sh.marginBottom)px">
        \(escapeHTML(text))
        </div>
        """
    }

    // MARK: - Block Rendering

    /// 渲染一个块
    private static func renderBlock(
        _ block: SWSBlock,
        sceneIndex: Int,
        blockIndex: Int,
        style: DisplayStyle,
        characterColors: [String: String]? = nil,
        editable: Bool = true
    ) -> String {
        switch block {
        case .dialogue(let d):
            return renderDialogue(d, sceneIndex: sceneIndex, blockIndex: blockIndex, style: style, characterColors: characterColors, editable: editable)
        case .action(let a):
            return renderAction(a, sceneIndex: sceneIndex, blockIndex: blockIndex, style: style, editable: editable)
        case .unattributed(let u):
            return renderUnattributed(u, sceneIndex: sceneIndex, blockIndex: blockIndex, style: style, editable: editable)
        case .emptyLine:
            return renderEmptyLine(style: style)
        }
    }

    // MARK: - Dialogue

    /// 渲染对白块
    private static func renderDialogue(
        _ d: SWSDialogueBlock,
        sceneIndex: Int,
        blockIndex: Int,
        style: DisplayStyle,
        characterColors: [String: String]? = nil,
        editable: Bool = true
    ) -> String {
        let ds = style.dialogue
        let bracketType = ds.modifierBracketType
        let modifierHTML: String
        if let modifier = d.modifier, !modifier.isEmpty {
            modifierHTML = renderModifier(modifier, style: ds.modifierStyle, bracketType: bracketType)
        } else {
            modifierHTML = ""
        }
        let ce = editable ? " contenteditable=\"true\"" : ""

        let lineHTML = escapeHTML(d.line)

        // 角色名显示文本（带可选的方括号包裹）
        let displayName: String = {
            let raw = escapeHTML(d.character)
            switch ds.nameBracket {
            case .none:   return raw
            case .square: return "【" + raw + "】"
            }
        }()

        // 角色颜色
        let charColor = characterColors?[d.character] ?? "#5bc0de"
        let charBgColor = charColor + "18" // 18 = ~10% 透明度

        switch ds.layout {
        case .nameAboveText:
            // 角色名居中，台词换行缩进
            return """
            <div class="sws-dialogue" data-sws-type="dialogue" data-character="\(escapeHTML(d.character))" data-scene="\(sceneIndex)" data-block="\(blockIndex)" style="margin-bottom:\(ds.marginBetweenDialogues)px;border-left:2px solid \(charColor);padding-left:8px;background:\(charBgColor)">
            <div \(ce) class="sws-dialogue-name" data-line-type="dialogue-name" data-character="\(escapeHTML(d.character))" style="text-align:\(ds.nameAlignment);font-size:\(ds.nameFont.size)px;font-weight:\(ds.nameFont.bold ? "bold" : "normal");color:\(charColor)">\(displayName)\(modifierHTML)</div>
            <div \(ce) class="sws-dialogue-text" data-line-type="dialogue-text" data-character="\(escapeHTML(d.character))" style="padding-left:\(ds.textIndentChars)em;font-size:\(ds.textFont.size)px;color:\(charColor)">\(lineHTML)</div>
            </div>
            """

        case .nameInlineColon:
            // 角色名：台词（同行）
            return """
            <div class="sws-dialogue" data-sws-type="dialogue" data-character="\(escapeHTML(d.character))" data-scene="\(sceneIndex)" data-block="\(blockIndex)" style="margin-bottom:\(ds.marginBetweenDialogues)px;border-left:2px solid \(charColor);padding-left:8px;background:\(charBgColor)">
            <span \(ce) class="sws-dialogue-name" data-line-type="dialogue-name" data-character="\(escapeHTML(d.character))" style="font-size:\(ds.nameFont.size)px;font-weight:\(ds.nameFont.bold ? "bold" : "normal");color:\(charColor)">\(displayName)\(modifierHTML)\(ds.separator)</span>
            <span \(ce) class="sws-dialogue-text" data-line-type="dialogue-text" data-character="\(escapeHTML(d.character))" style="font-size:\(ds.textFont.size)px;color:\(charColor)">\(lineHTML)</span>
            </div>
            """

        case .nameInlineDash:
            // 角色名——台词（同行）
            return """
            <div class="sws-dialogue" data-sws-type="dialogue" data-character="\(escapeHTML(d.character))" data-scene="\(sceneIndex)" data-block="\(blockIndex)" style="margin-bottom:\(ds.marginBetweenDialogues)px;border-left:2px solid \(charColor);padding-left:8px;background:\(charBgColor)">
            <span \(ce) class="sws-dialogue-name" data-line-type="dialogue-name" data-character="\(escapeHTML(d.character))" style="font-size:\(ds.nameFont.size)px;font-weight:\(ds.nameFont.bold ? "bold" : "normal");color:\(charColor)">\(displayName)\(modifierHTML)\(ds.separator)</span>
            <span \(ce) class="sws-dialogue-text" data-line-type="dialogue-text" data-character="\(escapeHTML(d.character))" style="font-size:\(ds.textFont.size)px;color:\(charColor)">\(lineHTML)</span>
            </div>
            """

        case .nameLeftTextIndent:
            // 角色名顶格，台词换行缩进
            return """
            <div class="sws-dialogue" data-sws-type="dialogue" data-character="\(escapeHTML(d.character))" data-scene="\(sceneIndex)" data-block="\(blockIndex)" style="margin-bottom:\(ds.marginBetweenDialogues)px;border-left:2px solid \(charColor);padding-left:8px;background:\(charBgColor)">
            <div \(ce) class="sws-dialogue-name" data-line-type="dialogue-name" data-character="\(escapeHTML(d.character))" style="text-align:\(ds.nameAlignment);font-size:\(ds.nameFont.size)px;font-weight:\(ds.nameFont.bold ? "bold" : "normal");color:\(charColor)">\(displayName)\(modifierHTML)</div>
            <div \(ce) class="sws-dialogue-text" data-line-type="dialogue-text" data-character="\(escapeHTML(d.character))" style="padding-left:\(ds.textIndentChars)em;font-size:\(ds.textFont.size)px;color:\(charColor)">\(lineHTML)</div>
            </div>
            """
        }
    }

    // MARK: - Modifier

    /// 渲染修饰语
    private static func renderModifier(_ modifier: String, style: ModifierStyle, bracketType: ModifierBracketType = .chineseParens) -> String {
        let left = bracketType.left
        let right = bracketType.right
        switch style {
        case .parentheses:
            return left + escapeHTML(modifier) + right
        case .parenthesesSmall:
            return "<small>" + left + escapeHTML(modifier) + right + "</small>"
        case .superscript:
            return "<sup>" + left + escapeHTML(modifier) + right + "</sup>"
        case .inlineItalic:
            return " <em>" + left + escapeHTML(modifier) + right + "</em>"
        }
    }

    // MARK: - Action

    /// 渲染动作块
    private static func renderAction(
        _ a: SWSActionBlock,
        sceneIndex: Int,
        blockIndex: Int,
        style: DisplayStyle,
        editable: Bool = true
    ) -> String {
        let as_ = style.action
        let ce = editable ? " contenteditable=\"true\"" : ""
        return """
        <div\(ce) class="sws-action" data-sws-type="action" data-line-type="action" data-scene="\(sceneIndex)" data-block="\(blockIndex)" style="font-size:\(as_.font.size)px;text-align:\(as_.alignment);text-indent:\(as_.firstLineIndentChars)em">
        \(escapeHTML(a.text))
        </div>
        """
    }

    // MARK: - Unattributed

    /// 渲染未标注对白块
    private static func renderUnattributed(
        _ u: SWSUnattributedBlock,
        sceneIndex: Int,
        blockIndex: Int,
        style: DisplayStyle,
        editable: Bool = true
    ) -> String {
        let ds = style.dialogue
        let lineHTML = u.lines.map { line -> String in
            if line.isEmpty {
                return "<br>"
            }
            return escapeHTML(line)
        }.joined(separator: "\n")
        let ce = editable ? " contenteditable=\"true\"" : ""

        return """
        <div\(ce) class="sws-unattributed" data-sws-type="unattributed" data-line-type="unattributed" data-scene="\(sceneIndex)" data-block="\(blockIndex)" style="font-size:\(ds.textFont.size)px;padding-left:\(ds.textIndentChars)em;color:#888;font-style:italic">
        \(lineHTML)
        </div>
        """
    }

    // MARK: - Empty Line

    /// 渲染空行
    private static func renderEmptyLine(style: DisplayStyle) -> String {
        return """
        <div class="sws-empty-line"></div>
        """
    }

    // MARK: - Scene Separator

    /// 渲染场间分隔
    private static func renderSceneSeparator(style: DisplayStyle) -> String {
        switch style.sceneSeparator.style {
        case .blankLine:
            let count = max(1, style.sceneSeparator.count)
            return String(repeating: "<div class=\"sws-empty-line\"></div>", count: count)
        case .rule:
            return "<hr class=\"sws-scene-separator\">"
        case .pageBreak:
            return "<div class=\"sws-page-break\" style=\"page-break-after:always\"></div>"
        }
    }

    // MARK: - CSS Builder

    /// 构建内嵌 CSS
    private static func buildCSS(style: DisplayStyle, extraCSS: String? = nil, characterColors: [String: String]? = nil, editable: Bool = true) -> String {
        var css = """
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        body {
            font-family: -apple-system, "PingFang SC", "Noto Sans SC", "Microsoft YaHei", sans-serif;
            padding: 20px;
            line-height: 1.8;
            color: #1a1a1a;
            background: #ffffff;
        }
        .sws-title {
            font-size: 20px;
            font-weight: bold;
            text-align: center;
            margin-bottom: 8px;
        }
        .sws-author {
            font-size: 14px;
            text-align: center;
            color: #666;
            margin-bottom: 24px;
        }
        .sws-scene {
            margin-bottom: 0;
        }
        .sws-scene-heading {
            margin-top: 16px;
        }
        .sws-dialogue {
            margin-top: 4px;
        }
        .sws-dialogue-text {
            white-space: pre-wrap;
            word-wrap: break-word;
        }
        .sws-action {
            margin-top: 4px;
            white-space: pre-wrap;
            word-wrap: break-word;
        }
        .sws-unattributed {
            margin-top: 4px;
            white-space: pre-wrap;
            word-wrap: break-word;
        }
        .sws-empty-line {
            height: 1em;
        }
        .sws-scene-separator {
            border: none;
            border-top: 1px solid #ccc;
            margin: 16px 0;
        }
        .sws-page-break {
            height: 0;
        }
        """

        // 预览模式：禁止选中文本
        if !editable {
            css += """
        body {
            -webkit-user-select: none;
            user-select: none;
        }
        """
        }

        if let extra = extraCSS {
            css += "\n" + extra
        }

        return css
    }

    // MARK: - HTML Escaping

    /// 转义 HTML 特殊字符
    private static func escapeHTML(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: "&", with: "&amp;")
        result = result.replacingOccurrences(of: "<", with: "&lt;")
        result = result.replacingOccurrences(of: ">", with: "&gt;")
        result = result.replacingOccurrences(of: "\"", with: "&quot;")
        result = result.replacingOccurrences(of: "'", with: "&#39;")
        return result
    }
}
