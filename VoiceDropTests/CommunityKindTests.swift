import XCTest
@testable import VoiceDrop

final class CommunityKindTests: XCTestCase {
    func testDecodeKindDefaultsToArticle() throws {
        let json = #"{"shareId":"abcdefghijkl","title":"t"}"#.data(using: .utf8)!
        let p = try JSONDecoder().decode(CommunityPost.self, from: json)
        XCTAssertFalse(p.isPrompt)
    }
    func testDecodePromptKind() throws {
        let json = #"{"shareId":"abcdefghijkl","title":"改毒舌","kind":"prompt"}"#.data(using: .utf8)!
        let p = try JSONDecoder().decode(CommunityPost.self, from: json)
        XCTAssertTrue(p.isPrompt)
    }
    func testFullPostDecodesPromptCode() throws {
        let json = #"{"shareId":"abcdefghijkl","articles":[{"title":"改毒舌","body":"把它改得更毒舌"}],"kind":"prompt","promptCode":"4563566"}"#.data(using: .utf8)!
        let p = try JSONDecoder().decode(CommunityFullPost.self, from: json)
        XCTAssertEqual(p.promptCode, "4563566")
        XCTAssertEqual(p.kind, "prompt")
    }
}
