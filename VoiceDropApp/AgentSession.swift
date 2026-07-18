import Foundation
import Observation

enum AgentState: Equatable { case idle, connecting, working, error }

/// 锚点协议 T3：长按目标（图/行）随请求结构化上传，服务端渲染成独立上下文行。
/// 只在长按菜单动作时携带（手势天然产生锚点）；语音自由指令没有锚点（nil = 现状）。
/// Codable 手写：wire 形状 `{type:"image", key}` / `{type:"line", line, text}` 与
/// docs/superpowers/specs/2026-07-16-anchor-protocol-design.md §3 严格一致，也复用
/// 同一编解码给磁盘队列持久化（PersistedEdit.anchor）。
enum EditAnchor: Equatable, Codable {
    case image(key: String)
    case line(Int, text: String)

    private enum CodingKeys: String, CodingKey { case type, key, line, text }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "image":
            self = .image(key: try c.decode(String.self, forKey: .key))
        case "line":
            self = .line(try c.decode(Int.self, forKey: .line), text: try c.decode(String.self, forKey: .text))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown anchor type \(type)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .image(let key):
            try c.encode("image", forKey: .type)
            try c.encode(key, forKey: .key)
        case .line(let line, let text):
            try c.encode("line", forKey: .type)
            try c.encode(line, forKey: .line)
            try c.encode(text, forKey: .text)
        }
    }

    /// WS `instruct` payload 里 `anchor` 字段的字典形状（JSONSerialization 用，键名
    /// 与服务端 wire 协议严格一致：image → type/key；line → type/line/text）。
    var wireDict: [String: Any] {
        switch self {
        case .image(let key):
            return ["type": "image", "key": key]
        case .line(let line, let text):
            return ["type": "line", "line": line, "text": text]
        }
    }
}

/// A 320×320 thumbnail sent alongside a voice instruction so the model can see
/// the image and decide where to place it.
struct AgentImage: Equatable {
    let key: String
    /// 2026-07-14 起不再携带 base64：服务端按 key 自己拉 320 边缘缩图给模型
    ///（缩图归服务端原则）。字段保留可选是给将来需要塞非 R2 图的口子。
    let base64: String?
}

/// A live WebSocket conversation with the article-editing Agent (Durable Object
/// behind wss://jianshuo.dev/agent/edit). The SERVER owns the durable queue; this
/// client submits instructions (each with a stable id), persists un-acked ones to
/// disk, and reconciles against the server's connect-time snapshot — so a dropped
/// socket, a backgrounding, or an app-kill never loses or double-applies an edit.
@MainActor
@Observable
final class ArticleAgentSession: VoiceAgentSession {
    struct EditRequest: Identifiable, Equatable {
        let id: String          // stable across reconnects/relaunches (sent on the wire)
        let text: String
        let images: [AgentImage]
        let articleIndex: Int   // which article (chip) was on screen — locator targeting
        /// 长按目标（图/行），语音自由指令为 nil（现状）。见 EditAnchor 文档注释。
        let anchor: EditAnchor?
        /// 长按菜单被调指令的 id（服务端出图时精确解析魔法数字进 XMP）；语音自由指令为 nil。
        let itemId: String?
        init(id: String = UUID().uuidString, text: String, images: [AgentImage] = [], articleIndex: Int = 0, anchor: EditAnchor? = nil, itemId: String? = nil) {
            self.id = id; self.text = text; self.images = images; self.articleIndex = articleIndex; self.anchor = anchor; self.itemId = itemId
        }
    }

    var state: AgentState = .idle
    var error: String?

    /// Outstanding edits the user has spoken but the server hasn't confirmed
    /// done. Drives the stacked queue UI. The server is the real authority.
    var queue: [EditRequest] = []

    var onUpdate: ((ArticleDoc?, [String]) -> Void)?
    var onReply: ((String, Bool) -> Void)?

    /// 实时预览（换风格/重写/语音整篇改写）：服务端边生成边推的纯文本增量。
    /// a = 文章下标，field = "title" | "body"。
    struct PreviewDelta: Equatable { let a: Int; let field: String; let text: String }
    var onPreview: (([PreviewDelta]) -> Void)?
    var onPreviewReset: (() -> Void)?
    var onPreviewDone: ((Bool) -> Void)?

