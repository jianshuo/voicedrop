import SwiftUI

// MARK: - 修改这本书 — 读书页 ⋯ 菜单弹出（书的主人专用）
//
// 每本书在 lab.jianshuo.dev 有一条**永久对话线**（服务端 bookmeta/<slug>.json）：
// 第一条是开书种子，之后每次修改一条——主人的指令 + agent 改完写的「修改说明」。
// 本 sheet 就是那条线的聊天式界面：上面翻历史，底部输入框发新指令。
//
// 契约：GET lab/api/book/history?slug=<slug>（bearer，主人可见；403=不是主人，
// 404=登记簿上线前的老书）→ {slug,author,running,thread:[{ts,kind,instruction,
// status,reply,error}]}。POST lab/api/book/revise {slug,instruction}（一口价
// 40 算力，402 带权威价目）→ 202 后 fire-and-forget，轮询 history 看进度；
// entry.status running→done 时 reply 就是 agent 的修改说明。
struct BookReviseSheet: View {
    let book: ShelfBook
    @Environment(\.dismiss) private var dismiss

    @State private var thread: [BookThreadEntry] = []
    @State private var denied: String?          // 403/404 等不可用的说明（占满界面）
    @State private var loading = true
    @State private var input = ""
    @State private var sending = false
    @State private var errorText: String?
    @FocusState private var inputFocused: Bool

    private static let price = 40   // 展示用价目；扣费真源在服务端（402 带权威数字）
    private static let historyBase = API.bookAPIBase.appending(path: "history")
    private static let reviseAPI = API.bookAPIBase.appending(path: "revise")

