import SwiftUI
import WebKit

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
    let chapters: Int    // 顶层章节 html 数；单页书为 0
    var id: String { slug }

    var coverURL: URL? { URL(string: "https://voicedrop.cn/books/\(slug)/cover.jpg") }
    var pageURL: URL? { URL(string: "https://voicedrop.cn/books/\(slug)/") }
}

@MainActor
@Observable
final class BooksShelfStore {
    var books: [ShelfBook] = []
    var loading = false
    var error: String?

    private static let indexURL = URL(string: "https://voicedrop.cn/books/?format=json")!
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
            let (data, resp) = try await URLSession.shared.data(from: Self.indexURL)
            guard resp.isOK else { throw URLError(.badServerResponse) }
            books = try JSONDecoder().decode(Index.self, from: data).books
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
            VStack(spacing: 8) {
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
            if book.cover, let url = book.coverURL {
                // 有 cover.jpg：直接铺封面图，出图前布面封面当占位。
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        Color.clear.overlay(image.resizable().scaledToFill())
                    }
                }
            }
        }
        .aspectRatio(0.7, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .leading) { spine }
        .overlay(alignment: .trailing) { pageEdge }
        .clipShape(coverShape)
        .shadow(color: Color(.sRGB, red: 60/255, green: 45/255, blue: 30/255, opacity: 0.35), radius: 8, y: 7)
        .shadow(color: Color(.sRGB, red: 60/255, green: 45/255, blue: 30/255, opacity: 0.20), radius: 2, y: 2)
    }

    /// 布面缺省封面：深色渐变 + 左上高光 + 书名／细线／副题（竖版书封的横排版）。
    private func clothCover(_ book: ShelfBook) -> some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(hex: book.c), Color(hex: book.c2)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [.white.opacity(0.10), .clear],
                           center: UnitPoint(x: 0.25, y: 0.15), startRadius: 0, endRadius: 190)
            if !book.cover {
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

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                NavSquare(systemName: "chevron.left") { dismiss() }.accessibilityLabel("返回")
                Text(book.main)
                    .font(.custom("Songti SC", size: 21).weight(.semibold))
                    .foregroundStyle(Theme.ink).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 10)
            if let url = book.pageURL {
                BookWebView(url: url)
                    .ignoresSafeArea(edges: .bottom)
            }
        }
        .background(Theme.appBG.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { Analytics.screen("读书") }
    }
}

private struct BookWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let wv = WKWebView()
        wv.allowsBackForwardNavigationGestures = true
        wv.isOpaque = false
        wv.backgroundColor = UIColor(Theme.appBG)   // 加载间隙透出暖纸色，不闪白
        wv.scrollView.backgroundColor = UIColor(Theme.appBG)
        wv.load(URLRequest(url: url))
        return wv
    }

    func updateUIView(_ wv: WKWebView, context: Context) {}
}