    /// 行级语音编辑的打字机流：i = 本轮第几个操作，op = replace_line/insert_after/set_title，
    /// line = 目标行号（set_title 为 nil），text = 新文本增量。
    struct EditDelta: Equatable { let i: Int; let op: String; let line: Int?; let text: String }
    var onEditPreview: (([EditDelta]) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var rec: Recording?
    private var closed = false

    private let base = API.agentWS + "/edit"
    private var token: String { AuthStore.shared.bearer }
    private var stem: String { rec?.stem ?? "" }

    func connect(_ rec: Recording) {
        self.rec = rec
        closed = false
        // Restore any edits persisted before a previous kill (text-only).
        queue = EditQueueStore.load(stem: rec.stem).map { EditRequest(id: $0.id, text: $0.text, articleIndex: $0.articleIndex ?? 0, anchor: $0.anchor, itemId: $0.itemId) }
        openSocket()
    }

    private func openSocket() {
        guard let rec, !token.isEmpty else { state = .error; error = "未登录"; return }
        state = queue.isEmpty ? .connecting : .working
        error = nil
        let stem = rec.stem.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? rec.stem
        guard let url = URL(string: "\(base)?stem=\(stem)") else { state = .error; return }
        var req = URLRequest(url: url)
        req.setBearer(token)
        let s = URLSession(configuration: .default)
        session = s
        let t = s.webSocketTask(with: req)
        task = t
        t.resume()
        receive()
        // Re-submit everything still outstanding. The server dedups by id, so a
        // resend of an already-done edit just replays its result (no double-apply).
        resubmitAll()
    }

    /// Queue a spoken instruction (optionally with photos). Persist it, then send.
    /// Protocol-conformance overload (`VoiceAgentSession.enqueue(_:images:articleIndex:)`
    /// has a fixed 3-arg signature — Swift witness matching doesn't accept extra
    /// defaulted params — so anchor gets its own overload below).
    func enqueue(_ instruction: String, images: [AgentImage] = [], articleIndex: Int = 0) {
        enqueue(instruction, images: images, articleIndex: articleIndex, anchor: nil)
    }

    /// Same as above, but carries the long-press target (image/line). Only
    /// long-press menu actions pass one; free-form voice instructions call the
    /// overload above (anchor stays nil = current behavior).
    func enqueue(_ instruction: String, images: [AgentImage] = [], articleIndex: Int = 0, anchor: EditAnchor?, itemId: String? = nil) {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let reqItem = EditRequest(text: text, images: images, articleIndex: articleIndex, anchor: anchor, itemId: itemId)
        queue.append(reqItem)
        persist()
        send(reqItem)
        state = .working
        editSentAt[reqItem.id] = Date()
        Analytics.capture("语音编辑发起", [
            "类型": text.hasPrefix("【回答追问】") ? "回答追问" : "普通修改",
            "字数": text.count,
            "带图": !images.isEmpty,
        ])
    }

    /// 埋点用：编辑发起时刻（键 = 请求 id），落地/出错时算端到端耗时。
    private var editSentAt: [String: Date] = [:]

    private func captureEditDone(_ id: String?, ok: Bool) {
        let effective = id ?? queue.first?.id
        var props: [String: Any] = ["成功": ok]
        if let effective, let began = editSentAt.removeValue(forKey: effective) {
            props["耗时秒"] = Int(Date().timeIntervalSince(began))
        }
        Analytics.capture("语音编辑落地", props)
    }

    private func resubmitAll() {
        for item in queue { send(item) }
    }

    private func send(_ item: EditRequest) {
        guard let task else { return }
        var payload: [String: Any] = ["type": "instruct", "id": item.id, "text": item.text, "articleIndex": item.articleIndex]
        if !item.images.isEmpty {
            payload["images"] = item.images.map { img -> [String: String] in
                var d = ["key": img.key, "mediaType": "image/jpeg"]
                if let b64 = img.base64 { d["data"] = b64 }   // 老路径兼容口，正常不走
                return d
            }
        }
        if let anchor = item.anchor { payload["anchor"] = anchor.wireDict }
        if let itemId = item.itemId { payload["itemId"] = itemId }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: data, encoding: .utf8) else { return }
        task.send(.string(str)) { [weak self] err in
            guard err != nil else { return }
            // Send failed (socket mid-drop). Leave the item in the queue; the
            // reconnect path resubmits it. Surface nothing — not a user error.
            Task { @MainActor in self?.state = .working }
        }
    }

