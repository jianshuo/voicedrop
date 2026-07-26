import Foundation
import Observation

/// A live WebSocket conversation with the library-level command Agent (Durable
/// Object behind wss://jianshuo.dev/agent/command). Unlike `ArticleAgentSession`
/// there's no single article/stem in view — instructions carry an explicit
/// numbered `refs` list (the on-screen article chips) so a spoken command like
/// "把第二篇和第三篇合并" tells the server which recordings it means. The SERVER
/// owns the durable queue; this client submits instructions (each with a stable
/// id), persists un-acked ones to disk, and reconciles against the server's
/// connect-time snapshot — so a dropped socket, a backgrounding, or an app-kill
/// never loses or double-applies a command.
@MainActor
@Observable
final class LibraryCommandSession: VoiceAgentSession {
    /// One entry in the numbered reference list shown alongside the mic (e.g.
    /// "1. 今天的会议记录  2. 周报草稿") so a spoken command can say "把第二篇…".
    struct CommandRef: Codable, Equatable {
        let n: Int
        let stem: String
        let title: String
    }

    var state: AgentState = .idle
    var error: String?

    /// Outstanding commands the user has spoken but the server hasn't confirmed
    /// done. Drives the stacked queue UI. The server is the real authority.
    /// Reuses `ArticleAgentSession.EditRequest` for the stacked-UI shape — these
    /// items are text-only; `articleIndex` is unused (always 0).
    var queue: [ArticleAgentSession.EditRequest] = []

    /// (updated doc if the server sent one, stems of the articles the command
    /// actually touched — the caller invalidates exactly those rows' caches)
    var onUpdate: ((ArticleDoc?, [String]) -> Void)?
    var onReply: ((String, Bool) -> Void)?
    /// Server wants the user to confirm a risky/ambiguous action before running
    /// it (e.g. deleting an article). UI should show a confirm card; respond
    /// with `confirm(id)` or `cancel(id)`.
    var onConfirm: ((_ id: String, _ summary: String) -> Void)?

    /// 连接生命周期（建连/25s 心跳/重连/关闭）全在基座里；本类只管协议帧和队列。
    /// 心跳以前只有 ArticleAgentSession 有——库级连接被 NAT 掐死后要等下次说话
    /// 才发现；共用基座后两边一致。
    private let socket = AgentSocket()
    private var refs: [CommandRef] = []

    private let base = API.agentWS + "/command"
    private var token: String { AuthStore.shared.bearer }
    /// Library commands aren't per-article; a single constant scope is enough
    /// until there's a real reason to split (e.g. per-account).
    private let scopeKey = "default"

    func connect() {
        // Restore any commands persisted before a previous kill (text-only).
        queue = CommandQueueStore.load(scope: scopeKey).map { ArticleAgentSession.EditRequest(id: $0.id, text: $0.text) }
        guard !token.isEmpty else { state = .error; error = "未登录"; return }
        guard let url = URL(string: base) else { state = .error; return }
        socket.onMessage = { [weak self] in self?.handle($0) }
        socket.onOpen = { [weak self] in
            guard let self else { return }
            state = queue.isEmpty ? .connecting : .working
            error = nil
            // Re-submit everything still outstanding. The server dedups by id, so a
            // resend of an already-done command just replays its result (no double-apply).
            resubmitAll()
        }
        socket.onAuthLost = { [weak self] in self?.state = .error; self?.error = "未登录" }
        socket.connect(url: url) { AuthStore.shared.bearer }
    }

    /// Set the current numbered reference list (the on-screen article chips) so
    /// the next `enqueue`/resend can tell the server which recordings a spoken
    /// command means.
    func setRefs(_ refs: [CommandRef]) {
        self.refs = refs
    }

    /// Queue a spoken command (images/articleIndex are meaningless at library
    /// scope and ignored). Persist it, then send with the current refs.
    func enqueue(_ instruction: String, images: [AgentImage] = [], articleIndex: Int = 0) {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let reqItem = ArticleAgentSession.EditRequest(text: text)
        queue.append(reqItem)
        persist()
        send(reqItem)
        Analytics.capture("语音编辑发起", ["类型": "库级命令", "字数": text.count, "带图": !images.isEmpty])
        state = .working
    }

    private func resubmitAll() {
        for item in queue { send(item) }
    }

