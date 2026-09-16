import SwiftUI
import UIKit

/// 「我的录音」— the app's home (方案二). White-card list of recordings; a docked
/// pure-red record key at the bottom opens the full-screen recording takeover;
/// the gear pushes Settings. Pulls fresh data on appear and drains any pending
/// local uploads.
enum HomeTab: Hashable { case recordings, community, books, tag(String) }

struct LibraryView: View {
    @State private var store = LibraryStore()
    @State private var uploader = Uploader.shared   // 单例：后台传输收尾要能路由到它
    private let community = CommunityStore.shared
    @State private var statusSession = StatusSession()
    @State private var linkResponder = DeviceLinkResponder()
    @State private var tab: HomeTab = .recordings
    @State private var confirmDelete: Recording?
    @State private var confirmReprocess: Recording?
    // A pending record launch. Item-based so parameters travel WITH the presentation:
    // fullScreenCover(item:) always builds the sheet from the item that triggered it
    // (isPresented: + separate @State flags read STALE on the first present — real bug).
    // The AI 采访员 is no longer chosen here: it's a toggle INSIDE the recording screen
    // (采访 key left of 停止), so the only launch parameter left is the tag.
    @State private var recordLaunch: RecordLaunch?
    private struct RecordLaunch: Identifiable {
        let id = UUID()
        let tag: String?        // deep-link/intent tag; nil = use the current page's tag
    }
    @State private var showSettings = false
    @State private var showUsage = false   // 算力账单直达（「文章被投喂」推送深链）
    @State private var selectedRec: Recording?
    @State private var selectedPost: CommunityPost?
    @State private var openFeedBook: ShelfBook?   // 社区书卡 → 推入书架同款 BookReaderView
    // Universal-link web fallback (/help/ 等无原生对应的页面) — in-app Safari.
    @State private var webSheet: WebSheetItem?
    private struct WebSheetItem: Identifiable {
        let id = UUID()
        let url: URL
    }
    // Universal link 指向别人的分享（非社区帖）→ 只读阅读页（SharedArticleView）。
    @State private var sharedArticle: SharedArticleNav?
    private struct SharedArticleNav: Identifiable, Hashable {
        let id = UUID()
        let shared: SharedArticle
        let index: Int
        static func == (l: Self, r: Self) -> Bool { l.id == r.id }
        func hash(into h: inout Hasher) { h.combine(id) }
    }
    @State private var confirmUnshare: CommunityPost?
    // Task 6：voicedrop.cn/<7位魔法数字> universal link → 从根上弹 PromptImportSheet
    // 预填该码（跟 webSheet 同一套「全局 sheet 兜底」模式）。PromptManagerView 深两层
    // push（我的录音→设置→提示词）且中间没有 item-based 导航通道，把它也一并 push 到
    // 属于「深度纠缠」，按 Task 6 brief 的兜底方案：连 showSettings 一起置位，sheet 收起后
    // 用户已经站在设置页，一步之遥；但没有列表可滚/高亮（PromptImportSheet 的 onImported
    // 用默认 no-op）——这点在 Task 6 报告里记了。
    @State private var promptImportPrefill: PromptImportPrefillItem?
    private struct PromptImportPrefillItem: Identifiable {
        let id: String   // 码本身即可当 id：同一个码不会有两份并存的 item
        var code: String { id }
    }

    @EnvironmentObject private var router: AppRouter
    @Environment(\.scenePhase) private var scenePhase

    /// Local takes still uploading (top) + just-uploaded optimistic 待处理 +
    /// server recordings. Same audioName = same row id, so badges change in place.
    private var rows: [Recording] {
        let serverNames = Set(store.recordings.map(\.audioName))
        let uploading = uploader.pending
            .map { Recording(audioName: $0.lastPathComponent, uploaded: "", hasArticles: false, isEmpty: false,
                             tags: uploader.pendingTagsByName[$0.lastPathComponent], uploading: true) }
            .filter { !serverNames.contains($0.audioName) }
        let busy = serverNames.union(uploading.map(\.audioName))
        // Optimistic: an uploaded take shows as 待处理 immediately, before the
        // server list catches up — so the row never disappears between states.
        let optimistic = uploader.justUploaded
            .filter { !busy.contains($0) }
            .map { Recording(audioName: $0, uploaded: "", hasArticles: false, isEmpty: false,
                             tags: uploader.pendingTagsByName[$0], uploading: false) }
        // store.recordings is ALREADY ordered newest-first (LibraryStore.load → Recording.newestFirst);
        // do NOT re-sort here. Just prepend the in-flight rows (uploading / just-uploaded), which are
        // the newest by definition, so they sit on top.
        // Server rows that haven't learned their tags yet (list caught up before the
        // R2 sidecar was read) borrow the uploader's remembered tags — otherwise the
        // row blinks off its tag page for one load cycle during the handoff.
        let server = store.recordings.map { rec in
            guard rec.tags == nil, let t = uploader.pendingTagsByName[rec.audioName] else { return rec }
            var patched = rec; patched.tags = t; return patched
        }
        return uploading + optimistic + server
    }

