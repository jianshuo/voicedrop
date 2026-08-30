import SwiftUI
import UIKit
import WebKit
import ImageIO

// MARK: - 「写书」tab · 图书馆（设计稿 Books.dc.html ①）
//
// 实体书书架：两本一排，排下一条木质搁板。第一格固定是「写书」入口（虚线封面 +
// 红色加号），点开现有的 BookWritingSheet；后面是公开书架 voicedrop.cn/books/ 上
// 已出版的书。有 cover.jpg 的书直接铺封面图（保留书脊、页口、投影的实体感），
// 没有的用书名＋副标题排一张布面缺省封面，颜色由服务端按 slug 哈希稳定分配。
// 点一本书 → 原地推入 BookReaderView（同一导航栈，像打开一篇文章），内嵌
// WKWebView 显示 voicedrop.cn/books/<slug>/ 的网页书（阅读体验沿用网页版）。
//
// 数据 = GET voicedrop.cn/books/?format=json（公开无鉴权，60s 缓存）：
// {books:[{slug,title,main,sub,c,c2,cover,chapters}]}。最近一次成功的响应存
// UserDefaults，离线/加载中先画上次的书架。

struct ShelfBook: Decodable, Identifiable, Equatable, Hashable {
    let slug: String
    let title: String
    let main: String
    let sub: String
    let c: String        // 封面色（深）
    let c2: String       // 封面色（更深，渐变尾）
    let cover: Bool      // <slug>/cover.jpg 存在 → 直接铺图
    let coverAt: Double? // cover.jpg 上传时间戳（ms）；老缓存里没有 → optional
    let chapters: Int    // 顶层章节 html 数；单页书为 0
    let author: String?  // <meta name="author">；老缓存里没有 → optional
    let hidden: Bool?    // 自己的隐藏书（登录态下服务端才会给）；公开条目无此字段
    var id: String { slug }

    /// ?v=coverAt 与网页书架同款破缓存：修书换封面 → 时间戳变 → URL 变，
    /// 绕开 EdgeOne 边缘 + URLCache 的旧图（否则 App 只能干等缓存过期）。
    // 书架资源随 APIRoute 线路走：国内 voicedrop.cn（EO 边缘缓存）、海外
    // jianshuo.dev/voicedrop（CF 直连），两边路径由 publicWebBase 归一。
    var coverURL: URL? { URL(string: "\(API.publicWebBase)/books/\(slug)/cover.jpg?v=\(Int64(coverAt ?? 0))") }
    var pageURL: URL? { URL(string: "\(API.publicWebBase)/books/\(slug)/") }
}

@MainActor
@Observable
final class BooksShelfStore {
    var books: [ShelfBook] = []
    var loading = false
    var error: String?

    private static var indexURL: URL { URL(string: "\(API.publicWebBase)/books/?format=json")! }
    private static let cacheKey = "books.shelf.cache"
    private struct Index: Decodable { let books: [ShelfBook] }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let cached = try? JSONDecoder().decode(Index.self, from: data) {
            books = cached.books
        }
    }

    func load() async {
        loading = true
        defer { loading = false }
        do {
            // 带登录态：服务端把「自己的 hidden 书」也列进来（条目带 hidden:true），
            // 书架给它们贴「隐藏」角标；未登录/别人的隐藏书照旧不可见。
            var req = URLRequest(url: Self.indexURL)
            let bearer = AuthStore.shared.bearer
            if !bearer.isEmpty { req.setBearer(bearer) }
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard resp.isOK else { throw URLError(.badServerResponse) }
            // 内容没变就不赋值：赋值会让整个书架视图树无效重建（几十本书一帧内
            // 重排 = 打开后几秒的整屏卡死），而绝大多数刷新书单其实没变。
            let fresh = try JSONDecoder().decode(Index.self, from: data).books
            if fresh != books { books = fresh }
            error = nil
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
        } catch {
            // 有缓存就静默用缓存；全空才把错误亮出来。
            if books.isEmpty { self.error = error.localizedDescription }
        }
    }
}

struct BooksShelfView: View {
    @State private var store = BooksShelfStore()
    @State private var showBookWriting = false
    @State private var openBook: ShelfBook?

    /// 封面文字用的奶油白（布面书封上的烫字）。
    private static let cream = Color(hex: "F7F1DF")

