import SwiftUI

// Apple App Store Guideline 1.2 (User-Generated Content) client-side pieces:
//  • BlockStore        — block abusive users (local only, never sent to the server)
//  • CommunityTerms    — EULA / 社区公约 with zero-tolerance, agreed before first post
//  • CommunityTermsSheet — the agree gate UI

/// Local block list. Apple 1.2 "block abusive users". Stored on-device only
/// (UserDefaults) — per the product decision, blocking never touches the server.
/// Blocks by the author's display name as shown in the feed; the community feed
/// filters blocked authors out client-side.
@MainActor
enum BlockStore {
    private static let key = "vd.blockedAuthors"

    static func blocked() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }
    static func isBlocked(_ author: String?) -> Bool {
        guard let a = author, !a.isEmpty else { return false }
        return blocked().contains(a)
    }
    static func block(_ author: String?) {
        guard let a = author, !a.isEmpty else { return }
        var s = blocked(); s.insert(a)
        UserDefaults.standard.set(Array(s), forKey: key)
    }
    static func unblock(_ author: String) {
        var s = blocked(); s.remove(author)
        UserDefaults.standard.set(Array(s), forKey: key)
    }
}

/// 社区公约 / EULA. Apple 1.2 requires agreeing to terms that state zero tolerance
/// for objectionable content and abusive users, BEFORE the user can post UGC.
enum CommunityTerms {
    private static let agreedKey = "vd.communityTermsAgreed"
    static var agreed: Bool {
        get { UserDefaults.standard.bool(forKey: agreedKey) }
        set { UserDefaults.standard.set(newValue, forKey: agreedKey) }
    }

    static let supportEmail = "jianshuo@hotmail.com"

    static let body = """
    发布到 VD社区，表示你同意以下社区公约：

    • 你对自己发布的内容负责，并拥有发布它的权利。
    • 严禁发布令人反感的内容——包括色情或露骨性内容、暴力血腥、仇恨或歧视、骚扰或欺凌、违法内容、自残等。VoiceDrop 对令人反感的内容和滥用行为零容忍。
    • 违规内容一经举报将被立即下架，并在 24 小时内处理；屡次或严重违规的账号将被移除。
    • 你可以随时举报不当内容、屏蔽不想看到的用户。

    继续即表示你已阅读并同意本社区公约与最终用户许可协议（EULA）。如需联系或投诉内容，请发邮件至 \(supportEmail)。
    """
}

/// The agree-gate shown before a user's first community post.
struct CommunityTermsSheet: View {
    var onAgree: () -> Void
    var onCancel: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Text("社区公约")
                .font(.system(size: 19, weight: .semibold)).foregroundStyle(Theme.ink)
                .padding(.top, 22).padding(.bottom, 14)
            ScrollView {
                Text(CommunityTerms.body)
                    .font(.system(size: 15)).foregroundStyle(Theme.bodyInk)
                    .lineSpacing(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22)
            }
            VStack(spacing: 10) {
                Button {
                    CommunityTerms.agreed = true
                    dismiss(); onAgree()
                } label: {
                    Text("同意并发布")
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                Button { dismiss(); onCancel() } label: {
                    Text("取消").font(.system(size: 15)).foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 18)
        }
        .background(Theme.appBG.ignoresSafeArea())
        .presentationDetents([.medium, .large])
    }
}

/// Manage the local block list (Settings → 已屏蔽用户). Lets the user unblock.
struct BlockedUsersView: View {
    @State private var blocked: [String] = []

    var body: some View {
        List {
            if blocked.isEmpty {
                Text("还没有屏蔽任何人")
                    .font(.system(size: 15)).foregroundStyle(Theme.secondary)
            } else {
                ForEach(blocked, id: \.self) { name in
                    HStack {
                        Text(name).font(.system(size: 16)).foregroundStyle(Theme.ink)
                        Spacer()
                        Button("取消屏蔽") { BlockStore.unblock(name); reload() }
                            .font(.system(size: 14)).foregroundStyle(Theme.accent)
                    }
                }
            }
        }
        .navigationTitle("已屏蔽用户")
        .onAppear(perform: reload)
    }

    private func reload() { blocked = BlockStore.blocked().sorted() }
}
