import SwiftUI
import UIKit

/// 「我的录音」列表主体——从 LibraryView 抽出，供原生首页与 page.json 的
/// `embed: articleList` 复用。选中/删除/重生成通过闭包上交给外壳处理
/// （它们驱动外壳的导航与 alert 状态）；重写/刷新只碰 store，留在列表内部。
struct RecordingsList: View {
    let store: LibraryStore
    let uploader: Uploader
    /// 红键按住说话时为 true——每行左上角浮出语音指令的序号（"删掉第二条"）。
    var numbered = false
    let onSelect: (Recording) -> Void
    let onDelete: (Recording) -> Void
    let onReprocess: (Recording) -> Void
    let onRefresh: () async -> Void

    /// Local takes still uploading (top) + just-uploaded optimistic 待处理 +
    /// server recordings. Same audioName = same row id, so badges change in place.
    private var rows: [Recording] {
        let serverNames = Set(store.recordings.map(\.audioName))
        let uploading = uploader.pending
            .map { Recording(audioName: $0.lastPathComponent, uploaded: "", hasArticles: false, isEmpty: false, uploading: true) }
            .filter { !serverNames.contains($0.audioName) }
        let busy = serverNames.union(uploading.map(\.audioName))
        // Optimistic: an uploaded take shows as 待处理 immediately, before the
        // server list catches up — so the row never disappears between states.
        let optimistic = uploader.justUploaded
            .filter { !busy.contains($0) }
            .map { Recording(audioName: $0, uploaded: "", hasArticles: false, isEmpty: false, uploading: false) }
        // store.recordings is ALREADY ordered newest-first (LibraryStore.load → Recording.newestFirst);
        // do NOT re-sort here. Just prepend the in-flight rows (uploading / just-uploaded), which are
        // the newest by definition, so they sit on top.
        return uploading + optimistic + store.recordings
    }

    var body: some View {
        if store.loading && rows.isEmpty {
            Spacer(); ProgressView().tint(Theme.recordRed); Spacer()
        } else if let err = store.error, rows.isEmpty {
            Spacer(); homeMessage("加载失败", err); Spacer()
        } else if rows.isEmpty {
            Spacer(); homeMessage("还没有录音", "点下面的红键录一条，过会儿服务器会自动转写并挖成文章。"); Spacer()
        } else {
            List {
                ForEach(rows) { rec in
                    Group {
                        if rec.uploading {
                            rowCard(rec)
                        } else {
                            // Button (not NavigationLink) so the List doesn't add its
                            // own trailing disclosure chevron — the card draws its own.
                            Button { onSelect(rec) } label: { rowCard(rec) }
                                .buttonStyle(.plain)
                        }
                    }
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 6, trailing: 16))
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if !rec.uploading {
                            Button(role: .destructive) { onDelete(rec) } label: { Label("删除", systemImage: "trash") }
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
            .refreshable { await onRefresh() }
        }
    }

    private func rowCard(_ rec: Recording) -> some View {
        let empty = rec.isEmpty
        return HStack(spacing: 13) {
            // The article's first photo as the row icon when it has one; otherwise
            // the waveform tile (also the fallback while the photo loads / on fail).
            if let cover = rec.coverPhotoKey {
                RowCoverIcon(store: store, relKey: cover)
            } else {
                waveTile(empty: empty)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(rec.rowTitle).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink)
                    .lineLimit(1).truncationMode(.tail)
                HStack(spacing: 9) {
                    if let dt = rec.dateTimeLabel {
                        Text(dt).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.metaChrome)
                    }
                    if let d = rec.durationLabel {
                        Text(d).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.metaChrome)
                    }
                    statusBadge(rec)
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
        .overlay(alignment: .topLeading) {
            if numbered, let n = commandNumber(for: rec) { numberBadge(n) }
        }
    }

    /// Small number ("2") pinned to a row's top-left corner while holding the red
    /// key to talk — the number the user speaks to target that recording ("删掉第
    /// 二条"). Design: a white rounded-square chip with a tan border (Navigation.dc).
    private func numberBadge(_ n: Int) -> some View {
        Text("\(n)")
            .font(.system(size: 12, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(Color(hex: "4A4438"))
            .frame(width: 20, height: 20)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.white))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Color(hex: "E4DBCB"), lineWidth: 1))
            .shadow(color: Color(hex: "3C2D1E").opacity(0.10), radius: 4, x: 0, y: 1)
            .offset(x: 13, y: 10)
    }

    /// The circled number to show on `rec`'s row while holding the red key to
    /// talk, or nil if `rec` isn't a numbered target (still uploading / not yet
    /// on the server). Matches `LibraryView.currentRefs()` 1:1 — both are absolute
    /// positions in `store.recordings` (newest-first).
    private func commandNumber(for rec: Recording) -> Int? {
        guard let idx = store.recordings.firstIndex(where: { $0.id == rec.id }) else { return nil }
        return idx + 1
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
            badge(Theme.greenDone, "已成文")
                .contentShape(Rectangle())
                .onLongPressGesture { onReprocess(rec) }
        } else if rec.isEmpty {
            badge(Theme.faint, "无语音")
        } else if let phase = rec.phase {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini).tint(Theme.accent)
                Text(phase.badge).font(.system(size: 12.5)).foregroundStyle(Theme.accent)
            }
        } else if let r = rec.blockReason {
            badge(Color(hex: "C0392B"), BlockReason(rawValue: r)?.label ?? BlockReason.noCredit.label)
        } else {
            badge(Theme.amberPending, "待处理")
        }
    }

    private func badge(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 12.5)).foregroundStyle(color)
        }
    }
}

