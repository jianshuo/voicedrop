import XCTest
import SwiftUI
@testable import VoiceDrop

final class PageRenderMappingTests: XCTestCase {
    func testColorTokensMapToTheme() {
        XCTAssertEqual(PageColorToken.accent.color, Theme.accent)
        XCTAssertEqual(PageColorToken.recordRed.color, Theme.recordRed)
        XCTAssertEqual(PageColorToken.ink.color, Theme.ink)
    }
    func testWeightMapping() {
        XCTAssertEqual(PageWeight.bold.swiftUI, .bold)
        XCTAssertEqual(PageWeight.regular.swiftUI, .regular)
    }
    func testAlignMapping() {
        XCTAssertEqual(PageAlign.trailing.horizontal, .trailing)
        XCTAssertEqual(PageAlign.center.textAlignment, .center)
    }
}
