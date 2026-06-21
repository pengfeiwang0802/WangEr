#!/usr/bin/env swift -I ../.build/debug -L ../.build/debug

import Foundation

// ── 测试样本 ──────────────────────────────────────────────

let sample1 = """
---
sws: 0.1
title: 测试剧本
author: 王二
created: 2026-07-15
---

## 第1场 · 内景 · 书房 · 日

[郑希远]
走吧。

[林小舟]
等等我。

## 第2场 · 外景 · 街道 · 夜

街上空无一人。

[郑希远]
（低语）
有点不对劲。

> "小心。"

[林小舟]
你说什么？
"""

let sample2 = """
[角色A]
你好。

[角色B]
你好你好。
"""

let sample3 = """
---
sws: 0.1
title: 空剧本
---

## 第1场 · 内景 · 空房间 · 日
"""

// ── 测试逻辑 ──────────────────────────────────────────────

@main
struct SWSIntegrationTest {
    static func main() {
        var passed = 0
        var failed: [String] = []

        // 测试 1: 完整剧本 round-trip
        do {
            var fmt = SWSFormatter()
            let doc = fmt.deserialize(sample1)
            let output = fmt.serialize(doc)
            let doc2 = fmt.deserialize(output)
            let output2 = fmt.serialize(doc2)

            guard doc.scenes.count == doc2.scenes.count else {
                failed.append("scene count mismatch: \(doc.scenes.count) vs \(doc2.scenes.count)")
                return
            }

            // 比较关键结构指标
            let c1 = doc.allCharacters.sorted()
            let c2 = doc2.allCharacters.sorted()
            guard c1 == c2 else {
                failed.append("characters mismatch: \(c1) vs \(c2)")
                return
            }

            guard doc.totalBlockCount == doc2.totalBlockCount else {
                failed.append("block count mismatch: \(doc.totalBlockCount) vs \(doc2.totalBlockCount)")
                return
            }

            // 验证内容不变（忽略尾随换行差异）
            let trimmed1 = output.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmed2 = output2.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed1 == trimmed2 else {
                failed.append("serialized content changed after round-trip")
                print("--- FIRST ---")
                print(output)
                print("--- SECOND ---")
                print(output2)
                return
            }

            passed += 1
            print("✅ 测试 1: 完整剧本 round-trip")
        }

        // 测试 2: 简单对话 round-trip
        do {
            var fmt = SWSFormatter()
            let doc = fmt.deserialize(sample2)
            let output = fmt.serialize(doc)
            let doc2 = fmt.deserialize(output)

            guard doc.scenes.count == doc2.scenes.count else {
                failed.append("simple round-trip scene count mismatch")
                return
            }

            let t1 = output.trimmingCharacters(in: .whitespacesAndNewlines)
            let t2 = fmt.serialize(doc2).trimmingCharacters(in: .whitespacesAndNewlines)
            guard t1 == t2 else {
                failed.append("simple round-trip content changed")
                return
            }

            passed += 1
            print("✅ 测试 2: 简单对话 round-trip")
        }

        // 测试 3: 空场景 round-trip
        do {
            var fmt = SWSFormatter()
            let doc = fmt.deserialize(sample3)
            let output = fmt.serialize(doc)
            let doc2 = fmt.deserialize(output)

            guard doc.scenes.count == doc2.scenes.count else {
                failed.append("empty scene count mismatch: \(doc.scenes.count) vs \(doc2.scenes.count)")
                return
            }

            passed += 1
            print("✅ 测试 3: 空场景 round-trip")
        }

        // 测试 4: 空字符串
        do {
            var fmt = SWSFormatter()
            let doc = fmt.deserialize("")
            guard doc.scenes.isEmpty else {
                failed.append("empty input should produce 0 scenes")
                return
            }
            let output = fmt.serialize(doc)
            guard output == "" else {
                failed.append("empty doc should serialize to empty string, got: \(output.debugDescription)")
                return
            }
            passed += 1
            print("✅ 测试 4: 空字符串")
        }

        // 测试 5: 多段对白
        do {
            let input = """
            [郑希远]
            第一段。

            第二段。

            第三段。
            """
            var fmt = SWSFormatter()
            let doc = fmt.deserialize(input)
            guard doc.scenes.count == 1 else {
                failed.append("multi-line: expected 1 scene, got \(doc.scenes.count)")
                return
            }
            let blocks = doc.scenes[0].blocks
            guard blocks.count >= 1 else {
                failed.append("multi-line: expected at least 1 block")
                return
            }
            if case .dialogue(let d) = blocks[0] {
                guard d.lines.count == 3 else {
                    failed.append("multi-line: expected 3 lines, got \(d.lines.count): \(d.lines)")
                    return
                }
            } else {
                failed.append("multi-line: first block should be dialogue")
                return
            }
            passed += 1
            print("✅ 测试 5: 多段对白")
        }

        // 测试 6: 场景头变体
        do {
            let variants = [
                "## 第1场 · 内景 · 书房 · 日",
                "## 第 1 场 · 外景 · 街道 · 夜",
                "## 第 99 场 · 内景 · 会议室 · 黎明"
            ]
            for v in variants {
                var fmt = SWSFormatter()
                let doc = fmt.deserialize(v)
                guard doc.scenes.count == 1 else {
                    failed.append("variant scene count: \(v)")
                    return
                }
                guard doc.scenes[0].heading != nil else {
                    failed.append("variant heading nil: \(v)")
                    return
                }
            }
            passed += 1
            print("✅ 测试 6: 场景头变体")
        }

        // 测试 7: 混合 inline / nameAbove
        do {
            let input = """
            [郑希远]走吧。

            [林小舟]
            等等我。
            """
            var fmt = SWSFormatter()
            let doc = fmt.deserialize(input)
            guard doc.scenes.count == 1 else {
                failed.append("mixed format scene count")
                return
            }
            let blocks = doc.scenes[0].blocks
            guard blocks.count == 2 else {
                failed.append("mixed format block count: \(blocks.count)")
                return
            }
            if case .dialogue(let d1) = blocks[0] {
                guard d1.character == "郑希远" else { failed.append("mixed format char 1"); return }
            } else { failed.append("mixed format block 0 type"); return }

            if case .dialogue(let d2) = blocks[1] {
                guard d2.character == "林小舟" else { failed.append("mixed format char 2"); return }
            } else { failed.append("mixed format block 1 type"); return }

            passed += 1
            print("✅ 测试 7: 混合 inline / nameAbove")
        }

        // ── 结果 ──
        print("")
        print("═══════════════════════════════════════")
        print("  集成测试结果: \(passed)/\(passed + failed.count) 通过")
        if !failed.isEmpty {
            print("  ❌ 失败:")
            for f in failed {
                print("    - \(f)")
            }
        }
        print("═══════════════════════════════════════")
    }
}
