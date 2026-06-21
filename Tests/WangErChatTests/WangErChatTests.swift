import Foundation
import Testing
@testable import SWS

// MARK: - SWSSceneHeading

@Test func sceneHeading_swsText_basic() {
    let h = SWSSceneHeading(number: "1", interiorExterior: "内景", location: "书房", time: "日")
    #expect(h.swsText == "## 第1场 · 内景 · 书房 · 日")
}

@Test func sceneHeading_swsText_missingFields() {
    let h = SWSSceneHeading(number: "3", location: "大街")
    #expect(h.swsText == "## 第3场 · 大街")
}

@Test func sceneHeading_separator() {
    let h = SWSSceneHeading(number: "1", interiorExterior: "外景", location: "公园", time: "黄昏", separator: " - ")
    #expect(h.swsText == "## 第1场 - 外景 - 公园 - 黄昏")
}

// MARK: - SWSDialogueBlock

@Test func dialogueBlock_textLines_filtersEmpty() {
    let d = SWSDialogueBlock(character: "郑希远", lines: ["走吧。", "", "别磨蹭了。"])
    #expect(d.textLines == ["走吧。", "别磨蹭了。"])
}

@Test func dialogueBlock_textLines_allEmpty() {
    let d = SWSDialogueBlock(character: "郑希远", lines: ["", "", ""])
    #expect(d.textLines == [])
}

@Test func dialogueBlock_characterCount() {
    let d = SWSDialogueBlock(character: "张三", lines: ["你好。", "", "再见。"])
    #expect(d.characterCount == 6) // "你好。"3字 + "再见。"3字，不含空行
}

@Test func dialogueBlock_withModifier() {
    let d = SWSDialogueBlock(character: "郑希远", modifier: "笑道", lines: ["走吧。"])
    #expect(d.modifier == "笑道")
    #expect(d.character == "郑希远")
}

// MARK: - SWSActionBlock

@Test func actionBlock_basic() {
    let a = SWSActionBlock(text: "窗外开始下雨。")
    #expect(a.text == "窗外开始下雨。")
}

// MARK: - SWSUnattributedBlock

@Test func unattributedBlock_textLines_filtersEmpty() {
    let u = SWSUnattributedBlock(lines: ["我知道你要说什么。", "", "但我不想听。"])
    #expect(u.textLines == ["我知道你要说什么。", "但我不想听。"])
}

// MARK: - SWSBlock Codable round-trip

@Test func blockCodable_dialogue() throws {
    let d = SWSDialogueBlock(character: "郑希远", modifier: "笑道", lines: ["走吧。"])
    let block = SWSBlock.dialogue(d)
    let json = try JSONEncoder().encode(block)
    let decoded = try JSONDecoder().decode(SWSBlock.self, from: json)
    guard case .dialogue(let rd) = decoded else {
        #expect(Bool(false), "Expected .dialogue, got \(decoded)")
        return
    }
    #expect(rd.character == "郑希远")
    #expect(rd.modifier == "笑道")
    #expect(rd.lines == ["走吧。"])
}

@Test func blockCodable_action() throws {
    let a = SWSActionBlock(text: "窗外下雨。")
    let block = SWSBlock.action(a)
    let json = try JSONEncoder().encode(block)
    let decoded = try JSONDecoder().decode(SWSBlock.self, from: json)
    guard case .action(let ra) = decoded else {
        #expect(Bool(false), "Expected .action")
        return
    }
    #expect(ra.text == "窗外下雨。")
}

@Test func blockCodable_unattributed() throws {
    let u = SWSUnattributedBlock(lines: ["hello"])
    let block = SWSBlock.unattributed(u)
    let json = try JSONEncoder().encode(block)
    let decoded = try JSONDecoder().decode(SWSBlock.self, from: json)
    guard case .unattributed(let ru) = decoded else {
        #expect(Bool(false), "Expected .unattributed")
        return
    }
    #expect(ru.lines == ["hello"])
}

@Test func blockCodable_emptyLine() throws {
    let block = SWSBlock.emptyLine
    let json = try JSONEncoder().encode(block)
    let decoded = try JSONDecoder().decode(SWSBlock.self, from: json)
    guard case .emptyLine = decoded else {
        #expect(Bool(false), "Expected .emptyLine, got \(decoded)")
        return
    }
}

// MARK: - SWSScene

@Test func scene_allCharacters_uniqueOrdered() {
    let scene = SWSScene(
        heading: SWSSceneHeading(number: "1", location: "书房"),
        blocks: [
            .dialogue(SWSDialogueBlock(character: "郑希远", lines: ["走吧。"])),
            .dialogue(SWSDialogueBlock(character: "张三", lines: ["来了。"])),
            .dialogue(SWSDialogueBlock(character: "郑希远", lines: ["快点。"])),
        ]
    )
    #expect(scene.allCharacters == ["郑希远", "张三"])
}

@Test func scene_dialogueCount() {
    let scene = SWSScene(blocks: [
        .dialogue(SWSDialogueBlock(character: "A", lines: ["1"])),
        .action(SWSActionBlock(text: "desc")),
        .dialogue(SWSDialogueBlock(character: "B", lines: ["2"])),
        .emptyLine,
    ])
    #expect(scene.dialogueCount == 2)
}

@Test func scene_actionCount() {
    let scene = SWSScene(blocks: [
        .action(SWSActionBlock(text: "a")),
        .action(SWSActionBlock(text: "b")),
        .dialogue(SWSDialogueBlock(character: "X", lines: ["x"])),
    ])
    #expect(scene.actionCount == 2)
}

// MARK: - SWSDocument

@Test func document_allCharacters_crossScene() {
    let doc = SWSDocument(
        scenes: [
            SWSScene(blocks: [
                .dialogue(SWSDialogueBlock(character: "A", lines: ["1"])),
                .dialogue(SWSDialogueBlock(character: "B", lines: ["2"])),
            ]),
            SWSScene(blocks: [
                .dialogue(SWSDialogueBlock(character: "A", lines: ["3"])),
                .dialogue(SWSDialogueBlock(character: "C", lines: ["4"])),
            ]),
        ]
    )
    #expect(doc.allCharacters == ["A", "B", "C"])
}

