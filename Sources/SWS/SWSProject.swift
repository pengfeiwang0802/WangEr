import Foundation

// MARK: - SWSProject（顶层）

/// `.swsproj` 项目文件的完整内存表示。
///
/// 按 `swsproj-spec.md` v1.0 定义，一个文件 = 一个项目。
/// 所有类型为 `struct` + `Codable`，零外部依赖。
public struct SWSProject: Codable {
    /// 格式版本号，当前 `"1.0"`
    public var swsproj: String
    /// 项目元信息
    public var meta: SWSProjectMeta
    /// 剧本大纲（Markdown 文本）
    public var outline: String?
    /// 角色列表
    public var characters: [SWSProjectCharacter]
    /// 场景列表
    public var scenes: [SWSProjectScene]
    /// 完整剧本（纯文本）
    public var script: String?
    /// 虚拟文件树；省略时编辑器自动构建
    public var tree: [SWSProjectTreeNode]?

    // MARK: - 工厂方法

    /// 创建一个空的 swsproj 项目
    public static func empty(title: String = "未命名剧本", author: String = "") -> SWSProject {
        let now = ISO8601DateFormatter().string(from: Date())
        return SWSProject(
            swsproj: "1.0",
            meta: SWSProjectMeta(
                title: title,
                author: author,
                createdAt: now,
                updatedAt: now
            ),
            outline: nil,
            characters: [],
            scenes: [],
            script: nil,
            tree: nil
        )
    }

    // MARK: - tree 访问

    /// 解析后的 tree，未提供时自动构建默认树
    public var resolvedTree: [SWSProjectTreeNode] {
        if let tree, !tree.isEmpty { return tree }
        return SWSProject.defaultTree(characters: characters, scenes: scenes, hasOutline: outline != nil)
    }

    /// 默认项目树：大纲 / 剧本
    /// - 人物和场景不在项目侧栏中显示（它们在时间线侧栏里管理）
    public static func defaultTree(
        characters: [SWSProjectCharacter],
        scenes: [SWSProjectScene],
        hasOutline: Bool
    ) -> [SWSProjectTreeNode] {
        var nodes: [SWSProjectTreeNode] = []

        // 大纲（始终显示）
        nodes.append(SWSProjectTreeNode(
            id: "f_outline",
            name: "大纲",
            type: .folder,
            defaultOpen: true,
            children: hasOutline
                ? [SWSProjectTreeNode(id: "file_outline", name: "大纲", type: .outline)]
                : []
        ))

        // 剧本（文件夹，包含多个 .sws 脚本文件）
        nodes.append(SWSProjectTreeNode(
            id: "f_scripts",
            name: "剧本",
            type: .folder,
            defaultOpen: true,
            children: []
        ))

        return nodes
    }

    // MARK: - 查找

    /// 按 id 找角色
    public func character(id: String) -> SWSProjectCharacter? {
        characters.first { $0.id == id }
    }

    /// 按 id 找场景
    public func scene(id: String) -> SWSProjectScene? {
        scenes.first { $0.id == id }
    }

    /// 在树中找节点
    public func findNode(id: String, in nodes: [SWSProjectTreeNode]? = nil) -> SWSProjectTreeNode? {
        let searchNodes = nodes ?? resolvedTree
        for node in searchNodes {
            if node.id == id { return node }
            if let children = node.children, let found = findNode(id: id, in: children) {
                return found
            }
        }
        return nil
    }
}

// MARK: - SWSProjectMeta

/// 项目元信息
public struct SWSProjectMeta: Codable {
    /// 剧本标题
    public var title: String
    /// 作者
    public var author: String
    /// 创建时间（ISO 8601）
    public var createdAt: String
    /// 最后修改时间（ISO 8601）
    public var updatedAt: String

    public init(title: String = "未命名剧本", author: String = "", createdAt: String = "", updatedAt: String = "") {
        self.title = title
        self.author = author
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - SWSProjectCharacter

/// 项目角色
public struct SWSProjectCharacter: Codable, Identifiable {
    /// 唯一标识
    public let id: String
    /// 角色名
    public var name: String
    /// 头像 emoji / 图标
    public var avatar: String?
    /// 角色颜色（hex）
    public var color: String?
    /// 一句话介绍（~50 字）
    public var tagline: String?
    /// 人物小传（Markdown，支持长文本）
    public var bio: String?

    public init(id: String, name: String, avatar: String? = nil, color: String? = nil, tagline: String? = nil, bio: String? = nil) {
        self.id = id
        self.name = name
        self.avatar = avatar
        self.color = color
        self.tagline = tagline
        self.bio = bio
    }
}

// MARK: - SWSProjectScene

/// 项目场景
public struct SWSProjectScene: Codable, Identifiable {
    /// 唯一标识
    public let id: String
    /// 场景名（如 "第1场"）
    public var title: String
    /// 地点
    public var location: String?
    /// 时间标注（如 "日·内"）
    public var time: String?
    /// 场景正文（纯文本）
    public var content: String?

    public init(id: String, title: String, location: String? = nil, time: String? = nil, content: String? = nil) {
        self.id = id
        self.title = title
        self.location = location
        self.time = time
        self.content = content
    }
}

// MARK: - SWSProjectTreeNode

/// 虚拟文件树节点
public struct SWSProjectTreeNode: Codable {
    /// 节点唯一 id
    public let id: String
    /// 显示名称
    public var name: String
    /// 节点类型
    public var type: NodeType
    /// 引用目标实体 id（character/scene 节点）
    public var ref: String?
    /// 文件夹默认展开
    public var defaultOpen: Bool?
    /// 子节点（folder 类型）
    public var children: [SWSProjectTreeNode]?

    public init(id: String, name: String, type: NodeType, ref: String? = nil, defaultOpen: Bool? = nil, children: [SWSProjectTreeNode]? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.ref = ref
        self.defaultOpen = defaultOpen
        self.children = children
    }

    /// 节点类型
    public enum NodeType: String, Codable {
        case folder     = "folder"
        case character  = "character"
        case scene      = "scene"
        case outline    = "outline"
        case script     = "script"
        case note       = "note"

        /// sidebar 图标（emoji）
        public var icon: String {
            switch self {
            case .folder:    return "📁"
            case .character: return "🧑"
            case .scene:     return "🎬"
            case .outline:   return "📝"
            case .script:    return "📄"
            case .note:      return "📎"
            }
        }
    }

    // MARK: - 遍历

    /// 递归查找节点（深度优先）
    public func find(id target: String) -> SWSProjectTreeNode? {
        if self.id == target { return self }
        guard let children else { return nil }
        for child in children {
            if let found = child.find(id: target) { return found }
        }
        return nil
    }

    /// 所有叶节点（非 folder）
    public var leafNodes: [SWSProjectTreeNode] {
        if type == .folder {
            return children?.flatMap { $0.leafNodes } ?? []
        }
        return [self]
    }
}
