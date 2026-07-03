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

    func testContainsListEmbedFindsNestedList() {
        let tree = PageNode.vstack(spacing: 12, padding: 0, align: .leading, children: [
            .text(value: "hi", size: 17, weight: .regular, color: .ink, align: .leading),
            .grid(columns: 2, spacing: 12, children: [.embed(block: .articleList)]),
        ])
        XCTAssertTrue(tree.containsListEmbed)
    }

    func testContainsListEmbedFalseForStaticAndNonListEmbeds() {
        let tree = PageNode.vstack(spacing: 12, padding: 0, align: .leading, children: [
            .card(title: "t", subtitle: nil, icon: nil, tint: .accent, tap: .record),
            .embed(block: .recordButton),
            .embed(block: .notePlaceholder),
        ])
        XCTAssertFalse(tree.containsListEmbed)
    }
}