@Test func document_totalBlockCount() {
    let doc = SWSDocument(
        scenes: [
            SWSScene(blocks: [
                .dialogue(SWSDialogueBlock(character: "A", lines: ["1"])),
                .emptyLine,
                .action(SWSActionBlock(text: "desc")),
            ]),
            SWSScene(blocks: [
                .dialogue(SWSDialogueBlock(character: "B", lines: ["2"])),
            ]),
        ]
    )
    #expect(doc.totalBlockCount == 4)
}

// MARK: - SWSDocument Codable

@Test func documentCodable_roundTrip() throws {
    let original = SWSDocument(
        metadata: SWSMetadata(sws: "1.0", title: "测试剧本", author: "王二"),
        scenes: [
            SWSScene(
                heading: SWSSceneHeading(number: "1", interiorExterior: "内景", location: "书房", time: "日"),
                blocks: [
                    .action(SWSActionBlock(text: "郑希远坐在书桌前。")),
                    .dialogue(SWSDialogueBlock(character: "郑希远", modifier: "笑道", lines: ["走吧。"])),
                    .emptyLine,
                    .unattributed(SWSUnattributedBlock(lines: ["我知道你要说什么。"])),
                ]
            ),
        ]
    )

    let json = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(SWSDocument.self, from: json)

    #expect(decoded.metadata.title == "测试剧本")
    #expect(decoded.metadata.author == "王二")
    #expect(decoded.scenes.count == 1)
    #expect(decoded.scenes[0].heading?.number == "1")
    #expect(decoded.scenes[0].blocks.count == 4)
    // 第一块 action
    guard case .action(let a) = decoded.scenes[0].blocks[0] else {
        #expect(Bool(false), "Block 0 should be action")
        return
    }
    #expect(a.text == "郑希远坐在书桌前。")
}

// MARK: - ValidationStatus

@Test func validationStatus_cssClass() {
    #expect(ValidationStatus.confirmed.cssClass == "sws-status-confirmed")
    #expect(ValidationStatus.pending.cssClass == "sws-status-pending")
    #expect(ValidationStatus.action.cssClass == "sws-status-action")
    #expect(ValidationStatus.none.cssClass == "")
}

@Test func validationStatus_colorHex() {
    #expect(ValidationStatus.confirmed.colorHex == "#22C55E")
    #expect(ValidationStatus.pending.colorHex == "#3B82F6")
    #expect(ValidationStatus.action.colorHex == "#9CA3AF")
    #expect(ValidationStatus.none.colorHex == "transparent")
}

// MARK: - LineValidation

@Test func lineValidation_basic() {
    let v = LineValidation(
        blockType: .dialogue,
        status: .confirmed,
        character: "郑希远",
        dialogueBlockClosed: false
    )
    #expect(v.blockType == .dialogue)
    #expect(v.status == .confirmed)
    #expect(v.character == "郑希远")
    #expect(v.dialogueBlockClosed == false)
}

@Test func lineValidation_pendingNameLine() {
    // 模拟「[角色名]独占一行，等下一行确认」的场景
    let v = LineValidation(
        blockType: .dialogue,
        status: .pending,
        character: "张三",
        dialogueBlockClosed: false
    )
    #expect(v.status == .pending)
    #expect(v.character == "张三")
}

// MARK: - CorrectionLog

@Test func correctionLog_predictCharacter_match() {
    var log = CorrectionLog()
    log.corrections.append(Correction(kind: .setCharacter, pattern: "郑希远", value: "郑希远"))
    let result = log.predictCharacter(for: "郑希远愣了一下")
    #expect(result == "郑希远")
}

@Test func correctionLog_predictCharacter_noMatch() {
    var log = CorrectionLog()
    log.corrections.append(Correction(kind: .setCharacter, pattern: "张三", value: "张三"))
    let result = log.predictCharacter(for: "李四走过来")
    #expect(result == nil)
}

@Test func correctionLog_shouldBeDialogue_true() {
    var log = CorrectionLog()
    log.corrections.append(Correction(kind: .markAsDialogue, pattern: "你好", value: nil))
    #expect(log.shouldBeDialogue("你好世界") == true)
}

@Test func correctionLog_shouldBeDialogue_false() {
    var log = CorrectionLog()
    log.corrections.append(Correction(kind: .markAsAction, pattern: "下雨", value: nil))
    #expect(log.shouldBeDialogue("窗外下雨了") == false)
}

@Test func correctionLog_shouldBeDialogue_nil() {
    let log = CorrectionLog()
    #expect(log.shouldBeDialogue("随便什么内容") == nil)
}

@Test func correctionLog_lastCorrectionWins() {
    // 同一 pattern 先标 action 再标 dialogue，后者优先
    var log = CorrectionLog()
    log.corrections.append(Correction(kind: .markAsAction, pattern: "你好", value: nil))
    log.corrections.append(Correction(kind: .markAsDialogue, pattern: "你好", value: nil))
    #expect(log.shouldBeDialogue("你好世界") == true)
}

// MARK: - DisplayStyle presets

@Test func displayStyle_fivePresets() {
    #expect(DisplayStyle.presets.count == 5)
    let names = DisplayStyle.presets.map(\.name)
    #expect(names.contains("chinese_standard"))
    #expect(names.contains("chinese_inline"))
    #expect(names.contains("stage_play"))
    #expect(names.contains("screenplay_english"))
    #expect(names.contains("novel_style"))
}

@Test func displayStyle_chineseStandard_layout() {
    let s = DisplayStyle.chineseStandard
    #expect(s.dialogue.layout == .nameAboveText)
    #expect(s.sceneHeading.alignment == "center")
}

@Test func displayStyle_chineseInline_layout() {
    let s = DisplayStyle.chineseInline
    #expect(s.dialogue.layout == .nameInlineColon)
    #expect(s.dialogue.separator == "：")
}

// MARK: - ImportProfile presets

@Test func importProfile_threePresets() {
    #expect(ImportProfile.presets.count == 3)
    let names = ImportProfile.presets.map(\.name)
    #expect(names.contains("chinese_inline_colon"))
    #expect(names.contains("chinese_name_above"))
    #expect(names.contains("auto_detect"))
}

