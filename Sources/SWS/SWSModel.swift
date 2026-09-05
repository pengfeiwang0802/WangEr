import Foundation

// MARK: - SWS Document (顶层)

/// SWS 剧本完整文档 —— 内存中的唯一结构化表示。
///
/// 架构：
/// ```
/// SWSDocument → [SWSScene] → [SWSBlock]
///                                ├── .dialogue(SWSDialogueBlock)
///                                ├── .action(SWSActionBlock)
///                                └── .unattributed(SWSUnattributedBlock)
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

    /// 按场号查找一场戏
    public func scene(byNumber number: String) -> SWSScene? {
        scenes.first { $0.heading?.number == number }
    }

    /// 所有场景 id 列表（用于目录导航），无场号时回退到索引
    public var allSceneIds: [String] {
        scenes.enumerated().map { (i, scene) in
            scene.sceneId ?? "scene-idx-\(i)"
        }
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

    /// 场景唯一标识，基于场号（如 "scene-1"）
    public var sceneId: String? {
        guard let number = heading?.number, !number.isEmpty else { return nil }
        return "scene-\(number)"
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
///
/// 设计说明：
/// - `.emptyLine` 已废弃。空行作为段落分隔符吸收到相邻块的文本内容中（\n\n）。
/// - `BlockType.emptyLine` 仅保留用于向后兼容解码，运行时不再产生此类型。
/// - 多行文本（action/dialogue/unattributed）中 \n 为软换行，\n\n 为段落分隔。
public enum SWSBlock: Codable {
    /// 对白（已绑定角色）
    case dialogue(SWSDialogueBlock)
    /// 动作 / 描述
    case action(SWSActionBlock)
    /// 对白（未标注角色，`> "..."` 前缀）
    case unattributed(SWSUnattributedBlock)

    // MARK: Codable

    public enum CodingKeys: String, CodingKey {
        case type, value
    }

    public enum BlockType: String, Codable {
        case dialogue, action, unattributed
        /// 已废弃：向后兼容解码用，运行时不再产出
        case emptyLine
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
            // 向后兼容：解码时遇到 emptyLine → 转为空 action（normalize 步骤会处理）
            self = .action(SWSActionBlock(text: ""))
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
        }
    }
}

// MARK: - Dialogue Block

/// 对白块 —— 角色 + 单行台词的一对一绑定
///
/// ```
/// [郑希远]
/// 第一段话。
/// ```
/// → `SWSDialogueBlock(character: "郑希远", line: "第一段话。")`
///
/// 多段台词 = 多个 SWSDialogueBlock，不在一个 block 内打包。
public struct SWSDialogueBlock: Codable {
    /// 角色名（如 "郑希远"）
    public let character: String
    /// 修饰语（如 "笑道" / "OV"），nil 表示无修饰
    public let modifier: String?
    /// 单行台词
    public let line: String

    public init(character: String, modifier: String? = nil, line: String = "") {
        self.character = character
        self.modifier = modifier
        self.line = line
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
    public var lines: [String]

    public init(lines: [String] = []) {
        self.lines = lines
    }

    /// 去除空行后的纯台词文本
    public var textLines: [String] {
        lines.filter { !$0.isEmpty }
    }
}

