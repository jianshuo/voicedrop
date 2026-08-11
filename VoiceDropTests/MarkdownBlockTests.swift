import XCTest
@testable import VoiceDrop

/// MarkdownBlock.classify 的纯逻辑单测——正文块级 Markdown 行分类。
final class MarkdownBlockTests: XCTestCase {

    private func kind(_ s: String) -> MarkdownBlock.Kind { MarkdownBlock.classify(s).kind }
    private func content(_ s: String) -> String { MarkdownBlock.classify(s).content }

    // MARK: 标题

    func testH1() {
        XCTAssertEqual(kind("# 标题"), .h1)
        XCTAssertEqual(content("# 标题"), "标题")
    }

    func testH2() {
        XCTAssertEqual(kind("## 二级标题"), .h2)
        XCTAssertEqual(content("## 二级标题"), "二级标题")
    }

    func testH3() {
        XCTAssertEqual(kind("### 三级"), .h3)
    }

    func testDeepHeadingsCollapseToH3() {
        XCTAssertEqual(kind("#### 四级"), .h3)
        XCTAssertEqual(kind("###### 六级"), .h3)
    }

    func testSevenHashesIsPlain() {
        XCTAssertEqual(kind("####### 太深"), .plain)
    }

    func testHashtagWithoutSpaceIsPlain() {
        XCTAssertEqual(kind("#话题不是标题"), .plain)
        XCTAssertEqual(kind("##也不是"), .plain)
    }

    func testHeadingKeepsInlineMarkdown() {
        XCTAssertEqual(content("## 带 **粗体** 的标题"), "带 **粗体** 的标题")
    }

    // MARK: 无序列表

    func testBulletDash() {
        XCTAssertEqual(kind("- 第一条"), .bullet)
        XCTAssertEqual(content("- 第一条"), "第一条")
    }

    func testBulletStarAndPlus() {
        XCTAssertEqual(kind("* 星号条目"), .bullet)
        XCTAssertEqual(kind("+ 加号条目"), .bullet)
    }

    func testDashWithoutSpaceIsPlain() {
        XCTAssertEqual(kind("-负号开头的句子"), .plain)
        XCTAssertEqual(kind("*强调*不是列表"), .plain)
    }

    // MARK: 有序列表

    func testOrderedDot() {
        XCTAssertEqual(kind("1. 第一"), .ordered("1"))
        XCTAssertEqual(content("1. 第一"), "第一")
    }

    func testOrderedParenAndChinese() {
        XCTAssertEqual(kind("2) 第二"), .ordered("2"))
        XCTAssertEqual(kind("3、第三"), .ordered("3"))
        XCTAssertEqual(content("3、第三"), "第三")
    }

    func testOrderedMultiDigit() {
        XCTAssertEqual(kind("12. 十二"), .ordered("12"))
    }

    func testYearIsNotOrdered() {
        // 4 位数字不当序号——「2026. 这一年…」更可能是年份。
        XCTAssertEqual(kind("2026. 这一年发生了很多"), .plain)
    }

    func testNumberDotNoSpaceIsPlain() {
        XCTAssertEqual(kind("1.5 倍速"), .plain)
    }

    // MARK: 引用

    func testQuote() {
        XCTAssertEqual(kind("> 引用一句话"), .quote)
        XCTAssertEqual(content("> 引用一句话"), "引用一句话")
    }

    func testQuoteNoSpace() {
        XCTAssertEqual(kind(">紧贴的引用"), .quote)
        XCTAssertEqual(content(">紧贴的引用"), "紧贴的引用")
    }

    func testNestedQuoteFlattens() {
        XCTAssertEqual(kind(">> 两层"), .quote)
        XCTAssertEqual(content(">> 两层"), "两层")
    }

    // MARK: 分隔线

    func testDividers() {
        XCTAssertEqual(kind("---"), .divider)
        XCTAssertEqual(kind("***"), .divider)
        XCTAssertEqual(kind("___"), .divider)
        XCTAssertEqual(kind("- - -"), .divider)
        XCTAssertEqual(kind("--------"), .divider)
    }

    func testTwoDashesIsPlain() {
        XCTAssertEqual(kind("--"), .plain)
    }

    func testMixedSymbolsIsPlain() {
        XCTAssertEqual(kind("-*-"), .plain)
    }

    // MARK: 普通段落

    func testPlainParagraph() {
        let s = "这是一段普通的正文，带**粗体**也不影响分类。"
        XCTAssertEqual(kind(s), .plain)
        XCTAssertEqual(content(s), s)
    }

    // MARK: 行内解析兜底

    func testInlineParsesBold() {
        let a = MarkdownBlock.inline("有**粗体**的行")
        XCTAssertEqual(String(a.characters), "有粗体的行")
    }
}