@Test func importProfile_autoDetect_hasAllStrategies() {
    let p = ImportProfile.autoDetect
    #expect(p.parsingRules.dialogue.strategies.count == 5)
}

// MARK: - DialogueLayout

@Test func dialogueLayout_allCases() {
    let all = DialogueLayout.allCases
    #expect(all.count == 4)
}

@Test func dialogueLayout_displayName() {
    #expect(DialogueLayout.nameAboveText.displayName.contains("角色名居中"))
    #expect(DialogueLayout.nameInlineColon.displayName.contains("："))
    #expect(DialogueLayout.nameInlineDash.displayName.contains("——"))
    #expect(DialogueLayout.nameLeftTextIndent.displayName.contains("顶格"))
}

// MARK: - ModifierStyle

@Test func modifierStyle_allCases() {
    #expect(ModifierStyle.allCases.count == 4)
}

// MARK: - SceneSeparatorStyle

@Test func sceneSeparatorStyle_allCases() {
    #expect(SceneSeparatorStyle.allCases.count == 3)
}

// MARK: - SWSFormatter: Serialize (Document → .sws)

@Test func formatter_serialize_emptyDocument() {
    let doc = SWSDocument()
    let f = SWSFormatter()
    let text = f.serialize(doc)
    // 空文档 → 仅末尾换行
    #expect(text == "\n")
}

@Test func formatter_serialize_metadataOnly() {
    let meta = SWSMetadata(sws: "1.0", title: "测试", author: "王二")
    let doc = SWSDocument(metadata: meta)
    let f = SWSFormatter()
    let text = f.serialize(doc)
    #expect(text.hasPrefix("---\n"))
    #expect(text.contains("sws: 1.0\n"))
    #expect(text.contains("title: 测试\n"))
    #expect(text.contains("author: 王二\n"))
    #expect(text.hasSuffix("---\n\n"))
}

@Test func formatter_serialize_oneScene_withHeading() {
    let scene = SWSScene(
        heading: SWSSceneHeading(number: "1", interiorExterior: "内景", location: "书房", time: "日"),
        blocks: [
            .action(SWSActionBlock(text: "郑希远坐在书桌前。")),
        ]
    )
    let doc = SWSDocument(scenes: [scene])
    let f = SWSFormatter()
    let text = f.serialize(doc)
    #expect(text.contains("## 第1场 · 内景 · 书房 · 日"))
    #expect(text.contains("郑希远坐在书桌前。"))
}

@Test func formatter_serialize_dialogue_nameAbove() {
    let d = SWSDialogueBlock(character: "郑希远", lines: ["走吧。", "别磨蹭了。"])
    let scene = SWSScene(blocks: [.dialogue(d)])
    let doc = SWSDocument(scenes: [scene])
    let f = SWSFormatter(dialogueFormat: .nameAbove)
    let text = f.serialize(doc)

    // 应该有 [郑希远] 独占一行，后跟台词
    #expect(text.contains("[郑希远]\n"))
    #expect(text.contains("走吧。\n"))
    #expect(text.contains("别磨蹭了。\n"))
    // 不应出现冒号格式
    #expect(!text.contains("[郑希远]："))
}

@Test func formatter_serialize_dialogue_nameAbove_withModifier() {
    let d = SWSDialogueBlock(character: "张三", modifier: "笑道", lines: ["来了。"])
    let scene = SWSScene(blocks: [.dialogue(d)])
    let doc = SWSDocument(scenes: [scene])
    let f = SWSFormatter(dialogueFormat: .nameAbove)
    let text = f.serialize(doc)
    #expect(text.contains("[张三 | 笑道]\n"))
}

@Test func formatter_serialize_dialogue_inline() {
    let d = SWSDialogueBlock(character: "郑希远", lines: ["走吧。", "别磨蹭了。"])
    let scene = SWSScene(blocks: [.dialogue(d)])
    let doc = SWSDocument(scenes: [scene])
    let f = SWSFormatter(dialogueFormat: .inline)
    let text = f.serialize(doc)
    // 每行台词带 [角色名]： 前缀
    #expect(text.contains("[郑希远]：走吧。"))
    #expect(text.contains("[郑希远]：别磨蹭了。"))
}

@Test func formatter_serialize_dialogue_inline_withModifier() {
    let d = SWSDialogueBlock(character: "张三", modifier: "VO", lines: ["我早就知道了。"])
    let scene = SWSScene(blocks: [.dialogue(d)])
    let doc = SWSDocument(scenes: [scene])
    let f = SWSFormatter(dialogueFormat: .inline)
    let text = f.serialize(doc)
    #expect(text.contains("[张三 | VO]：我早就知道了。"))
}

@Test func formatter_serialize_dialogue_inline_emptyLines() {
    // inline 格式：空行保留但不加前缀
    let d = SWSDialogueBlock(character: "郑希远", lines: ["第一段。", "", "第二段。"])
    let scene = SWSScene(blocks: [.dialogue(d)])
    let doc = SWSDocument(scenes: [scene])
    let f = SWSFormatter(dialogueFormat: .inline)
    let text = f.serialize(doc)
    #expect(text.contains("[郑希远]：第一段。"))
    #expect(text.contains("[郑希远]：第二段。"))
    // 空行应保留
    let lines = text.components(separatedBy: "\n")
    // 找到空行（台词段之间的空行）
    #expect(lines.contains(""))
}

@Test func formatter_serialize_unattributed() {
    let u = SWSUnattributedBlock(lines: ["\"我知道你要说什么。\""])
    let scene = SWSScene(blocks: [.unattributed(u)])
    let doc = SWSDocument(scenes: [scene])
    let f = SWSFormatter()
    let text = f.serialize(doc)
    #expect(text.contains("> \"我知道你要说什么。\""))
}