/// 「VD社区」列表主体——供原生首页与 `embed: communityFeed` 复用。
struct CommunityFeedList: View {
    let store: CommunityStore
    let onSelect: (CommunityPost) -> Void
    let onUnshare: (CommunityPost) -> Void

    var body: some View {
        if store.loading && store.posts.isEmpty {
            Spacer(); ProgressView().tint(Theme.accent); Spacer()
        } else if let err = store.error, store.posts.isEmpty {
            Spacer(); homeMessage("加载失败", err); Spacer()
        } else if store.posts.isEmpty {
            Spacer(); homeMessage("VD社区还没有分享", "在文章右上角 ⋯ 里点「分享到 VD社区」，大家就能看到。"); Spacer()
        } else {
            List {
                ForEach(store.posts) { post in
                    Button { onSelect(post) } label: { communityCard(post) }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 6, trailing: 16))
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if post.mine == true {
                                Button(role: .destructive) { onUnshare(post) } label: { Label("取消分享", systemImage: "trash") }
                                    .tint(.red)
                            }
                        }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contentMargins(.bottom, 24, for: .scrollContent)
            .refreshable { await store.load() }
        }
    }

    private func communityCard(_ post: CommunityPost) -> some View {
        HStack(spacing: 13) {
            RoundedRectangle(cornerRadius: Theme.R.card)
                .fill(Theme.accentSoft)
                .frame(width: 42, height: 42)
                .overlay(Image(systemName: "doc.text").font(.system(size: 17)).foregroundStyle(Theme.accent))
            VStack(alignment: .leading, spacing: 5) {
                Text(post.title ?? "(无题)").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink)
                    .lineLimit(1).truncationMode(.tail)
                HStack(spacing: 9) {
                    Text(post.author ?? "匿名").font(.system(size: 13)).foregroundStyle(Theme.accent)
                    Text(communityDate(post.firstSharedAt)).font(.system(size: 13)).foregroundStyle(Theme.metaChrome)
                }
            }
            Spacer(minLength: 6)
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.chevron)
        }
        .padding(.vertical, 14).padding(.horizontal, 15)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.R.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.R.card).stroke(Theme.borderChrome, lineWidth: 1))
        .cardChromeShadow()
    }
}

/// `embed: notePlaceholder` 的占位卡（Phase 1 无功能，仅示意）。
struct NotePlaceholder: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "brain").font(.system(size: 28)).foregroundStyle(Theme.faint)
            Text("思考 · 即将推出").font(.system(size: 15)).foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 28)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.R.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.R.card).stroke(Theme.borderChrome, lineWidth: 1))
        .padding(.horizontal, 16)
    }
}

/// 两个列表共用的居中提示（空态 / 加载失败）。
func homeMessage(_ title: String, _ subtitle: String) -> some View {
    VStack(spacing: 10) {
        Text(title).foregroundStyle(Theme.ink).font(.system(size: 17, weight: .semibold))
        Text(subtitle).foregroundStyle(Theme.secondary).font(.system(size: 15))
            .multilineTextAlignment(.center).padding(.horizontal, 40)
    }
    .frame(maxWidth: .infinity)
}

/// A 42×42 row icon showing the article's first photo. Loads it once (own scope +
/// rel key, same public `/photo/<key>` path as PhotoTile); shows the waveform tile
/// until the image lands and if it can't load — so a row never looks broken.
private struct RowCoverIcon: View {
    let store: LibraryStore
    let relKey: String
    @State private var image: UIImage?

    /// Process-wide decoded-image cache, shared across every row. Keyed by rel key
    /// (unique per photo). NSCache evicts under memory pressure on its own. This is
    /// what stops a re-download every time a row scrolls back into view.
    private static let cache = NSCache<NSString, UIImage>()

    var body: some View {
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
            .task(id: relKey) { await load() }
    }

    private func load() async {
        // Cache hit → show instantly, no network, no waveform flash. (Set to the
        // cached image for THIS key — or nil if absent — so a recycled row never
        // shows the previous photo.)
        let cached = Self.cache.object(forKey: relKey as NSString)
        image = cached
        if cached != nil { return }
        guard let scope = await store.ownerScope() else { return }
        if let data = await store.photoData(fullKey: scope + relKey), let ui = UIImage(data: data) {
            Self.cache.setObject(ui, forKey: relKey as NSString)
            // Guard against a stale set if the row got recycled to a new key mid-fetch
            // (.task(id:) cancels the old task on key change).
            if !Task.isCancelled { image = ui }
        }
    }
}