    /// Drop a finished edit (by id) from the local queue + disk.
    private func resolve(_ id: String) {
        queue.removeAll { $0.id == id }
        persist()
        state = queue.isEmpty ? .idle : .working
    }

    private func persist() {
        EditQueueStore.save(queue.map { PersistedEdit(id: $0.id, text: $0.text, articleIndex: $0.articleIndex, anchor: $0.anchor, itemId: $0.itemId) }, stem: stem)
    }

    private func receive() {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .failure:
                    if !self.closed { self.reconnect() }
                case .success(let message):
                    switch message {
                    case .string(let str): self.handle(str)
                    case .data(let d): if let str = String(data: d, encoding: .utf8) { self.handle(str) }
                    @unknown default: break
                    }
                    self.receive()
                }
            }
        }
    }

    private func decodeDoc(_ any: Any?) -> ArticleDoc? {
        // A JSON-null `article` arrives as NSNull (non-nil but not a valid top-level
        // JSON object); `data(withJSONObject:)` would throw an ObjC exception `try?`
        // can't catch → abort(). Gate on isValidJSONObject first. (See the same fix
        // in LibraryCommandSession.decodeDoc — the library path hits null far more.)
        guard let any, JSONSerialization.isValidJSONObject(any),
              let d = try? JSONSerialization.data(withJSONObject: any) else { return nil }
        return try? JSONDecoder().decode(ArticleDoc.self, from: d)
    }

    private func handle(_ str: String) {
        guard let data = str.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        let id = obj["id"] as? String
        switch type {
        case "status":
            if (obj["state"] as? String) == "working" { state = .working }
        case "updated":
            if let doc = decodeDoc(obj["article"]) { onUpdate?(doc, (obj["stems"] as? [String]) ?? []) }
            captureEditDone(id, ok: true)
            if let id { resolve(id) } else if !queue.isEmpty { resolve(queue[0].id) } // old-server fallback
        case "reply":
            if let text = obj["text"] as? String, !text.isEmpty {
                onReply?(text, obj["ok"] as? Bool ?? true)
            }
        case "error":
            let msg = (obj["message"] as? String) ?? "出错了"
            error = msg
            onReply?(msg, false)
            captureEditDone(id, ok: false)
            if let id { resolve(id) } else if !queue.isEmpty { resolve(queue[0].id) }
            if queue.isEmpty { state = .error }
        case "snapshot":
            reconcile(obj)
        case "preview-delta":
            let deltas = ((obj["items"] as? [[String: Any]]) ?? []).compactMap { it -> PreviewDelta? in
                guard let a = it["a"] as? Int, let f = it["field"] as? String, let t = it["text"] as? String else { return nil }
                return PreviewDelta(a: a, field: f, text: t)
            }
            if !deltas.isEmpty { onPreview?(deltas) }
        case "preview-reset":
            onPreviewReset?()
        case "preview-done":
            onPreviewDone?(obj["ok"] as? Bool ?? true)
        case "edit-preview":
            let deltas = ((obj["items"] as? [[String: Any]]) ?? []).compactMap { it -> EditDelta? in
                guard let i = it["i"] as? Int, let op = it["op"] as? String, let t = it["text"] as? String else { return nil }
                return EditDelta(i: i, op: op, line: it["line"] as? Int, text: t)
            }
            if !deltas.isEmpty { onEditPreview?(deltas) }
        default:
            break
        }
    }

    /// Reconcile the local queue against the server's authoritative snapshot.
    /// done → drop locally (apply the doc); pending/running → keep showing;
    /// anything the server doesn't know about → resend (we were killed before
    /// it landed). Always apply the snapshot's current article.
    private func reconcile(_ obj: [String: Any]) {
        if let doc = decodeDoc(obj["article"]) { onUpdate?(doc, (obj["stems"] as? [String]) ?? []) }
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

    private func reconnect() {
        guard !closed else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !self.closed { self.openSocket() }
        }
    }

    /// Close the socket but KEEP the queue (persisted). Called on a transient
    /// disappear (navigation away / backgrounding). The next connect resumes.
    func disconnect() {
        closed = true
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        state = queue.isEmpty ? .idle : .working
        // queue + disk intentionally preserved.
    }
}