@Test func formatter_serialize_emptyLine() {
    let scene = SWSScene(blocks: [
        .action(SWSActionBlock(text: "下雨了。")),
        .emptyLine,
        .action(SWSActionBlock(text: "打雷了。")),
    ])
    let doc = SWSDocument(scenes: [scene])
    let f = SWSFormatter()
    let text = f.serialize(doc)
    // 空行两边各一个 action
    let lines = text.components(separatedBy: "\n")
    let rainIdx = lines.firstIndex(of: "下雨了。")
    let thunderIdx = lines.firstIndex(of: "打雷了。")
    #expect(rainIdx != nil)
    #expect(thunderIdx != nil)
    #expect(thunderIdx! - rainIdx! >= 2) // 至少隔一个空行
}

@Test func formatter_serialize_fullExample() {
    // 基于 spec 第八节完整示例
    let doc = SWSDocument(
        metadata: SWSMetadata(sws: "1.0", title: "未命名剧本"),
        scenes: [
            SWSScene(
                heading: SWSSceneHeading(number: "1", interiorExterior: "内景", location: "郑希远书房", time: "日"),
                blocks: [
                    .action(SWSActionBlock(text: "郑希远坐在书桌前，窗外阳光刺眼。他盯着屏幕已经三个小时了。")),
                    .dialogue(SWSDialogueBlock(character: "郑希远", modifier: "揉了揉眼睛", lines: ["又 crash 了。"])),
                    .dialogue(SWSDialogueBlock(character: "李四", modifier: "从门外探头", lines: ["还没修好？"])),
                    .action(SWSActionBlock(text: "郑希远没回答，只是重重地合上了笔记本。")),
                    .dialogue(SWSDialogueBlock(character: "李四", lines: ["我跟你说个事。"])),
                    .dialogue(SWSDialogueBlock(character: "郑希远", lines: ["说。"])),
                    .action(SWSActionBlock(text: "李四点了一支烟，在房间里踱了两步。")),
                    .dialogue(SWSDialogueBlock(character: "李四", modifier: "深吸一口烟", lines: ["甲方要改需求。"])),
                    .action(SWSActionBlock(text: "郑希远慢慢地转过头来，表情像是听到了噩耗。")),
                    .dialogue(SWSDialogueBlock(character: "郑希远", modifier: "面无表情", lines: ["哪个甲方。"])),
                ]
            ),
            SWSScene(
                heading: SWSSceneHeading(number: "2", interiorExterior: "外景", location: "公司楼下", time: "夜"),
                blocks: [
                    .action(SWSActionBlock(text: "路灯昏黄。李四和郑希远沉默地站在路边。")),
                    .dialogue(SWSDialogueBlock(character: "李四", lines: ["全部。"])),
                ]
            ),
        ]
    )

    let f = SWSFormatter(dialogueFormat: .nameAbove)
    let text = f.serialize(doc)

    // 检查关键内容
    #expect(text.hasPrefix("---\n"))
    #expect(text.contains("title: 未命名剧本"))
    #expect(text.contains("## 第1场 · 内景 · 郑希远书房 · 日"))
    #expect(text.contains("[郑希远 | 揉了揉眼睛]"))
    #expect(text.contains("又 crash 了。"))
    #expect(text.contains("[李四 | 从门外探头]"))
    #expect(text.contains("哪个甲方。"))
    #expect(text.contains("## 第2场 · 外景 · 公司楼下 · 夜"))
    #expect(text.contains("[李四]"))
    #expect(text.contains("全部。"))
    #expect(!text.contains("[郑希远]："))  // nameAbove 格式
}

// MARK: - SWSFormatter: Deserialize (.sws → Document)

@Test func formatter_deserialize_emptyString() {
    var f = SWSFormatter()
    let doc = f.deserialize("")
    #expect(doc.scenes.isEmpty)
    #expect(doc.metadata.sws == "1.0")
}

@Test func formatter_deserialize_metadataOnly() {
    let text = """
    ---
    sws: 1.0
    title: 测试剧本
    author: 王二
    ---
    """
    var f = SWSFormatter()
    let doc = f.deserialize(text)
    #expect(doc.metadata.title == "测试剧本")
    #expect(doc.metadata.author == "王二")
    #expect(doc.scenes.isEmpty)
}

@Test func formatter_deserialize_sceneHeading() {
    let text = """
    ## 第1场 · 内景 · 书房 · 日

    郑希远坐在书桌前。
    """
    var f = SWSFormatter()
    let doc = f.deserialize(text)
    #expect(doc.scenes.count == 1)
    let scene = doc.scenes[0]
    #expect(scene.heading?.number == "1")
    #expect(scene.heading?.interiorExterior == "内景")
    #expect(scene.heading?.location == "书房")
    #expect(scene.heading?.time == "日")
    // 场景头后的空行 + 动作行 = 2 个 block（emptyLine + action）
    #expect(scene.blocks.count == 2)
    guard case .emptyLine = scene.blocks[0] else {
        #expect(Bool(false), "Expected emptyLine, got \(scene.blocks[0])")
        return
    }
    guard case .action(let a) = scene.blocks[1] else {
        #expect(Bool(false), "Expected action, got \(scene.blocks[1])")
        return
    }
    #expect(a.text == "郑希远坐在书桌前。")
}

@Test func formatter_deserialize_inlineDialogue() {
    let text = """
    [郑希远]：走吧。

    [张三]：来了。
    """
    var f = SWSFormatter()
    let doc = f.deserialize(text)
    #expect(doc.scenes.count == 1)
    #expect(doc.scenes[0].blocks.count == 3) // dialogue + emptyLine + dialogue
    guard case .dialogue(let d1) = doc.scenes[0].blocks[0] else {
        #expect(Bool(false), "Expected dialogue")
        return
    }
    #expect(d1.character == "郑希远")
    #expect(d1.lines == ["走吧。"])

    guard case .dialogue(let d2) = doc.scenes[0].blocks[2] else {
        #expect(Bool(false), "Expected dialogue")
        return
    }
    #expect(d2.character == "张三")
    #expect(d2.lines == ["来了。"])
}

@Test func formatter_deserialize_inlineDialogue_withModifier() {
    let text = "[张三 | VO]：我早就知道了。"
    var f = SWSFormatter()
    let doc = f.deserialize(text)
    #expect(doc.scenes.count == 1)
    guard case .dialogue(let d) = doc.scenes[0].blocks[0] else {
        #expect(Bool(false), "Expected dialogue")
        return
    }
    #expect(d.character == "张三")
    #expect(d.modifier == "VO")
    #expect(d.lines == ["我早就知道了。"])
}

