import XCTest
@testable import VoiceDrop

// 写书提交前「要不要先问作者名」的判定。纯逻辑不打网络。
// 规则：只有「拉到了 profile 且名字确实为空」才问；拉不到（nil）不打扰，
// 服务端有啥署啥——与没有这个提示框之前的行为一致。
final class BookAuthorNamePromptTests: XCTestCase {

    func testAskOnlyWhenNameKnownEmpty() {
        XCTAssertTrue(BookWritingSheet.shouldAskAuthorName(loadedName: ""))
    }

    func testNoAskWhenNameSet() {
        XCTAssertFalse(BookWritingSheet.shouldAskAuthorName(loadedName: "王建硕"))
    }

    func testNoAskWhenProfileUnavailable() {
        // 网络失败 / 没登录：不知道有没有名字，不能拦提交
        XCTAssertFalse(BookWritingSheet.shouldAskAuthorName(loadedName: nil))
    }
}
