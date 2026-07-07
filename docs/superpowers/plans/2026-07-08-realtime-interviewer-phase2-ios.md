# Realtime AI 采访员 · Phase 2（iOS 原生）Implementation Plan

> **执行模型不同于 Phase 1**：这是原生 iOS，**没有可在此环境运行的单元测试**。每个任务的验证是「在 Xcode build + 真机手测清单」，由王建硕在其 Xcode/TestFlight 环执行。Claude 写 Swift（复用现有骨架），逐任务在真机 compile-iterate。**不要用 subagent-driven-TDD / vitest**——没东西可跑。

**Goal:** 在 VoiceDrop 录音屏红键左边加隐蔽触发；按下后照常录音 + 同时用 WebSocket 接通 `gpt-realtime-2.1` 当媒体采访员（≥5s 停顿 + 限流才用 <5s 追问帮说话人续说），录音绝不被打断、照常保存上传，会话按官方费率计费。后端（`/agent/realtime/session`、`/agent/realtime/usage`）Phase 1 已上线。

**Architecture:** **两套录音后端，默认那套不动**——不按 realtime 触发走现有 `AVAudioRecorder`（零改动）；按了才切 `AVAudioEngine` 单采集 tee（引擎写同款 `.m4a` + 同一路 PCM 喂 AI + AEC，AI 音频 `AVAudioPlayerNode` 外放）。app 直连 OpenAI realtime WS，用 `/agent/realtime/session` 下发的临时 `ek_` 凭证鉴权（`OPENAI_API_KEY` 不上设备）。停顿判定/限流在 app 端（`response.create`）。

**Tech Stack:** SwiftUI + `AVAudioEngine`/`AVAudioFile`/`AVAudioPlayerNode` + `URLSessionWebSocketTask`。复用 `VoiceEdit.swift`（engine tap + 手写重采样）、`StatusSession.swift`/`AgentSession.swift`（WS 骨架）、`AuthStore.shared.bearer` + `req.setBearer`。

## Global Constraints

- **默认录音神圣不动**：不接 AI 的普通录音继续走 `AudioRecorder`(`AVAudioRecorder`)现有代码，一行不改。引擎后端只在 realtime 模式实例化。
- **输出契约一致**：引擎后端产出与 `AudioRecorder` 相同的 staging `recording-<ts>.m4a`（AAC mono，`Prefs.recorderSettings` 同款：16k/std 或 24k/high）→ 相同 `promote`→上传流程。不改 `RecordingPromoter`/`Uploader`。
- **录音写入 = 最高优先级、独立于 realtime**：tap 回调里先写文件，再（best-effort）喂 AI；realtime 任何错误只静默降级，录音继续。
- **连接（2026-07-08 纠正为中转，已线上验证）**：手机**只连自家中转** `wss://jianshuo.dev/agent/realtime/relay`（`enum API.agentWS` = `wss://jianshuo.dev/agent`，append `/realtime/relay`），握手头 `req.setBearer(AuthStore.shared.bearer)`——**和 `StatusSession` 一模一样**。**不连 OpenAI、无临时凭证、无 `session.update`（worker 已注入）**。手机连不了 api.openai.com，中转是唯一可行路径；worker 侧已线上验证连通+双向转发+计费。
- **音频格式**：realtime in/out = pcm16 **24kHz mono**。引擎输入（设备原生常 48k）→ 手写重采样到 24k Int16（抄 `VoiceEdit.convertToMono16kPCM`，目标 16000→24000），发 `input_audio_buffer.append`（base64）；AI 音频事件 = **`response.output_audio.delta`**（线上核实过），24k Int16 → `AVAudioPlayerNode` 播放。
- **计费**：**app 完全不管**——中转在服务端看穿过的 `response.done.usage` 累加、连接关闭时扣算力（Phase 1 已线上验证：1 次会话入账 `AI 采访` 条目）。app 不发 usage、不算钱。
- **AEC**：`engine.inputNode.setVoiceProcessingEnabled(true)`（外放 + 回声消除，用户定）。已知代价：录音音色被 AEC/AGC/NS 改变（用户已接受）。
- **采访员 instructions / turn_detection**：worker 连上 OpenAI 时**已注入** `session.update`（server_vad `create_response:false` + 采访员 instructions）。app 端只按 `input_audio_buffer.speech_started/stopped` 计时 + 限流发 `response.create`（经中转）。app **不需**再 session.update。
- **git**：voicedrop 仓库自己的 main，验证后直接提交（用户惯例）。每任务一 commit。
- **验证**：全部在真机手测（见每任务「真机验证」清单）。Claude 无法 build iOS。