    private var running: Bool { thread.contains { $0.status == "running" } }
    private var trimmedInput: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSend: Bool { !trimmedInput.isEmpty && !sending && !running && denied == nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let denied {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "lock.circle").font(.system(size: 40)).foregroundStyle(Theme.faint)
                    Text(denied)
                        .font(.system(size: 14)).foregroundStyle(Theme.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 36)
                }
                Spacer()
            } else {
                threadList
                inputBar
            }
        }
        .background(Theme.appBG.ignoresSafeArea())
        .presentationDragIndicator(.visible)
        .task { await load() }
        .task(id: running) { await pollWhileRunning() }
        .onAppear { Analytics.screen("修改书") }
    }

    private var header: some View {
        HStack {
            Button("关闭") { dismiss() }
                .font(.system(size: 16)).foregroundStyle(Theme.secondary)
            Spacer()
            Text("修改《\(book.main)》")
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
            Spacer()
            Text("关闭").font(.system(size: 16)).hidden()   // 平衡布局，让标题居中
        }
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)
    }

    // MARK: 对话线

    private var threadList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if loading && thread.isEmpty {
                        ProgressView().tint(Theme.recordRed)
                            .frame(maxWidth: .infinity).padding(.top, 40)
                    }
                    ForEach(thread) { entry in
                        entryView(entry)
                    }
                    if let err = errorText {
                        Text(err).font(.system(size: 13)).foregroundStyle(Theme.recordRed)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 12)
            }
            .onChange(of: thread.count) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    @ViewBuilder private func entryView(_ entry: BookThreadEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // 我的指令（右侧气泡）；第一条是开书种子，标出来
            VStack(alignment: .trailing, spacing: 3) {
                Text(entry.kind == "create" ? String(localized: "开书种子") : String(localized: "修改指令"))
                    .font(.system(size: 11)).foregroundStyle(Theme.metaChrome)
                Text(entry.instruction)
                    .font(.system(size: 15)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.R.primary))
                Text(Self.stamp(entry.ts))
                    .font(.system(size: 11)).foregroundStyle(Theme.faint)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            // agent 的答复（左侧气泡）
            replyView(entry).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func replyView(_ entry: BookThreadEntry) -> some View {
        switch entry.status {
        case "running":
            HStack(spacing: 8) {
                ProgressView().tint(Theme.secondary).scaleEffect(0.8)
                Text(entry.kind == "create" ? "正在写这本书…" : "正在修改…（改完这里会出现修改说明）")
                    .font(.system(size: 14)).foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.R.primary))
            .overlay(RoundedRectangle(cornerRadius: Theme.R.primary).stroke(Theme.borderRead, lineWidth: 1))
        case "failed":
            Text(entry.kind == "create" ? String(localized: "这本书当时没写完就中断了") : String(localized: "这次修改没有完成（没扣的算力不会少），可以再试一次"))
                .font(.system(size: 14)).foregroundStyle(Theme.recordRed)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.R.primary))
                .overlay(RoundedRectangle(cornerRadius: Theme.R.primary).stroke(Theme.borderRead, lineWidth: 1))
        default:
            if let reply = entry.reply, !reply.isEmpty {
                Text(reply)
                    .font(.system(size: 15)).foregroundStyle(Theme.ink)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.R.primary))
                    .overlay(RoundedRectangle(cornerRadius: Theme.R.primary).stroke(Theme.borderRead, lineWidth: 1))
            } else {
                Text(entry.kind == "create" ? "书写好了，上架在「写书」书架。" : "改好了。")
                    .font(.system(size: 14)).foregroundStyle(Theme.secondary)
            }
        }
    }

    // MARK: 输入框

    private var inputBar: some View {
        VStack(spacing: 7) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField("想怎么改这本书？比如：第三章开头太啰嗦，删一半", text: $input, axis: .vertical)
                    .font(.system(size: 15)).foregroundStyle(Theme.ink)
                    .lineLimit(1...5)
                    .focused($inputFocused)
                    .padding(.horizontal, 13).padding(.vertical, 10)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.R.primary))
                    .overlay(RoundedRectangle(cornerRadius: Theme.R.primary).stroke(Theme.accent, lineWidth: 1.5))
                Button { send() } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(canSend ? Theme.accent : Theme.faint, in: Circle())
                }
                .disabled(!canSend)
            }
            Text(running ? "有一个修改正在进行，等它改完再提下一个" : "每次修改 \(Self.price) 算力 · 提交后可以关掉，改完这里会留下修改说明")
                .font(.system(size: 12)).foregroundStyle(Theme.metaChrome)
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 12)
        .background(Theme.appBG)
        .overlay(alignment: .top) { Rectangle().fill(Theme.borderChrome).frame(height: 1) }
    }

    // MARK: 数据

    private var historyURL: URL {
        var c = URLComponents(url: Self.historyBase, resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "slug", value: book.slug)]
        return c.url!
    }

    private func load() async {
        defer { loading = false }
        let token = AuthStore.shared.bearer
        guard !token.isEmpty else { denied = String(localized: "登录状态不对，重启 App 再试。"); return }
        var req = URLRequest(url: historyURL)
        req.setBearer(token)
        req.timeoutInterval = 20
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let code = (resp as? HTTPURLResponse)?.statusCode else {
            if thread.isEmpty { errorText = String(localized: "没连上服务器，下拉或重开再试。") }
            return
        }
        switch code {
        case 200:
            if let t = try? JSONDecoder().decode(BookThread.self, from: data) {
                thread = t.thread
                denied = nil
            }
        case 403:
            denied = String(localized: "只有这本书的主人能修改。")
        case 404:
            denied = String(localized: "这本书是早期写的，还没登记主人，暂时不能在线修改。")
        default:
            if thread.isEmpty { errorText = String(localized: "服务器返回 \(code)，稍后再试。") }
        }
    }

    /// 有修改在跑时每 6 秒刷一次，直到 running 消失（task(id: running) 自动重启/取消）。
    private func pollWhileRunning() async {
        while running && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            await load()
        }
    }

    private func send() {
        guard canSend else { return }
        let instruction = trimmedInput
        inputFocused = false
        sending = true; errorText = nil
        Analytics.capture("修书发起", ["书": book.slug])
        Task {
            defer { sending = false }
            var req = URLRequest(url: Self.reviseAPI)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setBearer(AuthStore.shared.bearer)
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["slug": book.slug, "instruction": instruction])
            req.timeoutInterval = 30
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                switch (resp as? HTTPURLResponse)?.statusCode ?? 0 {
                case 202:
                    input = ""
                    // 乐观追加一条 running，等下一轮 history 轮询接管真数据
                    let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                    let ts = (body?["ts"] as? Double) ?? Date().timeIntervalSince1970 * 1000
                    thread.append(BookThreadEntry(ts: ts, kind: "revise", instruction: instruction,
                                                  status: "running", reply: nil, error: nil))
                    Analytics.capture("修书已受理", ["书": book.slug])
                case 402:
                    let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                    let have = (body?["suanli"] as? Double) ?? 0
                    errorText = String(localized: "算力不足：改一次要 \(Self.price) 算力，你现在有 \(Int(have.rounded()))。")
                case 403:
                    errorText = String(localized: "只有这本书的主人能修改。")
                case 409:
                    errorText = String(localized: "上一个修改还在进行，等它改完再提。")
                    await load()
                case 401:
                    errorText = String(localized: "身份校验没过，请稍后重试。")
                case let code:
                    errorText = String(localized: "服务器返回 \(code)，请稍后重试。")
                }
            } catch {
                errorText = String(localized: "没连上服务器：\(error.localizedDescription)")
            }
        }
    }

    /// 时间戳（毫秒）→「M月d日 HH:mm」。
    static func stamp(_ ms: Double) -> String {
        let d = Date(timeIntervalSince1970: ms / 1000)
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 HH:mm"
        return f.string(from: d)
    }
}

// MARK: - 对话线数据模型（服务端 bookmeta 的 thread；纯解码，单测覆盖）

struct BookThread: Decodable {
    let slug: String
    let author: String?
    let running: Bool
    let thread: [BookThreadEntry]
}

struct BookThreadEntry: Decodable, Identifiable, Equatable {
    let ts: Double
    let kind: String        // "create" | "revise"
    let instruction: String
    let status: String      // "running" | "done" | "failed"
    let reply: String?
    let error: String?
    var id: Double { ts }
}
