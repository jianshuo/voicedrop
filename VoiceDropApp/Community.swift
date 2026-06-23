import SwiftUI
import Observation

/// One community post as listed (metadata only).
struct CommunityPost: Decodable, Identifiable, Hashable {
    let shareId: String
    let author: String?
    let title: String?
    let firstSharedAt: Double?      // ms epoch
    let updatedAt: Double?
    let count: Int?
    let mine: Bool?                 // owned by the current user (can un-share)
    var id: String { shareId }
}

/// The full shared snapshot (title + articles), read-only.
struct CommunityFullPost: Decodable {
    let shareId: String
    let author: String?
    let title: String?
    let articles: [MinedArticle]?
    let firstSharedAt: Double?
}

/// One voice comment on a community post.
struct CommunityComment: Decodable, Identifiable {
    let commentId: String
    let author: String?
    let text: String
    let createdAt: Double?
    var id: String { commentId }
}

@MainActor
@Observable
final class CommunityStore {
    var posts: [CommunityPost] = []
    var loading = false
    var error: String?

    private let base = URL(string: "https://jianshuo.dev/files/api")!
    private var token: String { AuthStore.shared.bearer }

    /// All shared posts, newest-first by first-share time (server-sorted).
    func load() async {
        guard !token.isEmpty else { return }
        loading = true; error = nil
        defer { loading = false }
        var req = URLRequest(url: base.appending(path: "community").appending(path: "list"))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else { error = "加载失败"; return }
            struct R: Decodable { let posts: [CommunityPost] }
            posts = try JSONDecoder().decode(R.self, from: data).posts
        } catch { self.error = error.localizedDescription }
    }

    /// Share (or re-share) one of the user's articles to the community. Re-sharing
    /// updates the snapshot in place; the first-share time is preserved server-side.
    /// If the server returns 403 needs_apple_signin, triggers Apple sign-in and retries once.
    func share(_ rec: Recording) async -> Bool {
        needsAppleSignIn = false
        guard !token.isEmpty, rec.hasArticles else { return false }
        if await postShare(rec) { return true }
        // Not Apple-verified yet → sign in once and retry.
        if needsAppleSignIn {
            await AuthStore.shared.signInWithApple()
            guard AuthStore.shared.isAuthenticated else { return false }
            return await postShare(rec)
        }
        return false
    }

    private var needsAppleSignIn = false

    private func postShare(_ rec: Recording) async -> Bool {
        var req = URLRequest(url: base.appending(path: "community").appending(path: "share").appending(path: rec.articleKey))
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(code) { needsAppleSignIn = false; return true }
            needsAppleSignIn = (code == 403) &&
                ((try? JSONDecoder().decode([String:String].self, from: data))?["error"] == "needs_apple_signin")
            return false
        } catch { return false }
    }

    /// Un-share (delete) one of the user's own community posts. Removed from the
    /// list immediately (optimistic); reloads if the server rejects it.
    /// If the server returns 403 needs_apple_signin, triggers Apple sign-in and retries once.
    @discardableResult
    func unshare(_ shareId: String) async -> Bool {
        needsAppleSignIn = false
        guard !token.isEmpty else { return false }
        posts.removeAll { $0.shareId == shareId }
        if await postUnshare(shareId) { return true }
        // 403 needs sign-in → sign in once and retry
        if needsAppleSignIn {
            await AuthStore.shared.signInWithApple()
            if AuthStore.shared.isAuthenticated {
                if await postUnshare(shareId) { return true }
            }
            // Sign-in was dismissed or retry failed — restore the optimistically-removed post
            await load()
            return false
        }
        // Hard failure (non-403 or network error) — restore
        await load()
        return false
    }

    private func postUnshare(_ shareId: String) async -> Bool {
        var req = URLRequest(url: base.appending(path: "community").appending(path: "unshare").appending(path: shareId))
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(code) { needsAppleSignIn = false; return true }
            needsAppleSignIn = (code == 403) &&
                ((try? JSONDecoder().decode([String:String].self, from: data))?["error"] == "needs_apple_signin")
            return false
        } catch { return false }
    }

    /// Whether this article is currently shared to the community (drives the
    /// 分享 / 更新 menu label).
    func isShared(_ rec: Recording) async -> Bool {
        guard !token.isEmpty, rec.hasArticles else { return false }
        var req = URLRequest(url: base.appending(path: "community").appending(path: "shared").appending(path: rec.articleKey))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else { return false }
            struct R: Decodable { let shared: Bool }
            return (try? JSONDecoder().decode(R.self, from: data))?.shared ?? false
        } catch { return false }
    }

    func fetchPost(_ shareId: String) async -> CommunityFullPost? {
        guard !token.isEmpty else { return nil }
        var req = URLRequest(url: base.appending(path: "community").appending(path: "get").appending(path: shareId))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else { return nil }
            return try JSONDecoder().decode(CommunityFullPost.self, from: data)
        } catch { return nil }
    }

    func loadComments(_ shareId: String) async -> [CommunityComment] {
        guard !token.isEmpty else { return [] }
        var req = URLRequest(url: base.appending(path: "community").appending(path: "comments").appending(path: shareId))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else { return [] }
            struct R: Decodable { let comments: [CommunityComment] }
            return (try? JSONDecoder().decode(R.self, from: data))?.comments ?? []
        } catch { return [] }
    }

    func postComment(_ text: String, to shareId: String) async -> CommunityComment? {
        guard !token.isEmpty else { return nil }
        var req = URLRequest(url: base.appending(path: "community").appending(path: "comment").appending(path: shareId))
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(["text": text])
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else { return nil }
            struct R: Decodable { let comment: CommunityComment }
            return (try? JSONDecoder().decode(R.self, from: data))?.comment
        } catch { return nil }
    }
}

