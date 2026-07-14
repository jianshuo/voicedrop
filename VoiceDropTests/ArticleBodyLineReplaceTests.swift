import XCTest
@testable import VoiceDrop

// 键盘精修（design_handoff_paragraph_edit 方向 1a）：ArticleBody.replacingLine 决定
// 用户敲的字最终落进正文哪个位置。这条函数的行号必须与 RecordingDetailView.bodyRows
// 给用户看到的「第N行」完全一致，写错一行就是把别的段落覆盖掉——所以覆盖率要往宽了测：
// 普通段落、紧邻图片标记（独占一行/嵌在文字里两种）、边界行、越界不存在的行号。
final class ArticleBodyLineReplaceTests: XCTestCase {

    func testReplacesFirstLine() {
        let body = "第一段。\n\n第二段。\n\n第三段。"
        let out = ArticleBody.replacingLine(1, with: "改过的第一段。", in: body)
        XCTAssertEqual(out, "改过的第一段。\n\n第二段。\n\n第三段。")
    }

    func testReplacesMiddleLineLeavesSiblingsByteIdentical() {
        let body = "第一段。\n\n第二段。\n\n第三段。"
        let out = ArticleBody.replacingLine(2, with: "改过的第二段。", in: body)
        XCTAssertEqual(out, "第一段。\n\n改过的第二段。\n\n第三段。")
    }

    func testReplacesLastLine() {
        let body = "第一段。\n\n第二段。\n\n第三段。"
        let out = ArticleBody.replacingLine(3, with: "改过的第三段。", in: body)
        XCTAssertEqual(out, "第一段。\n\n第二段。\n\n改过的第三段。")
    }

    /// 图片标记独占一行——本身消耗一个第N行编号，前后段落不受影响。
    func testPreservesPhotoMarkerOnItsOwnLine() {
        let body = "第一段。\n\n[[photo:photos/a.jpg]]\n\n第二段。"
        let out = ArticleBody.replacingLine(3, with: "改过的第二段。", in: body)
        XCTAssertEqual(out, "第一段。\n\n[[photo:photos/a.jpg]]\n\n改过的第二段。")
    }

    func testCannotTargetAPhotoMarkerLineViaThisFunction() {
        // UI 从不对 .image 行提供「编辑」入口，但函数本身对越界/图片行为的契约仍要
        // 锁住：命中一个图片标记的行号时原样返回（不产生半吊子的错误替换）。
        let body = "第一段。\n\n[[photo:photos/a.jpg]]\n\n第二段。"
        let out = ArticleBody.replacingLine(2, with: "不应该出现", in: body)
        XCTAssertEqual(out, body)
    }

    /// 图片标记嵌在同一物理行的文字中间——bodyRows/segments 仍会把它拆成 3 个
    /// 「行」（文字/图片/文字），replacingLine 必须按同一套切分计数，不能按原始 "\n"
    /// 数误判成 1 行。
    func testInlinePhotoMarkerWithinOneLineCountsAsSeparateRow() {
        let body = "看这张照片[[photo:photos/a.jpg]]很美\n\n第二段。"
        // 第1行=「看这张照片」，第2行=图片，第3行=「很美」，第4行=「第二段。」
        let out = ArticleBody.replacingLine(3, with: "真好看", in: body)
        XCTAssertEqual(out, "看这张照片[[photo:photos/a.jpg]]真好看\n\n第二段。")
    }

    func testOutOfRangeLineReturnsBodyUnchanged() {
        let body = "第一段。\n\n第二段。"
        let out = ArticleBody.replacingLine(99, with: "不应该出现", in: body)
        XCTAssertEqual(out, body)
    }

    func testOnlyTargetLineChangesRestByteIdentical() {
        let body = "带「引号」的第一段，还有 emoji 🎉。\n\n第二段 with English mixed in.\n\n第三段。"
        let out = ArticleBody.replacingLine(2, with: "全新的第二段。", in: body)
        XCTAssertEqual(out, "带「引号」的第一段，还有 emoji 🎉。\n\n全新的第二段。\n\n第三段。")
    }

    func testLegacyOriginCommentIsStrippedConsistentlyWithNumbering() {
        // 与 ArticleBody.segments/bodyRows 一致：origin comment 在编号前先被剥掉，
        // 所以「第1行」指的是剥掉注释之后的第一段，不是原始字符串里的第一行。
        let body = "<!--style: v8-->\n第一段。\n\n第二段。"
        let out = ArticleBody.replacingLine(1, with: "改过的第一段。", in: body)
        XCTAssertEqual(out, "改过的第一段。\n\n第二段。")
    }
}
