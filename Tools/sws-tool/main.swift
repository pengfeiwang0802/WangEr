import Foundation
import SWS

// ── 子命令 ──────────────────────────────────────────────

enum Command: String, CaseIterable {
    case roundtrip   // 读 .sws → 序列化 → 反序列化 → 再序列化，比较前后
    case info        // 读 .sws → 输出统计信息
    case validate    // 读 .sws → 检查格式合法性
}

func usage() -> Never {
    print("用法: sws-tool <子命令> [文件路径]")
    print("")
    print("子命令:")
    for cmd in Command.allCases {
        switch cmd {
        case .roundtrip: print("  roundtrip  读入 .sws 文件，做 round-trip 验证")
        case .info:      print("  info       读入 .sws 文件，输出统计")
        case .validate:  print("  validate   读入 .sws 文件，检查格式")
        }
    }
    exit(1)
}

func readFile(_ path: String) -> String {
    let url = URL(fileURLWithPath: path)
    return try! String(contentsOf: url, encoding: .utf8)
}

// ── Round-trip ──────────────────────────────────────────

func cmdRoundtrip(_ path: String) {
    let text = readFile(path)
    var fmt = SWSFormatter()
    let doc = fmt.deserialize(text)
    let output = fmt.serialize(doc)
    let doc2 = fmt.deserialize(output)
    let output2 = fmt.serialize(doc2)

    let trimmed1 = output.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmed2 = output2.trimmingCharacters(in: .whitespacesAndNewlines)

    print("📄 \(URL(fileURLWithPath: path).lastPathComponent)")
    print("  场景数: \(doc.scenes.count)")
    print("  总块数: \(doc.totalBlockCount)")
    print("  角色数: \(doc.allCharacters.count)")
    print("  角色列表: \(doc.allCharacters.joined(separator: ", "))")

    if trimmed1 == trimmed2 {
        print("  ✅ Round-trip 一致")
    } else {
        print("  ❌ Round-trip 不一致!")
        print("")
        print("--- 第一次序列化 ---")
        print(output)
        print("--- 第二次序列化 ---")
        print(output2)
    }
}

// ── Info ────────────────────────────────────────────────

func cmdInfo(_ path: String) {
    let text = readFile(path)
    var fmt = SWSFormatter()
    let doc = fmt.deserialize(text)

    print("📊 \(URL(fileURLWithPath: path).lastPathComponent)")
    print("  标题: \(doc.metadata.title ?? "(无)")")
    print("  作者: \(doc.metadata.author ?? "(无)")")
    print("  场景数: \(doc.scenes.count)")
    print("  总块数: \(doc.totalBlockCount)")
    print("  角色: \(doc.allCharacters.count) 个")

    for char in doc.allCharacters {
        var count = 0
        var totalChars = 0
        for scene in doc.scenes {
            for block in scene.blocks {
                if case .dialogue(let d) = block, d.character == char {
                    count += 1
                    totalChars += d.line.count
                }
            }
        }
        print("    \(char): \(count) 段对白, \(totalChars) 字")
    }

    print("")
    print("  场景列表:")
    for (i, scene) in doc.scenes.enumerated() {
        let heading = scene.heading.map { "\($0.number) · \($0.location) · \($0.time)" } ?? "(无场景头)"
        let dialogueCount = scene.dialogueCount
        let actionCount = scene.actionCount
        print("    [\(i+1)] \(heading) — \(dialogueCount) 段对白, \(actionCount) 段动作")
    }
}

// ── Validate ────────────────────────────────────────────

func cmdValidate(_ path: String) {
    let text = readFile(path)
    var fmt = SWSFormatter()
    let doc = fmt.deserialize(text)

    var issues: [String] = []

    for (i, scene) in doc.scenes.enumerated() {
        if scene.heading == nil && !scene.blocks.isEmpty {
            issues.append("场景 \(i+1): 有内容但无场景头")
        }
        for (j, block) in scene.blocks.enumerated() {
            switch block {
            case .dialogue(let d):
                if d.character.isEmpty {
                    issues.append("场景 \(i+1) 块 \(j+1): 空角色名")
                }
                if d.line.trimmingCharacters(in: .whitespaces).isEmpty {
                    issues.append("场景 \(i+1) 块 \(j+1): 对白 [\(d.character)] 无内容")
                }
            case .action(let a):
                if a.text.trimmingCharacters(in: .whitespaces).isEmpty {
                    issues.append("场景 \(i+1) 块 \(j+1): 空动作")
                }
            case .unattributed(let u):
                if u.lines.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                    issues.append("场景 \(i+1) 块 \(j+1): 空引文")
                }
            case .emptyLine:
                break
            }
        }
    }

    if issues.isEmpty {
        print("✅ 格式验证通过")
    } else {
        print("⚠️  发现 \(issues.count) 个问题:")
        for issue in issues {
            print("  - \(issue)")
        }
    }
}

// ── 入口 ────────────────────────────────────────────────

let args = CommandLine.arguments

guard args.count >= 2 else { usage() }

let command = args[1]
let path = args.count >= 3 ? args[2] : nil

switch command {
case "roundtrip":
    guard let path else { print("❌ 需要文件路径"); exit(1) }
    cmdRoundtrip(path)
case "info":
    guard let path else { print("❌ 需要文件路径"); exit(1) }
    cmdInfo(path)
case "validate":
    guard let path else { print("❌ 需要文件路径"); exit(1) }
    cmdValidate(path)
default:
    usage()
}
