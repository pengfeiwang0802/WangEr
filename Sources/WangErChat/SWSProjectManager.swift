import Foundation
import SWS

// MARK: - SWSProjectManager

/// 管理 `.swsproj` 项目的文件 I/O 和内存状态。
///
/// 纯逻辑层：不依赖 AppKit，不发送通知，不管理 UI。
/// UI 层（如 ScriptwritingPlugin）持有实例，自己处理面板和渲染。
final class SWSProjectManager {
    // MARK: - 公开状态

    private(set) var project: SWSProject?
    private(set) var fileURL: URL?

    var isModified: Bool { _isModified }
    private var _isModified = false

    var isProjectOpen: Bool { project != nil }
    var projectTitle: String { project?.meta.title ?? "未命名剧本" }
    var fileName: String { fileURL?.lastPathComponent ?? "未命名.swsproj" }

    // MARK: - I/O 工具

    private let dateFormatter: ISO8601DateFormatter
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        dateFormatter = ISO8601DateFormatter()
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
    }

    // MARK: - 新建

    /// 创建项目文件夹，内含 .swsproj + 初始 .sws 文件
    ///
    /// `url` 是用户选择的**文件夹**路径（NSSavePanel 返回的文件路径即用作目录名）。
    /// 例如 `/Users/xxx/Documents/我的电影` → 创建目录 `我的电影/`，
    /// 内含 `我的电影.swsproj` 和 `第1场.sws`。
    func createProject(at url: URL, title: String) throws {
        let proj = SWSProject.empty(title: title)

        // 1. 创建项目文件夹
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        // 2. 在文件夹内写入 swsproj
        let projURL = url.appendingPathComponent("\(title).swsproj")
        try write(project: proj, to: projURL)
        project = proj
        fileURL = projURL
        _isModified = false

        // 3. 在文件夹内写入初始 .sws 文件
        if let ref = proj.scripts?.first {
            let swsURL = url.appendingPathComponent(ref.path)
            let doc = SWSDocument()
            let data = try encoder.encode(doc)
            try data.write(to: swsURL, options: .atomic)
        }
    }

    // MARK: - 加载

    /// 从 URL 加载 .swsproj 项目
    func loadProject(from url: URL) throws {
        guard url.pathExtension == "swsproj" else {
            throw ProjectError.invalidFileType(url.pathExtension)
        }
        let data = try Data(contentsOf: url)
        let proj = try decoder.decode(SWSProject.self, from: data)
        guard proj.swsproj == "1.0" else {
            throw ProjectError.unsupportedVersion(proj.swsproj)
        }
        project = proj
        fileURL = url
        _isModified = false
    }

    // MARK: - 保存

    func save() throws {
        guard let proj = project else { throw ProjectError.noProject }
        guard let url = fileURL else { throw ProjectError.noFileURL }
        try write(project: proj, to: url)
        _isModified = false
    }

    func saveAs(to url: URL) throws {
        guard let proj = project else { throw ProjectError.noProject }
        try write(project: proj, to: url)
        fileURL = url
        _isModified = false
    }

    // MARK: - 项目目录

    /// 项目根目录（swsproj 所在文件夹），用于解析相对路径
    var projectDir: URL? {
        fileURL?.deletingLastPathComponent()
    }

    // MARK: - 关闭

    func close() {
        project = nil
        fileURL = nil
        _isModified = false
    }

    // MARK: - 脏标记

    func markDirty() {
        _isModified = true
    }

    // MARK: - 内容变更

    func updateOutline(_ md: String) {
        guard var proj = project else { return }
        proj.outline = md
        project = proj
        markDirty()
    }

    @available(*, deprecated, message: "使用 saveScript(doc:ref:) 写入独立 .sws 文件")
    func updateScript(_ text: String) {
        guard var proj = project else { return }
        proj.script = text
        project = proj
        markDirty()
    }

    // MARK: - 脚本文件 I/O

    /// 加载指定脚本引用的 .sws 文件
    func loadScript(ref: SWSProjectScriptRef) throws -> SWSDocument {
        guard let dir = projectDir else {
            throw ProjectError.noFileURL
        }
        let url = dir.appendingPathComponent(ref.path)
        let data = try Data(contentsOf: url)
        return try decoder.decode(SWSDocument.self, from: data)
    }

    /// 保存 SWSDocument 到指定脚本引用的 .sws 文件
    func saveScript(doc: SWSDocument, ref: SWSProjectScriptRef) throws {
        guard let dir = projectDir else {
            throw ProjectError.noFileURL
        }
        let url = dir.appendingPathComponent(ref.path)
        let data = try encoder.encode(doc)
        try data.write(to: url, options: .atomic)
    }

    /// 新建 .sws 文件并添加到项目索引
    func addScript(name: String, fileName: String, doc: SWSDocument = SWSDocument()) throws {
        guard var proj = project else { throw ProjectError.noProject }
        guard let dir = projectDir else { throw ProjectError.noFileURL }

        // 写入 .sws 文件
        let swsURL = dir.appendingPathComponent(fileName)
        let data = try encoder.encode(doc)
        try data.write(to: swsURL, options: .atomic)

        // 添加到索引
        let ref = SWSProjectScriptRef(
            id: "script_" + UUID().uuidString.prefix(8).lowercased(),
            name: name,
            path: fileName,
            order: (proj.scripts ?? []).count,
            sceneNumbering: .continueFromPrevious
        )
        var scripts = proj.scripts ?? []
        scripts.append(ref)
        proj.scripts = scripts
        proj.tree = proj.resolvedTree
        project = proj
        markDirty()
    }

    /// 从外部导入 .sws 文件到项目文件夹并加入索引
    ///
    /// - 复制文件到项目目录（保留原始文件不动）
    /// - 默认追加到 scripts 末尾，sceneNumbering = .continueFromPrevious
    /// - 返回新创建的引用
    func importScript(from externalURL: URL) throws -> SWSProjectScriptRef {
        guard var proj = project else { throw ProjectError.noProject }
        guard let dir = projectDir else { throw ProjectError.noFileURL }

        let fileName = externalURL.lastPathComponent
        let destURL = dir.appendingPathComponent(fileName)

        // 同名文件加序号
        let finalDestURL: URL
        if FileManager.default.fileExists(atPath: destURL.path) {
            let stem = externalURL.deletingPathExtension().lastPathComponent
            let ext = externalURL.pathExtension
            var counter = 1
            var candidate: URL
            repeat {
                candidate = dir.appendingPathComponent("\(stem) \(counter).\(ext)")
                counter += 1
            } while FileManager.default.fileExists(atPath: candidate.path)
            finalDestURL = candidate
        } else {
            finalDestURL = destURL
        }

        // 复制文件
        try FileManager.default.copyItem(at: externalURL, to: finalDestURL)

        // 加入索引
        let ref = SWSProjectScriptRef(
            id: "script_" + UUID().uuidString.prefix(8).lowercased(),
            name: externalURL.deletingPathExtension().lastPathComponent,
            path: finalDestURL.lastPathComponent,
            order: (proj.scripts ?? []).count,
            sceneNumbering: .continueFromPrevious
        )
        var scripts = proj.scripts ?? []
        scripts.append(ref)
        proj.scripts = scripts
        proj.tree = proj.resolvedTree
        project = proj
        markDirty()

        return ref
    }

    /// 检查给定文件路径是否属于当前项目的 scripts 数组
    func isScriptInProject(_ filePath: URL) -> Bool {
        guard let proj = project, let dir = projectDir else { return false }
        let resolved = filePath.standardized
        return proj.resolvedScripts.contains { ref in
            let refURL = dir.appendingPathComponent(ref.path).standardized
            return refURL == resolved
        }
    }

    /// 完整的 sidebar tree（含游离文件区域）
    ///
    /// 有项目时：项目 tree + 分隔线 + 游离文件
    /// 无项目时：只显示游离文件
    func sidebarTree(externalScripts: [URL]) -> [SWSProjectTreeNode] {
        var nodes: [SWSProjectTreeNode] = []

        if let proj = project {
            nodes.append(contentsOf: proj.resolvedTree)

            if !externalScripts.isEmpty {
                nodes.append(SWSProjectTreeNode(
                    id: "div_external", name: "游离文件", type: .divider
                ))
                for url in externalScripts {
                    nodes.append(SWSProjectTreeNode(
                        id: "ext_" + url.lastPathComponent,
                        name: url.lastPathComponent,
                        type: .externalScript,
                        ref: url.path
                    ))
                }
            }
        } else {
            for url in externalScripts {
                nodes.append(SWSProjectTreeNode(
                    id: "ext_" + url.lastPathComponent,
                    name: url.lastPathComponent,
                    type: .externalScript,
                    ref: url.path
                ))
            }
        }

        return nodes
    }

    /// 从索引中移除脚本引用
    /// - Parameter deleteFile: 是否同时删除磁盘上的 .sws 文件
    func removeScript(id: String, deleteFile: Bool = false) {
        guard var proj = project else { return }
        if deleteFile, let ref = proj.scriptRef(id: id), let dir = projectDir {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(ref.path))
        }
        proj.scripts?.removeAll { $0.id == id }
        project = proj
        markDirty()
    }

    /// 重排序脚本引用
    func reorderScripts(to orderedIDs: [String]) {
        guard var proj = project,
              var scripts = proj.scripts else { return }
        var reordered: [SWSProjectScriptRef] = []
        for (i, id) in orderedIDs.enumerated() {
            if var ref = scripts.first(where: { $0.id == id }) {
                ref.order = i
                reordered.append(ref)
            }
        }
        // 保留不在 orderedIDs 中的项（追加到末尾）
        for ref in scripts where !orderedIDs.contains(ref.id) {
            var r = ref
            r.order = reordered.count
            reordered.append(r)
        }
        proj.scripts = reordered
        proj.tree = proj.resolvedTree
        project = proj
        markDirty()
    }

    /// 更新脚本引用的元数据（名称、分组名、场号模式）
    func updateScriptRef(id: String, name: String? = nil, groupName: String? = nil, sceneNumbering: SceneNumbering? = nil) {
        guard var proj = project,
              var scripts = proj.scripts,
              let i = scripts.firstIndex(where: { $0.id == id }) else { return }
        if let name { scripts[i].name = name }
        if let groupName { scripts[i].groupName = groupName }
        if let sceneNumbering { scripts[i].sceneNumbering = sceneNumbering }
        proj.scripts = scripts
        proj.tree = proj.resolvedTree
        project = proj
        markDirty()
    }

    // MARK: - Build

    /// Build 指定的分组，返回 (组名, 完整 SWS 文本)
    /// - 每组内按 SceneNumbering 规则自动计算场号
    /// - 返回列表供 UI 渲染为多 Tab 或拼接
    func buildGroups(_ groupIDs: Set<String>) throws -> [(groupName: String, text: String)] {
        guard let proj = project else { throw ProjectError.noProject }
        let allGroups = proj.computeGroups()
        let selected = allGroups.filter { groupIDs.contains($0.id) }
        guard !selected.isEmpty else { return [] }

        var results: [(groupName: String, text: String)] = []

        for group in selected {
            var output = ""
            var sceneOffset = 0
            var sceneCountInGroup = 0

            for ref in group.scriptRefs {
                let doc: SWSDocument
                // 兼容旧项目：path 为空时回退到 proj.script
                #if swift(>=5.9)
                let _ = proj  // silence unused warning in the non-deprecated branch
                #endif
                if ref.path.isEmpty, let inlineScript = ({ () -> String? in proj.script })() {
                    // 从旧 script 文本无法重建 SWSDocument，直接输出原文
                    output += inlineScript + "\n\n"
                    continue
                }
                doc = try loadScript(ref: ref)

                // 场号重算
                if sceneCountInGroup == 0 || ref.sceneNumbering == .resetToFirst {
                    sceneOffset = 0  // 组内第一项或显式重置
                } else {
                    // continueFromPrevious：偏移保持
                }

                for scene in doc.scenes {
                    sceneCountInGroup += 1
                    let sceneNumber = sceneOffset + sceneCountInGroup

                    // 输出场景头（重编号）
                    if let heading = scene.heading {
                        let parts = ["第\(sceneNumber)场", heading.interiorExterior, heading.location, heading.time]
                            .compactMap { $0 }
                        output += "## " + parts.joined(separator: heading.separator) + "\n"
                    }

                    // 输出块
                    for block in scene.blocks {
                        switch block {
                        case .dialogue(let d):
                            output += "[\(d.character)]"
                            if let mod = d.modifier { output += "（\(mod)）" }
                            output += "\n\(d.line)\n"
                        case .action(let a):
                            if !a.text.isEmpty { output += "\(a.text)\n" }
                        case .unattributed(let u):
                            for line in u.lines {
                                output += "> \"\(line)\"\n"
                            }
                        }
                    }
                    output += "\n"
                }

                sceneOffset = sceneCountInGroup
            }

            results.append((groupName: group.name, text: output.trimmingCharacters(in: .whitespacesAndNewlines)))
        }

        return results
    }

    /// Build 单个分组
    func buildGroup(id: String) throws -> (groupName: String, text: String)? {
        let results = try buildGroups([id])
        return results.first
    }

    /// Build 全部分组
    func buildAllGroups() throws -> [(groupName: String, text: String)] {
        guard let proj = project else { throw ProjectError.noProject }
        let allIDs = Set(proj.computeGroups().map { $0.id })
        return try buildGroups(allIDs)
    }

    func updateCharacter(id: String, name: String? = nil, tagline: String? = nil, bio: String? = nil, avatar: String? = nil) {
        guard var proj = project,
              let i = proj.characters.firstIndex(where: { $0.id == id }) else { return }
        if let name { proj.characters[i].name = name }
        if let tagline { proj.characters[i].tagline = tagline }
        if let bio { proj.characters[i].bio = bio }
        if let avatar { proj.characters[i].avatar = avatar }
        project = proj
        markDirty()
    }

    func updateScene(id: String, title: String? = nil, content: String? = nil, location: String? = nil, time: String? = nil) {
        guard var proj = project,
              let i = proj.scenes.firstIndex(where: { $0.id == id }) else { return }
        if let title { proj.scenes[i].title = title }
        if let content { proj.scenes[i].content = content }
        if let location { proj.scenes[i].location = location }
        if let time { proj.scenes[i].time = time }
        project = proj
        markDirty()
    }

    func deleteCharacter(id: String) {
        guard var proj = project else { return }
        proj.characters.removeAll(where: { $0.id == id })
        project = proj
        markDirty()
    }

    func addCharacter(name: String, avatar: String? = nil, tagline: String? = nil, bio: String? = nil) {
        guard var proj = project else { return }
        let char = SWSProjectCharacter(
            id: "char_" + UUID().uuidString.prefix(8).lowercased(),
            name: name,
            avatar: avatar,
            tagline: tagline,
            bio: bio
        )
        proj.characters.append(char)
        project = proj
        markDirty()
    }

    func addScene(title: String, location: String? = nil, time: String? = nil, content: String? = nil) {
        guard var proj = project else { return }
        let scene = SWSProjectScene(
            id: "scene_" + UUID().uuidString.prefix(8).lowercased(),
            title: title,
            location: location,
            time: time,
            content: content
        )
        proj.scenes.append(scene)
        project = proj
        markDirty()
    }

    func rebuildTree() {
        guard var proj = project else { return }
        proj.tree = proj.resolvedTree
        project = proj
        markDirty()
    }

    // MARK: - 序列化（公开给外部用）

    func encode(project: SWSProject) throws -> Data {
        try encoder.encode(project)
    }

    func decode(data: Data) throws -> SWSProject {
        try decoder.decode(SWSProject.self, from: data)
    }

    // MARK: - 内部

    private func write(project proj: SWSProject, to url: URL) throws {
        var mutable = proj
        mutable.meta.updatedAt = dateFormatter.string(from: Date())
        let data = try encode(project: mutable)
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - 错误

enum ProjectError: LocalizedError {
    case noProject
    case noFileURL
    case invalidFileType(String)
    case unsupportedVersion(String)

    var errorDescription: String? {
        switch self {
        case .noProject: return "没有打开的项目"
        case .noFileURL: return "项目尚未保存过，请先另存为"
        case .invalidFileType(let ext): return "文件类型不正确：.\(ext)，期望 .swsproj"
        case .unsupportedVersion(let v): return "不支持的 swsproj 版本：\(v)"
        }
    }
}

// MARK: - 调试

#if DEBUG
extension SWSProjectManager {
    func dump() -> String {
        guard let proj = project else { return "<无项目>" }
        let groups = proj.computeGroups()
        let groupDescs = groups.map { "     \($0.name) (\($0.scriptRefs.count) 个脚本)" }
        var lines: [String] = [
            "📦 \(proj.meta.title)",
            "   版本: swsproj \(proj.swsproj)",
            "   路径: \(fileURL?.path ?? "<未保存>")",
            "   脏: \(_isModified ? "是" : "否")",
            "   角色: \(proj.characters.count) 个",
            "   场景: \(proj.scenes.count) 个",
            "   大纲: \(proj.outline != nil ? "有" : "无")",
            "   脚本: \(proj.resolvedScripts.count) 个引用",
            "   分组: \(groups.count) 组",
        ]
        lines.append(contentsOf: groupDescs)
        lines.append("   树节点: \(proj.resolvedTree.count) 个顶层")
        return lines.joined(separator: "\n")
    }
}
#endif