    /// The tag of the page the user is on (nil on 我的录音 / VD社区). A recording
    /// started here default-carries this tag.
    private var currentPageTag: String? {
        if case .tag(let t) = tab { return t }
        return nil
    }

    /// Every tag currently on any article, deduped, ordered by the newest
    /// recording that carries it — drives the dynamic tag tabs after VD社区.
    private var allTags: [String] {
        var seen = Set<String>(), out: [String] = []
        for rec in store.recordings {
            for t in rec.tags ?? [] where seen.insert(t).inserted { out.append(t) }
        }
        return out
    }

    // Explicit Binding<Bool> so the SwiftUI view body doesn't pay to type-infer an
    // inline `.init(get:set:)` per alert — a chain of 4 alerts with inline bindings
    // blows the Swift type-checker's budget ("unable to type-check in reasonable time",
    // machine-dependent: passes locally, times out on the slower CI runner).
    private func clearBinding(_ isSet: @escaping () -> Bool, _ clear: @escaping () -> Void) -> Binding<Bool> {
        Binding(get: isSet, set: { if !$0 { clear() } })
    }

    // Split into two typed `some View` properties: the type-checker handles each half
    // independently, keeping each well under budget. Do NOT re-collapse into one chain.
    var body: some View {
        rowAlerts
    }

