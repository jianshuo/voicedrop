import SwiftUI

// MARK: - 写书（实验功能）— 关于 → 实验功能 → 写书

/// 把一个词 / 一句话 / 一篇文章交给 lab.jianshuo.dev 上的常驻 Claude agent，
/// 用 wjs-voicedrop-writing-book skill 长成一本书：一个 agent 写大纲、每章一个
/// subagent 写正文、独立评审过稿后增量发布到公开书架 voicedrop.cn/books/。
///
/// 连接契约：POST /api/chat（SSE）。服务端在客户端断线时会中止 agent——所以
/// 写书期间必须保持连接（屏幕常亮 + 禁下滑关闭）；中途断线已发布的章节保留。
/// 访问密码 = lab.jianshuo.dev 前置 Caddy basic auth（用户名 wjs），只存本机。
struct BookWritingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("bookAgentPassword") private var password = ""
    @State private var seed = ""
    @State private var running = false
    @State private var finished = false
    @State private var errorText: String?
    @State private var log = ""
    @State private var task: Task<Void, Never>?
    @FocusState private var seedFocused: Bool

    private static let booksURL = URL(string: "https://voicedrop.cn/books/")!
    private static let chatURL = URL(string: "https://lab.jianshuo.dev/api/chat")!

    private var trimmedSeed: String { seed.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canStart: Bool { !trimmedSeed.isEmpty && !password.isEmpty && !running }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if running || finished || errorText != nil {
                        progressSection
                    } else {
                        introSection
                        inputSection
                    }
                }
                .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 30)
            }
        }
        .background(Theme.appBG.ignoresSafeArea())
        .presentationDragIndicator(running ? .hidden : .visible)
        .interactiveDismissDisabled(running)
        .onDisappear {
            task?.cancel()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private var header: some View {
        HStack {
            Button(running ? String(localized: "停止") : String(localized: "关闭")) {
                if running { task?.cancel() } else { dismiss() }
            }
            .font(.system(size: 16)).foregroundStyle(running ? Theme.recordRed : Theme.secondary)
            Spacer()
            Text("写书").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
            Spacer()
            Button(running ? String(localized: "写作中…") : String(localized: "开写")) { start() }
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(canStart ? Theme.accent : Theme.faint)
                .disabled(!canStart)
        }
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)
    }

    private var introSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("给一个词、一句话，或贴一整篇文章，AI 会把它长成一本书：先写大纲，再每章一个写手并行写正文（费曼式白话），独立评审过稿一章、发布一章。")
                .font(.system(size: 14)).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("写一本书通常要 10–30 分钟。期间请把手机留在这个页面（会自动保持屏幕常亮）；中途停止的话，已写完的章节也会留在书架上。")
                .font(.system(size: 13)).foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
            SettingsCard {
                Link(destination: Self.booksURL) {
                    SettingsRow(tileBG: Theme.tileNeutral, symbol: "books.vertical", tileFG: Theme.secondary,
                                title: String(localized: "公开书架"), subtitle: String(localized: "voicedrop.cn/books · 已出版的书都在这")) { settingsChevron }
                }.buttonStyle(.plain)
            }
        }
    }

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .topLeading) {
                if seed.isEmpty {
                    Text("书的种子：一个词、一句话，或一整篇文章……")
                        .font(.system(size: 16)).foregroundStyle(Theme.faint)
                        .padding(.top, 22).padding(.leading, 20)
                }
                TextEditor(text: $seed)
                    .font(.system(size: 16)).foregroundStyle(Theme.ink)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 140)
                    .focused($seedFocused)
                    .padding(.vertical, 14).padding(.horizontal, 15)
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.R.primary))
            .overlay(RoundedRectangle(cornerRadius: Theme.R.primary).stroke(Theme.accent, lineWidth: 1.5))

            SecureField(String(localized: "访问密码（实验功能，向开发者索取）"), text: $password)
                .font(.system(size: 15)).foregroundStyle(Theme.ink)
                .textContentType(.password)
                .padding(.vertical, 12).padding(.horizontal, 15)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.R.primary))
                .overlay(RoundedRectangle(cornerRadius: Theme.R.primary).stroke(Theme.borderChrome, lineWidth: 1))
            Text("写书跑在开发者自己的 AI 服务器上（lab.jianshuo.dev），密码只保存在本机。")
                .font(.system(size: 12.5)).foregroundStyle(Theme.faint)
        }
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if finished {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 44)).foregroundStyle(Theme.greenDone)
                    Text("写完了！去书架看看吧。").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
                    Link(destination: Self.booksURL) {
                        Text("打开公开书架")
                            .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                            .padding(.vertical, 12).padding(.horizontal, 24)
                            .background(Theme.accent, in: Capsule())
                    }
                }
                .frame(maxWidth: .infinity).padding(.top, 20)
            } else if let err = errorText {
                VStack(alignment: .leading, spacing: 8) {
                    Text("没写成").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.recordRed)
                    Text(err).font(.system(size: 14)).foregroundStyle(Theme.secondary)
                    Button {
                        errorText = nil; log = ""
                    } label: {
                        Text("返回重试").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accent)
                    }
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView().tint(Theme.accent)
                    Text("正在写书……请保持在这个页面")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                }
            }
            if !log.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(log)
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                        Color.clear.frame(height: 1).id("tail")
                    }
                    .frame(height: 320)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.R.primary))
                    .overlay(RoundedRectangle(cornerRadius: Theme.R.primary).stroke(Theme.borderChrome, lineWidth: 1))
                    .onChange(of: log) { _, _ in withAnimation { proxy.scrollTo("tail", anchor: .bottom) } }
                }
            }
        }
    }

    private func start() {
        guard canStart else { return }
        seedFocused = false
        running = true; finished = false; errorText = nil; log = ""
        UIApplication.shared.isIdleTimerDisabled = true
        Analytics.capture("写书发起")
        let message = "用 wjs-voicedrop-writing-book skill 写一本书。种子：\n\(trimmedSeed)"
        task = Task {
            do {
                try await streamChat(message: message)
                if !Task.isCancelled { finished = true; Analytics.capture("写书完成") }
            } catch is CancellationError {
                errorText = String(localized: "已停止。写到一半的书，已过稿的章节保留在书架上。")
            } catch let e as BookAgentError {
                errorText = e.message
            } catch {
                errorText = String(localized: "连接断了：\(error.localizedDescription)。已过稿的章节保留在书架上。")
            }
            running = false
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private struct BookAgentError: Error { let message: String }

    /// POST /api/chat and follow the SSE stream until `done`. The connection
    /// IS the job — server aborts the agent when we drop it.
    private func streamChat(message: String) async throws {
        var req = URLRequest(url: Self.chatURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let basic = Data("wjs:\(password)".utf8).base64EncodedString()
        req.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["message": message])
        req.timeoutInterval = 120  // server heartbeats every 15s; only a dead pipe times out

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 3 * 3600
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        let (bytes, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse else { throw BookAgentError(message: String(localized: "服务器没有响应")) }
        if http.statusCode == 401 { throw BookAgentError(message: String(localized: "访问密码不对")) }
        guard http.statusCode == 200 else { throw BookAgentError(message: String(localized: "服务器返回 \(http.statusCode)")) }

        var event = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            if line.hasPrefix("event: ") { event = String(line.dropFirst(7)); continue }
            guard line.hasPrefix("data: "),
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? [String: Any]
            else { continue }
            switch event {
            case "text":
                if let d = obj["delta"] as? String { appendLog(d) }
            case "tool_use":
                if let name = obj["name"] as? String { appendLog("\n▸ \(name)\n") }
            case "error":
                throw BookAgentError(message: (obj["message"] as? String) ?? String(localized: "服务器出错"))
            case "result":
                if (obj["isError"] as? Bool) == true {
                    throw BookAgentError(message: String(localized: "agent 没跑完（\((obj["error"] as? String) ?? "unknown")）。已过稿的章节保留在书架上。"))
                }
            case "done":
                return
            default:
                break
            }
        }
    }

    private func appendLog(_ s: String) {
        log += s
        if log.count > 20000 { log = String(log.suffix(12000)) }  // keep the view light on a long run
    }
}
