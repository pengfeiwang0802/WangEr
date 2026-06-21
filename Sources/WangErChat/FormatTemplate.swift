import Foundation
import SWS

// MARK: - Format Template

/// 用户自定义格式模板 —— 组合显示规则 + 解析规则
///
/// 持久化为 JSON，存放在 `~/Library/Application Support/WangEr/templates/`
public struct FormatTemplate: Codable, Equatable {
    /// 唯一标识
    public let id: String
    /// 模板名称
    public var name: String
    /// 一句话描述
    public var description: String

    // 格式选项
    public var characterLayout: CharacterLayoutOption
    public var modifierBracket: ModifierBracketChoice
    public var sceneHeadingFormat: SceneHeadingFormatChoice

    public init(
        id: String = UUID().uuidString,
        name: String,
        description: String = "",
        characterLayout: CharacterLayoutOption = .nameOwnLine,
        modifierBracket: ModifierBracketChoice = .chineseParens,
        sceneHeadingFormat: SceneHeadingFormatChoice = .hashMark
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.characterLayout = characterLayout
        self.modifierBracket = modifierBracket
        self.sceneHeadingFormat = sceneHeadingFormat
    }

    /// 将模板转换为 DisplayStyle（用于渲染预览）
    public func toDisplayStyle() -> DisplayStyle {
        let (layout, separator, nameBracket): (DialogueLayout, String, NameBracketType) = {
            switch characterLayout {
            case .nameOwnLine:
                return (.nameAboveText, "", .none)
            case .nameColonSameLine:
                return (.nameInlineColon, "：", .none)
            case .bracketOwnLine:
                return (.nameAboveText, "", .square)
            case .bracketColonSameLine:
                return (.nameInlineColon, "：", .square)
            }
        }()

        let bracketType: ModifierBracketType = {
            switch modifierBracket {
            case .chineseParens:  return .chineseParens
            case .englishParens:  return .englishParens
            case .squareBrackets: return .squareBrackets
            case .none:           return .none
            }
        }()

        let heading: SceneHeadingStyle = {
            switch sceneHeadingFormat {
            case .hashMark:
                return SceneHeadingStyle(
                    prefixTemplate: "第{number}场",
                    fieldSeparator: " · ",
                    font: FontStyle(bold: true, size: 16),
                    alignment: "center",
                    marginBottom: 24
                )
            case .fieldPrefix:
                return SceneHeadingStyle(
                    prefixTemplate: "场{number}",
                    fieldSeparator: " · ",
                    font: FontStyle(bold: true, size: 16),
                    alignment: "center",
                    marginBottom: 24
                )
            case .plainNumber:
                return SceneHeadingStyle(
                    prefixTemplate: "{number}.",
                    fieldSeparator: " ",
                    font: FontStyle(bold: true, size: 16),
                    alignment: "left",
                    marginBottom: 20
                )
            }
        }()

        return DisplayStyle(
            name: name,
            description: name,
            sceneHeading: heading,
            dialogue: DialogueStyle(
                layout: layout,
                nameFont: FontStyle(bold: false, size: 14),
                nameAlignment: layout == .nameAboveText ? "center" : "left",
                modifierStyle: .parenthesesSmall,
                modifierBracketType: bracketType,
                nameBracket: nameBracket,
                textIndentChars: layout == .nameAboveText ? 2 : 0,
                textFont: FontStyle(size: 14),
                separator: separator,
                marginBetweenDialogues: 8
            ),
            action: ActionStyle(
                font: FontStyle(size: 13),
                firstLineIndentChars: 2,
                alignment: "justify"
            ),
            sceneSeparator: SceneSeparatorConfig(style: .blankLine, count: 2)
        )
    }
}

// MARK: - 格式选项枚举

/// 角色名 + 台词布局
public enum CharacterLayoutOption: String, Codable, CaseIterable {
    case nameOwnLine = "name_own_line"
    case nameColonSameLine = "name_colon_same"
    case bracketOwnLine = "bracket_own_line"
    case bracketColonSameLine = "bracket_colon_same"

