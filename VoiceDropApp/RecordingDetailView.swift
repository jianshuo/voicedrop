import SwiftUI

/// One recording: an audio player on top, then a segmented switch between the
/// subtitle (SRT) and the mined article(s).
struct RecordingDetailView: View {
    let store: LibraryStore
    let recording: Recording

    @State private var player = AudioPlayer()
    @State private var doc: ArticleDoc?
    @State private var loadingDoc = true
    @State private var loadingAudio = false
    @State private var tab = 0                 // 0 = 文章, 1 = 字幕
    @State private var articleIndex = 0

    private var articles: [MinedArticle] { doc?.resolvedArticles ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            playerBar
            Divider().overlay(Color.white.opacity(0.1))
            if loadingDoc {
                Spacer(); ProgressView().tint(.white); Spacer()
            } else if articles.isEmpty && (doc?.srt ?? "").isEmpty {
                Spacer(); pending; Spacer()
            } else {
                Picker("", selection: $tab) {
                    Text("文章\(articles.count > 1 ? " (\(articles.count))" : "")").tag(0)
                    Text("字幕").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16).padding(.vertical, 10)

                if tab == 0 { articlePane } else { srtPane }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(recording.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.black, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task {
            doc = await store.fetchDoc(recording); loadingDoc = false
        }
        .onDisappear { player.stop() }
    }

    // MARK: Player

    private var playerBar: some View {
        HStack(spacing: 14) {
            Button {
                if player.duration == 0 { Task { await loadAndPlay() } } else { player.toggle() }
            } label: {
                Image(systemName: loadingAudio ? "arrow.down.circle" : (player.isPlaying ? "pause.circle.fill" : "play.circle.fill"))
                    .font(.system(size: 40)).foregroundStyle(.white)
                    .symbolEffect(.pulse, isActive: loadingAudio)
            }
            .disabled(loadingAudio)

            ProgressView(value: player.progress)
                .tint(.white).scaleEffect(y: 1.2)

            if let d = recording.durationLabel {
                Text(d).foregroundStyle(.white.opacity(0.5)).font(.caption.monospaced())
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    private func loadAndPlay() async {
        loadingAudio = true; defer { loadingAudio = false }
        if let url = await store.downloadAudio(recording) {
            player.load(url); player.toggle()
        }
    }

    // MARK: Articles

    private var articlePane: some View {
        VStack(spacing: 0) {
            if articles.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(articles.enumerated()), id: \.offset) { i, a in
                            Button {
                                articleIndex = i
                            } label: {
                                Text(a.title).lineLimit(1)
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                                    .background(i == articleIndex ? Color.white.opacity(0.18) : Color.white.opacity(0.06),
                                                in: Capsule())
                                    .foregroundStyle(i == articleIndex ? .white : .white.opacity(0.55))
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 6)
            }
            if let a = articles[safe: articleIndex] {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(a.title).font(.title3.bold()).foregroundStyle(.white)
                        ForEach(Array(a.body.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, para in
                            Text(.init(para))           // inline markdown
                                .foregroundStyle(.white.opacity(0.82))
                                .font(.body).lineSpacing(5)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                }
                .overlay(alignment: .bottomTrailing) {
                    Button {
                        UIPasteboard.general.string = a.title + "\n\n" + a.body
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.callout).foregroundStyle(.white)
                            .padding(12).background(.white.opacity(0.14), in: Circle())
                    }
                    .padding(18)
                }
            }
        }
    }

    // MARK: SRT

    private var srtPane: some View {
        ScrollView {
            Text((doc?.srt?.isEmpty == false ? doc!.srt! : (doc?.transcript ?? "")))
                .font(.callout.monospaced())
                .foregroundStyle(.white.opacity(0.75))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(20)
        }
    }

    private var pending: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 36)).foregroundStyle(.white.opacity(0.4))
            Text("还没成文").foregroundStyle(.white.opacity(0.7)).font(.headline)
            Text("服务器每 2 小时自动处理一次，过会儿再来看。")
                .foregroundStyle(.white.opacity(0.45)).font(.callout)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
        }
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