## 文件结构

- Create `VoiceDropApp/RealtimeSession.swift` — **中转** WS 客户端（连 `/agent/realtime/relay`，`setBearer`；发 `input_audio_buffer.append`/`response.create`/`response.cancel`；收 `speech_started/stopped`+`response.output_audio.delta`）。纯传输，回调暴露给上层。**不连 OpenAI、不管计费、不发 session.update**。
- Create `VoiceDropApp/EngineRecorder.swift` — `AVAudioEngine` 录音后端：tap→写 `.m4a`(AVAudioFile) + 暴露 24k PCM 回调 + AEC + `AVAudioPlayerNode` 播 AI；产出 `AudioRecorder.Recording`。
- Create `VoiceDropApp/RealtimeInterviewer.swift` — 编排：EngineRecorder PCM → RealtimeSession；RealtimeSession 音频 → EngineRecorder 播放；停顿计时+限流。**无 usage 上报**（服务端中转计费）。
- Modify `VoiceDropApp/RecordSession.swift` — 左侧隐蔽触发 + realtime 模式切换到 EngineRecorder/RealtimeInterviewer；停止仍走 `promote`。
- 可选 Create `VoiceDropApp/RecordingBackend.swift` — 协议，`AudioRecorder` 与 `EngineRecorder` 都遵守，RecordSession 透明切换。

---

### Task 1: `RealtimeSession.swift` — 中转 WS 客户端（先不接音频）

连自家中转 `/agent/realtime/relay`、收到 OpenAI 事件（经中转），验证链路，**不碰音频/录音**。比原设计简单得多：**无 mint、无 OpenAI 直连、无 session.update**（worker 已注入），鉴权就是 `setBearer`。Phase 1 中转已线上验证（101→session.created→session.updated→AI 音频→计费入账）。

**Files:** Create `VoiceDropApp/RealtimeSession.swift`

**复用**：连接/收循环/重连**直接抄 `StatusSession.swift:28-106`**（一模一样的 `wss://jianshuo.dev/agent/...` + `req.setBearer`）；事件分派用 `JSONSerialization` dict + `obj["type"]`（同 `AgentSession`）。

**起始实现（compile-iterate）：**
```swift
import Foundation

// 连自家 Cloudflare 中转（/agent/realtime/relay），worker 在边缘转发到 OpenAI。
// 手机不碰 OpenAI 凭证；OPENAI_API_KEY 全在 worker。事件经中转透传。
@MainActor
final class RealtimeSession {
    var onAudioDelta: ((Data) -> Void)?     // response.output_audio.delta 解码后的 PCM16(24k)
    var onSpeechStarted: (() -> Void)?
    var onSpeechStopped: (() -> Void)?
    var onStateChange: ((String) -> Void)?  // "connecting"/"live"/"degraded"

    private var task: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var closed = false

    func connect() {
        closed = false
        onStateChange?("connecting")
        let token = AuthStore.shared.bearer
        guard !token.isEmpty, let url = URL(string: "\(API.agentWS)/realtime/relay") else { return }
        var req = URLRequest(url: url)
        req.setBearer(token)                                  // 握手头，和 StatusSession 一样
        let s = URLSession(configuration: .default); urlSession = s
        let t = s.webSocketTask(with: req); task = t; t.resume()
        receive()
        onStateChange?("live")
    }

    private func receive() {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                switch result {
                case .failure: self.onStateChange?("degraded")    // 中转/网络断：录音继续（上层保证）
                case .success(let msg):
                    if case .string(let str) = msg { self.handle(str) }
                    if case .data(let d) = msg, let str = String(data: d, encoding: .utf8) { self.handle(str) }
                    self.receive()
                }
            }
        }
    }

    private func handle(_ str: String) {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(str.utf8))) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "input_audio_buffer.speech_started": onSpeechStarted?()
        case "input_audio_buffer.speech_stopped": onSpeechStopped?()
        case "response.output_audio.delta":       // 线上核实过的 AI 音频事件名
            if let b64 = obj["delta"] as? String, let d = Data(base64Encoded: b64) { onAudioDelta?(d) }
        default: break   // 首连时把 default 打日志核实其它事件名
        }
    }

    func appendAudio(_ pcm16le24k: Data) { send(["type": "input_audio_buffer.append", "audio": pcm16le24k.base64EncodedString()]) }
    func createResponse(maxTokens: Int = 120) { send(["type": "response.create", "response": ["max_output_tokens": maxTokens]]) }
    func cancelResponse() { send(["type": "response.cancel"]) }

    private func send(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: d, encoding: .utf8) else { return }
        task?.send(.string(s)) { _ in }
    }

    func disconnect() { closed = true; task?.cancel(with: .goingAway, reason: nil); task = nil; urlSession?.invalidateAndCancel(); urlSession = nil }
}
```

