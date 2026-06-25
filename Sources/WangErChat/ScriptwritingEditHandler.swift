import Foundation
import SWS

// MARK: - 编辑操作副作用（由 Plugin 执行）

enum ScriptwritingPostEditAction {
    case reRender
    case focusBlock(scene: String, blockIndex: Int, atEnd: Bool = false, cursorOffset: Int? = nil)
    case focusBlockChipSelected(scene: String, blockIndex: Int)
}

// MARK: - 编辑操作结果

enum ScriptwritingEditResult {
    case noChange
    case updated(SWSDocument, postActions: [ScriptwritingPostEditAction])
}

// MARK: - 编剧助手编辑处理器

/// 纯数据层：接收 JS 编辑消息 → 返回突变后的文档 + UI 副作用指令
/// 零 AppKit / WKWebView 依赖，零 Plugin 状态引用
enum ScriptwritingEditHandler {

    // MARK: - Edit 消息分发

    static let editActions: Set<String> = [
        "updateHeading", "updateBlock", "updateModifier", "insertBlock",
        "deleteBlock", "insertBlockBefore", "deletePairAndFocusPrevious",
        "splitBlock", "mergeWithPreviousBlock", "insertBlockBelow",
        "updateBlockChipCharacter"
    ]

    static func isEditAction(_ action: String) -> Bool {
        return editActions.contains(action)
    }

    static func processEdit(action: String, body: [String: Any], document: SWSDocument) -> ScriptwritingEditResult {
        switch action {
        case "updateHeading": return applyUpdateHeading(body, document: document)
        case "updateBlock": return applyUpdateBlock(body, document: document)
        case "updateModifier": return applyUpdateModifier(body, document: document)
        case "insertBlock": return applyInsertBlock(body, document: document)
        case "deleteBlock": return applyDeleteBlock(body, document: document)
        case "insertBlockBefore": return applyInsertBlockBefore(body, document: document)
        case "deletePairAndFocusPrevious": return applyDeletePairAndFocusPrevious(body, document: document)
        case "splitBlock": return applySplitBlock(body, document: document)
        case "mergeWithPreviousBlock": return applyMergeWithPrevious(body, document: document)
        case "insertBlockBelow": return applyInsertBlockBelow(body, document: document)
        case "updateBlockChipCharacter": return applyUpdateBlockChipCharacter(body, document: document)
        default: return .noChange
        }
    }

    // MARK: - Project 序列化

