import SwiftUI
import UIKit

/// One recording: an audio player on top, then a segmented switch between the
/// subtitle (SRT) and the mined article(s).
struct RecordingDetailView: View {
    let store: LibraryStore
    let recording: Recording

    @State private var player = AudioPlayer()
    @State private var doc: ArticleDoc?
    @State private var emptyReason: String?
    @State private var loadingDoc = true
    @State private var loadingAudio = false
    @State private var articleIndex = 0
    @State private var sharing = false
    @State private var sharePayload: SharePayload?

    private var articles: [MinedArticle] { doc?.resolvedArticles ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            playerBar
            Divider().overlay(Color.white.opacity(0.1))
            if loadingDoc {
                Spacer(); ProgressView().tint(.white); Spacer()
            } else if recording.isEmpty {
                Spacer(); emptyState; Spacer()
            } else if articles.isEmpty {
                Spacer(); pending; Spacer()
            } else {
                // No 文章/字幕 tabs — show the article directly. The only switcher
                // is the per-article chip row inside articlePane, shown only when
                // there's more than one article.
                articlePane
            }
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(recording.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.black, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            if !articles.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            sharing = true
                            if let u = await store.shareURL(recording) {
                                let text = Self.composeShareText(articles[safe: articleIndex], url: u)
                                sharePayload = SharePayload(text: text)
                            }
                            sharing = false
                        }
                    } label: {
                        if sharing { ProgressView().tint(.white) }
                        else { Image(systemName: "square.and.arrow.up") }
                    }
                    .disabled(sharing)
                    .accessibilityLabel("分享文章")
                }
            }
        }
        .task {
            if recording.isEmpty {
                emptyReason = await store.fetchEmptyReason(recording)
            } else {
                doc = await store.fetchDoc(recording)
            }
            loadingDoc = false
        }
        .onDisappear { player.stop() }
        .sheet(item: $sharePayload) { ShareSheet(items: [$0.text]) }
    }

    // MARK: Article rendering

    /// Title + body as one styled, selectable AttributedString. Body markdown is
    /// parsed inline while preserving paragraph breaks.
    private func articleAttributed(_ a: MinedArticle) -> AttributedString {
        var title = AttributedString(a.title)
        title.font = .title3.bold()
        title.foregroundColor = .white
        var body = (try? AttributedString(markdown: a.body, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible))) ?? AttributedString(a.body)
        body.font = .body
        body.foregroundColor = .white.opacity(0.82)
        return title + AttributedString("\n\n") + body
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
                    // One selectable block (title + body) so a long-press → Select
                    // All → Copy grabs the whole article, not a single paragraph.
                    // Sharing lives in the top-right toolbar; its sheet has Copy.
                    Text(articleAttributed(a))
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                }
            }
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

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "speaker.slash")
                .font(.system(size: 36)).foregroundStyle(.white.opacity(0.35))
            Text("没检测到语音").foregroundStyle(.white.opacity(0.7)).font(.headline)
            Text(emptyReasonText)
                .foregroundStyle(.white.opacity(0.45)).font(.callout)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
        }
    }

    private var emptyReasonText: String {
        switch emptyReason {
        case "corrupt": return "这条录音的文件损坏了，没法转写。"
        case "silent":  return "这条录音太短或几乎是静音，没有可转写的内容。"
        default:        return "这条录音里没有识别到说话声，已标记为无语音。"
        }
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// A ready-to-share payload: ONE combined string (article excerpt + short link),
/// sized to fit X's 280 weighted-char cap. We hand the share sheet a single
/// String rather than String+URL because X's extension is unreliable when given
/// both (it may drop one); inside one string the link is still tappable elsewhere.
struct SharePayload: Identifiable { let text: String; var id: String { text } }

extension RecordingDetailView {
    /// X counts "weighted" characters: ASCII = 1, everything else (CJK) = 2.
    private static func xWeight(_ s: String) -> Int {
        s.reduce(0) { $0 + ($1.isASCII ? 1 : 2) }
    }

    /// Build the share string: title, a blank line, then as much of the body's
    /// opening as fits — cut at a sentence boundary — then a blank line and the
    /// short link. Budget = 280 − 23 (any URL is t.co-shortened to 23) − 4 (two
    /// "\n\n" separators) for the title+excerpt text.
    static func composeShareText(_ article: MinedArticle?, url: URL) -> String {
        let link = url.absoluteString
        guard let a = article else { return link }
        let title = a.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let textBudget = 280 - 23 - 4
        let excerpt = sentenceTruncated(
            a.body.trimmingCharacters(in: .whitespacesAndNewlines),
            toWeight: max(0, textBudget - xWeight(title))
        )
        var out = title
        if !excerpt.isEmpty { out += "\n\n" + excerpt }
        out += "\n\n" + link
        return out
    }

    /// Longest prefix of `s` within `budget` weighted chars, ending at the last
    /// sentence boundary (。！？!?.\n) seen. Appends "…" only on a mid-sentence cut.
    private static func sentenceTruncated(_ s: String, toWeight budget: Int) -> String {
        if budget <= 2 { return "" }
        let boundaries: Set<Character> = ["。", "！", "？", "!", "?", ".", "\n"]
        var weight = 0
        var cut = s.startIndex            // hard-cut end (exclusive)
        var lastBoundary = s.startIndex   // end after the most recent boundary char
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            let w = c.isASCII ? 1 : 2
            if weight + w > budget - 2 { break }   // reserve 2 for a possible "…"
            weight += w
            let next = s.index(after: i)
            cut = next
            if boundaries.contains(c) { lastBoundary = next }
            i = next
        }
        let usedBoundary = lastBoundary > s.startIndex
        let end = usedBoundary ? lastBoundary : cut
        var out = String(s[s.startIndex..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        if end < s.endIndex && !usedBoundary && !out.isEmpty { out += "…" }
        return out
    }
}

/// The system share sheet (UIActivityViewController) for SwiftUI.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