    private var rowAlerts: some View {
        mainContent
            .onChange(of: store.recordings) { _, recs in checkPendingReplies(recs) }
            .alert("删除这条录音？", isPresented: clearBinding({ confirmDelete != nil }, { confirmDelete = nil }),
                   presenting: confirmDelete) { rec in
                Button("删除", role: .destructive) { Task { await store.delete(rec) } }
                Button("取消", role: .cancel) {}
            } message: { _ in Text("音频和已挖出的文章都会从云端删除，不可恢复。") }
            .alert("重新生成这篇文章？", isPresented: clearBinding({ confirmReprocess != nil }, { confirmReprocess = nil }),
                   presenting: confirmReprocess) { rec in
                Button("重新生成", role: .destructive) { Task { await store.deleteArticle(rec) } }
                Button("取消", role: .cancel) {}
            } message: { _ in Text("删掉当前文章、保留录音，立即重新挖一遍。生成的内容可能和原来不同。") }
            .alert("从社区移除？", isPresented: clearBinding({ confirmUnshare != nil }, { confirmUnshare = nil }),
                   presenting: confirmUnshare) { post in
                Button("移除", role: .destructive) { Task { await community.unshare(post.shareId) } }
                Button("取消", role: .cancel) {}
            } message: { _ in Text("社区里将看不到这篇；你的原文章不受影响，以后还能再分享。") }
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            topBar
            tabHeader
            switch tab {
            case .recordings: recordingsContent
            case .community: communityContent
            case .books: BooksShelfView()
            case .tag(let t): tagContent(t)
            }
        }
        .background(Theme.appBG.ignoresSafeArea())
        .onChange(of: allTags) { _, tags in
            // The tab a user is ON can disappear (voice-removed its last tag);
            // fall back to 我的录音 instead of stranding them on a headless page.
            // NEVER judge mid-load: enrichment may still be arriving and a
            // transient tag-less state would bounce the user for nothing.
            if !store.loading, case .tag(let t) = tab, !tags.contains(t) { tab = .recordings }
            // Keep the App Intents tag picker's candidates fresh (see CachedTags).
            if !tags.isEmpty || !store.loading { CachedTags.save(tags) }
        }
        .onChange(of: store.loading) { _, isLoading in
            // Loading just finished — now the tag set is authoritative; if the
            // page's tag is truly gone (deleted mid-load), fall back once.
            if !isLoading, case .tag(let t) = tab, !allTags.contains(t) { tab = .recordings }
        }
        .overlay(alignment: .bottom) {
            // The red key (record + press-and-hold voice commands) lives on 我的
            // 录音 AND every tag page — a tag page is the same list, filtered.
            // VD社区和写书书架没有它（书架第一格自己就是入口）。
            if tab != .community && tab != .books {
                recordButton
            } else {
                EmptyView()
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(item: $selectedRec) { rec in RecordingDetailView(store: store, recording: rec) }
        .navigationDestination(item: $selectedPost) { post in
            CommunityPostView(store: community, post: post, onRecordFinished: responseRecorded)
        }
        .navigationDestination(item: $openFeedBook) { book in BookReaderView(book: book) }
        .navigationDestination(item: $sharedArticle) { nav in
            SharedArticleView(store: community, shared: nav.shared, articleIndex: nav.index)
        }
        .navigationDestination(isPresented: $showSettings) { SettingsView(libraryStore: store) }
        .navigationDestination(isPresented: $showUsage) { UsageView() }
        .fullScreenCover(item: $recordLaunch) { launch in
            RecordSession(defaultTag: launch.tag ?? currentPageTag) {
                recordLaunch = nil
                Task { await refresh() }
            }
        }
        .onAppear { Analytics.screen("录音列表") }   // 回到列表 = 离开某条录音，清掉「当前录音」
        .task {
            statusSession.onPhase = { stem, phase in store.markPhase(stem: stem, phase: phase) }
            statusSession.onDone = { stem in store.markDone(stem: stem) }
            statusSession.onLinkRequest = { pid, code, pubkey in linkResponder.present(pairingId: pid, code: code, pubkey: pubkey) }
            statusSession.onLinkRelease = { pid in linkResponder.release(pairingId: pid) }
            statusSession.connect()
            await refresh()
            _ = await store.ownerScope()   // 顺手触发 /whoami → Analytics.identify（匿名事件并入账号）
        }
        // 划走 = 拒绝这次登录。以前划走只是静默置空 pending，服务端还以为配对活着，
        // 手机却已经把 pubkey 扔了 —— 无声僵死到超时。
        .sheet(item: $linkResponder.pending, onDismiss: { linkResponder.sheetDismissed() }) { p in
            DeviceLinkApprovalSheet(responder: linkResponder, pending: p)
        }
        .sheet(item: $webSheet) { item in
            SafariView(url: item.url).ignoresSafeArea()
        }
        .sheet(item: $promptImportPrefill) { item in
            PromptImportSheet(prefill: item.code)
        }
        .onChange(of: scenePhase) { _, p in
            if p == .active { statusSession.connect(); Task { await refresh() } }
            else if p == .background { statusSession.disconnect() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .vdDidAdoptAccount)) { _ in
            statusSession.disconnect()
            statusSession.connect()
            Task { await refresh() }
        }
        .onReceive(router.$pending.compactMap { $0 }) { link in
            // A deep link (voicedrop://<page>) arrived — apply it, clearing any
            // pushed detail/settings so it lands cleanly, then reset.
            // RECORDING IS SACRED: if a take is in progress (cover presented), a deep
            // link must NOT dismiss it — the old `recordLaunch = nil` here tore down
            // the cover and onDisappear discarded the un-promoted take (total loss of
            // however long the user had been speaking). Drop the link instead.
            guard recordLaunch == nil else {
                EngineRecorder.trace("deep link ignored — recording in progress")
                router.pending = nil
                return
            }
            switch link {
            case .recordings, .invite:
                // .invite：归因已在 AppRouter 记过（第 1 层），已装用户点邀请链接落主页即可。
                tab = .recordings; selectedRec = nil; selectedPost = nil; showSettings = false; showUsage = false; sharedArticle = nil
                Task { await refresh() }
            case .community:
                tab = .community; selectedRec = nil; selectedPost = nil; showSettings = false; showUsage = false; sharedArticle = nil
            case .books:
                tab = .books; selectedRec = nil; selectedPost = nil; showSettings = false; showUsage = false; sharedArticle = nil
            case .settings:
                selectedRec = nil; selectedPost = nil; showSettings = true; showUsage = false; sharedArticle = nil
            case .usage:
                // 「文章被投喂」推送点开 → 直达算力账单，不绕设置页。
                selectedRec = nil; selectedPost = nil; showSettings = false; sharedArticle = nil
                showUsage = true
            case .record(let tag):
                // A deep-link/intent tag beats the current page's tag; nil keeps
                // page behavior (record on a tag page → that page's tag).
                selectedRec = nil; selectedPost = nil; showSettings = false; showUsage = false; sharedArticle = nil
                recordLaunch = RecordLaunch(tag: tag)
            case .article(let stem):
                tab = .recordings; selectedPost = nil; showSettings = false; showUsage = false; sharedArticle = nil
                // 深链即权威:article 深链只在成文后才会发出(「文章已生成」推送/分享链),
                // 而本地快照多半还停在挖矿前(hasArticles=false),fetchDoc 会被旧 flag
                // 挡住不问服务端。强行置位后详情页第一次 .task 就直接拉正文,点开约
                // 1 秒见文章;不置位就得等下面整列表刷新换入新值、靠 .task(id:) 二次
                // 拉取,要多等两三秒。若推送撒谎(文章其实没有),fetchDoc 404 → 仍显示
                // 「还没成文」,和从前一样。
                if var snap = store.recordings.first(where: { $0.stem == stem }) {
                    snap.hasArticles = true
                    selectedRec = snap
                } else {
                    selectedRec = nil   // 本地还没这条录音,等刷新后由下面的 fresh 补开
                }
                let opened = selectedRec
                Task {
                    await refresh()
                    guard selectedRec == opened else { return }   // 刷新期间用户自己导航了,不打扰
                    if let fresh = store.recordings.first(where: { $0.stem == stem }), fresh != opened {
                        selectedRec = fresh
                    }
                }
            case .shareLink(let id, let fallback):
                // https://voicedrop.cn/<id> — ask the server what it points at;
                // my own article opens natively, anything else opens the public
                // page in-app. Resolution is async; the .article it may enqueue
                // re-enters this handler (and its recording guard) normally.
                Task { await openShareLink(id, fallback: fallback) }
            case .promptImport(let code):
                // https://voicedrop.cn/<7位数字> — 推到设置页 + 弹导入 sheet 预填该码
                // （Task 6；PromptManagerView 本身够不着，见上面 promptImportPrefill 的注释）。
                selectedRec = nil; selectedPost = nil; sharedArticle = nil; showUsage = false
                showSettings = true
                promptImportPrefill = PromptImportPrefillItem(id: code)
            case .web(let u):
                webSheet = WebSheetItem(url: u)
            }
            Task { @MainActor in router.pending = nil }
        }
    }

    /// Resolve a universal-link share id (voicedrop.cn/<id>) via the public
    /// GET /files/api/link/<id> — 全部原生落地：
    ///   我自己的文章   → 原生详情页（RecordingDetailView，复用 .article 路由）
    ///   社区帖         → 原生帖子页（CommunityPostView 自己按 shareId 拉全文/回复/投币态）
    ///   别人的普通分享 → 只读阅读页（SharedArticleView，正文就在 link 响应里）
    ///   解析失败/过期  → 站内 Safari 兜底，绝不死链。
    private func openShareLink(_ id: String, fallback: URL) async {
        if let (data, resp) = try? await URLSession.shared.data(from: API.filesBase.appending(path: "link/\(id)")),
           resp.isOK,
           let shared = try? JSONDecoder().decode(SharedArticle.self, from: data) {
            if let scope = await store.ownerScope(), shared.owner == scope {
                router.pending = .article(shared.stem)
            } else if shared.type == "community" {
                tab = .community; selectedRec = nil; showSettings = false; showUsage = false; sharedArticle = nil
                selectedPost = CommunityPost(shareId: id, author: nil, title: nil,
                                             firstSharedAt: nil, updatedAt: nil,
                                             count: nil, mine: nil, replyTo: nil)
            } else {
                // ?s=<i> = 分享者当时选中的那篇；越界回落第 0 篇。
                let s = URLComponents(url: fallback, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "s" })?.value.flatMap(Int.init) ?? 0
                let count = shared.articles?.count ?? 0
                selectedRec = nil; selectedPost = nil; showSettings = false
                sharedArticle = SharedArticleNav(shared: shared, index: (0..<max(count, 1)).contains(s) ? s : 0)
            }
            return
        }
        webSheet = WebSheetItem(url: fallback)
    }

