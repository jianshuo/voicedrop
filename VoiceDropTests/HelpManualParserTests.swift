import XCTest
@testable import VoiceDrop

// ManualParser（设置→使用手册的 markdown → 块解析）。纯逻辑，不碰 bundle。
final class HelpManualParserTests: XCTestCase {

    func testHeadingsAndParagraph() {
        let md = "# 总标题\n\n开场白。\n\n## 第 1 章 上手\n\n### 小节\n\n两行\n拼成一段。\n"
        let blocks = ManualParser.parse(md)
        XCTAssertEqual(blocks, [
            .title("总标题"),
            .paragraph("开场白。"),
            .chapter("第 1 章 上手"),
            .section("小节"),
            .paragraph("两行 拼成一段。"),
        ])
    }

    func testConsecutiveBulletsStayOneBlock() {
        let md = "- 甲\n- 乙\n- 丙\n\n1. 一\n2. 二\n"
        let blocks = ManualParser.parse(md)
        XCTAssertEqual(blocks, [
            .bullets(["甲", "乙", "丙"]),
            .numbered(["一", "二"]),
        ])
    }

    func testTableSkipsSeparatorRow() {
        let md = "| 状态 | 意思 |\n|---|---|\n| 待处理 | 排队 |\n| 已成文 | 写好了 |\n"
        let blocks = ManualParser.parse(md)
        XCTAssertEqual(blocks, [
            .table(header: ["状态", "意思"], rows: [["待处理", "排队"], ["已成文", "写好了"]]),
        ])
    }

    func testCodeBlockKeptVerbatim() {
        let md = "```\nVoiceDrop-2026-06-18.m4a\n```\n后面一段。\n"
        let blocks = ManualParser.parse(md)
        XCTAssertEqual(blocks, [
            .code("VoiceDrop-2026-06-18.m4a"),
            .paragraph("后面一段。"),
        ])
    }

    // 真手册整本喂进去：标题齐全（8 章）、无空段落、状态表还在。内容改版时
    // 这条测试兜住「解析器吃不下新写法」的回归。注意 bundle 在测试环境走
    // host app 的 Bundle.main，取不到就跳过（纯逻辑用例已覆盖解析器本身）。
    func testRealManualParsesWhenBundled() throws {
        guard !HelpManual.text.isEmpty else { throw XCTSkip("HelpManual.md 不在测试 bundle") }
        let blocks = ManualParser.parse(HelpManual.text)
        let chapters = blocks.filter { if case .chapter = $0 { return true } else { return false } }
        XCTAssertEqual(chapters.count, 8)
        for case .paragraph(let t) in blocks { XCTAssertFalse(t.isEmpty) }
        XCTAssertTrue(blocks.contains { if case .table = $0 { return true } else { return false } })
    }
}
