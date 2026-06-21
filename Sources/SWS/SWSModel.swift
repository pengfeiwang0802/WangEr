import Foundation

// MARK: - SWS Document (顶层)

/// SWS 剧本完整文档 —— 内存中的唯一结构化表示。
///
/// 架构：
/// ```
/// SWSDocument → [SWSScene] → [SWSBlock]
///                                ├── .dialogue(SWSDialogueBlock)
///                                ├── .action(SWSActionBlock)
///                                ├── .unattributed(SWSUnattributedBlock)
///                                └── .emptyLine
/// ```
///
/// 所有类型为 `struct` + `let`，编辑操作返回新实例，天然适配 undo/redo。
/// COW（Copy on Write）保证大剧本拷贝开销极低。
public struct SWSDocument: Codable {
    public let metadata: SWSMetadata
    public let scenes: [SWSScene]

    public init(metadata: SWSMetadata = SWSMetadata(), scenes: [SWSScene] = []) {
        self.metadata = metadata
        self.scenes = scenes
    }

    // MARK: - 便捷访问

    /// 所有角色名（去重，按首次出场排序）
    public var allCharacters: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for scene in scenes {
            for name in scene.allCharacters where !seen.contains(name) {
                seen.insert(name)
                result.append(name)
            }
        }
        return result
    }

    /// 总块数（含空行）
    public var totalBlockCount: Int {
        scenes.reduce(0) { $0 + $1.blocks.count }
    }
}

// MARK: - Metadata

/// YAML front matter 元数据
public struct SWSMetadata: Codable {
    /// SWS 规范版本号（如 "1.0"）
    public var sws: String
    public var title: String?
    public var author: String?
    public var created: String?
    public var sourceFormat: String?

    /// 额外字段，自由扩展
    public var extra: [String: String]

    public init(
        sws: String = "1.0",
        title: String? = nil,
        author: String? = nil,
        created: String? = nil,
        sourceFormat: String? = nil,
        extra: [String: String] = [:]
    ) {
        self.sws = sws
        self.title = title
        self.author = author
        self.created = created
        self.sourceFormat = sourceFormat
        self.extra = extra
    }
}

// MARK: - Scene

/// 一场戏
public struct SWSScene: Codable {
    public let heading: SWSSceneHeading?
    public let blocks: [SWSBlock]

    public init(heading: SWSSceneHeading? = nil, blocks: [SWSBlock] = []) {
        self.heading = heading
        self.blocks = blocks
    }

    /// 本场所有出场角色（去重，按出场顺序）
    public var allCharacters: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for block in blocks {
            if case .dialogue(let d) = block, !seen.contains(d.character) {
                seen.insert(d.character)
                result.append(d.character)
            }
        }
        return result
    }

    /// 本场对白块数
    public var dialogueCount: Int {
        blocks.filter { if case .dialogue = $0 { true } else { false } }.count
    }

    /// 本场动作块数
    public var actionCount: Int {
        blocks.filter { if case .action = $0 { true } else { false } }.count
    }
}

// MARK: - Scene Heading

/// 场景头
///
/// SWS 格式：`## 第1场 · 内景 · 书房 · 日`
public struct SWSSceneHeading: Codable {
    /// 场号（纯数字，去掉「第」「场」）
    public let number: String
    /// 内景 / 外景
    public let interiorExterior: String?
    /// 地点
    public let location: String?
    /// 时间（日 / 夜 / 黄昏 …）
    public let time: String?
    /// 分隔符（记录原始使用的分隔符，序列化时还原）
    public let separator: String

    public init(
        number: String,
        interiorExterior: String? = nil,
        location: String? = nil,
        time: String? = nil,
        separator: String = " · "
    ) {
        self.number = number
        self.interiorExterior = interiorExterior
        self.location = location
        self.time = time
        self.separator = separator
    }

    /// 还原为标准 SWS 文本
    public var swsText: String {
        let parts = ["第\(number)场", interiorExterior, location, time]
            .compactMap { $0 }
        return "## " + parts.joined(separator: separator)
    }
}

// MARK: - Block Types

/// 剧本块 —— 一场戏内的一行或一组行
public enum SWSBlock: Codable {
    /// 对白（已绑定角色）
    case dialogue(SWSDialogueBlock)
    /// 动作 / 描述
    case action(SWSActionBlock)
    /// 对白（未标注角色，`> "..."` 前缀）
    case unattributed(SWSUnattributedBlock)
    /// 语义空行
    case emptyLine

    // MARK: Codable

    public enum CodingKeys: String, CodingKey {
        case type, value
    }