    private func checkPendingReplies(_ recs: [Recording]) {
        for rec in recs where rec.hasArticles {
            let key = "vd.pendingReply.\(rec.audioName)"
            if let replyTo = UserDefaults.standard.string(forKey: key) {
                UserDefaults.standard.removeObject(forKey: key)
                Task { _ = await community.share(rec, replyTo: replyTo) }
            }
        }
    }

    private func responseRecorded() { Task { await refresh() } }

    private func refresh() async {
        uploader.refreshPending()                 // surface 正在上传 rows immediately
        await store.load()
        if uploader.pendingCount > 0 { _ = await uploader.drainPending(); await store.load() }
        // 失败留队的照片：去掉 drain 内退避后，前台刷新是「app 常驻前台、网络无波动」
        // 场景下的主要重试路径（其余触发点：启动/联网恢复/enqueue/音频上传前）。
        if PhotoUploadQueue.shared.hasPending { Task { await PhotoUploadQueue.shared.drain() } }
        uploader.dropConfirmed(Set(store.recordings.map(\.audioName)))  // prune confirmed optimistic rows
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack {
            HStack(spacing: 8) {
                WaveformBars(color: Theme.recordRed, heights: [6, 12, 16, 8], barWidth: 3, spacing: 2.5)
                Text("VoiceDrop 口述").font(.system(size: 14, weight: .semibold)).tracking(1).foregroundStyle(Theme.ink)
            }
            Spacer()
            NavSquare(systemName: "gearshape") { showSettings = true }.accessibilityLabel("设置")
        }
        .padding(.top, 6).padding(.horizontal, 22).padding(.bottom, 10)
    }

