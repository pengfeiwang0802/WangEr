import Foundation
import SWS

// MARK: - 编辑操作副作用（由 Plugin 执行）

enum ScriptwritingPostEditAction {
    case reRender
    case focusBlock(scene: String, blockIndex: Int)
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

    static func processEdit(action: String, body: [String: Any], document: SWSDocument) -> ScriptwritingEditResult {
        switch action {
        case "updateHeading": return applyUpdateHeading(body, document: document)
        case "updateBlock": return applyUpdateBlock(body, document: document)
        case "insertBlock": return applyInsertBlock(body, document: document)
        case "deleteBlock": return applyDeleteBlock(body, document: document)
        case "insertBlockBefore": return applyInsertBlockBefore(body, document: document)
        case "deletePairAndFocusPrevious": return applyDeletePairAndFocusPrevious(body, document: document)
        default: return .noChange
        }
    }

    // MARK: - Project 序列化

    static func encodeProjectToJSON(_ project: SWSProject) -> String {
        var dict: [String: Any] = [
            "title": project.meta.title,
            "author": project.meta.author,
            "tree": project.resolvedTree.map { encodeTreeNode($0) },
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

    private static func applyInsertBlock(_ body: [String: Any], document: SWSDocument) -> ScriptwritingEditResult {
        guard let sceneNum = body["scene"] as? String,
              let afterBlock = body["afterBlock"] as? Int else { return .noChange }
        guard let sceneIdx = document.scenes.firstIndex(where: { $0.heading?.number == sceneNum }) else { return .noChange }
        var scene = document.scenes[sceneIdx]

        var blocks = scene.blocks
        let insertIdx = min(afterBlock + 1, blocks.count)
        blocks.insert(.action(SWSActionBlock(text: "")), at: insertIdx)

        scene = SWSScene(heading: scene.heading, blocks: blocks)
        var scenes = document.scenes
        scenes[sceneIdx] = scene
        return .updated(SWSDocument(metadata: document.metadata, scenes: scenes),
                        postActions: [.reRender, .focusBlock(scene: sceneNum, blockIndex: insertIdx)])
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
}