**真机验证：**
- [ ] build 通过；临时按钮 `session.connect()`，`onStateChange` 到 `"live"`。
- [ ] `handle` 的 `default` 分支打印所有 `type`——确认经中转收到 `session.created`/`session.updated`（worker 注入的 config）等。
- [ ] 断网 → `onStateChange("degraded")`，不崩。

- [ ] **Commit** `feat(realtime-ios): RealtimeSession 中转 WS 客户端（连通+事件，未接音频）`

---

### Task 2: `EngineRecorder.swift` — AVAudioEngine 录音后端（**先不接 AI**，最险一步单独验）

用 `AVAudioEngine` 录出与 `AVAudioRecorder` **等价的 `.m4a`**。这是唯一动录音写入的地方，必须先在真机证明等价、无爆音，再往后接 AI。

**Files:** Create `VoiceDropApp/EngineRecorder.swift`（+ 可选 `RecordingBackend.swift` 协议）

**复用**：engine/tap 起停抄 `VoiceEdit.swift:203-241`；`Recording` 结构 + staging 命名 + 中断处理抄 `AudioRecorder.swift`（同款 `stagingURL`/`startDate`/`onInterrupted`/`Prefs.recorderSettings`/权限）。

**起始实现要点：**
- `engine.inputNode.installTap(onBus:0, bufferSize:4096, format: inputFormat)`，回调里 `try? audioFile.write(from: buffer)`（**先写文件，最高优先级**）。
- `audioFile = try AVAudioFile(forWriting: stagingURL, settings: Prefs.shared.recorderSettings)`（AAC mono，与 AVAudioRecorder 同 settings → 同款 `.m4a`）。
- `elapsed`/`level`（从 buffer 算 RMS→dB，喂现有波形 UI；对齐 `AudioRecorder.level` 语义）。
- AudioSession：`setCategory(.playAndRecord, mode: .default, options: [.duckOthers])`（先不开 AEC，Task 3 再开），`setActive(true)`。
- `stop()` → `engine.stop()` + `removeTap` + close file → 返回 `AudioRecorder.Recording(url:start:duration:)`。
- 遵守共享协议 `RecordingBackend`（`start()`/`stop()->Recording?`/`elapsed`/`level`/`isRecording`/`onInterrupted`），让 `AudioRecorder` 也遵守（加 conformance，不改其实现）。

**真机验证（THE 风险闸）：**
- [ ] 用 EngineRecorder 录一段 → 生成的 `recording-<ts>.m4a` 能在「文件」/播放器正常播放，时长/音质与今天 `AVAudioRecorder` 一致。
- [ ] 走完整流程：录 → `promote` → 上传 → 服务端挖矿成文正常（证明格式被下游接受）。
- [ ] 无爆音/断音/丢头（对比 AVAudioRecorder 录同样内容）。
- [ ] 来电中断（`interruptionNotification`）→ 正确 finalize、文件可播（对齐 `AudioRecorder.handleInterruption`）。
- [ ] 后台/锁屏继续录（若现状支持）。
- [ ] **默认路径回归**：确认普通录音（不经 realtime）仍用 `AudioRecorder`、完全不受影响。

