import Foundation
import SWS

let url = URL(fileURLWithPath: "/Users/pengfei/4王二/测试剧本.sws")
let text = try String(contentsOf: url, encoding: .utf8)
let doc = try SWSFormatter.deserialize(text)
print("角色数: \(doc.allCharacters.count)")
print("角色列表: \(doc.allCharacters)")
print("场景数: \(doc.scenes.count)")
for (i, scene) in doc.scenes.enumerated() {
    print("场景\(i+1): heading=\(scene.heading?.swsText ?? "nil"), blocks=\(scene.blocks.count)")
    for (j, block) in scene.blocks.enumerated() {
        switch block {
        case .dialogue(let d):
            print("  块\(j): 对白 char=\(d.character) lines=\(d.lines)")
        case .action(let a):
            let preview = a.text.prefix(40)
            print("  块\(j): 动作 text=\(preview)...")
        case .unattributed(let u):
            print("  块\(j): 未标注 lines=\(u.lines)")
        case .emptyLine:
            print("  块\(j): 空行")
        }
    }
}
