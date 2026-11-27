import XCTest
@testable import VoiceDrop

// 书的「下载到本地」：只有一份内容——线上原样的页面由 vdbook:// 从本地文件应答。
// 这里钉的是那层映射：线上怎么取（路径），本地就怎么给（文件）。
final class BookOfflineTests: XCTestCase {

    func testRequestPathsMapToLocalFilesLikeTheOnlineRoutes() {
        typealias L = BookOfflineLayout
        XCTAssertEqual(L.target(forPath: "/books/entropy/"), .file("entropy/index.html"))
        XCTAssertEqual(L.target(forPath: "/books/entropy"), .file("entropy/index.html"))
        XCTAssertEqual(L.target(forPath: "/books/entropy/01.html"), .file("entropy/01.html"))
        XCTAssertEqual(L.target(forPath: "/books/entropy/cover.jpg"), .file("entropy/cover.jpg"))
        // 播放器连播取的章节清单：页面里是 ../<slug>/_src/book.json
        XCTAssertEqual(L.target(forPath: "/books/entropy/_src/book.json"), .file("entropy/_src/book.json"))
        // 「听本章」取的音频：页面里是 ../audiobook/<slug>/<章>
        XCTAssertEqual(L.target(forPath: "/books/audiobook/entropy/01"), .file("entropy/audio/01.mp3"))
        XCTAssertEqual(L.target(forPath: "/books/audiobook/entropy/chapter-03"), .file("entropy/audio/chapter-03.mp3"))
        // 页面顶栏的「书架」链接（../）
        XCTAssertEqual(L.target(forPath: "/books/"), .shelf)
        XCTAssertEqual(L.target(forPath: "/books"), .shelf)
    }

    func testUnsafeOrForeignPathsAreRejected() {
        typealias L = BookOfflineLayout
        XCTAssertEqual(L.target(forPath: "/books/entropy/../other/01.html"), .invalid)
        XCTAssertEqual(L.target(forPath: "/books/audiobook/entropy"), .invalid)
        XCTAssertEqual(L.target(forPath: "/books/audiobook/entropy/01/extra"), .invalid)
        XCTAssertEqual(L.target(forPath: "/etc/passwd"), .invalid)
        XCTAssertEqual(L.target(forPath: "/books/en tropy/01.html"), .invalid)
        XCTAssertFalse(L.isSafeSegment(".."))
        XCTAssertFalse(L.isSafeSegment(""))
        XCTAssertFalse(L.isSafeSegment("a/b"))
        XCTAssertNil(L.rootURL(slug: "../x"))
    }

    func testPublicAndLocalURLsRoundTripOnBothDomains() {
        typealias L = BookOfflineLayout
        let cn = URL(string: "https://voicedrop.cn/books/entropy/03.html")!
        let cf = URL(string: "https://jianshuo.dev/voicedrop/books/entropy/03.html")!
        XCTAssertEqual(L.localURL(forPublic: cn, slug: "entropy")?.absoluteString, "vdbook://offline/books/entropy/03.html")
        XCTAssertEqual(L.localURL(forPublic: cf, slug: "entropy")?.absoluteString, "vdbook://offline/books/entropy/03.html")
        // 书根页有没有尾斜杠都认
        XCTAssertEqual(L.localURL(forPublic: URL(string: "https://voicedrop.cn/books/entropy")!, slug: "entropy")?.absoluteString,
                       "vdbook://offline/books/entropy/")
        XCTAssertEqual(L.rootURL(slug: "entropy")?.absoluteString, "vdbook://offline/books/entropy/")
        // 别的书的地址不归这本书的本地副本管
        XCTAssertNil(L.localURL(forPublic: URL(string: "https://voicedrop.cn/books/other/01.html")!, slug: "entropy"))
        XCTAssertNil(L.localURL(forPublic: URL(string: "https://voicedrop.cn/books/entropy-2/01.html")!, slug: "entropy"))
        // 换算回线上：分享出去的链接别人得打得开
        let local = URL(string: "vdbook://offline/books/entropy/03.html")!
        XCTAssertEqual(L.publicURL(forLocal: local, base: "https://voicedrop.cn")?.absoluteString, "https://voicedrop.cn/books/entropy/03.html")
        XCTAssertEqual(L.publicURL(forLocal: local, base: "https://jianshuo.dev/voicedrop")?.absoluteString,
                       "https://jianshuo.dev/voicedrop/books/entropy/03.html")
        XCTAssertNil(L.publicURL(forLocal: cn, base: "https://voicedrop.cn"))
    }