@Test func formatter_deserialize_nameAboveDialogue() {
    let text = """
    [郑希远]
    走吧。
    别磨蹭了。
    """
    var f = SWSFormatter()
    let doc = f.deserialize(text)
    #expect(doc.scenes.count == 1)
    #expect(doc.scenes[0].blocks.count == 1)
    guard case .dialogue(let d) = doc.scenes[0].blocks[0] else {
        #expect(Bool(false), "Expected dialogue")
        return
    }
    #expect(d.character == "郑希远")
    #expect(d.modifier == nil)
    #expect(d.lines == ["走吧。", "别磨蹭了。"])
}

@Test func formatter_deserialize_nameAboveDialogue_withModifier() {
    let text = """
    [郑希远 | 笑道]
    走吧。
    """
    var f = SWSFormatter()
    let doc = f.deserialize(text)
    guard case .dialogue(let d) = doc.scenes[0].blocks[0] else {
        #expect(Bool(false), "Expected dialogue")
        return
    }
    #expect(d.character == "郑希远")
    #expect(d.modifier == "笑道")
    #expect(d.lines == ["走吧。"])
}

@Test func formatter_deserialize_multiLineDialogue() {
    // spec 4.3: 多段对白
    let text = """
    [郑希远]
    第一段话。

    第二段话。

    [张三]
    轮到我了。
    """
    var f = SWSFormatter()
    let doc = f.deserialize(text)
    #expect(doc.scenes.count == 1)
    #expect(doc.scenes[0].blocks.count == 2)  // 两个 dialogue block

    guard case .dialogue(let d1) = doc.scenes[0].blocks[0] else {
        #expect(Bool(false), "Expected dialogue")
        return
    }
    #expect(d1.character == "郑希远")
    // 内部空行保留，但尾随空行（对白块分隔符）已被 trim
    #expect(d1.lines == ["第一段话。", "", "第二段话。"])

    guard case .dialogue(let d2) = doc.scenes[0].blocks[1] else {
        #expect(Bool(false), "Expected dialogue")
        return
    }
    #expect(d2.character == "张三")
    #expect(d2.lines == ["轮到我了。"])
}

@Test func formatter_deserialize_dialogueEndedByAction() {
    // 对白块内普通文本行 = 台词延续（用户可通过编辑器右键修正拆分为动作）
    let text = """
    [郑希远]
    走吧。

    窗外开始下雨。
    """
    var f = SWSFormatter()
    let doc = f.deserialize(text)
    // 对白块直到下一个 [角色名] 或 ## 才结束
    #expect(doc.scenes[0].blocks.count == 1)

    guard case .dialogue(let d) = doc.scenes[0].blocks[0] else {
        #expect(Bool(false), "Expected dialogue")
        return
    }
    // 所有行都在对白块内
    #expect(d.lines == ["走吧。", "", "窗外开始下雨。"])
}

@Test func formatter_deserialize_unattributed() {
    let text = "> \"我知道你要说什么。\""
    var f = SWSFormatter()
    let doc = f.deserialize(text)
    guard case .unattributed(let u) = doc.scenes[0].blocks[0] else {
        #expect(Bool(false), "Expected unattributed")
        return
    }
    #expect(u.lines == ["\"我知道你要说什么。\""])
}

@Test func formatter_deserialize_emptyDialogueLine() {
    let text = ">"
    var f = SWSFormatter()
    let doc = f.deserialize(text)
    guard case .unattributed(let u) = doc.scenes[0].blocks[0] else {
        #expect(Bool(false), "Expected unattributed")
        return
    }
    #expect(u.lines == [""])
}

@Test func formatter_deserialize_actionBeforeScene() {
    // 无场景头的动作行
    let text = "郑希远坐在书桌前。"
    var f = SWSFormatter()
    let doc = f.deserialize(text)
    #expect(doc.scenes.count == 1)
    #expect(doc.scenes[0].heading == nil)
    guard case .action(let a) = doc.scenes[0].blocks[0] else {
        #expect(Bool(false), "Expected action")
        return
    }
    #expect(a.text == "郑希远坐在书桌前。")
}

@Test func formatter_deserialize_mixedInlineNameAbove() {
    // 混用：一个 inline，一个 name-above
    let text = """
    [郑希远]：走吧。

    [张三]
    知道了。
    """
    var f = SWSFormatter()
    let doc = f.deserialize(text)
    #expect(doc.scenes[0].blocks.count == 3) // inline Dialogue + emptyLine + name-above Dialogue

    guard case .dialogue(let d1) = doc.scenes[0].blocks[0] else {
        #expect(Bool(false), "Expected dialogue")
        return
    }
    #expect(d1.character == "郑希远")
    #expect(d1.lines == ["走吧。"])

    guard case .dialogue(let d2) = doc.scenes[0].blocks[2] else {
        #expect(Bool(false), "Expected dialogue")
        return
    }
    #expect(d2.character == "张三")
    #expect(d2.lines == ["知道了。"])
}

@Test func formatter_deserialize_bracketedActionNotDialogue() {
    // [方括号文本]但没有：且不独占一行 → 动作，不是对白
    let text = "他看了一眼[张三]，没说话。"
    var f = SWSFormatter()
    let doc = f.deserialize(text)
    guard case .action(let a) = doc.scenes[0].blocks[0] else {
        #expect(Bool(false), "Expected action, got \(doc.scenes[0].blocks[0])")
        return
    }
    #expect(a.text == "他看了一眼[张三]，没说话。")
}

@Test func formatter_deserialize_bracketedTextAfterName() {
    // [郑希远]慢慢地抬起头 → 不是对白（方括号后有文字但不是 ： ）
    let text = "[郑希远]慢慢地抬起头"
    var f = SWSFormatter()
    let doc = f.deserialize(text)
    guard case .action(let a) = doc.scenes[0].blocks[0] else {
        #expect(Bool(false), "Expected action, got \(doc.scenes[0].blocks[0])")
        return
    }
    #expect(a.text == "[郑希远]慢慢地抬起头")
}