/// Format a ms-epoch share time as "6月22日" (or a year if not this year).
func communityDate(_ ms: Double?) -> String {
    guard let ms else { return "" }
    let date = Date(timeIntervalSince1970: ms / 1000)
    let f = DateFormatter()
    f.locale = Locale(identifier: "zh_CN")
    f.dateFormat = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year) ? "M月d日" : "yyyy年M月d日"
    return f.string(from: date)
}

// MARK: - Community read view (read-only article + voice comments)

struct CommunityPostView: View {
    let store: CommunityStore
    let post: CommunityPost

    @Environment(\.dismiss) private var dismiss
    @State private var full: CommunityFullPost?
    @State private var loading = true
    @State private var articleIndex = 0

    @State private var comments: [CommunityComment] = []
    @State private var dictation = SpeechDictation()
    @State private var willCancel = false
    @State private var posting = false
    @State private var toast: String?

    private var articles: [MinedArticle] { full?.articles ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                NavSquare(systemName: "chevron.left", stroke: Theme.inkRead, border: Theme.borderRead) { dismiss() }
                    .accessibilityLabel("返回")
                Spacer()
            }
            .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 8)

            if loading {
                Spacer(); ProgressView().tint(Theme.accent); Spacer()
            } else if articles.isEmpty {
                Spacer()
                Text("这篇分享已不可用").foregroundStyle(Theme.secondary).font(.system(size: 15))
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if let a = articles[safe: articleIndex] {
                            Text(a.title)
                                .font(.system(size: 23, weight: .semibold)).foregroundStyle(Theme.inkRead)
                                .lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 18)
                            HStack(spacing: 8) {
                                Text(full?.author ?? "匿名").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.accent)
                                Text(communityDate(full?.firstSharedAt)).font(.system(size: 13)).foregroundStyle(Theme.metaRead)
                            }
                            .padding(.top, 8)

                            if articles.count > 1 { chipRow.padding(.top, 16) }

                            Text((try? AttributedString(markdown: a.body, options: .init(
                                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                failurePolicy: .returnPartiallyParsedIfPossible))) ?? AttributedString(a.body))
                                .font(.system(size: 16)).foregroundStyle(Theme.bodyRead)
                                .lineSpacing(9).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, articles.count > 1 ? 16 : 20)
                        }
                        commentsSection
                    }
                    .padding(.horizontal, 20)
                }
                .contentMargins(.bottom, 80, for: .scrollContent)
            }
        }
        .background(Theme.readBG.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .bottom) { voiceCommentBar }
        .overlay(alignment: .bottom) { toastView }
        .task {
            full = await store.fetchPost(post.shareId)
            loading = false
            comments = await store.loadComments(post.shareId)
            await dictation.requestAuth()
        }
    }

    // MARK: Article chips

    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(articles.enumerated()), id: \.offset) { i, a in
                    Button { articleIndex = i } label: {
                        Text(a.title).lineLimit(1)
                            .font(.system(size: 13, weight: i == articleIndex ? .semibold : .regular))
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .background(i == articleIndex ? Theme.accentSoft : Theme.card,
                                        in: RoundedRectangle(cornerRadius: Theme.R.chip))
                            .overlay(RoundedRectangle(cornerRadius: Theme.R.chip)
                                .stroke(i == articleIndex ? .clear : Theme.borderRead, lineWidth: 1))
                            .foregroundStyle(i == articleIndex ? Theme.accent : Theme.metaRead)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Comments section (inline, after article body)

    private var commentsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Theme.borderRead).frame(height: 1).padding(.top, 32)
            Text("评论").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.secondary)
                .padding(.top, 16).padding(.bottom, 12)
            if comments.isEmpty {
                Text("还没有评论，按住下方麦克风说第一条").font(.system(size: 14))
                    .foregroundStyle(Theme.faint).padding(.bottom, 8)
            } else {
                ForEach(comments) { c in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text(c.author ?? "匿名").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.accent)
                            Text(communityDate(c.createdAt)).font(.system(size: 12)).foregroundStyle(Theme.metaRead)
                        }
                        Text(c.text).font(.system(size: 15)).foregroundStyle(Theme.bodyRead)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 10)
                    .overlay(Rectangle().fill(Theme.borderRead).frame(height: 0.5), alignment: .bottom)
                }
            }
        }
    }

    // MARK: Floating voice comment bar

    private var voiceCommentBar: some View {
        VStack(spacing: 8) {
            if dictation.isRecording { transcriptBubble(dictation.transcript) }
            micPill
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .animation(.easeInOut(duration: 0.18), value: dictation.isRecording)
    }

    private var micPill: some View {
        HStack(spacing: 7) {
            if dictation.isRecording {
                Image(systemName: "waveform").font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, options: .repeating)
                Text(willCancel ? "上滑取消 · 松开放弃" : "松开 发送 · 上滑取消")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            } else if posting {
                ProgressView().tint(Theme.accent).scaleEffect(0.8)
                Text("发送中…").font(.system(size: 15)).foregroundStyle(Theme.secondary)
            } else {
                Image(systemName: "mic.fill").font(.system(size: 14)).foregroundStyle(Theme.ink)
                Text("按住说评论").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.ink)
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 24)
            .fill(dictation.isRecording ? Theme.accent : Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 24)
            .stroke(dictation.isRecording ? Color(hex: "C94A2E") : Theme.borderRead, lineWidth: 1))
        .shadow(color: dictation.isRecording
            ? Color(.sRGB, red: 216/255, green: 89/255, blue: 59/255, opacity: 0.30) : .black.opacity(0.08),
                radius: 8, x: 0, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: 24))
        .gesture(holdGesture())
        .disabled(posting)
        .animation(.easeInOut(duration: 0.15), value: dictation.isRecording)
    }

    private func transcriptBubble(_ text: String) -> some View {
        VStack(spacing: 0) {
            Text(text.isEmpty ? "在听…" : text)
                .font(.system(size: 15))
                .foregroundStyle(text.isEmpty ? Color(hex: "B6AD9E") : Color(hex: "FBF6EE"))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color(hex: "2E2823"), in: RoundedRectangle(cornerRadius: 14))
            DownTriangle().fill(Color(hex: "2E2823")).frame(width: 16, height: 8)
                .padding(.leading, 30).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func holdGesture() -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if dictation.authorized == nil { Task { await dictation.requestAuth() }; return }
                guard dictation.authorized == true else { return }
                if !dictation.isRecording { dictation.start() }
                willCancel = v.translation.height < -60
            }
            .onEnded { v in
                guard dictation.isRecording else { willCancel = false; return }
                let cancel = v.translation.height < -60
                willCancel = false
                if cancel { dictation.stop(); return }
                Task {
                    let text = (await dictation.stopAndGetFinal()).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { await submitComment(text) }
                }
            }
    }

    private func submitComment(_ text: String) async {
        posting = true
        if let c = await store.postComment(text, to: post.shareId) {
            comments.append(c)
            showToast("评论已发送")
        } else {
            showToast("发送失败，请稍后再试")
        }
        posting = false
    }

    // MARK: Toast

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
                .padding(.bottom, 96)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