    var body: some View {
        ScrollView {
            // LazyVStack：书多了以后只构建可见的几排（每格有渐变/Canvas/阴影/封面图，
            // 全量构建 + 全量起封面加载任务是整屏卡死的主因之一），滚到哪建到哪。
            LazyVStack(spacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: 22) {
                        ForEach(row) { cell in
                            cellView(cell)
                        }
                        if row.count == 1 {
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                    shelfBar
                }
                if store.loading && store.books.isEmpty {
                    ProgressView().tint(Theme.recordRed).padding(.top, 24)
                } else if let err = store.error, store.books.isEmpty {
                    Text("书架没加载出来：\(err)")
                        .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                        .padding(.top, 18)
                }
            }
            .padding(.top, 6).padding(.horizontal, 20).padding(.bottom, 20)
        }
        .contentMargins(.bottom, 24, for: .scrollContent)
        .refreshable { await store.load() }
        .task { await store.load() }
        .onAppear { Analytics.screen("书架") }
        .sheet(isPresented: $showBookWriting) { BookWritingSheet() }
        .navigationDestination(item: $openBook) { book in BookReaderView(book: book) }
    }

    // MARK: rows（第一格永远是写书入口，两格一排）

    private enum Cell: Identifiable {
        case write
        case book(ShelfBook)
        var id: String {
            switch self {
            case .write: return "·write·"
            case .book(let b): return b.id
            }
        }
    }

    private var rows: [[Cell]] {
        let cells: [Cell] = [.write] + store.books.map { .book($0) }
        return stride(from: 0, to: cells.count, by: 2).map { Array(cells[$0..<min($0 + 2, cells.count)]) }
    }

    @ViewBuilder private func cellView(_ cell: Cell) -> some View {
        switch cell {
        case .write: writeEntry
        case .book(let b): bookCell(b)
        }
    }

    // MARK: 写书入口（第一本书的位置）

