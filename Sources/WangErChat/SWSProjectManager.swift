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

    /// 创建空项目并写入指定 URL
    func createProject(at url: URL, title: String) throws {
        let proj = SWSProject.empty(title: title)
        try write(project: proj, to: url)
        project = proj
        fileURL = url
        _isModified = false
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

    func updateScript(_ text: String) {
        guard var proj = project else { return }
        proj.script = text
        project = proj
        markDirty()
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
        proj.tree = proj.resolvedTree
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
        proj.tree = proj.resolvedTree
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
        return [
            "📦 \(proj.meta.title)",
            "   版本: swsproj \(proj.swsproj)",
            "   路径: \(fileURL?.path ?? "<未保存>")",
            "   脏: \(_isModified ? "是" : "否")",
            "   角色: \(proj.characters.count) 个",
            "   场景: \(proj.scenes.count) 个",
            "   大纲: \(proj.outline != nil ? "有" : "无")",
            "   剧本: \(proj.script != nil ? "有" : "无")",
            "   树节点: \(proj.resolvedTree.count) 个顶层",
        ].joined(separator: "\n")
    }
}
#endif