@Test func formatter_deserialize_sceneHeading_dashSeparator() {
    let text = "## 1 - 外景 - 大街 - 夜"
    var f = SWSFormatter()
    let doc = f.deserialize(text)
    let h = doc.scenes[0].heading
    #expect(h?.number == "1")
    #expect(h?.interiorExterior == "外景")
    #expect(h?.location == "大街")
    #expect(h?.time == "夜")
    #expect(h?.separator == " - ")
}

@Test func formatter_deserialize_sceneHeading_minimal() {
    let text = "## 第1场"
    var f = SWSFormatter()
    let doc = f.deserialize(text)
    let h = doc.scenes[0].heading
    #expect(h?.number == "1")
    #expect(h?.interiorExterior == nil)
    #expect(h?.location == nil)
    #expect(h?.time == nil)
}

@Test func formatter_deserialize_warnings() {
    var f = SWSFormatter()
    // 无效 YAML 行
    let _ = f.deserialize("---\nbad line\n---\n")
    let warnings = f.lastWarnings
    #expect(!warnings.isEmpty)
    #expect(warnings[0].message.contains("YAML"))
}

// MARK: - SWSFormatter: Round-trip (deserialize ∘ serialize == id)

@Test func formatter_roundTrip_nameAbove() {
    // nameAbove 格式 round-trip：语义内容（角色、台词、动作文本、场景头）完全保留
    let original = SWSDocument(
        metadata: SWSMetadata(sws: "1.0", title: "Round Trip", author: "测试"),
        scenes: [
            SWSScene(
                heading: SWSSceneHeading(number: "1", interiorExterior: "内景", location: "书房", time: "日"),
                blocks: [
                    .action(SWSActionBlock(text: "郑希远坐在书桌前。")),
                    .dialogue(SWSDialogueBlock(character: "郑希远", modifier: "笑道", lines: ["走吧。", "别磨蹭了。"])),
                    .emptyLine,
                    .dialogue(SWSDialogueBlock(character: "张三", lines: ["来了。"])),
                    .unattributed(SWSUnattributedBlock(lines: ["\"我知道。\""])),
                ]
            ),
            SWSScene(
                heading: SWSSceneHeading(number: "2", interiorExterior: "外景", location: "公司楼下", time: "夜"),
                blocks: [
                    .action(SWSActionBlock(text: "路灯昏黄。")),
                ]
            ),
        ]
    )

    // nameAbove 格式保留多段对白
    let f1 = SWSFormatter(dialogueFormat: .nameAbove)
    let text = f1.serialize(original)

    var f2 = SWSFormatter()
    let round = f2.deserialize(text)

    // 语义验证（非逐 block 结构对比）
    #expect(round.metadata.title == original.metadata.title)
    #expect(round.metadata.author == original.metadata.author)
    #expect(round.scenes.count == original.scenes.count)

    // Scene 1
    let s1 = round.scenes[0]
    #expect(s1.heading?.number == "1")
    #expect(s1.heading?.interiorExterior == "内景")
    #expect(s1.heading?.location == "书房")
    #expect(s1.heading?.time == "日")
    #expect(s1.allCharacters == ["郑希远", "张三"])
    #expect(s1.dialogueCount == 2)

    // 合并对白文本对比
    let origDialogueTexts = original.scenes[0].blocks.compactMap { block -> String? in
        if case .dialogue(let d) = block {
            return "\(d.character):\(d.modifier ?? ""):\(d.lines.joined())"
        }
        return nil
    }
    let roundDialogueTexts = round.scenes[0].blocks.compactMap { block -> String? in
        if case .dialogue(let d) = block {
            return "\(d.character):\(d.modifier ?? ""):\(d.lines.joined())"
        }
        return nil
    }
    #expect(origDialogueTexts == roundDialogueTexts)

    // 动作文本
    let origActions = original.scenes[0].blocks.compactMap { if case .action(let a) = $0 { a.text } else { nil } }
    let roundActions = round.scenes[0].blocks.compactMap { if case .action(let a) = $0 { a.text } else { nil } }
    #expect(origActions == roundActions)

    // Unattributed
    let origUnattr = original.scenes[0].blocks.compactMap { if case .unattributed(let u) = $0 { u.lines } else { nil } }
    let roundUnattr = round.scenes[0].blocks.compactMap { if case .unattributed(let u) = $0 { u.lines } else { nil } }
    #expect(origUnattr == roundUnattr)

    // Scene 2
    #expect(round.scenes[1].heading?.number == "2")
}

@Test func formatter_roundTrip_noMetadata() {
    // 无元数据，用 nameAbove 格式 + 语义验证
    let original = SWSDocument(
        scenes: [
            SWSScene(
                heading: SWSSceneHeading(number: "1", location: "书房"),
                blocks: [
                    .action(SWSActionBlock(text: "下雨了。")),
                    .emptyLine,
                    .dialogue(SWSDialogueBlock(character: "A", lines: ["你好。"])),
                ]
            )
        ]
    )
    let f1 = SWSFormatter(dialogueFormat: .nameAbove)
    let text = f1.serialize(original)

    var f2 = SWSFormatter()
    let round = f2.deserialize(text)

    #expect(round.metadata.title == nil)
    #expect(round.scenes.count == 1)
    #expect(round.scenes[0].heading?.number == "1")
    #expect(round.scenes[0].heading?.location == "书房")
    // 语义：有 action 和对白
    #expect(round.scenes[0].dialogueCount == 1)
    #expect(round.scenes[0].actionCount == 1)
    let actions = round.scenes[0].blocks.compactMap { if case .action(let a) = $0 { a.text } else { nil } }
    #expect(actions == ["下雨了。"])
    let dialogues = round.scenes[0].blocks.compactMap { if case .dialogue(let d) = $0 { d } else { nil } }
    #expect(dialogues.count == 1)
    #expect(dialogues[0].character == "A")
    #expect(dialogues[0].lines == ["你好。"])
}

