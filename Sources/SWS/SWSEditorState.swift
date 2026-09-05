import Foundation

// MARK: - SWSEditorState
/// 编辑器运行时状态（项目级配置，不写入 .sws）
/// 从 SWSModel.swift 拆分而来（2026-09）：用户修正历史 + 增量校验状态

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