    private func send(_ item: ArticleAgentSession.EditRequest) {
        let payload: [String: Any] = [
            "type": "instruct",
            "id": item.id,
            "text": item.text,
            "refs": refs.map { ["n": $0.n, "stem": $0.stem, "title": $0.title] }
        ]
        sendRaw(payload)
    }

    /// Approve a pending server-side confirmation (e.g. "yes, delete it").
    func confirm(_ id: String) {
        sendRaw(["type": "confirm", "id": id])
    }

    /// Reject a pending server-side confirmation.
    func cancel(_ id: String) {
        sendRaw(["type": "cancel", "id": id])
    }

    private func sendRaw(_ payload: [String: Any]) {
        // Send failed (socket mid-drop) → item stays in the queue; the
        // reconnect path resubmits it. Surface nothing — not a user error.
        socket.send(payload) { [weak self] in self?.state = .working }
    }

    /// Drop a finished command (by id) from the local queue + disk.
    private func resolve(_ id: String) {
        queue.removeAll { $0.id == id }
        persist()
        state = queue.isEmpty ? .idle : .working
    }

    private func persist() {
        let refsData = try? JSONEncoder().encode(refs)
        let refsJSON = refsData.flatMap { String(data: $0, encoding: .utf8) }
        CommandQueueStore.save(queue.map { PersistedCommand(id: $0.id, text: $0.text, refsJSON: refsJSON) }, scope: scopeKey)
    }

    private func decodeDoc(_ any: Any?) -> ArticleDoc? { ArticleDoc.fromWire(any) }

    private func handle(_ str: String) {
        guard let data = str.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        let id = obj["id"] as? String
        switch type {
        case "status":
            if (obj["state"] as? String) == "working" { state = .working }
        case "updated":
            // article may be null (e.g. after a library-wide refresh where
            // there's no single article to report back) — the UI just refreshes.
            onUpdate?(decodeDoc(obj["article"]), (obj["stems"] as? [String]) ?? [])
            if let id { resolve(id) } else if !queue.isEmpty { resolve(queue[0].id) } // old-server fallback
        case "reply":
            if let text = obj["text"] as? String, !text.isEmpty {
                onReply?(text, obj["ok"] as? Bool ?? true)
            }
        case "error":
            let msg = (obj["message"] as? String) ?? "出错了"
            error = msg
            onReply?(msg, false)
            if let id { resolve(id) } else if !queue.isEmpty { resolve(queue[0].id) }
            if queue.isEmpty { state = .error }
        case "confirm":
            if let id, let summary = obj["summary"] as? String {
                onConfirm?(id, summary)
            }
        case "snapshot":
            reconcile(obj)
        default:
            break
        }
    }

    /// Reconcile the local queue against the server's authoritative snapshot.
    /// done → drop locally (apply the doc); pending/running → keep showing;
    /// anything the server doesn't know about → resend (we were killed before
    /// it landed). Always apply the snapshot's current article, if any.
    private func reconcile(_ obj: [String: Any]) {
        // stems 必须透传且 onUpdate 无条件调用（对齐上面 "updated" 分支）：库级
        // 命令 merge/delete 场景 article 常为 null——若在 doc 非空时才回调，
        // 快照对账就既丢 stems 又跳过 refresh，界面拿旧缓存装作已更新。
        onUpdate?(decodeDoc(obj["article"]), (obj["stems"] as? [String]) ?? [])
        let serverItems = (obj["queue"] as? [[String: Any]]) ?? []
        var serverStatus: [String: String] = [:]
        for it in serverItems { if let sid = it["id"] as? String, let st = it["status"] as? String { serverStatus[sid] = st } }
        for item in queue {
            switch serverStatus[item.id] {
            case "done": resolve(item.id)
            case "pending", "running": break          // in flight on the server; keep it shown
            case "error": resolve(item.id)
            default: send(item)                        // server never saw it → resend
            }
        }
        state = queue.isEmpty ? .idle : .working
    }

    /// Close the socket but KEEP the queue (persisted). Called on a transient
    /// disappear (navigation away / backgrounding). The next connect resumes.
    func disconnect() {
        socket.disconnect()
        state = queue.isEmpty ? .idle : .working
        // queue + disk intentionally preserved.
    }
}