    // MARK: Tabs (我的录音 / 社区)

    private var tabHeader: some View {
        // Horizontally scrollable: the three fixed tabs plus one tab per existing
        // article tag (newest first). With no tags the layout is unchanged.
        // 选中的 tab 自动滚进可视区——深链/点选落在被截断的 tab 上时把它带进来。
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .firstTextBaseline, spacing: 20) {
                    tabLabel(String(localized: "我的录音"), .recordings)
                    tabLabel(String(localized: "VD社区"), .community)
                    tabLabel(String(localized: "写书"), .books)
                    ForEach(allTags, id: \.self) { t in
                        tabLabel(t, .tag(t))
                    }
                }
                .padding(.horizontal, 22)
            }
            .onChange(of: tab) { _, t in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(t) }
            }
        }
        .padding(.bottom, 10)
    }

    private func tabLabel(_ title: String, _ t: HomeTab) -> some View {
        let active = tab == t
        return Button {
            tab = t
            if t == .community { Task { await community.load() } }
        } label: {
            VStack(spacing: 5) {
                Text(title).font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(active ? Theme.ink : Theme.faint)
                Capsule().fill(active ? Theme.recordRed : .clear).frame(height: 3)
                    .frame(maxWidth: active ? .infinity : 0)
            }
        }
        .buttonStyle(.plain)
        .id(t)
    }

    // MARK: List

    @ViewBuilder private var recordingsContent: some View {
        recordingsList(rows, emptyTitle: String(localized: "还没有录音"),
                       emptyHint: String(localized: "点下面的红键录一条，过会儿服务器会自动转写并挖成文章。"))
    }

    /// A tag tab's page: the same rows, filtered to articles carrying that tag.
    @ViewBuilder private func tagContent(_ t: String) -> some View {
        recordingsList(rows.filter { $0.tags?.contains(t) ?? false },
                       emptyTitle: String(localized: "还没有文章"), emptyHint: String(localized: "「\(t)」标签下还没有文章。"))
    }

    @ViewBuilder private func recordingsList(_ list: [Recording], emptyTitle: String, emptyHint: String) -> some View {
        if store.loading && list.isEmpty {
            Spacer(); ProgressView().tint(Theme.recordRed); Spacer()
        } else if let err = store.error, list.isEmpty {
            Spacer(); message(String(localized: "加载失败"), err); Spacer()
        } else if list.isEmpty {
            Spacer(); message(emptyTitle, emptyHint); Spacer()
        } else {
            List {
                ForEach(list) { rec in
                    Group {
                        if rec.uploading {
                            rowCard(rec)
                        } else {
                            // Button (not NavigationLink) so the List doesn't add its
                            // own trailing disclosure chevron — the card draws its own.
                            Button { selectedRec = rec } label: { rowCard(rec) }
                                .buttonStyle(.plain)
                        }
                    }
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 6, trailing: 16))
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if !rec.uploading {
                            Button(role: .destructive) { confirmDelete = rec } label: { Label("删除", systemImage: "trash") }
                                .tint(.red)
                            // 「重写」在删除左边：复用已有 ASR、按原逻辑重挖（仅对已成文的录音）
                            if rec.hasArticles {
                                Button { Task { await store.remine(rec) } } label: { Label("重写", systemImage: "arrow.clockwise") }
                                    .tint(Theme.accent)
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contentMargins(.bottom, 104, for: .scrollContent)   // clear the floating button
            .refreshable { await refresh() }
        }
    }

    // MARK: Community list

    @ViewBuilder private var communityContent: some View {
        if community.loading && community.posts.isEmpty {
            Spacer(); ProgressView().tint(Theme.accent); Spacer()
        } else if let err = community.error, community.posts.isEmpty {
            Spacer(); message(String(localized: "加载失败"), err); Spacer()
        } else if community.posts.isEmpty {
            Spacer(); message(String(localized: "VD社区还没有分享"), String(localized: "在文章右上角 ⋯ 里点「分享到 VD社区」，大家就能看到。")); Spacer()
        } else {
            // 双排瀑布流（CommunityFeedView，design handoff 方向 1a）。取消分享从
            // swipe 改长按 context menu——masonry 不在 List 里，没有 swipeActions。
            // 书卡（kind:"book"，服务端 reco feed 混入，shareId = "book-<slug>"）没有
            // 分享快照可开——由卡片字段拼一个 ShelfBook，推入书架同款 BookReaderView
            // （同一导航栈，back 回到社区原位置；c/c2 只有书架封面用，这里随便给）。
            CommunityFeedView(store: community,
                              onSelect: { post in
                                  if post.kind == "book", post.shareId.hasPrefix("book-") {
                                      // 书卡不走帖子详情页，view 埋点在这里补——书帖的
                                      // 互动记录与普通帖同权（喂推荐排序）。红心暂不做。
                                      Task { await community.engage(post.shareId, action: "view") }
                                      let slug = String(post.shareId.dropFirst(5))
                                      openFeedBook = ShelfBook(
                                          slug: slug,
                                          title: post.title ?? slug, main: post.title ?? slug,
                                          sub: post.preview ?? "", c: "#8A7A5A", c2: "#6E5F44",
                                          cover: post.coverPhotoKey != nil, coverAt: nil,
                                          chapters: post.count ?? 0, author: post.author, hidden: nil,
                                          mine: nil, category: nil)   // 社区来的书拿不到归属，宁可不显示主人菜单
                                  } else {
                                      selectedPost = post
                                  }
                              },
                              onUnshare: { confirmUnshare = $0 })
        }
    }

    private func rowCard(_ rec: Recording) -> some View {
        let empty = rec.isEmpty
        return HStack(spacing: 13) {
            // The dedicated cover.jpg (2:3 book ratio) when the article has one,
            // else the article's first photo as a square icon; otherwise the
            // waveform tile (also the fallback while images load / on fail).
            if rec.hasArticles || rec.coverPhotoKey != nil {
                RowCoverIcon(store: store,
                             coverKey: rec.hasArticles ? rec.coverJpgKey : nil,
                             relKey: rec.coverPhotoKey)
            } else {
                waveTile(empty: empty)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(rec.rowTitle).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink)
                    .lineLimit(1).truncationMode(.tail)
                HStack(spacing: 9) {
                    if let dt = rec.dateTimeLabel {
                        Text(dt).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.metaChrome)
                            .layoutPriority(1)
                    }
                    if let d = rec.durationLabel {
                        Text(d).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.metaChrome)
                            .layoutPriority(1)
                    }
                    // Tags share the meta line; they're the one flexible element,
                    // so when space runs out THEY truncate, not the date/duration/badge.
                    if let tags = rec.tags, !tags.isEmpty {
                        Text(tags.joined(separator: " · "))
                            .font(.system(size: 12)).foregroundStyle(Theme.metaChrome)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    statusBadge(rec).layoutPriority(1)
                }
            }
            Spacer(minLength: 6)
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.chevron)
        }
        .padding(.vertical, 14).padding(.horizontal, 15)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.R.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.R.card).stroke(Theme.borderChrome, lineWidth: 1))
        .cardChromeShadow()
        .opacity(empty ? 0.72 : 1)
    }

    /// The default row icon: a soft rounded tile with a 3-bar waveform. Unchanged
    /// visual — used for rows without a cover photo, and as `RowCoverIcon`'s fallback.
    private func waveTile(empty: Bool) -> some View {
        RoundedRectangle(cornerRadius: Theme.R.card)
            .fill(empty ? Color(hex: "F1ECE3") : Theme.recordRedSoft)
            .frame(width: 42, height: 42)
            .overlay(WaveformBars(color: empty ? Color(hex: "C3B9A8") : Theme.recordRed,
                                  heights: [11, 19, 14], barWidth: 3, spacing: 2.5))
    }

    @ViewBuilder private func statusBadge(_ rec: Recording) -> some View {
        if store.reminingStems.contains(rec.stem) {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini).tint(Theme.accent)
                Text("重写中").font(.system(size: 12.5)).foregroundStyle(Theme.accent)
            }
        } else if rec.uploading {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini).tint(Theme.recordRed)
                Text("正在上传").font(.system(size: 12.5)).foregroundStyle(Theme.recordRed)
            }
        } else if rec.hasArticles {
            badge(Theme.greenDone, String(localized: "已成文"))
                .contentShape(Rectangle())
                .onLongPressGesture { confirmReprocess = rec }
        } else if rec.isEmpty {
            badge(Theme.faint, String(localized: "无语音"))
        } else if let phase = rec.phase {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini).tint(Theme.accent)
                Text(phase.badge).font(.system(size: 12.5)).foregroundStyle(Theme.accent)
            }
        } else if let r = rec.blockReason {
            badge(Color(hex: "C0392B"), BlockReason(rawValue: r)?.label ?? BlockReason.noCredit.label)
        } else {
            badge(Theme.amberPending, String(localized: "待处理"))
        }
    }

    private func badge(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 12.5)).foregroundStyle(color)
        }
    }

    private func message(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 10) {
            Text(title).foregroundStyle(Theme.ink).font(.system(size: 17, weight: .semibold))
            Text(subtitle).foregroundStyle(Theme.secondary).font(.system(size: 15))
                .multilineTextAlignment(.center).padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Record button (floats over the list — no pane)

    /// The red key. Tap opens the recorder on touch-up; holding past
    /// `holdToRecordSeconds` opens it *while the finger is still down* (with a
    /// haptic), so the WeChat 「按住说话」 reflex lands in a live recording instead
    /// of waiting for a release the user may never think to do. It used to double
    /// as a press-and-hold 语音指令 mic (「长按说话」), but 31 days of server logs
    /// (2026-08-15 → 09-14) showed 26 of the 44 users who ever held it were
    /// dictating *content* and then hunting for a recording that never existed;
    /// only 12 issued a real command. The library-level command agent
    /// (/agent/command) is still live server-side; the client entry point is
    /// gone on purpose. Both paths funnel through `launchRecorder()`, which is
    /// re-entrancy guarded: after the hold fires, the eventual touch-up may still
    /// deliver the Button action, and it must not stack a second recorder.
    private var recordButton: some View {
        VStack(spacing: 7) {
            Button { launchRecorder() } label: { redCircle }
                .buttonStyle(RecordKeyStyle())
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: Self.holdToRecordSeconds, maximumDistance: 24)
                        .onEnded { _ in launchRecorder(haptic: true) }
                )
                .accessibilityLabel("录音")
            Text("轻点录音")
                .font(.system(size: 12)).tracking(1)
                .foregroundStyle(Theme.secondary)
        }
        .padding(.bottom, 8)
    }

    /// How long a hold on the red key waits before opening the recorder on its
    /// own. Long enough that a slow tap doesn't trip it, short enough that a
    /// WeChat-style hold starts recording before the user begins talking.
    private static let holdToRecordSeconds: Double = 0.4

    private func launchRecorder(haptic: Bool = false) {
        guard recordLaunch == nil else { return }
        if haptic { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
        recordLaunch = RecordLaunch(tag: nil)
    }

    /// The pure-red circle key, at rest. Pressed feedback lives in `RecordKeyStyle`.
    private var redCircle: some View {
        Circle().fill(Theme.card).frame(width: 66, height: 66)
            .overlay(Circle().stroke(Color(hex: "E8DECF"), lineWidth: 1))
            .overlay(
                Circle().fill(Theme.recordRed).frame(width: 54, height: 54)
                    .shadow(color: Color(.sRGB, red: 229/255, green: 57/255, blue: 46/255, opacity: 0.40), radius: 4, x: 0, y: 2)
            )
            .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 5)   // lift off the list
            .contentShape(Circle())
    }

    /// Press feedback for the red key: a slight shrink while the finger is down,
    /// so a held press visibly "arms" and the release that opens the recorder
    /// reads as the completion of one gesture.
    private struct RecordKeyStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.92 : 1)
                .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