    private var writeEntry: some View {
        Button {
            showBookWriting = true
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                ZStack {
                    Color(hex: "F3ECE0")
                    VStack(spacing: 9) {
                        ZStack {
                            Circle().fill(Theme.recordRed)
                                .frame(width: 34, height: 34)
                                .shadow(color: Theme.recordRed.opacity(0.30), radius: 4.5, y: 3)
                            Image(systemName: "plus")
                                .font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                        }
                        Text("写书")
                            .font(.system(size: 15, weight: .semibold)).tracking(1)
                            .foregroundStyle(Color(hex: "6F685D"))
                    }
                }
                .aspectRatio(0.7, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(coverShape)
                .overlay(coverShape.stroke(Color(hex: "CFC0A6"), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                caption(title: String(localized: "写一本新书"), meta: " ")
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: 一本书

    private func bookCell(_ book: ShelfBook) -> some View {
        Button {
            openBook = book
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                bookCover(book)
                caption(title: book.main, meta: metaLine(book))
            }
        }
        .buttonStyle(.plain)
    }

    private func metaLine(_ book: ShelfBook) -> String {
        if book.chapters > 0 { return String(localized: "\(book.chapters) 章") }
        if !book.sub.isEmpty { return book.sub }
        return " "
    }

    @ViewBuilder private func bookCover(_ book: ShelfBook) -> some View {
        ZStack {
            clothCover(book)
            if book.cover {
                // 有 cover.jpg：直接铺封面图，出图前布面封面（带书名）当占位。
                CoverImage(book: book)
            }
        }
        .aspectRatio(0.7, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .leading) { spine }
        .overlay(alignment: .trailing) { pageEdge }
        .overlay(alignment: .topTrailing) {
            if book.hidden == true {
                Text("隐藏")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(6)
            }
        }
        .clipShape(coverShape)
        .shadow(color: Color(.sRGB, red: 60/255, green: 45/255, blue: 30/255, opacity: 0.35), radius: 8, y: 7)
        .shadow(color: Color(.sRGB, red: 60/255, green: 45/255, blue: 30/255, opacity: 0.20), radius: 2, y: 2)
    }

    /// 封面图：弃 AsyncImage（无持久缓存、失败即终态，弱网下随机哪本就空白了），
    /// 改 DiskCache 持久缓存 + 指数退避重试。命中磁盘 = 零网络秒出；未命中才拉网，
    /// 成功落盘，下次冷启动也不再依赖网络。key 带 coverAt，修书换封面自动失效。
    private struct CoverImage: View {
        let book: ShelfBook
        @State private var image: UIImage?

        var body: some View {
            ZStack {
                if let image {
                    Color.clear.overlay(Image(uiImage: image).resizable().scaledToFill())
                }
            }
            .task(id: book.coverURL) { image = await Self.load(book) }
        }

        static func load(_ book: ShelfBook) async -> UIImage? {
            let name = "cover-\(book.slug)-\(Int64(book.coverAt ?? 0)).jpg"
            if let d = DiskCache.loadData(name), let img = decoded(d) { return img }
            guard let url = book.coverURL else { return nil }
            for attempt in 0..<4 {
                if Task.isCancelled { return nil }   // 划走的格子别白费流量
                if attempt > 0 { try? await Task.sleep(for: .seconds(Double(1 << attempt))) }
                var req = URLRequest(url: url)
                // 头两次走正常缓存；再失败就怀疑 URLCache 钉了坏响应，穿透重拉
                if attempt >= 2 { req.cachePolicy = .reloadIgnoringLocalCacheData }
                if let (data, resp) = try? await URLSession.shared.data(for: req),
                   (resp as? HTTPURLResponse)?.statusCode == 200,
                   let img = decoded(data) {
                    DiskCache.saveData(data, name)
                    return img
                }
            }
            return nil
        }

        /// ImageIO 降采样 + 立即解码：`UIImage(data:)` 只包壳，真正的 JPEG 解码
        /// 拖到主线程首次渲染那一刻——几十本封面一起到齐就是整屏冻住 1-2 秒。
        /// 这里在后台线程按显示尺寸（格宽 ~170pt，640px 富余）出预解码位图，
        /// 主线程只画现成像素。
        private static func decoded(_ data: Data) -> UIImage? {
            guard let src = CGImageSourceCreateWithData(data as CFData,
                    [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
            let opts = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceShouldCacheImmediately: true,
                        kCGImageSourceThumbnailMaxPixelSize: 640] as CFDictionary
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts) else { return nil }
            return UIImage(cgImage: cg)
        }
    }

    /// 布面缺省封面：深色渐变 + 左上高光 + 书名／细线／副题（竖版书封的横排版）。
    private func clothCover(_ book: ShelfBook) -> some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(hex: book.c), Color(hex: book.c2)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [.white.opacity(0.10), .clear],
                           center: UnitPoint(x: 0.25, y: 0.15), startRadius: 0, endRadius: 190)
            // 书名常驻布面：有封面图时它是加载占位/失败兜底（图是不透明 JPEG，
            // 载入后完全盖住），此前 `if !book.cover` 的门导致图挂了就剩纯色块。
            VStack(alignment: .leading, spacing: 9) {
                    Text(book.main)
                        .font(.custom("Songti SC", size: 22).weight(.bold))
                        .tracking(3).lineSpacing(4)
                        .foregroundStyle(Self.cream)
                        .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
                    Rectangle().fill(Self.cream.opacity(0.55)).frame(width: 26, height: 1)
                    if !book.sub.isEmpty {
                        Text(book.sub)
                            .font(.custom("Songti SC", size: 11.5))
                            .foregroundStyle(Self.cream.opacity(0.72))
                            .lineSpacing(3)
                    }
                }
            .padding(.top, 26).padding(.leading, 24).padding(.trailing, 16)
        }
    }

    /// 书脊：左缘一条 13pt 的暗→亮渐变，压出圆脊的弧面。
    private var spine: some View {
        LinearGradient(stops: [
            .init(color: .black.opacity(0.36), location: 0),
            .init(color: .black.opacity(0.10), location: 0.55),
            .init(color: .white.opacity(0.12), location: 1),
        ], startPoint: .leading, endPoint: .trailing)
        .frame(width: 13)
        .allowsHitTesting(false)
    }

    /// 页口：右缘 3pt，一深一浅的横纹画出纸页。
    private var pageEdge: some View {
        Canvas { ctx, size in
            var y: CGFloat = 0
            while y < size.height {
                ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(.white.opacity(0.85)))
                ctx.fill(Path(CGRect(x: 0, y: y + 1, width: size.width, height: 1)),
                         with: .color(Color(hex: "D6CAB4").opacity(0.9)))
                y += 2
            }
        }
        .frame(width: 3)
        .allowsHitTesting(false)
    }

    private func caption(title: String, meta: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.custom("Songti SC", size: 14.5).weight(.semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            Text(meta)
                .font(.system(size: 12.5)).foregroundStyle(Theme.metaChrome)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 书封外形：书脊侧 2pt 小圆角，翻口侧 5pt——跟设计稿一致的「精装书」轮廓。
    private var coverShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 2, bottomLeadingRadius: 2,
                               bottomTrailingRadius: 5, topTrailingRadius: 5)
    }

