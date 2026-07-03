import SwiftUI

/// Deep-link targets for the `voicedrop://` URL scheme. One address per main
/// page. The Share Extension and any external link open these; `AppRouter`
/// parses the URL and `LibraryView` applies it (switching tab AND clearing any
/// pushed detail/settings so the link always lands cleanly — the earlier
/// "just set the tab" approach left you on whatever detail page was open).
///
/// Addresses:
///   voicedrop://recordings        我的录音（列表根）
///   voicedrop://community         VD社区
///   voicedrop://settings          设置
///   voicedrop://record            开始录音（全屏）
///   voicedrop://article/<stem>    某篇文章详情（stem 形如 VoiceDrop-2026-07-01-…）
enum DeepLink: Equatable {
    case recordings
    case community
    case settings
    case record
    case article(String)
}

@MainActor
final class AppRouter: ObservableObject {
    /// The last deep link received, awaiting application by LibraryView. Cleared
    /// after it's applied so re-subscribing doesn't re-trigger it.
    @Published var pending: DeepLink?

    func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "voicedrop" else { return }
        switch (url.host ?? "").lowercased() {
        case "", "recordings", "home": pending = .recordings
        case "community":              pending = .community
        case "settings", "setting":    pending = .settings
        case "record":                 pending = .record
        case "article":
            // voicedrop://article/<stem>  → path components after the host
            let stem = url.pathComponents.filter { $0 != "/" }.joined(separator: "/")
            pending = stem.isEmpty ? .recordings : .article(stem)
        default:                       pending = .recordings
        }
    }
}