/// The article's row icon. Prefers the dedicated cover (`photos/<ts>/cover.jpg`,
/// shown as a 2:3 book-shaped thumbnail — the standard book-cover ratio); falls
/// back to the first photo as a 42×42 square, then to the waveform tile — so a
/// row never looks broken. cover.jpg misses are remembered for the session so
/// scrolling doesn't re-probe a 404.
private struct RowCoverIcon: View {
    let store: LibraryStore
    let coverKey: String?       // photos/<ts>/cover.jpg candidate (nil = don't probe)
    let relKey: String?         // first-photo fallback (nil = waveform fallback)
    @State private var image: UIImage?
    @State private var isBookCover = false

    /// Process-wide decoded-image cache, shared across every row. Keyed by rel key
    /// (unique per photo). NSCache evicts under memory pressure on its own. This is
    /// what stops a re-download every time a row scrolls back into view.
    private static let cache = NSCache<NSString, UIImage>()
    /// Session-lifetime negative cache: cover.jpg keys that 404'd. In-memory only —
    /// a cover generated later shows up on next app launch (never pinned on disk,
    /// the lesson of the "正在制作中卡死" URL-level negative cache).
    @MainActor private static var coverMissing = Set<String>()

    var body: some View {
        Group {
            if let image, isBookCover {
                // Book cover: 2:3 portrait (the common trade-book jacket ratio).
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: 40, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.borderChrome, lineWidth: 1))
            } else {
                RoundedRectangle(cornerRadius: Theme.R.card)
                    .fill(Theme.recordRedSoft)
                    .frame(width: 42, height: 42)
                    .overlay {
                        if let image {
                            Image(uiImage: image).resizable().scaledToFill()
                        } else {
                            WaveformBars(color: Theme.recordRed, heights: [11, 19, 14], barWidth: 3, spacing: 2.5)
                        }
                    }
                    .frame(width: 42, height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.R.card))
            }
        }
        .task(id: "\(coverKey ?? "")|\(relKey ?? "")") { await load() }
    }

    private func load() async {
        // Cache hits → show instantly, no network, no waveform flash. (Set for THIS
        // row's keys — or nil if absent — so a recycled row never shows the previous
        // photo.) The dedicated cover always wins over the first photo.
        if let coverKey, let cached = Self.cache.object(forKey: coverKey as NSString) {
            image = cached; isBookCover = true; return
        }
        isBookCover = false
        image = relKey.flatMap { Self.cache.object(forKey: $0 as NSString) }
        if let coverKey, !Self.coverMissing.contains(coverKey) {
            guard let scope = await store.ownerScope() else { return }
            if let ui = await store.photoImage(fullKey: scope + coverKey, preferThumb: true) {
                Self.cache.setObject(ui, forKey: coverKey as NSString)
                if !Task.isCancelled { image = ui; isBookCover = true }
                return
            }
            Self.coverMissing.insert(coverKey)
        }
        guard image == nil, let relKey else { return }
        guard let scope = await store.ownerScope() else { return }
        if let ui = await store.photoImage(fullKey: scope + relKey, preferThumb: true) {
            Self.cache.setObject(ui, forKey: relKey as NSString)
            // Guard against a stale set if the row got recycled to a new key mid-fetch
            // (.task(id:) cancels the old task on key change).
            if !Task.isCancelled { image = ui }
        }
    }
}