    /// 将项目编码为 JSON（供 WebView 加载）。
    /// `treeOverride` 可选，用于注入包含游离文件的完整 sidebar tree。
    static func encodeProjectToJSON(_ project: SWSProject, treeOverride: [SWSProjectTreeNode]? = nil) -> String {
        let usedTree = treeOverride ?? project.resolvedTree

        var dict: [String: Any] = [
            "title": project.meta.title,
            "author": project.meta.author,
            "tree": usedTree.map { encodeTreeNode($0) },
        ]
        if let outline = project.outline { dict["outline"] = outline }
        if let script = project.script { dict["script"] = script }
        dict["characters"] = project.characters.map { char in
            var c: [String: Any] = ["id": char.id, "name": char.name]
            if let tagline = char.tagline { c["tagline"] = tagline }
            if let bio = char.bio { c["bio"] = bio }
            if let avatar = char.avatar { c["avatar"] = avatar }
            if let color = char.color { c["color"] = color }
            return c
        }
        dict["scenes"] = project.scenes.map { scene in
            var s: [String: Any] = ["id": scene.id, "title": scene.title]
            if let location = scene.location { s["location"] = location }
            if let time = scene.time { s["time"] = time }
            if let content = scene.content { s["content"] = content }
            return s
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    /// 仅编码 sidebar tree（无项目骨架时的最小 JSON）
    static func encodeSidebarTree(_ tree: [SWSProjectTreeNode]) -> String {
        let dict: [String: Any] = [
            "tree": tree.map { encodeTreeNode($0) },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    private static func encodeTreeNode(_ node: SWSProjectTreeNode) -> [String: Any] {
        var d: [String: Any] = [
            "id": node.id,
            "name": node.name,
            "type": node.type.rawValue,
            "icon": node.type.icon,
        ]
        if let ref = node.ref { d["ref"] = ref }
        if let defaultOpen = node.defaultOpen { d["defaultOpen"] = defaultOpen }
        if let children = node.children, !children.isEmpty {
            d["children"] = children.map { encodeTreeNode($0) }
        }
        return d
    }

    // MARK: - Edit handlers

    private static func applyUpdateHeading(_ body: [String: Any], document: SWSDocument) -> ScriptwritingEditResult {
        guard let sceneNum = body["scene"] as? String,
              let field = body["field"] as? String,
              let value = body["value"] as? String else { return .noChange }
        guard let sceneIdx = document.scenes.firstIndex(where: { $0.heading?.number == sceneNum }) else { return .noChange }
        var scene = document.scenes[sceneIdx]
        guard var heading = scene.heading else { return .noChange }

        switch field {
        case "interiorExterior": heading = SWSSceneHeading(number: heading.number, interiorExterior: value.isEmpty ? nil : value, location: heading.location, time: heading.time, separator: heading.separator)
        case "location": heading = SWSSceneHeading(number: heading.number, interiorExterior: heading.interiorExterior, location: value.isEmpty ? nil : value, time: heading.time, separator: heading.separator)
        case "time": heading = SWSSceneHeading(number: heading.number, interiorExterior: heading.interiorExterior, location: heading.location, time: value.isEmpty ? nil : value, separator: heading.separator)
        default: return .noChange
        }

        scene = SWSScene(heading: heading, blocks: scene.blocks)
        var scenes = document.scenes
        scenes[sceneIdx] = scene
        return .updated(SWSDocument(metadata: document.metadata, scenes: scenes), postActions: [])
    }

    private static func applyUpdateBlock(_ body: [String: Any], document: SWSDocument) -> ScriptwritingEditResult {
        guard let sceneNum = body["scene"] as? String,
              let blockIdx = body["blockIndex"] as? Int,
              let type = body["type"] as? String,
              let value = body["value"] as? String else { return .noChange }
        guard let sceneIdx = document.scenes.firstIndex(where: { $0.heading?.number == sceneNum }) else { return .noChange }
        var scene = document.scenes[sceneIdx]
        guard blockIdx < scene.blocks.count else { return .noChange }

        var blocks = scene.blocks
        let block = blocks[blockIdx]

        switch (type, block) {
        case ("action", .action):
            blocks[blockIdx] = .action(SWSActionBlock(text: value))
        case ("dialogue", .dialogue(let d)):
            blocks[blockIdx] = .dialogue(SWSDialogueBlock(character: d.character, modifier: d.modifier, line: value))
        case ("unattributed", .unattributed):
            blocks[blockIdx] = .unattributed(SWSUnattributedBlock(lines: [value]))
        default:
            return .noChange
        }

        scene = SWSScene(heading: scene.heading, blocks: blocks)
        var scenes = document.scenes
        scenes[sceneIdx] = scene
        return .updated(SWSDocument(metadata: document.metadata, scenes: scenes), postActions: [])
    }

    private static func applyUpdateModifier(_ body: [String: Any], document: SWSDocument) -> ScriptwritingEditResult {
        guard let sceneNum = body["scene"] as? String,
              let blockIdx = body["blockIndex"] as? Int,
              let value = body["value"] as? String else { return .noChange }
        guard let sceneIdx = document.scenes.firstIndex(where: { $0.heading?.number == sceneNum }) else { return .noChange }
        var scene = document.scenes[sceneIdx]
        guard blockIdx < scene.blocks.count else { return .noChange }
        var blocks = scene.blocks
        guard case .dialogue(let d) = blocks[blockIdx] else { return .noChange }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let newModifier: String? = trimmed.isEmpty ? nil : trimmed
        blocks[blockIdx] = .dialogue(SWSDialogueBlock(character: d.character, modifier: newModifier, line: d.line))
        scene = SWSScene(heading: scene.heading, blocks: blocks)
        var scenes = document.scenes
        scenes[sceneIdx] = scene
        return .updated(SWSDocument(metadata: document.metadata, scenes: scenes), postActions: [])
    }

    private static func applyInsertBlock(_ body: [String: Any], document: SWSDocument) -> ScriptwritingEditResult {
        guard let sceneNum = body["scene"] as? String,
              let afterBlock = body["afterBlock"] as? Int else { return .noChange }
        guard let sceneIdx = document.scenes.firstIndex(where: { $0.heading?.number == sceneNum }) else { return .noChange }
        var scene = document.scenes[sceneIdx]

        var blocks = scene.blocks
        let insertIdx = min(afterBlock + 1, blocks.count)
        let blockType = body["type"] as? String
        if blockType == "dialogue" {
            blocks.insert(.dialogue(SWSDialogueBlock(character: "", modifier: nil, line: "")), at: insertIdx)
        } else {
            blocks.insert(.action(SWSActionBlock(text: "")), at: insertIdx)
        }

        scene = SWSScene(heading: scene.heading, blocks: blocks)
        var scenes = document.scenes
        scenes[sceneIdx] = scene
        let postActions: [ScriptwritingPostEditAction]
        if blockType == "dialogue" {
            postActions = [.reRender, .focusBlockChipSelected(scene: sceneNum, blockIndex: insertIdx)]
        } else {
            postActions = [.reRender, .focusBlock(scene: sceneNum, blockIndex: insertIdx)]
        }
        return .updated(SWSDocument(metadata: document.metadata, scenes: scenes),
                        postActions: postActions)
    }

    private static func applyDeleteBlock(_ body: [String: Any], document: SWSDocument) -> ScriptwritingEditResult {
        guard let sceneNum = body["scene"] as? String,
              let blockIdx = body["blockIndex"] as? Int else { return .noChange }
        guard let sceneIdx = document.scenes.firstIndex(where: { $0.heading?.number == sceneNum }) else { return .noChange }
        var scene = document.scenes[sceneIdx]
        guard blockIdx < scene.blocks.count else { return .noChange }
        guard scene.blocks.count > 1 else { return .noChange }

        var blocks = scene.blocks
        blocks.remove(at: blockIdx)

        scene = SWSScene(heading: scene.heading, blocks: blocks)
        var scenes = document.scenes
        scenes[sceneIdx] = scene
        let focusIdx = max(0, blockIdx - 1)
        return .updated(SWSDocument(metadata: document.metadata, scenes: scenes),
                        postActions: [.reRender, .focusBlock(scene: sceneNum, blockIndex: focusIdx)])
    }

    private static func applyInsertBlockBefore(_ body: [String: Any], document: SWSDocument) -> ScriptwritingEditResult {
        guard let sceneNum = body["scene"] as? String,
              let blockIdx = body["blockIndex"] as? Int else { return .noChange }
        guard let sceneIdx = document.scenes.firstIndex(where: { $0.heading?.number == sceneNum }) else { return .noChange }
        var scene = document.scenes[sceneIdx]
        guard blockIdx < scene.blocks.count else { return .noChange }

        var blocks = scene.blocks
        blocks.insert(.action(SWSActionBlock(text: "")), at: blockIdx)

        scene = SWSScene(heading: scene.heading, blocks: blocks)
        var scenes = document.scenes
        scenes[sceneIdx] = scene
        let newDialogueIdx = blockIdx + 1
        return .updated(SWSDocument(metadata: document.metadata, scenes: scenes),
                        postActions: [.reRender, .focusBlockChipSelected(scene: sceneNum, blockIndex: newDialogueIdx)])
    }

    private static func applyDeletePairAndFocusPrevious(_ body: [String: Any], document: SWSDocument) -> ScriptwritingEditResult {
        guard let sceneNum = body["scene"] as? String,
              let blockIdx = body["blockIndex"] as? Int else { return .noChange }
        guard let sceneIdx = document.scenes.firstIndex(where: { $0.heading?.number == sceneNum }) else { return .noChange }
        var scene = document.scenes[sceneIdx]
        guard blockIdx < scene.blocks.count else { return .noChange }

        var blocks = scene.blocks
        let wasOnlyBlock = blocks.count <= 1
        if wasOnlyBlock {
            blocks[blockIdx] = .action(SWSActionBlock(text: ""))
        } else {
            blocks.remove(at: blockIdx)
        }

        scene = SWSScene(heading: scene.heading, blocks: blocks)
        var scenes = document.scenes
        scenes[sceneIdx] = scene
        let focusIdx = wasOnlyBlock ? blockIdx : max(0, blockIdx - 1)
        return .updated(SWSDocument(metadata: document.metadata, scenes: scenes),
                        postActions: [.reRender, .focusBlock(scene: sceneNum, blockIndex: focusIdx)])
    }

    // MARK: - Step 1d: 块内 Enter 拆分 + Backspace 合并

    /// Enter 在光标处拆分为两个块（JS 已乐观更新 DOM）
    private static func applySplitBlock(_ body: [String: Any], document: SWSDocument) -> ScriptwritingEditResult {
        guard let sceneNum = body["scene"] as? String,
              let blockIdx = body["blockIndex"] as? Int,
              let beforeText = body["beforeText"] as? String,
              let afterText = body["afterText"] as? String else { return .noChange }
        guard let sceneIdx = document.scenes.firstIndex(where: { $0.heading?.number == sceneNum }) else { return .noChange }
        var scene = document.scenes[sceneIdx]
        guard blockIdx < scene.blocks.count else { return .noChange }

        var blocks = scene.blocks
        let block = blocks[blockIdx]
        let newBlock: SWSBlock

        switch block {
        case .action:
            blocks[blockIdx] = .action(SWSActionBlock(text: beforeText))
            newBlock = .action(SWSActionBlock(text: afterText))
        case .dialogue(let d):
            blocks[blockIdx] = .dialogue(SWSDialogueBlock(character: d.character, modifier: d.modifier, line: beforeText))
            newBlock = .dialogue(SWSDialogueBlock(character: d.character, modifier: d.modifier, line: afterText))
        case .unattributed:
            blocks[blockIdx] = .unattributed(SWSUnattributedBlock(lines: [beforeText]))
            newBlock = .unattributed(SWSUnattributedBlock(lines: [afterText]))
        }

        blocks.insert(newBlock, at: blockIdx + 1)
        scene = SWSScene(heading: scene.heading, blocks: blocks)
        var scenes = document.scenes
        scenes[sceneIdx] = scene
        return .updated(SWSDocument(metadata: document.metadata, scenes: scenes),
                        postActions: [.focusBlock(scene: sceneNum, blockIndex: blockIdx + 1)])
    }

    /// Enter in dialogue → 下方插入空 dialogue（同角色、同修饰语，台词为空）
    private static func applyInsertBlockBelow(_ body: [String: Any], document: SWSDocument) -> ScriptwritingEditResult {
        guard let sceneNum = body["scene"] as? String,
              let blockIdx = body["blockIndex"] as? Int else { return .noChange }
        guard let sceneIdx = document.scenes.firstIndex(where: { $0.heading?.number == sceneNum }) else { return .noChange }
        var scene = document.scenes[sceneIdx]
        guard blockIdx < scene.blocks.count else { return .noChange }

        var blocks = scene.blocks
        let insertIdx = blockIdx + 1

        // 复制当前块的角色和修饰语，创建空 dialogue
        let block = blocks[blockIdx]
        if case .dialogue(let d) = block {
            blocks.insert(.dialogue(SWSDialogueBlock(character: "", modifier: nil, line: "")), at: insertIdx)
        } else {
            // 非 dialogue 降级为 action
            blocks.insert(.action(SWSActionBlock(text: "")), at: insertIdx)
        }

        scene = SWSScene(heading: scene.heading, blocks: blocks)
        var scenes = document.scenes
        scenes[sceneIdx] = scene
        return .updated(SWSDocument(metadata: document.metadata, scenes: scenes),
                        postActions: [.reRender, .focusBlockChipSelected(scene: sceneNum, blockIndex: insertIdx)])
    }

    /// 更新 dialogue 块的角色名（chip 编辑）
    private static func applyUpdateBlockChipCharacter(_ body: [String: Any], document: SWSDocument) -> ScriptwritingEditResult {
        guard let sceneNum = body["scene"] as? String,
              let blockIdx = body["blockIndex"] as? Int,
              let character = body["character"] as? String else { return .noChange }
        guard let sceneIdx = document.scenes.firstIndex(where: { $0.heading?.number == sceneNum }) else { return .noChange }
        var scene = document.scenes[sceneIdx]
        guard blockIdx < scene.blocks.count else { return .noChange }
        var blocks = scene.blocks
        guard case .dialogue(let d) = blocks[blockIdx] else { return .noChange }
        let trimmed = character.trimmingCharacters(in: .whitespaces)
        let newChar = trimmed.isEmpty ? "" : trimmed
        blocks[blockIdx] = .dialogue(SWSDialogueBlock(character: newChar, modifier: d.modifier, line: d.line))
        scene = SWSScene(heading: scene.heading, blocks: blocks)
        var scenes = document.scenes
        scenes[sceneIdx] = scene
        return .updated(SWSDocument(metadata: document.metadata, scenes: scenes), postActions: [])
    }

    /// Backspace 在块开头合并到上一个块（JS 已乐观更新 DOM）
    private static func applyMergeWithPrevious(_ body: [String: Any], document: SWSDocument) -> ScriptwritingEditResult {
        guard let sceneNum = body["scene"] as? String,
              let blockIdx = body["blockIndex"] as? Int else { return .noChange }
        guard blockIdx > 0 else { return .noChange }
        guard let sceneIdx = document.scenes.firstIndex(where: { $0.heading?.number == sceneNum }) else { return .noChange }
        var scene = document.scenes[sceneIdx]
        guard blockIdx < scene.blocks.count else { return .noChange }

        var blocks = scene.blocks
        let prevBlock = blocks[blockIdx - 1]
        let currBlock = blocks[blockIdx]

        // 提取文本
        let prevText: String
        let currText: String
        switch prevBlock {
        case .action(let a):      prevText = a.text
        case .dialogue(let d):    prevText = d.line
        case .unattributed(let u): prevText = u.lines.joined(separator: "\n")
        }
        switch currBlock {
        case .action(let a):      currText = a.text
        case .dialogue(let d):    currText = d.line
        case .unattributed(let u): currText = u.lines.joined(separator: "\n")
        }

        // 记录光标应在的交接位置（上一块原文末尾）
        let mergeOffset = prevText.count

        // 同类型合并保留结构，否则降级为 action
        switch (prevBlock, currBlock) {
        case (.action, .action):
            blocks[blockIdx - 1] = .action(SWSActionBlock(text: prevText + currText))
        case (.dialogue(let p), .dialogue):
            blocks[blockIdx - 1] = .dialogue(SWSDialogueBlock(character: p.character, modifier: p.modifier, line: prevText + currText))
        case (.unattributed, .unattributed):
            blocks[blockIdx - 1] = .unattributed(SWSUnattributedBlock(lines: [prevText + currText]))
        default:
            // 跨类型降级为 action
            blocks[blockIdx - 1] = .action(SWSActionBlock(text: prevText + currText))
        }

        blocks.remove(at: blockIdx)
        scene = SWSScene(heading: scene.heading, blocks: blocks)
        var scenes = document.scenes
        scenes[sceneIdx] = scene
        return .updated(SWSDocument(metadata: document.metadata, scenes: scenes),
                        postActions: [.focusBlock(scene: sceneNum, blockIndex: blockIdx - 1, cursorOffset: mergeOffset)])
    }
}
