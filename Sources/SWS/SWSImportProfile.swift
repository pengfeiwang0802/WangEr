import Foundation

// MARK: - SWSImportProfile
/// 导入规则 Profile —— 描述「原始剧本是按什么规则写的」
/// Display Style 的反向应用，指导系统从外部格式提取结构化信息。
/// 从 SWSModel.swift 拆分而来（2026-09）。预留：未来 ImportParser 的规则承载对象。

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

