import Foundation

// MARK: - SWSConfig
/// 显示风格与导入规则配置（运行时/项目级，非 .sws 文档内容）
/// 从 SWSModel.swift 拆分而来（2026-09，架构层职责分离）
/// - DisplayStyle: 定义「.sws 在屏幕上长什么样」（Render 系）
/// - ImportProfile: 定义「原始剧本按什么规则写」（未来 ImportParser 系）

// MARK: - Display Style（运行时配置，非 .sws 内容）

/// 对白布局模式
public enum DialogueLayout: String, Codable, CaseIterable {
    case nameAboveText = "name_above_text"
    case nameInlineColon = "name_inline_colon"
    case nameInlineDash  = "name_inline_dash"
    case nameLeftTextIndent = "name_left_text_indent"

    public var displayName: String {
        switch self {
        case .nameAboveText:      return "角色名居中 + 台词换行缩进"
        case .nameInlineColon:    return "角色名：台词（同行）"
        case .nameInlineDash:     return "角色名——台词（同行）"
        case .nameLeftTextIndent: return "角色名顶格 + 台词换行缩进"
        }
    }
}

/// 修饰语显示方式
public enum ModifierStyle: String, Codable, CaseIterable {
    case parentheses       = "parentheses"
    case parenthesesSmall  = "parentheses_small"
    case superscript       = "superscript"
    case inlineItalic      = "inline_italic"

    public var displayName: String {
        switch self {
        case .parentheses:       return "括号（正常大小）"
        case .parenthesesSmall:  return "括号（小字）"
        case .superscript:       return "上标"
        case .inlineItalic:      return "斜体前置"
        }
    }
}

/// 修饰语括号类型
public enum ModifierBracketType: String, Codable, CaseIterable {
    case chineseParens = "chinese_parens"
    case englishParens = "english_parens"
    case squareBrackets = "square_brackets"
    case none = "none"

    public var displayName: String {
        switch self {
        case .chineseParens:   return "中文括号（）"
        case .englishParens:   return "英文括号()"
        case .squareBrackets:  return "方括号【】"
        case .none:            return "无括号"
        }
    }

    /// 左括号字符
    public var left: String {
        switch self {
        case .chineseParens:  return "（"
        case .englishParens:  return "("
        case .squareBrackets: return "【"
        case .none:           return ""
        }
    }

    /// 右括号字符
    public var right: String {
        switch self {
        case .chineseParens:  return "）"
        case .englishParens:  return ")"
        case .squareBrackets: return "】"
        case .none:           return ""
        }
    }
}

/// 角色名括号类型（用于 [角色名] 格式）
public enum NameBracketType: String, Codable, CaseIterable {
    case none = "none"
    case square = "square"

    public var displayName: String {
        switch self {
        case .none:   return "无括号"
        case .square: return "方括号【】"
        }
    }
}

/// 场间分隔样式
public enum SceneSeparatorStyle: String, Codable, CaseIterable {
    case blankLine  = "blank_line"
    case rule       = "rule"
    case pageBreak  = "page_break"
}

// MARK: - Display Style 定义

/// Display Style —— 定义「.sws 在屏幕上长什么样」
///
/// 与 .sws 文件分离存储（项目级配置）。
public struct DisplayStyle: Codable {
    public let name: String
    public let description: String

    /// 人类可读的短名称（括号前部分）
    public var displayName: String {
        description.components(separatedBy: "（").first ?? description
    }

    public let sceneHeading: SceneHeadingStyle
    public let dialogue: DialogueStyle
    public let action: ActionStyle
    public let sceneSeparator: SceneSeparatorConfig

    public init(name: String, description: String, sceneHeading: SceneHeadingStyle, dialogue: DialogueStyle, action: ActionStyle, sceneSeparator: SceneSeparatorConfig) {
        self.name = name
        self.description = description
        self.sceneHeading = sceneHeading
        self.dialogue = dialogue
        self.action = action
        self.sceneSeparator = sceneSeparator
    }

