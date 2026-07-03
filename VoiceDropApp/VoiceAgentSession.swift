import Foundation

/// Shared UI contract for a live voice-driven agent session. `ArticleAgentSession`
/// (per-article editing) conforms today; a future library-level command session
/// (batch operations across recordings, no single article in view) will conform
/// too — hence `onUpdate` accepts a nil doc (e.g. after a library-wide refresh
/// where there's no single article to report back).
@MainActor
protocol VoiceAgentSession: AnyObject {
    var state: AgentState { get }
    var queue: [ArticleAgentSession.EditRequest] { get }
    var onReply: ((String, Bool) -> Void)? { get set }
    var onUpdate: ((ArticleDoc?) -> Void)? { get set }
    func enqueue(_ instruction: String, images: [AgentImage], articleIndex: Int)
    func disconnect()
}