- [ ] **Commit** `feat(realtime-ios): EngineRecorder（AVAudioEngine 录同款 m4a，未接 AI）`

---

### Task 3: Tee + AEC + AI 回放（`EngineRecorder` 出 PCM/播放 + `RealtimeInterviewer` 接线）

给 EngineRecorder 开 AEC、暴露 24k PCM 回调、加 `AVAudioPlayerNode` 播 AI；`RealtimeInterviewer` 把两头接上。

**Files:** Create `VoiceDropApp/RealtimeInterviewer.swift`；Modify `EngineRecorder.swift`

**要点：**
- EngineRecorder：`engine.inputNode.setVoiceProcessingEnabled(true)`（AEC，Task 2 的 AudioSession 已 `.playAndRecord`）。
- tap 回调里：(a) 写文件；(b) `let pcm = convertToMono24kInt16(buffer)`（抄 `VoiceEdit.convertToMono16kPCM`，目标改 24000）→ `onPCM?(pcm)`。
- 加 `playerNode: AVAudioPlayerNode` 挂到 `engine.mainMixerNode`；`func playAI(_ pcm16le24k: Data)`：把 Int16 24k 转成 `AVAudioPCMBuffer`（engine 输出格式）→ `playerNode.scheduleBuffer` → `playerNode.play()`。
- `RealtimeInterviewer`：`start()` → `EngineRecorder.start()` + `RealtimeSession.mint()`+`connect`；`recorder.onPCM = { session.appendAudio($0) }`；`session.onAudioDelta = { recorder.playAI($0) }`。realtime 失败只降级，录音继续。

**真机验证：**
- [ ] 说话时 AI 能「听到」（`response.done` 有内容 / 手动 `createResponse()` 让它复述验证链路通）。
- [ ] **AI 外放的声音不进录音文件**（AEC 生效）：放一段 AI 语音，回放录音确认干净、只有说话人。
- [ ] 录音仍完整、无爆音（AEC 开启后再验一遍 Task 2 的等价性）。
- [ ] realtime 断开 → AI 静默、录音继续无感。

- [ ] **Commit** `feat(realtime-ios): 引擎 PCM→AI + AI→AVAudioPlayerNode 回放 + AEC`

---

### Task 4: 停顿逻辑 + 限流（`RealtimeInterviewer`）

AI 平时静音旁听；程序判定 ≥5s 停顿 + 限流才 `response.create`；说话人续说即掐断。

**Files:** Modify `VoiceDropApp/RealtimeInterviewer.swift`

**要点（常量真机可调）：**
- `session.onSpeechStopped = { startSilenceTimer() }`；`onSpeechStarted = { cancelSilenceTimer(); if aiSpeaking { session.cancelResponse() }; hadNewSpeech = true }`。
- `startSilenceTimer`：5s 后触发；触发时若 `hadNewSpeech && now - lastAsk >= MIN_GAP(20s)` → `session.createResponse(maxTokens: 120)`；置 `lastAsk=now`、`hadNewSpeech=false`。
- `aiSpeaking`：`response.created`→true、`response.done`→false（收 audio delta 期间为 true）。
- 追问长度：`createResponse(maxTokens:120)` + mint 时 instructions 已限「一句、<5秒」。

**真机验证：**
- [ ] 连续说话时 AI 不插话；停 ≥5s 才出现一句简短追问。
- [ ] 停顿 <5s 不追问；两次追问间隔 < MIN_GAP 不重复问。
- [ ] AI 正说话时你一开口 → AI 立刻停（`response.cancel`）。
- [ ] 追问确实短（<5s），扣住刚说的内容。

- [ ] **Commit** `feat(realtime-ios): ≥5s 停顿+限流触发追问 + 抢话掐断`

---