    /// 预设 Style
    public static let chineseStandard = DisplayStyle(
        name: "chinese_standard",
        description: "中国影视剧本标准格式（名字居中+台词缩进）",
        sceneHeading: SceneHeadingStyle(
            prefixTemplate: "第{number}场",
            fieldSeparator: " · ",
            font: FontStyle(bold: true, size: 16),
            alignment: "center",
            marginBottom: 24
        ),
        dialogue: DialogueStyle(
            layout: .nameAboveText,
            nameFont: FontStyle(bold: false, size: 14),
            nameAlignment: "center",
            modifierStyle: .parenthesesSmall,
            textIndentChars: 2,
            textFont: FontStyle(size: 14),
            separator: "——",
            marginBetweenDialogues: 8
        ),
        action: ActionStyle(
            font: FontStyle(size: 13),
            firstLineIndentChars: 2,
            alignment: "justify"
        ),
        sceneSeparator: SceneSeparatorConfig(style: .blankLine, count: 2)
    )

    public static let chineseInline = DisplayStyle(
        name: "chinese_inline",
        description: "中文同行冒号格式（名字：台词）",
        sceneHeading: SceneHeadingStyle(
            prefixTemplate: "第{number}场",
            fieldSeparator: " · ",
            font: FontStyle(bold: true, size: 16),
            alignment: "left",
            marginBottom: 20
        ),
        dialogue: DialogueStyle(
            layout: .nameInlineColon,
            nameFont: FontStyle(bold: true, size: 14),
            nameAlignment: "left",
            modifierStyle: .parentheses,
            textIndentChars: 0,
            textFont: FontStyle(size: 14),
            separator: "：",
            marginBetweenDialogues: 4
        ),
        action: ActionStyle(
            font: FontStyle(size: 13),
            firstLineIndentChars: 2,
            alignment: "justify"
        ),
        sceneSeparator: SceneSeparatorConfig(style: .blankLine, count: 2)
    )

    public static let stagePlay = DisplayStyle(
        name: "stage_play",
        description: "话剧院格式（名字顶格大写+台词缩进）",
        sceneHeading: SceneHeadingStyle(
            prefixTemplate: "第{number}场",
            fieldSeparator: " - ",
            font: FontStyle(bold: true, size: 16),
            alignment: "center",
            marginBottom: 24
        ),
        dialogue: DialogueStyle(
            layout: .nameLeftTextIndent,
            nameFont: FontStyle(bold: true, size: 14),
            nameAlignment: "left",
            modifierStyle: .parentheses,
            textIndentChars: 4,
            textFont: FontStyle(size: 14),
            separator: "",
            marginBetweenDialogues: 8
        ),
        action: ActionStyle(
            font: FontStyle(size: 13),
            firstLineIndentChars: 4,
            alignment: "left"
        ),
        sceneSeparator: SceneSeparatorConfig(style: .blankLine, count: 2)
    )

    public static let screenplayEnglish = DisplayStyle(
        name: "screenplay_english",
        description: "英文电影剧本标准格式",
        sceneHeading: SceneHeadingStyle(
            prefixTemplate: "Scene {number}",
            fieldSeparator: " - ",
            font: FontStyle(bold: true, size: 12),
            alignment: "left",
            marginBottom: 24
        ),
        dialogue: DialogueStyle(
            layout: .nameAboveText,
            nameFont: FontStyle(bold: false, size: 12),
            nameAlignment: "center",
            modifierStyle: .parentheses,
            textIndentChars: 4,
            textFont: FontStyle(size: 12),
            separator: "",
            marginBetweenDialogues: 4
        ),
        action: ActionStyle(
            font: FontStyle(size: 12),
            firstLineIndentChars: 0,
            alignment: "left"
        ),
        sceneSeparator: SceneSeparatorConfig(style: .blankLine, count: 2)
    )