    public var displayName: String {
        switch self {
        case .nameOwnLine:         return "角色居中独行 + 台词下行"
        case .nameColonSameLine:   return "角色名：台词（同行冒号）"
        case .bracketOwnLine:      return "[角色名]独行 + 台词下行"
        case .bracketColonSameLine: return "[角色名]：台词（同行）"
        }
    }
}

/// 修饰语括号
public enum ModifierBracketChoice: String, Codable, CaseIterable {
    case chineseParens = "chinese_parens"
    case englishParens = "english_parens"
    case squareBrackets = "square_brackets"
    case none = "none"

    public var displayName: String {
        switch self {
        case .chineseParens:  return "中文括号（）"
        case .englishParens:  return "英文括号()"
        case .squareBrackets: return "方括号【】"
        case .none:           return "无括号"
        }
    }
}

/// 场号格式
public enum SceneHeadingFormatChoice: String, Codable, CaseIterable {
    case hashMark = "hash_mark"
    case fieldPrefix = "field_prefix"
    case plainNumber = "plain_number"

    public var displayName: String {
        switch self {
        case .hashMark:    return "## 第N场 · 内景 · 地点 · 时间"
        case .fieldPrefix: return "场N · 内景 · 地点 · 时间"
        case .plainNumber: return "N. 内景 地点 时间"
        }
    }
}

/// 动作描述标记
public enum ActionMarkerChoice: String, Codable, CaseIterable {
    case none = "none"
    case angleBracket = "angle_bracket"
    case parensWrap = "parens_wrap"

    public var displayName: String {
        switch self {
        case .none:         return "无标记（纯文本）"
        case .angleBracket: return "> 开头标记"
        case .parensWrap:   return "（）括号包裹"
        }
    }
}

/// 台词结束判定
public enum DialogueEndRuleChoice: String, Codable, CaseIterable {
    case emptyLine = "empty_line"
    case nextCharacter = "next_character"
    case sameLineSwitch = "same_line_switch"

    public var displayName: String {
        switch self {
        case .emptyLine:       return "空行结束"
        case .nextCharacter:   return "遇下个角色名结束"
        case .sameLineSwitch:  return "同行换角色结束"
        }
    }
}

// MARK: - 样例文档

extension FormatTemplate {