    /// 搁板：一条 6pt 的木色渐变，向两侧各探出 6pt。
    private var shelfBar: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(LinearGradient(colors: [Color(hex: "E3D7C2"), Color(hex: "C9B99E")],
                                 startPoint: .top, endPoint: .bottom))
            .frame(height: 6)
            .shadow(color: Color(.sRGB, red: 120/255, green: 95/255, blue: 60/255, opacity: 0.18), radius: 3.5, y: 3)
            .padding(.horizontal, -6)
            .padding(.bottom, 14)
    }
}

// MARK: - 读一本书（原地推入，设计稿 Books.dc.html ④ 的头部样式）

/// 点书后推入同一导航栈：暖纸顶栏（返回键 + 宋体书名）+ 内嵌 WKWebView 显示
/// voicedrop.cn/books/<slug>/ 的网页书。章节跳转都在这个 WebView 里进行，
/// 左缘手势先回退网页历史，退无可退时由系统 pop 回书架。
struct BookReaderView: View {
    @Environment(\.dismiss) private var dismiss
    let book: ShelfBook
    @State private var sharePayload: SharePayload?
    @State private var toast: String?
    @State private var showRevise = false
    @State private var reloadStamp = 0   // 修改 sheet 关掉后 +1，强制 WebView 重载看最新版
    @State private var pageURL: URL?     // WebView 当前页（章节跳转跟着变）
    @State private var pageTitle: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                NavSquare(systemName: "chevron.left") { dismiss() }.accessibilityLabel("返回")
                Text(book.main)
                    .font(.custom("Songti SC", size: 21).weight(.semibold))
                    .foregroundStyle(Theme.ink).lineLimit(1)
                Spacer()
                moreMenu
            }
            .padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 10)
            if let url = book.pageURL {
                BookWebView(url: url, pageURL: $pageURL, pageTitle: $pageTitle)
                    .id(reloadStamp)   // 修改 sheet 关掉后换实例重载，立刻看到新版
                    .ignoresSafeArea(edges: .bottom)
            }
        }
        .background(Theme.appBG.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { Analytics.screen("读书") }
        .sheet(item: $sharePayload) { ShareSheet(items: $0.activityItems) }
        .sheet(isPresented: $showRevise, onDismiss: { reloadStamp += 1 }) { BookReviseSheet(book: book) }
        .overlay(alignment: .bottom) { toastView }
        .animation(.easeInOut(duration: 0.2), value: toast)
    }

    /// 顶栏右上角的 ⋯（与文章页 moreMenu 同款）：白底灰点 + 描边，展开分享。
    private var moreMenu: some View {
        Menu {
            Button { showRevise = true } label: {
                Label("修改这本书", systemImage: "pencil.line")
            }
            Button { Task { await shareToWechat(timeline: false) } } label: {
                Label("分享给微信好友", systemImage: "message")
            }
            Button { Task { await shareToWechat(timeline: true) } } label: {
                Label("分享到朋友圈", systemImage: "person.2")
            }
            Button { Task { await shareBook() } } label: {
                Label("分享", systemImage: "square.and.arrow.up")
            }
        } label: {
            RoundedRectangle(cornerRadius: Theme.R.nav)
                .fill(Theme.card)
                .frame(width: 38, height: 38)
                .overlay {
                    Image(systemName: "ellipsis").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.secondary)
                }
                .overlay(RoundedRectangle(cornerRadius: Theme.R.nav).stroke(Theme.borderRead, lineWidth: 1))
                .navButtonShadow()
        }
        .accessibilityLabel("更多")
    }

    /// 分享目标 = WebView 当前浏览的页面（章节跳转跟着变）。只认 /books/ 域内的
    /// 页面（防外链），拿不到就退回书根页。章节页标题用网页 <title>，书根页
    /// （或标题还没加载出来）用《书名》— 作者。
    private var currentShare: (url: URL, title: String, isChapter: Bool)? {
        guard let root = book.pageURL else { return nil }
        let byline = (book.author?.isEmpty == false) ? " — \(book.author!)" : ""
        let bookTitle = "《\(book.title)》\(byline)"
        guard let u = pageURL, u.path.hasPrefix("/books/"), u.path != root.path else {
            return (root, bookTitle, false)
        }
        let t = (pageTitle?.isEmpty == false) ? pageTitle! : bookTitle
        return (u, t, true)
    }

    /// 微信好友 / 朋友圈：OpenSDK 正规分享——弹微信原生确认页，链接卡片带封面
    /// 缩略图。没装微信才退回旧的「剪贴板直达」。
    private func shareToWechat(timeline: Bool) async {
        guard let target = currentShare else { return }
        Analytics.capture(timeline ? "分享书到朋友圈" : "分享书给微信好友",
                          ["书": book.slug, "章节页": target.isChapter])
        guard WeChatShare.isInstalled else {
            UIPasteboard.general.string = "\(target.title)\n\(target.url.absoluteString)"
            showToast(String(localized: "没检测到微信，链接在剪贴板里"))
            return
        }
        var thumb: UIImage?
        if book.cover, let coverURL = book.coverURL,
           let (data, resp) = try? await URLSession.shared.data(from: coverURL), resp.isOK {
            thumb = UIImage(data: data)
        }
        let byline = (book.author?.isEmpty == false) ? " — \(book.author!)" : ""
        let desc = target.isChapter ? "《\(book.title)》\(byline)"
                                    : String(localized: "VoiceDrop 图书馆 · 点开即读")
        // 好友出小程序卡（book-reader 页，章节分享带 &page= 直接翻到那一页）；
        // 朋友圈仍走网页卡。
        if !timeline {
            WeChatShare.shareMiniProgram(
                webpageUrl: target.url,
                path: WeChatShare.bookReaderPath(slug: book.slug, title: book.title,
                                                 main: book.main, author: book.author ?? "",
                                                 cover: book.cover, coverAt: Int64(book.coverAt ?? 0),
                                                 chapterURL: target.isChapter ? target.url : nil),
                title: target.title, description: desc, thumb: thumb)
        } else {
            WeChatShare.shareWebpage(url: target.url, title: target.title,
                                     description: desc, thumb: thumb, timeline: timeline)
        }
    }

    private func showToast(_ msg: String) {
        toast = msg
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if toast == msg { toast = nil }
        }
    }

    @ViewBuilder private var toastView: some View {
        if let toast {
            Text(toast)
                .font(.system(size: 15)).foregroundStyle(Theme.inkRead)
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Theme.borderRead, lineWidth: 1))
                .padding(.bottom, 32)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// 分享（系统面板）：同样跟着 WebView 当前页走——微信拿裸链接出富卡片（有
    /// cover.jpg 就带上当缩略图），X / 复制等拿「标题 + 链接」的整段文字。
    /// 同社区的 SharePayload 通路。
    private func shareBook() async {
        guard let target = currentShare else { return }
        let text = "\(target.title)\n\(target.url.absoluteString)"
        var image: UIImage?
        if book.cover, let coverURL = book.coverURL,
           let (data, resp) = try? await URLSession.shared.data(from: coverURL), resp.isOK {
            image = UIImage(data: data)
        }
        Analytics.capture("分享书", ["书": book.slug, "章节页": target.isChapter])
        sharePayload = SharePayload(text: text, url: target.url, title: target.title, image: image)
    }
}

private struct BookWebView: UIViewRepresentable {
    let url: URL
    @Binding var pageURL: URL?     // 当前浏览到的页面（章节跳转跟着变）——分享分享的是它
    @Binding var pageTitle: String?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let wv = WKWebView()
        wv.allowsBackForwardNavigationGestures = true
        wv.isOpaque = false
        wv.backgroundColor = UIColor(Theme.appBG)   // 加载间隙透出暖纸色，不闪白
        wv.scrollView.backgroundColor = UIColor(Theme.appBG)
        // KVO 跟踪 url/title（WebKit 在主线程发）；SPA 内跳转、前进后退都会触发。
        context.coordinator.urlObs = wv.observe(\.url, options: [.initial, .new]) { wv, _ in
            let u = wv.url
            Task { @MainActor in pageURL = u }
        }
        context.coordinator.titleObs = wv.observe(\.title, options: [.initial, .new]) { wv, _ in
            let t = wv.title
            Task { @MainActor in pageTitle = t }
        }
        wv.load(URLRequest(url: url))
        return wv
    }

    func updateUIView(_ wv: WKWebView, context: Context) {}

    final class Coordinator {
        var urlObs: NSKeyValueObservation?
        var titleObs: NSKeyValueObservation?
    }
}