### Task 5: 列表页红键旁隐蔽触发 + 开始即定后端（`LibraryView.swift` + `RecordSession.swift`）

**触发在列表页那个大红录音键旁边**（不在录音屏内），因为红键的手势已满（tap=录音 / 长按=口述 / 长按上滑=取消）。**点隐蔽区 = 以 realtime 模式拉起录音屏**，`AVAudioEngine` 从 t=0 就跑；普通红键 tap → `AVAudioRecorder` 照旧。**后端在开始那一刻定死，全程无切换、无缝**（这解决了「切换断音」——不存在中途切换）。

**Files:** Modify `VoiceDropApp/LibraryView.swift`（红键 `redCircle` :559 旁加隐蔽触发 + `showRecord`/`RecordSession` 加 `realtime` 参数）、`VoiceDropApp/RecordSession.swift`（`.task` 里按 `realtime` 选后端）。

**要点：**
- `LibraryView.swift`：在红键 `recordButton` 附近放一个低调隐蔽区（`Image(systemName:"waveform.and.mic")` 或 `"ear"`，`Color(hex:"A89E8E")`@0.45 + label「AI 采访」`Color(hex:"C2B8A8")`），点它置 `recordRealtime = true` 再 `showRecord = true`；普通红键 tap 保持 `recordRealtime = false`。
- `RecordSession` 加 `var realtime = false`。`.task` 里 `start` 按它选后端：`realtime ? interviewer.start() : recorder.start()`；`recordingScreen` 的 `elapsed`/`level`/`waveform` 从共享协议 `RecordingBackend` 取（两后端都遵守）。**录音屏内不再有 realtime 触发**（避免中途切换）。
- realtime 模式顶部加状态小指示：连接中/已接通/**降级（realtime 挂但录音继续）**（复用 Theme 色，读 `RealtimeSession.onStateChange`）。
- `stop()`：两后端都返回 `Recording` → 同一个 `promote(take)`（不变）；realtime 额外 `interviewer.stop()`（`disconnect`，中转侧自动结算计费）。

**真机验证：**
- [ ] 普通红键 tap = 和今天完全一样的录音（默认路径回归，`AVAudioRecorder` 未受影响）。
- [ ] 点隐蔽区 → 录音屏以引擎模式开，**从头一路无缝** + AI 接通；停止 → 录音照常 promote+上传，AI 断开、中转结算。
- [ ] 隐蔽区不误触红键的 tap/长按手势。

- [ ] **Commit** `feat(realtime-ios): 列表页红键旁隐蔽触发 + 开始即定后端（无切换）`

### Task 6:（已删除）会话计费——**服务端中转已做，app 不管**

原计划的「app 上报 usage 计费」在中转架构下**取消**：worker 中转在服务端看穿过的 `response.done.usage` 累加、连接关闭时扣算力（Phase 1 已线上验证入账 `AI 采访` 条目）。app 端**无需**任何计费代码。停止会话只需 `interviewer.stop()` → `RealtimeSession.disconnect()`，中转侧自动结算。

## Self-Review

- **Spec coverage**：隐蔽触发+录音同时接 AI（Task 5）✓；录音不被打断/两后端默认不动（Task 2/5，Global Constraints）✓；WS+ek 凭证/key 不上设备（Task 1）✓；AEC 外放（Task 3）✓；≥5s+限流追问（Task 4）✓；官方费率计费（Task 6→Phase 1 后端）✓；保存上传不变（Task 2/5 复用 promote）✓。
- **Placeholder scan**：无 TODO。多处「真机核实/回填」（WS 鉴权机制、audio delta 事件名、usage 字段结构）是**外部 API 的真实未知**，只能真机首连时确定——已明确标为验证步骤 + 回填点，非偷懒占位。
- **风险排序**：Task 2（引擎录音等价）是最高风险且不可在此验——单独隔离、默认路径完全不动做兜底。Task 1 的 OpenAI WS 鉴权/事件名是外部未知——第一步就核实，避免后面返工。
- **执行现实**：全部代码是「真机 compile-iterate 起点」，非即可运行成品；Claude 无法 build iOS。逐任务在真机验证清单过关后再进下一任务。