    /// 写死的样例 SWS 文档，用于模板编辑器实时预览
    ///
    /// 覆盖所有格式选项：
    /// - 多角色（≥3）→ 颜色区分
    /// - 修饰语（多种括号风格）→ 中文/英文/方括号
    /// - 未归属对白（unattributed）
    /// - 多段台词（paragraph break）
    /// - 动作描述
    /// - 沉默/省略号
    public static let sampleDocument: SWSDocument = {
        SWSDocument(
            metadata: SWSMetadata(
                title: "雨夜",
                author: "王二"
            ),
            scenes: [
                // ── 第 1 场：内景 ──
                SWSScene(
                    heading: SWSSceneHeading(
                        number: "1",
                        interiorExterior: "内景",
                        location: "书房",
                        time: "夜"
                    ),
                    blocks: [
                        .action(SWSActionBlock(text: "窗外大雨滂沱。郑希远坐在书桌前，面前摊着一本翻到一半的旧日记。")),
                        .action(SWSActionBlock(text: "他拿起笔，悬在半空，迟迟没有落下。")),
                        .dialogue(SWSDialogueBlock(character: "郑希远", line: "你来了。")),
                        .dialogue(SWSDialogueBlock(character: "林小满", modifier: "轻声", line: "我一直在等你。")),
                        .action(SWSActionBlock(text: "她走到窗边，推开窗户。雨水的气味涌进来，混着泥土和旧书的味道。")),
                        .dialogue(SWSDialogueBlock(character: "郑希远", modifier: "OV", line: "有时候，")),
                        .dialogue(SWSDialogueBlock(character: "郑希远", line: "我分不清是雨声还是心声。")),
                        .unattributed(SWSUnattributedBlock(lines: ["窗外一阵闷雷滚过，书桌上的台灯闪了一下。"])),
                        .dialogue(SWSDialogueBlock(character: "林小满", modifier: "苦笑", line: "三年了。你一点都没变。")),
                    ]
                ),
                // ── 第 2 场：外景 ──
                SWSScene(
                    heading: SWSSceneHeading(
                        number: "2",
                        interiorExterior: "外景",
                        location: "街角咖啡店",
                        time: "黄昏"
                    ),
                    blocks: [
                        .action(SWSActionBlock(text: "雨停了。街灯一盏接一盏亮起来，湿漉漉的柏油路面倒映着暖黄色的光。")),
                        .dialogue(SWSDialogueBlock(character: "林小满", line: "你不打算解释吗？")),
                        .dialogue(SWSDialogueBlock(character: "郑希远", modifier: "低头搅动咖啡", line: "……我不知道从哪说起。")),
                        .action(SWSActionBlock(text: "远处传来电车的叮当声。店里放着不知名的爵士乐。")),
                        .dialogue(SWSDialogueBlock(character: "林小满", modifier: "激动", line: "从你消失那天说起！")),
                        .dialogue(SWSDialogueBlock(character: "郑希远", line: "那天的事……")),
                        .dialogue(SWSDialogueBlock(character: "郑希远", line: "我也想了很久。可能我们都不够勇敢。")),
                        .unattributed(SWSUnattributedBlock(lines: ["咖啡凉了。", "", "窗外的街灯在水洼里碎成一片。"])),
                    ]
                ),
                // ── 第 3 场：多了个角色 + 更多格式变化 ──
                SWSScene(
                    heading: SWSSceneHeading(
                        number: "3",
                        interiorExterior: "内景",
                        location: "医院走廊",
                        time: "凌晨"
                    ),
                    blocks: [
                        .action(SWSActionBlock(text: "走廊的白炽灯嗡嗡作响。周阿姨端着热水壶从值班室出来，看见坐在长椅上的两个人。")),
                        .dialogue(SWSDialogueBlock(character: "周阿姨", modifier: "笑着", line: "你们小两口，大半夜的坐在这儿干嘛呢？")),
                        .dialogue(SWSDialogueBlock(character: "郑希远", modifier: "无奈", line: "阿姨，不是你想的那样。")),
                        .action(SWSActionBlock(text: "周阿姨看了看林小满红肿的眼睛，没再说话。她把热水壶放在长椅边上，转身走了。")),
                        .dialogue(SWSDialogueBlock(character: "林小满", line: "……")),
                        .dialogue(SWSDialogueBlock(character: "周阿姨", modifier: "VO", line: "热水趁热喝。有事按铃。")),
                        .action(SWSActionBlock(text: "脚步声渐远。走廊重新安静下来，只剩白炽灯的嗡嗡声。")),
                        .dialogue(SWSDialogueBlock(character: "郑希远", modifier: "握住她的手", line: "这一次，我不走了。")),
                        .unattributed(SWSUnattributedBlock(lines: ["窗外天色微亮，雨不知道什么时候停了。"])),
                    ]
                ),
            ]
        )
    }()
}

// MARK: - 持久化

extension FormatTemplate {

    /// 模板存储目录
    public static var templatesDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("WangEr/templates", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 加载所有自定义模板
    public static func loadAll() -> [FormatTemplate] {
        let dir = templatesDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        var templates: [FormatTemplate] = []
        let decoder = JSONDecoder()
        for url in files where url.pathExtension == "json" {
            if let data = try? Data(contentsOf: url),
               let t = try? decoder.decode(FormatTemplate.self, from: data) {
                templates.append(t)
            }
        }
        return templates.sorted { $0.name < $1.name }
    }

    /// 保存模板到磁盘
    public func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        let url = Self.templatesDirectory.appendingPathComponent("\(id).json")
        try data.write(to: url)
    }

    /// 删除模板
    public func delete() throws {
        let url = Self.templatesDirectory.appendingPathComponent("\(id).json")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
