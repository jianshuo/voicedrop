import XCTest
@testable import VoiceDrop

final class PageStoreTests: XCTestCase {
    private let good = Data(#"{ "root": { "type":"vstack", "children":[ {"type":"embed","block":"articleList"} ] } }"#.utf8)
    private var goodRoot: PageNode { PageDocument.decode(good)!.root }

    func test404MeansNativeHome() {
        let r = PageStore.resolveTree(status: 404, data: Data(), lastGood: goodRoot)
        XCTAssertNil(r.tree)   // nil → 原生首页（即使之前有 lastGood，404=被重置）
    }

    func testValidIsAdoptedAndRemembered() {
        let r = PageStore.resolveTree(status: 200, data: good, lastGood: nil)
        XCTAssertEqual(r.tree, goodRoot)
        XCTAssertEqual(r.lastGood, goodRoot)
    }

    func testBrokenJsonKeepsLastGood() {
        let r = PageStore.resolveTree(status: 200, data: Data("garbage".utf8), lastGood: goodRoot)
        XCTAssertEqual(r.tree, goodRoot)
    }

    func testTransientErrorKeepsLastGood() {
        let r = PageStore.resolveTree(status: 500, data: Data(), lastGood: goodRoot)
        XCTAssertEqual(r.tree, goodRoot)
    }

    func testBrokenJsonWithNoLastGoodFallsToNative() {
        let r = PageStore.resolveTree(status: 200, data: Data("garbage".utf8), lastGood: nil)
        XCTAssertNil(r.tree)
    }
}
