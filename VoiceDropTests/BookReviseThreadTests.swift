import XCTest
@testable import VoiceDrop

// 修书对话线（lab /api/book/history 的 JSON）解码 + 时间戳格式。纯逻辑不打网络。
final class BookReviseThreadTests: XCTestCase {

    func testDecodeThread() throws {
        let json = """
        {"slug":"entropy","author":"王建硕","createdAt":1755100000000,"running":true,
         "thread":[
           {"ts":1755100000000,"kind":"create","instruction":"熵","sessionId":"abc","status":"done","reply":"书写好了"},
           {"ts":1755200000000,"kind":"revise","instruction":"第三章太啰嗦","status":"running"}
         ]}
        """.data(using: .utf8)!
        let t = try JSONDecoder().decode(BookThread.self, from: json)
        XCTAssertEqual(t.slug, "entropy")
        XCTAssertTrue(t.running)
        XCTAssertEqual(t.thread.count, 2)
        XCTAssertEqual(t.thread[0].kind, "create")
        XCTAssertEqual(t.thread[0].reply, "书写好了")
        XCTAssertEqual(t.thread[1].status, "running")
        XCTAssertNil(t.thread[1].reply)          // 缺字段 → nil，不炸
        XCTAssertEqual(t.thread[1].id, 1755200000000)   // id = ts（列表稳定标识）
    }

    func testDecodeMinimalEntryAndUnknownFields() throws {
        // 服务端以后加字段（如 costUsd）老 App 也要能解——Decodable 默认忽略未知键
        let json = """
        {"slug":"x","running":false,"thread":[
          {"ts":1,"kind":"revise","instruction":"改","status":"failed","error":"error_max_turns","costUsd":0.5}
        ]}
        """.data(using: .utf8)!
        let t = try JSONDecoder().decode(BookThread.self, from: json)
        XCTAssertNil(t.author)
        XCTAssertEqual(t.thread[0].error, "error_max_turns")
    }

    func testStamp() {
        // 2026-08-15 12:30 UTC+8 附近的毫秒戳 → 中文「M月d日 HH:mm」格式（本地时区跑，只验形状）
        let s = BookReviseSheet.stamp(1755232200000)
        XCTAssertTrue(s.contains("月") && s.contains("日") && s.contains(":"), s)
    }
}
