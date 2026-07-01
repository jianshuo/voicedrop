import SwiftUI

/// Posted when the app is opened via its `voicedrop://recordings` URL scheme —
/// the Share Extension deep-links here right after 生成文章 so the user lands on
/// 我的录音 and watches the mining progress. LibraryView observes it.
extension Notification.Name { static let vdOpenRecordings = Notification.Name("VDOpenRecordings") }

@main
struct VoiceDropApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .onOpenURL { url in
                    if url.scheme == "voicedrop" {
                        NotificationCenter.default.post(name: .vdOpenRecordings, object: nil)
                    }
                }
        }
    }
}