@Test func formatter_deserialize_fullSpecExample() {
    // 基于 spec 第八节完整示例的 .sws 文本
    let text = """
    ---
    sws: 1.0
    title: 未命名剧本
    ---

    ## 第1场 · 内景 · 郑希远书房 · 日

    郑希远坐在书桌前，窗外阳光刺眼。他盯着屏幕已经三个小时了。

    [郑希远 | 揉了揉眼睛]
    又 crash 了。

    [李四 | 从门外探头]
    还没修好？

    郑希远没回答，只是重重地合上了笔记本。

    [李四]
    我跟你说个事。

    [郑希远]
    说。

    李四点了一支烟，在房间里踱了两步。

    [李四 | 深吸一口烟]
    甲方要改需求。

    郑希远慢慢地转过头来，表情像是听到了噩耗。

    [郑希远 | 面无表情]
    哪个甲方。

    ## 第2场 · 外景 · 公司楼下 · 夜

    路灯昏黄。李四和郑希远沉默地站在路边。

    [李四]
    全部。
    """

    var f = SWSFormatter()
    let doc = f.deserialize(text)

    // Metadata
    #expect(doc.metadata.title == "未命名剧本")

    // Scenes
    #expect(doc.scenes.count == 2)

    // Scene 1
    let s1 = doc.scenes[0]
    #expect(s1.heading?.number == "1")
    #expect(s1.heading?.location == "郑希远书房")
    #expect(s1.allCharacters == ["郑希远", "李四"])

    // Count dialogue blocks in scene 1
    let s1Dialogues = s1.blocks.compactMap { if case .dialogue(let d) = $0 { d } else { nil } }
    #expect(s1Dialogues.count == 6)
    #expect(s1Dialogues[0].character == "郑希远")
    #expect(s1Dialogues[0].modifier == "揉了揉眼睛")
    #expect(s1Dialogues[0].lines == ["又 crash 了。"])
    #expect(s1Dialogues[1].character == "李四")
    #expect(s1Dialogues[1].modifier == "从门外探头")
    #expect(s1Dialogues[5].character == "郑希远")
    #expect(s1Dialogues[5].modifier == "面无表情")

    // Scene 2
    let s2 = doc.scenes[1]
    #expect(s2.heading?.number == "2")
    #expect(s2.heading?.location == "公司楼下")
    #expect(s2.allCharacters == ["李四"])

    let s2Dialogues = s2.blocks.compactMap { if case .dialogue(let d) = $0 { d } else { nil } }
    #expect(s2Dialogues.count == 1)
    #expect(s2Dialogues[0].character == "李四")
    #expect(s2Dialogues[0].lines == ["全部。"])

    // Cross-scene characters
    #expect(doc.allCharacters == ["郑希远", "李四"])
}

// MARK: - SWSRenderer Tests

@Test func renderer_emptyDocument() {
    let doc = SWSDocument()
    let html = SWSRenderer.render(document: doc, style: .chineseStandard)
    #expect(html.hasPrefix("<!DOCTYPE html>"))
    #expect(html.contains("</html>"))
    #expect(html.contains("sws-scene"))
}

@Test func renderer_titleAndAuthor() {
    let meta = SWSMetadata(title: "测试剧本", author: "王二")
    let doc = SWSDocument(metadata: meta)
    let body = SWSRenderer.renderBody(document: doc, style: .chineseStandard)
    #expect(body.contains("测试剧本"))
    #expect(body.contains("王二"))
    #expect(body.contains("sws-title"))
    #expect(body.contains("sws-author"))
}

@Test func renderer_sceneHeading() {
    let heading = SWSSceneHeading(number: "1", interiorExterior: "内景", location: "书房", time: "日")
    let scene = SWSScene(heading: heading)
    let doc = SWSDocument(scenes: [scene])
    let body = SWSRenderer.renderBody(document: doc, style: .chineseStandard)
    #expect(body.contains("第1场"))
    #expect(body.contains("内景"))
    #expect(body.contains("书房"))
    #expect(body.contains("日"))
    #expect(body.contains("sws-scene-heading"))
    #expect(body.contains("data-scene=\"0\""))
}

@Test func renderer_dialogue() {
    let block = SWSBlock.dialogue(SWSDialogueBlock(character: "郑希远", modifier: "笑道", lines: ["你好。", "今天天气不错。"]))
    let scene = SWSScene(blocks: [block])
    let doc = SWSDocument(scenes: [scene])
    let body = SWSRenderer.renderBody(document: doc, style: .chineseStandard)
    #expect(body.contains("郑希远"))
    #expect(body.contains("笑道"))
    #expect(body.contains("你好。"))
    #expect(body.contains("今天天气不错。"))
    #expect(body.contains("data-sws-type=\"dialogue\""))
}

@Test func renderer_dialogueInlineColon() {
    let block = SWSBlock.dialogue(SWSDialogueBlock(character: "郑希远", lines: ["走吧。"]))
    let scene = SWSScene(blocks: [block])
    let doc = SWSDocument(scenes: [scene])
    let body = SWSRenderer.renderBody(document: doc, style: .chineseInline)
    #expect(body.contains("郑希远"))
    #expect(body.contains("："))  // colon separator
    #expect(body.contains("走吧。"))
}

@Test func renderer_action() {
    let block = SWSBlock.action(SWSActionBlock(text: "郑希远坐在书桌前。"))
    let scene = SWSScene(blocks: [block])
    let doc = SWSDocument(scenes: [scene])
    let body = SWSRenderer.renderBody(document: doc, style: .chineseStandard)
    #expect(body.contains("郑希远坐在书桌前。"))
    #expect(body.contains("data-sws-type=\"action\""))
}

@Test func renderer_unattributed() {
    let block = SWSBlock.unattributed(SWSUnattributedBlock(lines: ["我知道你要说什么。", "但我不想听。"]))
    let scene = SWSScene(blocks: [block])
    let doc = SWSDocument(scenes: [scene])
    let body = SWSRenderer.renderBody(document: doc, style: .chineseStandard)
    #expect(body.contains("我知道你要说什么。"))
    #expect(body.contains("但我不想听。"))
    #expect(body.contains("data-sws-type=\"unattributed\""))
    #expect(body.contains("#888"))  // italic gray style
}

