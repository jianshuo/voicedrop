import SwiftUI
import UIKit

/// 「我的录音」— the app's home (方案二). White-card list of recordings; a docked
/// pure-red record key at the bottom opens the full-screen recording takeover;
/// the gear pushes Settings. Pulls fresh data on appear and drains any pending
/// local uploads.
enum HomeTab { case recordings, community }

struct LibraryView: View {
    @State private var store = LibraryStore()
    @State private var uploader = Uploader()
    @State private var community = CommunityStore()
    @State private var statusSession = StatusSession()
    @State private var linkResponder = DeviceLinkResponder()
    @State private var tab: HomeTab = .recordings
    @State private var confirmDelete: Recording?
    @State private var confirmReprocess: Recording?
    @State private var showRecord = false
    @State private var showSettings = false
    @State private var selectedRec: Recording?
    @State private var selectedPost: CommunityPost?
    @State private var confirmUnshare: CommunityPost?

    // 语音指令 walkie-talkie: the red record button itself doubles as a
    // library-wide press-and-hold mic that can act on any recording by its
    // on-screen number ("删掉第二条"). Separate dictation + session instances
    // from RecordingDetailView's article-level editing.
    @State private var talking = false
    @State private var willCancel = false
    @State private var dictation = SpeechDictation()
    @State private var command = LibraryCommandSession()
    @State private var commandReply: AgentReply?
    @State private var confirmPrompt: (id: String, summary: String)?
    @State private var pageStore = PageStore()   // 自定义首页 page.json；tree==nil → 原生首页
    @EnvironmentObject private var router: AppRouter
    @Environment(\.scenePhase) private var scenePhase

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
            .alert(confirmPrompt?.summary ?? "确认操作",
                   isPresented: clearBinding({ confirmPrompt != nil }, { confirmPrompt = nil }),
                   presenting: confirmPrompt) { p in
                // 语音指令 destructive confirm (e.g. "删掉第二条") — the server asks
                // before acting; summary is its plain-language description of the action.
                Button("删除", role: .destructive) { command.confirm(p.id); confirmPrompt = nil }
                Button("取消", role: .cancel) { command.cancel(p.id); confirmPrompt = nil }
            }
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
            if let tree = pageStore.tree {
                // 有自滚动的列表 embed 时不能再套 ScrollView（List 在 ScrollView 里塌成零高）；
                // 纯静态页则套上，超屏可滚。
                if tree.containsListEmbed {
                    PageRenderer(node: tree, ctx: pageContext)
                } else {
                    ScrollView { PageRenderer(node: tree, ctx: pageContext) }
                }
            } else {
                tabHeader
                if tab == .recordings { recordingsContent } else { communityContent }
            }
        }
        .background(Theme.appBG.ignoresSafeArea())
        .overlay(alignment: .bottom) {
            if pageStore.tree == nil && tab == .recordings {
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
        .navigationDestination(isPresented: $showSettings) { SettingsView(libraryStore: store) }
        .fullScreenCover(isPresented: $showRecord) {
            RecordSession { showRecord = false; Task { await refresh() } }
        }
        .task {
            statusSession.onPhase = { stem, phase in store.markPhase(stem: stem, phase: phase) }
            statusSession.onDone = { stem in store.markDone(stem: stem) }
            statusSession.onLinkRequest = { pid, code, pubkey in linkResponder.present(pairingId: pid, code: code, pubkey: pubkey) }
            statusSession.onLinkRelease = { pid in linkResponder.release(pairingId: pid) }
            statusSession.connect()
            await pageStore.load()
            await refresh()
        }
        .task {
            // Library-wide voice-command session: reply bubble + list refresh after
            // an edit lands + a destructive-action confirm prompt.
            command.onReply = { text, ok in commandReply = AgentReply(text: text, ok: ok) }
            command.onUpdate = { _ in Task { await refresh() } }
            command.onConfirm = { id, summary in
                confirmPrompt = (id: id, summary: summary)
                // A destructive result can land while a hold is still active (the
                // confirm round-trip is usually faster than a press, but not always)
                // — drop out of "talking" so the alert isn't fighting the mic UI.
                if talking { talking = false }
            }
            command.connect()
            await dictation.requestAuth()
        }
        .sheet(item: $linkResponder.pending) { p in
            DeviceLinkApprovalSheet(responder: linkResponder, pending: p)
        }
        .onChange(of: scenePhase) { _, p in
            if p == .active { statusSession.connect(); Task { await pageStore.load(); await refresh() } }
            else if p == .background { statusSession.disconnect() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .vdDidAdoptAccount)) { _ in
            statusSession.disconnect()
            statusSession.connect()
            Task { await refresh() }
        }
        .onReceive(router.$pending.compactMap { $0 }) { link in
            // A deep link (voicedrop://<page>) arrived — apply it, clearing any
            // pushed detail/settings/record so it lands cleanly, then reset.
            showRecord = false
            switch link {
            case .recordings:
                tab = .recordings; selectedRec = nil; selectedPost = nil; showSettings = false
                Task { await refresh() }
            case .community:
                tab = .community; selectedRec = nil; selectedPost = nil; showSettings = false
            case .settings:
                selectedRec = nil; selectedPost = nil; showSettings = true
            case .record:
                selectedRec = nil; selectedPost = nil; showSettings = false; showRecord = true
            case .article(let stem):
                tab = .recordings; selectedPost = nil; showSettings = false
                if let rec = store.recordings.first(where: { $0.stem == stem }) {
                    selectedRec = rec
                } else {
                    Task { await refresh(); selectedRec = store.recordings.first { $0.stem == stem } }
                }
            }
            Task { @MainActor in router.pending = nil }
        }
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
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            tabLabel("我的录音", .recordings)
            tabLabel("VD社区", .community)
            Spacer()
        }
        .padding(.horizontal, 22).padding(.bottom, 10)
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
    }

    // MARK: SDUI 自定义首页（page.json）

    /// embed 桥 + 动作回调：自定义页里的列表/录音键与原生首页共享同一批状态与导航。
    private var pageContext: PageContext {
        PageContext(
            articleList: AnyView(recordingsContent),
            communityFeed: AnyView(communityContent),
            recordButton: AnyView(recordButton),
            notePlaceholder: AnyView(NotePlaceholder()),
            loadPhoto: { [store] key in
                guard let scope = await store.ownerScope() else { return nil }
                return await store.photoData(fullKey: scope + key)
            },
            onTap: { handlePageAction($0) }
        )
    }

    private func handlePageAction(_ action: PageAction) {
        switch action {
        case .record: showRecord = true
        case .openArticles: tab = .recordings
        case .openCommunity: tab = .community; Task { await community.load() }
        case .openSettings: showSettings = true
        case .openNote: break   // 占位：Phase 1 无动作
        }
    }

    // MARK: List (bodies live in HomeLists.swift — reused by the SDUI embed bridge)

    @ViewBuilder private var recordingsContent: some View {
        RecordingsList(store: store, uploader: uploader, numbered: talking,
                       onSelect: { selectedRec = $0 },
                       onDelete: { confirmDelete = $0 },
                       onReprocess: { confirmReprocess = $0 },
                       onRefresh: { await refresh() })
    }

    @ViewBuilder private var communityContent: some View {
        CommunityFeedList(store: community,
                          onSelect: { selectedPost = $0 },
                          onUnshare: { confirmUnshare = $0 })
    }

    // MARK: Record button (floats over the list — no pane; IS the walkie-talkie)

    /// The red key itself: tap records a take (unchanged); press-and-hold turns
    /// it into a 微信式「按住说话」 mic for library-wide 语音指令 ("删掉第二条"),
    /// reusing the same feedback bubbles as article-level voice editing.
    private var recordButton: some View {
        VStack(spacing: 7) {
            if talking || commandReply != nil || !command.queue.isEmpty {
                VoiceFeedbackStack(transcript: talking ? dictation.transcript : nil,
                                   reply: commandReply, queue: command.queue)
                    .padding(.horizontal, 16)
            }
            redCircle
                .scaleEffect(talking ? 1.08 : 1)
                .gesture(talkGesture)
                .simultaneousGesture(TapGesture().onEnded { if !talking { showRecord = true } })
            Text(talking ? (willCancel ? "上滑取消 · 松开放弃" : "松开发送 · 上滑取消") : "轻点录音 · 长按说话")
                .font(.system(size: 12)).tracking(1)
                .foregroundStyle(talking ? Theme.accent : Theme.secondary)
        }
        .padding(.bottom, 8)
        .animation(.easeInOut(duration: 0.18), value: talking)
    }

    /// The pure-red circle key. Same visuals as before at rest; while `talking`
    /// a thin accent ring adds emphasis (the `scaleEffect` bump lives in
    /// `recordButton`, applied on top of this).
    private var redCircle: some View {
        Circle().fill(Theme.card).frame(width: 66, height: 66)
            .overlay(Circle().stroke(talking ? Theme.recordRed.opacity(0.55) : Color(hex: "E8DECF"),
                                      lineWidth: talking ? 2 : 1))
            .overlay(
                Circle().fill(Theme.recordRed).frame(width: 54, height: 54)
                    .shadow(color: Color(.sRGB, red: 229/255, green: 57/255, blue: 46/255, opacity: 0.40), radius: 4, x: 0, y: 2)
            )
            .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 5)   // lift off the list
            .contentShape(Circle())
            .accessibilityLabel("录音")
    }

    /// Sequenced long-press → drag so the whole hold is ONE continuous touch:
    /// a quick tap never engages this gesture (falls through to the sibling
    /// `TapGesture` and records normally); holding past 0.3s starts dictation,
    /// and sliding up cancels — mirroring `PushToTalkBar.holdGesture()`.
    private var talkGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                if case .second(true, let drag) = value {
                    if !talking {
                        talking = true
                        commandReply = nil
                        if dictation.authorized == true { dictation.start() }
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }
                    willCancel = (drag?.translation.height ?? 0) < -60
                }
            }
            .onEnded { value in
                guard case .second(true, _) = value else { return }
                let cancel = willCancel
                talking = false; willCancel = false
                if cancel { dictation.stop(); return }
                Task {
                    let text = (await dictation.stopAndGetFinal()).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    command.setRefs(currentRefs())
                    command.enqueue(text, images: [], articleIndex: 0)
                }
            }
    }

    // MARK: 语音指令 refs (长按红键说话)

    /// Numbered refs for the command agent, matching the on-screen circled numbers
    /// in `rowCard` 1:1 — both are absolute positions in `store.recordings`
    /// (newest-first). In-flight uploads/optimistic rows aren't real articles yet,
    /// so they're not numbered and can't be targeted by a spoken command.
    private func currentRefs() -> [LibraryCommandSession.CommandRef] {
        store.recordings.enumerated().map { i, rec in
            .init(n: i + 1, stem: rec.stem, title: rec.rowTitle)
        }
    }

}