    public enum BlockType: String, Codable {
        case dialogue, action, unattributed, emptyLine
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(BlockType.self, forKey: .type)
        switch type {
        case .dialogue:
            self = .dialogue(try container.decode(SWSDialogueBlock.self, forKey: .value))
        case .action:
            self = .action(try container.decode(SWSActionBlock.self, forKey: .value))
        case .unattributed:
            self = .unattributed(try container.decode(SWSUnattributedBlock.self, forKey: .value))
        case .emptyLine:
            self = .emptyLine
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .dialogue(let d):
            try container.encode(BlockType.dialogue, forKey: .type)
            try container.encode(d, forKey: .value)
        case .action(let a):
            try container.encode(BlockType.action, forKey: .type)
            try container.encode(a, forKey: .value)
        case .unattributed(let u):
            try container.encode(BlockType.unattributed, forKey: .type)
            try container.encode(u, forKey: .value)
        case .emptyLine:
            try container.encode(BlockType.emptyLine, forKey: .type)
        }
    }
}

// MARK: - Dialogue Block

/// 对白块 —— 一个角色的一段台词
///
/// 多段对白（4.3 节）合并为一个 block，lines 数组保留空行节奏。
///
/// ```sws
/// [郑希远]
/// 第一段话。
///
/// 第二段话。
/// ```
/// → `SWSDialogueBlock(character: "郑希远", lines: ["第一段话。", "", "第二段话。"])`
public struct SWSDialogueBlock: Codable {
    /// 角色名（如 "郑希远"）
    public let character: String
    /// 修饰语（如 "笑道，拍桌子" / "VO"），nil 表示无修饰
    public let modifier: String?
    /// 台词行数组，空字符串表示段落间的空行
    public let lines: [String]

    public init(character: String, modifier: String? = nil, lines: [String] = []) {
        self.character = character
        self.modifier = modifier
        self.lines = lines
    }

    /// 去除空行后的纯台词文本
    public var textLines: [String] {
        lines.filter { !$0.isEmpty }
    }

    /// 台词总字数（不含空行和标点）
    public var characterCount: Int {
        textLines.reduce(0) { $0 + $1.count }
    }
}

// MARK: - Action Block

/// 动作 / 描述块
///
/// ```sws
/// 郑希远坐在书桌前，一脸愁容。
/// 窗外下起了雨。
/// ```
public struct SWSActionBlock: Codable {
    /// 文本内容（单行）
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

// MARK: - Unattributed Block

/// 未标注角色的对白块（`> "..."` 前缀）
///
/// ```sws
/// > "我知道你要说什么，"他顿了顿，"但我不想听。"
/// ```
public struct SWSUnattributedBlock: Codable {
    /// 台词行数组（与 SWSDialogueBlock 结构一致，但缺少角色绑定）
    public let lines: [String]

    public init(lines: [String] = []) {
        self.lines = lines
    }

    /// 去除空行后的纯台词文本
    public var textLines: [String] {
        lines.filter { !$0.isEmpty }
    }
}

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

    public let sceneHeading: SceneHeadingStyle
    public let dialogue: DialogueStyle
    public let action: ActionStyle
    public let sceneSeparator: SceneSeparatorConfig

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
}

public struct DialogueStyle: Codable {
    public let layout: DialogueLayout
    public let nameFont: FontStyle
    public let nameAlignment: String
    public let modifierStyle: ModifierStyle
    public let textIndentChars: Int
    public let textFont: FontStyle
    public let separator: String
    public let marginBetweenDialogues: Int
}

public struct ActionStyle: Codable {
    public let font: FontStyle
    public let firstLineIndentChars: Int
    public let alignment: String
}

public struct SceneSeparatorConfig: Codable {
    public let style: SceneSeparatorStyle
    public let count: Int
}

// MARK: - Import Profile

/// Import Profile —— 描述「原始剧本是按什么规则写的」
///
/// Display Style 的反向应用。指导系统从外部格式中提取结构化信息。
public struct ImportProfile: Codable {
    public let name: String
    /// 关联的 Display Style 名称
    public let basedOnStyle: String

    public let parsingRules: ParsingRules

