import XCTest
@testable import VoiceDrop

final class PageModelTests: XCTestCase {
    private func doc(_ json: String) -> PageDocument? {
        PageDocument.decode(Data(json.utf8))
    }

    func testDecodesValidTree() {
        let d = doc("""
        { "schema":1, "version":3, "root": {
            "type":"vstack", "spacing":16, "padding":20, "align":"leading", "children":[
              { "type":"text", "value":"早安", "size":28, "weight":"bold", "color":"ink" },
              { "type":"grid", "columns":2, "children":[
                 { "type":"card", "title":"写文章", "icon":"doc.text", "tint":"accent", "tap":"openArticles" }
              ]},
              { "type":"embed", "block":"recordButton" }
            ] } }
        """)
        XCTAssertEqual(d?.version, 3)
        guard case let .vstack(spacing, padding, align, children)? = d?.root else { return XCTFail("root not vstack") }
        XCTAssertEqual(spacing, 16); XCTAssertEqual(padding, 20); XCTAssertEqual(align, .leading)
        XCTAssertEqual(children.count, 3)
        guard case .text(let v, let sz, let w, let c, _) = children[0] else { return XCTFail() }
        XCTAssertEqual(v, "早安"); XCTAssertEqual(sz, 28); XCTAssertEqual(w, .bold); XCTAssertEqual(c, .ink)
        guard case .grid(let cols, _, let gkids) = children[1] else { return XCTFail() }
        XCTAssertEqual(cols, 2)
        guard case .card(_, _, let icon, let tint, let tap) = gkids[0] else { return XCTFail() }
        XCTAssertEqual(icon, "doc.text"); XCTAssertEqual(tint, .accent); XCTAssertEqual(tap, .openArticles)
        guard case .embed(.recordButton) = children[2] else { return XCTFail() }
    }

    func testUnknownTypeBecomesUnknownNode() {
        let d = doc(#"{ "root": { "type":"vstack", "children":[ {"type":"blink"} ] } }"#)
        guard case let .vstack(_, _, _, kids)? = d?.root else { return XCTFail() }
        XCTAssertEqual(kids.first, .unknown)
    }

    func testBadTokensFallBackNotThrow() {
        let d = doc(#"{ "root": { "type":"text", "value":"x", "weight":"ultra", "color":"neon", "align":"justify" } }"#)
        guard case .text(_, _, let w, let c, let a)? = d?.root else { return XCTFail() }
        XCTAssertEqual(w, .regular); XCTAssertEqual(c, .ink); XCTAssertEqual(a, .leading)
    }

    func testMissingFieldsGetDefaults() {
        let d = doc(#"{ "root": { "type":"vstack" } }"#)
        guard case let .vstack(spacing, padding, _, kids)? = d?.root else { return XCTFail() }
        XCTAssertEqual(spacing, 12); XCTAssertEqual(padding, 0); XCTAssertTrue(kids.isEmpty)
    }

    func testGridColumnsClampedTo1Through4() {
        let hi = doc(#"{ "root": { "type":"grid", "columns":99 } }"#)
        let lo = doc(#"{ "root": { "type":"grid", "columns":0 } }"#)
        if case .grid(let c, _, _)? = hi?.root { XCTAssertEqual(c, 4) } else { XCTFail() }
        if case .grid(let c, _, _)? = lo?.root { XCTAssertEqual(c, 1) } else { XCTFail() }
    }

    func testDisallowedIconDropped() {
        let d = doc(#"{ "root": { "type":"card", "title":"t", "icon":"nuke.fill", "tap":"record" } }"#)
        guard case .card(_, _, let icon, _, _)? = d?.root else { return XCTFail() }
        XCTAssertNil(icon)
    }

    func testCardWithoutValidTapIsUnknown() {
        let d = doc(#"{ "root": { "type":"card", "title":"t", "tap":"launchMissiles" } }"#)
        XCTAssertEqual(d?.root, .unknown)
    }

    func testEmbedWithoutValidBlockIsUnknown() {
        let d = doc(#"{ "root": { "type":"embed", "block":"weather" } }"#)
        XCTAssertEqual(d?.root, .unknown)
    }

    func testStructurallyBrokenReturnsNil() {
        XCTAssertNil(doc("not json"))
        XCTAssertNil(doc(#"{ "noroot": true }"#))
    }

    func testUnknownRootTreatedAsBroken() {
        XCTAssertNil(doc(#"{ "root": { "type":"???" } }"#))
    }
}
