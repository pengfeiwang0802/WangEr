import Foundation

// MARK: - Scene Numbering Mode

/// 场号编排模式 —— 控制 Build 时场号如何跨文件接续
public enum SceneNumbering: String, Codable, CaseIterable {
    /// 接续上一文件的场号（电影多 part 合并、同一集拆多个文件）
    case continueFromPrevious
    /// 从第 1 场重新开始（新一集、新一个独立单元）
    case resetToFirst
}

// MARK: - Script File Reference

/// 项目中引用的一个 .sws 剧本文件
public struct SWSProjectScriptRef: Codable, Identifiable {
    /// 唯一标识（如 "script_0"）
    public let id: String
    /// sidebar 显示名（如 "第1场-开场"）
    public var name: String
    /// 相对于 swsproj 所在目录的路径（如 "第1场-开场.sws"）
    public var path: String
    /// 排序权重（数字越小越靠前）
    public var order: Int
    /// 场号编排模式
    public var sceneNumbering: SceneNumbering
    /// 分组名（仅 sceneNumbering == .resetToFirst 时生效；nil 则用首脚本 name 自动命名）
    public var groupName: String?

    public init(
        id: String,
        name: String,
        path: String,
        order: Int,
        sceneNumbering: SceneNumbering = .continueFromPrevious,
        groupName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.order = order
        self.sceneNumbering = sceneNumbering
        self.groupName = groupName
    }
}

// MARK: - Script Group (Runtime)

/// 分组 —— 由 resetToFirst 边界从 scripts 数组派生，不持久化
///
/// 一个分组就是一个可独立 Build 的"单元"：
/// - 可能是一部完整的电影（1 组）
/// - 可能是电影的一部分（多人协作的一个 part）
/// - 可能是一集或多集电视剧
public struct ScriptGroup: Identifiable {
    public let id: String
    /// 分组显示名
    public let name: String
    /// 本组包含的剧本文件
    public let scriptRefs: [SWSProjectScriptRef]
    /// 在 project.scripts 中的起始索引
    public let startIndex: Int

    public init(id: String, name: String, scriptRefs: [SWSProjectScriptRef], startIndex: Int) {
        self.id = id
        self.name = name
        self.scriptRefs = scriptRefs
        self.startIndex = startIndex
    }
}

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
    /// 剧本文件引用列表（🆕 替代 script）
    public var scripts: [SWSProjectScriptRef]?
    /// 完整剧本（纯文本）—— 已废弃，请使用 scripts
    @available(*, deprecated, message: "使用 scripts 引用外部 .sws 文件")
    public var script: String?
    /// 虚拟文件树；省略时编辑器自动构建
    public var tree: [SWSProjectTreeNode]?

    // MARK: - 工厂方法

    /// 创建一个空的 swsproj 项目（含一个初始 .sws 脚本引用）
    public static func empty(title: String = "未命名剧本", author: String = "") -> SWSProject {
        let now = ISO8601DateFormatter().string(from: Date())
        let defaultScript = SWSProjectScriptRef(
            id: "script_0",
            name: "第1场",
            path: "第1场.sws",
            order: 0,
            sceneNumbering: .resetToFirst,
            groupName: nil
        )
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
            scripts: [defaultScript],
            script: nil,
            tree: nil
        )
    }

    // MARK: - tree 访问

    /// 解析后的 tree，未提供时自动构建默认树
    public var resolvedTree: [SWSProjectTreeNode] {
        if let tree, !tree.isEmpty { return tree }
        return SWSProject.defaultTree(
            characters: characters,
            scenes: scenes,
            hasOutline: outline != nil,
            scripts: resolvedScripts
        )
    }

    /// 脚本引用列表：优先 scripts，回退到旧 script 字段兼容
    public var resolvedScripts: [SWSProjectScriptRef] {
        if let scripts, !scripts.isEmpty { return scripts.sorted { $0.order < $1.order } }
        // 兼容旧项目：仅有 script 文本时，构造一个虚拟引用
        if let _ = script {
            return [SWSProjectScriptRef(
                id: "script_legacy",
                name: "剧本",
                path: "",
                order: 0,
                sceneNumbering: .resetToFirst
            )]
        }
        return []
    }

    /// 默认项目树：大纲 / 剧本（含 .sws 文件列表）
    /// - 人物和场景不在项目侧栏中显示（它们在时间线侧栏里管理）
    public static func defaultTree(
        characters: [SWSProjectCharacter],
        scenes: [SWSProjectScene],
        hasOutline: Bool,
        scripts: [SWSProjectScriptRef] = []
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

        // 剧本（列出所有 .sws 文件）
        let scriptNodes = scripts
            .sorted { $0.order < $1.order }
            .map { ref in
                SWSProjectTreeNode(id: ref.id, name: ref.name, type: .script, ref: ref.id)
            }
        nodes.append(SWSProjectTreeNode(
            id: "f_scripts",
            name: "剧本",
            type: .folder,
            defaultOpen: true,
            children: scriptNodes.isEmpty
                ? [SWSProjectTreeNode(id: "f_scripts_empty", name: "（空）", type: .script)]
                : scriptNodes
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

    /// 按 id 找脚本引用
    public func scriptRef(id: String) -> SWSProjectScriptRef? {
        resolvedScripts.first { $0.id == id }
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

    // MARK: - 分组计算

    /// 从脚本列表中按 resetToFirst 边界切分分组（纯计算，无 I/O）
    ///
    /// - 第一项强制为分组起始（无论其 sceneNumbering 是什么）
    /// - 后续每个 `.resetToFirst` 项开始一个新分组
    /// - 分组名优先用 `groupName`，其次用首脚本的 name
    public func computeGroups() -> [ScriptGroup] {
        let scripts = resolvedScripts
        guard !scripts.isEmpty else { return [] }

        var groups: [ScriptGroup] = []
        var currentRefs: [SWSProjectScriptRef] = []
        var currentStartIndex = 0

        for (i, ref) in scripts.enumerated() {
            if i > 0 && ref.sceneNumbering == .resetToFirst {
                let name = scripts[currentStartIndex].groupName ?? scripts[currentStartIndex].name
                groups.append(ScriptGroup(
                    id: "group_\(groups.count)",
                    name: name,
                    scriptRefs: currentRefs,
                    startIndex: currentStartIndex
                ))
                currentRefs = []
                currentStartIndex = i
            }
            currentRefs.append(ref)
        }

        // 最后一个分组
        if !currentRefs.isEmpty {
            let name = scripts[currentStartIndex].groupName ?? scripts[currentStartIndex].name
            groups.append(ScriptGroup(
                id: "group_\(groups.count)",
                name: name,
                scriptRefs: currentRefs,
                startIndex: currentStartIndex
            ))
        }

        return groups
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
        case folder         = "folder"
        case character      = "character"
        case scene          = "scene"
        case outline        = "outline"
        case script         = "script"
        case note           = "note"
        case externalScript = "externalScript"  // 游离文件（不属于当前项目）
        case divider        = "divider"         // 分隔线

        /// sidebar 图标（emoji）
        public var icon: String {
            switch self {
            case .folder:         return "📁"
            case .character:      return "🧑"
            case .scene:          return "🎬"
            case .outline:        return "📝"
            case .script:         return "📄"
            case .note:           return "📎"
            case .externalScript: return "📄"
            case .divider:        return ""
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