    /// 预设 Import Profile
    static let chineseInlineColon = ImportProfile(
        name: "chinese_inline_colon",
        basedOnStyle: "chinese_inline",
        parsingRules: ParsingRules(
            sceneHeading: SceneHeadingParsing(
                patterns: ["第{n}场", "Scene {n}"],
                fieldOrder: ["场号", "内外景", "地点", "时间"],
                fieldSeparators: [" - ", " · ", "  "],
                caseSensitive: false
            ),
            dialogue: DialogueParsing(
                strategies: [
                    DialogueStrategy(
                        type: .nameColonInline,
                        pattern: "{name}：{text}",
                        nameBeforeModifier: true
                    ),
                    DialogueStrategy(
                        type: .nameColonInline,
                        pattern: "{name}{modifier}：{text}",
                        nameBeforeModifier: true,
                        modifierDelimiters: ["（", "）"]
                    ),
                    DialogueStrategy(
                        type: .nameSeparateLine,
                        pattern: "{name}\\n{text}",
                        nameLineMaxChars: 6
                    )
                ],
                continuationRules: ContinuationRules(
                    indentedLines: true,
                    quotedBlocks: true
                )
            ),
            action: ActionParsing(
                fallback: true,
                excludeIf: ["starts_with_name", "starts_with_scene_pattern"]
            ),
            characterNames: CharacterNameExtraction(
                source: "extract_from_text",
                extractionRules: ExtractionRules(
                    fromDialoguePrefix: true,
                    fromStandaloneShortLines: true,
                    minOccurrences: 2,
                    maxCharsCJK: 4,
                    maxCharsLatin: 20
                )
            )
        )
    )

    static let chineseNameAbove = ImportProfile(
        name: "chinese_name_above",
        basedOnStyle: "chinese_standard",
        parsingRules: ParsingRules(
            sceneHeading: SceneHeadingParsing(
                patterns: ["第{n}场"],
                fieldOrder: ["场号", "内外景", "地点", "时间"],
                fieldSeparators: [" - ", " · "],
                caseSensitive: false
            ),
            dialogue: DialogueParsing(
                strategies: [
                    DialogueStrategy(
                        type: .nameSeparateLine,
                        pattern: "{name}\\n{text}",
                        nameLineMaxChars: 6
                    )
                ],
                continuationRules: ContinuationRules(
                    indentedLines: true,
                    quotedBlocks: false
                )
            ),
            action: ActionParsing(
                fallback: true,
                excludeIf: ["starts_with_name", "starts_with_scene_pattern"]
            ),
            characterNames: CharacterNameExtraction(
                source: "extract_from_text",
                extractionRules: ExtractionRules(
                    fromDialoguePrefix: false,
                    fromStandaloneShortLines: true,
                    minOccurrences: 2,
                    maxCharsCJK: 4,
                    maxCharsLatin: 20
                )
            )
        )
    )

    static let autoDetect = ImportProfile(
        name: "auto_detect",
        basedOnStyle: "chinese_inline",
        parsingRules: ParsingRules(
            sceneHeading: SceneHeadingParsing(
                patterns: ["第{n}场", "Scene {n}", "{n}.", "{n}."],
                fieldOrder: ["场号", "内外景", "地点", "时间"],
                fieldSeparators: [" - ", " · ", "  ", " "],
                caseSensitive: false
            ),
            dialogue: DialogueParsing(
                strategies: [
                    DialogueStrategy(type: .nameColonInline, pattern: "{name}：{text}"),
                    DialogueStrategy(type: .nameColonInline, pattern: "{name}{modifier}：{text}",
                                     modifierDelimiters: ["（", "）"]),
                    DialogueStrategy(type: .nameDashInline, pattern: "{name}——{text}"),
                    DialogueStrategy(type: .nameSeparateLine, pattern: "{name}\\n{text}",
                                     nameLineMaxChars: 6),
                    DialogueStrategy(type: .quotedText, pattern: "\"{text}\""),
                ],
                continuationRules: ContinuationRules(
                    indentedLines: true,
                    quotedBlocks: true
                )
            ),
            action: ActionParsing(
                fallback: true,
                excludeIf: ["starts_with_name", "starts_with_scene_pattern"]
            ),
            characterNames: CharacterNameExtraction(
                source: "extract_from_text",
                extractionRules: ExtractionRules(
                    fromDialoguePrefix: true,
                    fromStandaloneShortLines: true,
                    minOccurrences: 1,
                    maxCharsCJK: 4,
                    maxCharsLatin: 20
                )
            )
        )
    )

    static let presets: [ImportProfile] = [
        .chineseInlineColon, .chineseNameAbove, .autoDetect
    ]
}

// MARK: - Import Profile Sub-types

public struct ParsingRules: Codable {
    public let sceneHeading: SceneHeadingParsing
    public let dialogue: DialogueParsing
    public let action: ActionParsing
    public let characterNames: CharacterNameExtraction
}

public struct SceneHeadingParsing: Codable {
    public let patterns: [String]
    public let fieldOrder: [String]
    public let fieldSeparators: [String]
    public let caseSensitive: Bool
}