@Test func renderer_emptyLine() {
    let scene = SWSScene(blocks: [SWSBlock.emptyLine])
    let doc = SWSDocument(scenes: [scene])
    let body = SWSRenderer.renderBody(document: doc, style: .chineseStandard)
    #expect(body.contains("sws-empty-line"))
}

@Test func renderer_fullExampleRoundTrip() throws {
    // Build a full example document inline
    let metadata = SWSMetadata(
        sws: "1.0",
        title: "Bug 人生",
        author: "郑希远",
        created: "2026-06-26",
        sourceFormat: "finaldraft"
    )
    let doc = SWSDocument(
        metadata: metadata,
        scenes: [
            SWSScene(
                heading: SWSSceneHeading(number: "1", interiorExterior: "内景", location: "郑希远书房", time: "深夜"),
                blocks: [
                    .action(SWSActionBlock(text: "郑希远坐在书桌前，一脸愁容。窗外下起了雨。")),
                    .dialogue(SWSDialogueBlock(character: "郑希远", modifier: "揉了揉眼睛", lines: ["又 crash 了。"])),
                    .dialogue(SWSDialogueBlock(character: "李四", modifier: "从门外探头", lines: ["还没修好？"])),
                    .dialogue(SWSDialogueBlock(character: "郑希远", lines: ["没。"])),
                    .dialogue(SWSDialogueBlock(character: "李四", lines: ["我跟你说个事。"])),
                    .action(SWSActionBlock(text: "李四点了一支烟，在房间里踱了两步。")),
                    .dialogue(SWSDialogueBlock(character: "李四", modifier: "深吸一口烟", lines: ["甲方要改需求。"])),
                    .dialogue(SWSDialogueBlock(character: "郑希远", modifier: "面无表情", lines: ["改什么。"])),
                ]
            ),
            SWSScene(
                heading: SWSSceneHeading(number: "2", interiorExterior: "外景", location: "公司楼下", time: "夜"),
                blocks: [
                    .action(SWSActionBlock(text: "路灯昏黄。李四和郑希远沉默地站在路边。")),
                    .dialogue(SWSDialogueBlock(character: "李四", lines: ["全部。"])),
                ]
            ),
        ]
    )
    let formatter = SWSFormatter()
    let swsText = formatter.serialize(doc)
    var mutableFormatter = SWSFormatter()
    let parsed = mutableFormatter.deserialize(swsText)
    let html = SWSRenderer.render(document: parsed, style: .chineseStandard)
    #expect(html.contains("郑希远"))
    #expect(html.contains("李四"))
    #expect(html.contains("第1场"))
    #expect(html.contains("第2场"))
    #expect(html.contains("又 crash 了。"))
    #expect(html.contains("全部。"))
    #expect(html.contains("揉了揉眼睛"))
    #expect(html.contains("从门外探头"))
    #expect(html.hasPrefix("<!DOCTYPE html>"))
    #expect(html.contains("</html>"))
}

@Test func renderer_escapeHTML() {
    let block = SWSBlock.action(SWSActionBlock(text: "A < B & C > D \"quote\""))
    let scene = SWSScene(blocks: [block])
    let doc = SWSDocument(scenes: [scene])
    let body = SWSRenderer.renderBody(document: doc, style: .chineseStandard)
    #expect(body.contains("&lt;"))
    #expect(body.contains("&gt;"))
    #expect(body.contains("&amp;"))
    #expect(body.contains("&quot;"))
    #expect(!body.contains("< B"))  // raw < should not appear
}

@Test func renderer_sceneSeparator() {
    let scene = SWSScene(heading: SWSSceneHeading(number: "1"))
    let doc = SWSDocument(scenes: [scene, scene])
    let body = SWSRenderer.renderBody(document: doc, style: .chineseStandard)
    // chineseStandard uses blankLine (2 lines)
    #expect(body.contains("sws-empty-line"))
}

@Test func renderer_modifierStyle_parentheses() {
    let block = SWSBlock.dialogue(SWSDialogueBlock(character: "郑希远", modifier: "笑道", lines: ["你好。"]))
    let scene = SWSScene(blocks: [block])
    let doc = SWSDocument(scenes: [scene])

    // Use chineseInline which uses .parentheses by default
    let body = SWSRenderer.renderBody(document: doc, style: .chineseInline)
    #expect(body.contains("（"))
    #expect(body.contains("）"))
}

@Test func renderer_modifierStyle_superscript() {
    let block = SWSBlock.dialogue(SWSDialogueBlock(character: "郑希远", modifier: "VO", lines: ["画外音。"]))
    let scene = SWSScene(blocks: [block])
    let doc = SWSDocument(scenes: [scene])

    // Build a custom style with superscript modifier
    let ds = DisplayStyle.chineseStandard
    let customDialogue = DialogueStyle(
        layout: ds.dialogue.layout,
        nameFont: ds.dialogue.nameFont,
        nameAlignment: ds.dialogue.nameAlignment,
        modifierStyle: .superscript,
        textIndentChars: ds.dialogue.textIndentChars,
        textFont: ds.dialogue.textFont,
        separator: ds.dialogue.separator,
        marginBetweenDialogues: ds.dialogue.marginBetweenDialogues
    )
    let customStyle = DisplayStyle(
        name: "custom",
        description: "custom",
        sceneHeading: ds.sceneHeading,
        dialogue: customDialogue,
        action: ds.action,
        sceneSeparator: ds.sceneSeparator
    )
    let body = SWSRenderer.renderBody(document: doc, style: customStyle)
    #expect(body.contains("<sup>"))
    #expect(body.contains("</sup>"))
}

@Test func renderer_dataAttributes() {
    let dBlock = SWSBlock.dialogue(SWSDialogueBlock(character: "郑希远", lines: ["你好。"]))
    let aBlock = SWSBlock.action(SWSActionBlock(text: "他站起身。"))
    let scene = SWSScene(heading: SWSSceneHeading(number: "1"), blocks: [dBlock, aBlock])
    let doc = SWSDocument(scenes: [scene])
    let body = SWSRenderer.renderBody(document: doc, style: .chineseStandard)
    #expect(body.contains("data-scene=\"0\""))
    #expect(body.contains("data-block=\"0\""))
    #expect(body.contains("data-block=\"1\""))
}