    func testVideoBookPathsResolveLikeOnline() {
        typealias L = BookOfflineLayout
        // 目录页的动画版 iframe 指向 <书根>/video/；它的脚本、字体、口播都是相对引用。
        XCTAssertEqual(L.target(forPath: "/books/entropy/video/"), .file("entropy/video/index.html"))
        XCTAssertEqual(L.target(forPath: "/books/entropy/video"), .file("entropy/video/index.html"))
        XCTAssertEqual(L.target(forPath: "/books/entropy/video/index.html"), .file("entropy/video/index.html"))
        XCTAssertEqual(L.target(forPath: "/books/entropy/video/bundle.js"), .file("entropy/video/bundle.js"))
        XCTAssertEqual(L.target(forPath: "/books/entropy/video/fonts/PuHui-Bold.woff2"), .file("entropy/video/fonts/PuHui-Bold.woff2"))
        XCTAssertEqual(L.mimeType(forPath: "entropy/video/bundle.js"), "text/javascript; charset=utf-8")
    }

    func testOnlySafeManifestPathsAreMirrored() {
        typealias L = BookOfflineLayout
        for ok in ["index.html", "01.html", "cover.jpg", "_src/book.json", "video/index.html", "video/fonts/PuHui-Bold.woff2"] {
            XCTAssertTrue(L.isSafeRelativePath(ok), ok)
        }
        for bad in ["", "../x.html", "video/../../x", "/etc/passwd", "a//b", "有 空格.html", "a/b/c/d/e/f/g.js"] {
            XCTAssertFalse(L.isSafeRelativePath(bad), bad)
        }
    }

    func testFileListDecodesServerShape() throws {
        let json = #"{"slug":"entropy","files":[{"path":"index.html","size":120},{"path":"video/narration.mp3","size":31000000}],"audio":["01","02"],"bytes":31000120}"#
        let list = try JSONDecoder().decode(BookOfflineDownloader.FileList.self, from: Data(json.utf8))
        XCTAssertEqual(list.files.map(\.path), ["index.html", "video/narration.mp3"])
        XCTAssertEqual(list.files[1].size, 31_000_000)
        XCTAssertEqual(list.audio, ["01", "02"])
    }

    func testByteRangeMatchesWhatAudioElementsAsk() {
        typealias L = BookOfflineLayout
        XCTAssertEqual(L.byteRange("bytes=0-1", size: 1000), 0..<2)          // Safari 的探测请求
        XCTAssertEqual(L.byteRange("bytes=0-", size: 1000), 0..<1000)
        XCTAssertEqual(L.byteRange("bytes=500-699", size: 1000), 500..<700)
        XCTAssertEqual(L.byteRange("bytes=900-5000", size: 1000), 900..<1000) // 尾巴越界就截到文件尾
        XCTAssertEqual(L.byteRange("bytes=-200", size: 1000), 800..<1000)
        XCTAssertNil(L.byteRange(nil, size: 1000))
        XCTAssertNil(L.byteRange("bytes=1000-", size: 1000))                  // 起点越界 → 回整个文件
        XCTAssertNil(L.byteRange("bytes=0-1,5-9", size: 1000))                // 多段不支持
        XCTAssertNil(L.byteRange("items=0-1", size: 1000))
        XCTAssertNil(L.byteRange("bytes=0-1", size: 0))
    }

    func testMimeTypes() {
        XCTAssertEqual(BookOfflineLayout.mimeType(forPath: "a/01.html"), "text/html; charset=utf-8")
        XCTAssertEqual(BookOfflineLayout.mimeType(forPath: "a/audio/01.mp3"), "audio/mpeg")
        XCTAssertEqual(BookOfflineLayout.mimeType(forPath: "a/_src/book.json"), "application/json")
        XCTAssertEqual(BookOfflineLayout.mimeType(forPath: "a/cover.JPG"), "image/jpeg")
    }
}