    public static let novelStyle = DisplayStyle(
        name: "novel_style",
        description: "小说体（引号对白，行内叙述）",
        sceneHeading: SceneHeadingStyle(
            prefixTemplate: "第{number}章",
            fieldSeparator: " ",
            font: FontStyle(bold: true, size: 18),
            alignment: "center",
            marginBottom: 16
        ),
        dialogue: DialogueStyle(
            layout: .nameInlineColon,
            nameFont: FontStyle(bold: false, size: 13),
            nameAlignment: "left",
            modifierStyle: .inlineItalic,
            textIndentChars: 0,
            textFont: FontStyle(size: 13),
            separator: "",
            marginBetweenDialogues: 0
        ),
        action: ActionStyle(
            font: FontStyle(size: 13),
            firstLineIndentChars: 2,
            alignment: "justify"
        ),
        sceneSeparator: SceneSeparatorConfig(style: .blankLine, count: 1)
    )

    /// 所有预设
    public static let presets: [DisplayStyle] = [
        .chineseStandard, .chineseInline, .stagePlay, .screenplayEnglish, .novelStyle
    ]
}

// MARK: - Style Sub-types

public struct FontStyle: Codable {
    public var bold: Bool
    public var italic: Bool
    public var size: Int

    public init(bold: Bool = false, italic: Bool = false, size: Int = 14) {
        self.bold = bold
        self.italic = italic
        self.size = size
    }
}

public struct SceneHeadingStyle: Codable {
    public let prefixTemplate: String
    public let fieldSeparator: String
    public let font: FontStyle
    public let alignment: String
    public let marginBottom: Int

    public init(prefixTemplate: String = "第{number}场", fieldSeparator: String = " · ", font: FontStyle = FontStyle(), alignment: String = "center", marginBottom: Int = 24) {
        self.prefixTemplate = prefixTemplate
        self.fieldSeparator = fieldSeparator
        self.font = font
        self.alignment = alignment
        self.marginBottom = marginBottom
    }
}

public struct DialogueStyle: Codable {
    public let layout: DialogueLayout
    public let nameFont: FontStyle
    public let nameAlignment: String
    public let modifierStyle: ModifierStyle
    public let modifierBracketType: ModifierBracketType
    public let nameBracket: NameBracketType
    public let textIndentChars: Int
    public let textFont: FontStyle
    public let separator: String
    public let marginBetweenDialogues: Int

    public init(layout: DialogueLayout = .nameAboveText, nameFont: FontStyle = FontStyle(), nameAlignment: String = "center", modifierStyle: ModifierStyle = .parenthesesSmall, modifierBracketType: ModifierBracketType = .chineseParens, nameBracket: NameBracketType = .none, textIndentChars: Int = 2, textFont: FontStyle = FontStyle(), separator: String = "——", marginBetweenDialogues: Int = 8) {
        self.layout = layout
        self.nameFont = nameFont
        self.nameAlignment = nameAlignment
        self.modifierStyle = modifierStyle
        self.modifierBracketType = modifierBracketType
        self.nameBracket = nameBracket
        self.textIndentChars = textIndentChars
        self.textFont = textFont
        self.separator = separator
        self.marginBetweenDialogues = marginBetweenDialogues
    }
}

public struct ActionStyle: Codable {
    public let font: FontStyle
    public let firstLineIndentChars: Int
    public let alignment: String

    public init(font: FontStyle = FontStyle(size: 13), firstLineIndentChars: Int = 2, alignment: String = "justify") {
        self.font = font
        self.firstLineIndentChars = firstLineIndentChars
        self.alignment = alignment
    }
}

public struct SceneSeparatorConfig: Codable {
    public let style: SceneSeparatorStyle
    public let count: Int

    public init(style: SceneSeparatorStyle = .blankLine, count: Int = 2) {
        self.style = style
        self.count = count
    }
}

