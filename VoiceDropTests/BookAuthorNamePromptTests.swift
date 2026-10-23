import XCTest
@testable import VoiceDrop

// 写书表单「作者」框要不要写回 profile.name。纯逻辑不打网络。
// 规则：没变不存；改了就存（含清空 = 不署名）；profile 没拉到（nil）时
// 空框不能抹掉设置里的名字，只有填了才存。
final class BookAuthorNamePromptTests: XCTestCase {

    func testUnchangedNotSaved() {
        XCTAssertNil(BookWritingSheet.nameToSave(draft: "王建硕", loaded: "王建硕"))
        XCTAssertNil(BookWritingSheet.nameToSave(draft: "  王建硕 ", loaded: "王建硕"))
    }

    func testChangedSaved() {
        XCTAssertEqual(BookWritingSheet.nameToSave(draft: "建硕", loaded: "王建硕"), "建硕")
        XCTAssertEqual(BookWritingSheet.nameToSave(draft: "王建硕", loaded: ""), "王建硕")
    }

    func testClearedSavesEmpty() {
        XCTAssertEqual(BookWritingSheet.nameToSave(draft: "  ", loaded: "王建硕"), "")
    }

    func testProfileUnavailable() {
        // 网络失败 / 没登录：空框不覆盖，填了才存
        XCTAssertNil(BookWritingSheet.nameToSave(draft: "", loaded: nil))
        XCTAssertEqual(BookWritingSheet.nameToSave(draft: "王建硕", loaded: nil), "王建硕")
    }
}
