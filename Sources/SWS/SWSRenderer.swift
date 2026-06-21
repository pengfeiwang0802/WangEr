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

    // MARK: - Public API

    /// 渲染完整 HTML 文档
    /// - Parameters:
    ///   - document: 待渲染的剧本
    ///   - style: 显示风格（预设或自定义）
    ///   - extraCSS: 额外的 CSS 规则（可选，用于主题覆盖）
    /// - Returns: 完整 HTML 字符串
    public static func render(
        document: SWSDocument,
        style: DisplayStyle = .chineseStandard,
        extraCSS: String? = nil
    ) -> String {
        let body = renderBody(document: document, style: style)
        let css = buildCSS(style: style, extraCSS: extraCSS)
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
        style: DisplayStyle = .chineseStandard
    ) -> String {
        var html = ""

        // 标题
        if let title = document.metadata.title {
            html += "<div class=\"sws-title\">\(escapeHTML(title))</div>"
        }
        if let author = document.metadata.author {
            html += "<div class=\"sws-author\">\(escapeHTML(author))</div>"
        }

        // 场景
        for (sceneIndex, scene) in document.scenes.enumerated() {
            html += renderScene(scene, index: sceneIndex, style: style)
        }

        return html
    }

    // MARK: - Scene Rendering

    /// 渲染一场戏
    private static func renderScene(
        _ scene: SWSScene,
        index: Int,
        style: DisplayStyle
    ) -> String {
        var html = "<div class=\"sws-scene\" data-scene=\"\(index)\">"

        // 场景头
        if let heading = scene.heading {
            let headingHTML = renderSceneHeading(heading, style: style)
            html += headingHTML
        }

        // 块
        for (blockIndex, block) in scene.blocks.enumerated() {
            html += renderBlock(block, sceneIndex: index, blockIndex: blockIndex, style: style)
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
        style: DisplayStyle
    ) -> String {
        let sh = style.sceneHeading
        let text = heading.swsText
        let align = sh.alignment
        let fontSize = sh.font.size

        return """
        <div class="sws-scene-heading" style="text-align:\(align);font-size:\(fontSize)px;font-weight:\(sh.font.bold ? "bold" : "normal");margin-bottom:\(sh.marginBottom)px">
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
        style: DisplayStyle
    ) -> String {
        switch block {
        case .dialogue(let d):
            return renderDialogue(d, sceneIndex: sceneIndex, blockIndex: blockIndex, style: style)
        case .action(let a):
            return renderAction(a, sceneIndex: sceneIndex, blockIndex: blockIndex, style: style)
        case .unattributed(let u):
            return renderUnattributed(u, sceneIndex: sceneIndex, blockIndex: blockIndex, style: style)
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
        style: DisplayStyle
    ) -> String {
        let ds = style.dialogue
        let modifierHTML: String
        if let modifier = d.modifier, !modifier.isEmpty {
            modifierHTML = renderModifier(modifier, style: ds.modifierStyle)
        } else {
            modifierHTML = ""
        }

        let linesHTML = d.lines.map { line -> String in
            if line.isEmpty {
                return "<br>"
            }
            return escapeHTML(line)
        }.joined(separator: "\n")

        switch ds.layout {
        case .nameAboveText:
            // 角色名居中，台词换行缩进
            return """
            <div class="sws-dialogue" data-sws-type="dialogue" data-scene="\(sceneIndex)" data-block="\(blockIndex)" style="margin-bottom:\(ds.marginBetweenDialogues)px">
            <div class="sws-dialogue-name" style="text-align:\(ds.nameAlignment);font-size:\(ds.nameFont.size)px;font-weight:\(ds.nameFont.bold ? "bold" : "normal")">\(escapeHTML(d.character))\(modifierHTML)</div>
            <div class="sws-dialogue-text" style="padding-left:\(ds.textIndentChars)em;font-size:\(ds.textFont.size)px">\(linesHTML)</div>
            </div>
            """

        case .nameInlineColon:
            // 角色名：台词（同行）
            return """
            <div class="sws-dialogue" data-sws-type="dialogue" data-scene="\(sceneIndex)" data-block="\(blockIndex)" style="margin-bottom:\(ds.marginBetweenDialogues)px">
            <span class="sws-dialogue-name" style="font-size:\(ds.nameFont.size)px;font-weight:\(ds.nameFont.bold ? "bold" : "normal")">\(escapeHTML(d.character))\(modifierHTML)\(ds.separator)</span>
            <span class="sws-dialogue-text" style="font-size:\(ds.textFont.size)px">\(linesHTML)</span>
            </div>
            """

        case .nameInlineDash:
            // 角色名——台词（同行）
            return """
            <div class="sws-dialogue" data-sws-type="dialogue" data-scene="\(sceneIndex)" data-block="\(blockIndex)" style="margin-bottom:\(ds.marginBetweenDialogues)px">
            <span class="sws-dialogue-name" style="font-size:\(ds.nameFont.size)px;font-weight:\(ds.nameFont.bold ? "bold" : "normal")">\(escapeHTML(d.character))\(modifierHTML)\(ds.separator)</span>
            <span class="sws-dialogue-text" style="font-size:\(ds.textFont.size)px">\(linesHTML)</span>
            </div>
            """

        case .nameLeftTextIndent:
            // 角色名顶格，台词换行缩进
            return """
            <div class="sws-dialogue" data-sws-type="dialogue" data-scene="\(sceneIndex)" data-block="\(blockIndex)" style="margin-bottom:\(ds.marginBetweenDialogues)px">
            <div class="sws-dialogue-name" style="text-align:\(ds.nameAlignment);font-size:\(ds.nameFont.size)px;font-weight:\(ds.nameFont.bold ? "bold" : "normal")">\(escapeHTML(d.character))\(modifierHTML)</div>
            <div class="sws-dialogue-text" style="padding-left:\(ds.textIndentChars)em;font-size:\(ds.textFont.size)px">\(linesHTML)</div>
            </div>
            """
        }
    }

    // MARK: - Modifier

    /// 渲染修饰语
    private static func renderModifier(_ modifier: String, style: ModifierStyle) -> String {
        switch style {
        case .parentheses:
            return "（" + escapeHTML(modifier) + "）"
        case .parenthesesSmall:
            return "<small>（" + escapeHTML(modifier) + "）</small>"
        case .superscript:
            return "<sup>（" + escapeHTML(modifier) + "）</sup>"
        case .inlineItalic:
            return " <em>（" + escapeHTML(modifier) + "）</em>"
        }
    }

    // MARK: - Action

    /// 渲染动作块
    private static func renderAction(
        _ a: SWSActionBlock,
        sceneIndex: Int,
        blockIndex: Int,
        style: DisplayStyle
    ) -> String {
        let as_ = style.action
        return """
        <div class="sws-action" data-sws-type="action" data-scene="\(sceneIndex)" data-block="\(blockIndex)" style="font-size:\(as_.font.size)px;text-align:\(as_.alignment);text-indent:\(as_.firstLineIndentChars)em">
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
        style: DisplayStyle
    ) -> String {
        let ds = style.dialogue
        let linesHTML = u.lines.map { line -> String in
            if line.isEmpty {
                return "<br>"
            }
            return escapeHTML(line)
        }.joined(separator: "\n")

        return """
        <div class="sws-unattributed" data-sws-type="unattributed" data-scene="\(sceneIndex)" data-block="\(blockIndex)" style="font-size:\(ds.textFont.size)px;padding-left:\(ds.textIndentChars)em;color:#888;font-style:italic">
        \(linesHTML)
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
    private static func buildCSS(style: DisplayStyle, extraCSS: String? = nil) -> String {
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