public struct DialogueParsing: Codable {
    public let strategies: [DialogueStrategy]
    public let continuationRules: ContinuationRules
}

public enum DialogueStrategyType: String, Codable {
    case nameColonInline  = "name_colon_inline"
    case nameSeparateLine = "name_separate_line"
    case nameDashInline   = "name_dash_inline"
    case quotedText       = "quoted_text"
}

public struct DialogueStrategy: Codable {
    public let type: DialogueStrategyType
    public let pattern: String
    public var nameBeforeModifier: Bool?
    public var modifierDelimiters: [String]?
    public var nameLineMaxChars: Int?
}

public struct ContinuationRules: Codable {
    public let indentedLines: Bool
    public let quotedBlocks: Bool
}

public struct ActionParsing: Codable {
    public let fallback: Bool
    public let excludeIf: [String]
}

public struct CharacterNameExtraction: Codable {
    public let source: String
    public let extractionRules: ExtractionRules
}

public struct ExtractionRules: Codable {
    public let fromDialoguePrefix: Bool
    public let fromStandaloneShortLines: Bool
    public let minOccurrences: Int
    public let maxCharsCJK: Int
    public let maxCharsLatin: Int
}

// MARK: - 编辑器修正记录（项目级配置，不写入 .sws）

/// 一次用户修正操作
public struct Correction: Codable {
    /// 修正类型
    public enum Kind: String, Codable {
        case markAsDialogue  = "mark_as_dialogue"   // 这是对白
        case markAsAction    = "mark_as_action"      // 这是动作
        case setCharacter    = "set_character"       // 角色是 ___
        case changeCharacter = "change_character"     // 从「X」改到「Y」
    }

    public let kind: Kind
    /// 匹配该行的文本模式（用于后续自动匹配）
    public let pattern: String
    public let value: String?
    public let timestamp: Date

    public init(kind: Kind, pattern: String, value: String? = nil, timestamp: Date = Date()) {
        self.kind = kind
        self.pattern = pattern
        self.value = value
        self.timestamp = timestamp
    }
}

/// 项目的用户修正历史
public struct CorrectionLog: Codable {
    public var corrections: [Correction]

    public init(corrections: [Correction] = []) {
        self.corrections = corrections
    }

    /// 根据已有修正预测当前行的角色名
    public func predictCharacter(for text: String) -> String? {
        for c in corrections.reversed() {
            if c.kind == .setCharacter || c.kind == .changeCharacter {
                if text.contains(c.pattern) {
                    return c.value
                }
            }
        }
        return nil
    }

    /// 根据已有修正判断某行是否应为对白
    public func shouldBeDialogue(_ text: String) -> Bool? {
        for c in corrections.reversed() {
            if c.kind == .markAsDialogue && text.contains(c.pattern) {
                return true
            }
            if c.kind == .markAsAction && text.contains(c.pattern) {
                return false
            }
        }
        return nil
    }
}

// MARK: - 编辑器状态点

/// 编辑器增量校验的状态指示
public enum ValidationStatus {
    /// 已确认的对白或场景头
    case confirmed
    /// 待确认（如 `[角色名]` 独占一行，等待下一行）
    case pending
    /// 动作/描述
    case action
    /// 无标记（空行等）
    case none

    /// CSS 颜色类名（给 WKWebView 用）
    public var cssClass: String {
        switch self {
        case .confirmed: return "sws-status-confirmed"
        case .pending:   return "sws-status-pending"
        case .action:    return "sws-status-action"
        case .none:      return ""
        }
    }

    /// 状态点的十六进制颜色
    public var colorHex: String {
        switch self {
        case .confirmed: return "#22C55E"
        case .pending:   return "#3B82F6"
        case .action:    return "#9CA3AF"
        case .none:      return "transparent"
        }
    }
}

// MARK: - 行级校验结果

/// 一行的校验结果（编辑器运行时生成，不持久化）
public struct LineValidation {
    /// 该行的语义类型
    public let blockType: SWSBlock.BlockType
    /// 状态指示
    public let status: ValidationStatus
    /// 绑定的角色名（对白行有效）
    public let character: String?
    /// 当前对白块是否已结束（用于蓝色点的生命周期管理）
    public let dialogueBlockClosed: Bool

    public init(
        blockType: SWSBlock.BlockType,
        status: ValidationStatus,
        character: String? = nil,
        dialogueBlockClosed: Bool = false
    ) {
        self.blockType = blockType
        self.status = status
        self.character = character
        self.dialogueBlockClosed = dialogueBlockClosed
    }
}
