import SwiftUI
import Observation
import AVFoundation

/// The 「从这段录音成文」sheet — the Share Extension's landing page for **audio**
/// shares (`ShareRouter`/`ShareRootView` route audio here, never to
/// `StyleDatasetView`'s 风格数据集 flow). Unlike that flow this doesn't collect a
/// corpus item: it uploads the shared file as a normal `VoiceDrop-*.m4a` take
/// (`RecordingName.make` — now compiled into this target, see `project.yml`)
/// and immediately kicks the miner, so sharing audio means "一步转写并成文"
/// (per the 音频例外 callout in `Share Collect.dc.html`).
struct AudioComposeView: View {
    let payload: SharePayload
    let close: () -> Void

    @State private var player = SharePlaybackController()
    @State private var fileSize: Int = 0
    @State private var uploading = false
    @State private var uploadFailed = false
    /// 写作风格 row value — starts neutral, replaced by `loadStyle()` once the
    /// user's actual style loads (never a fake placeholder; see that func).
    @State private var styleLabel = "未设置"

    /// A filename-derived title — the design's "来自 备忘录" source-app label
    /// isn't reliably available from a Share Extension, so this stands in for it.
    private var displayName: String {
        guard let url = payload.audio else { return "语音备忘录" }
        let stem = url.deletingPathExtension().lastPathComponent
        return stem.isEmpty ? "语音备忘录" : stem
    }

    /// Rough estimate shown to the user before generating: ASR ¥0.8/hr × 23
    /// 算力/¥ + ~2 算力 for the mining step, `ceil`'d, min 1 (matches the task
    /// brief's formula exactly). Falls back to a sane "2" while duration is
    /// still loading (`player.duration == 0`).
    private var costEstimate: Int {
        let hours = player.duration / 3600
        return max(1, Int((hours * 0.8 * 23).rounded(.up)) + 2)
    }

    var body: some View {
        VStack(spacing: 0) {
            grabber
            header
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    audioCard
                    settingsSection
                    costLine
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 8)
            }
            footer
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: UIScreen.main.bounds.height * 0.85)
        .background(ShareTheme.sheetBG)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 18, style: .continuous))
        .shadow(color: Color(hex: "3C301E").opacity(0.16), radius: 20, x: 0, y: -6)
        .ignoresSafeArea(edges: .bottom)
        .task {
            load()
            await loadStyle()
        }
        .onDisappear { player.stop() }
    }

    // MARK: - Header / grabber

    private var grabber: some View {
        Capsule()
            .fill(Color(hex: "DDD3C2"))
            .frame(width: 38, height: 5)
            .padding(.top, 10)
            .padding(.bottom, 2)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("从这段录音成文")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(ShareTheme.ink)
                Text("已就绪")
                    .font(.system(size: 13))
                    .foregroundStyle(ShareTheme.secondary)
            }
            Spacer(minLength: 0)
            Button(action: close) {
                Text("关闭")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(ShareTheme.secondary)
            }
            .buttonStyle(.plain)
            .disabled(uploading)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Audio card

    private var audioCard: some View {
        // Explicit per-gap top padding rather than a uniform VStack spacing:
        // the design (Share Collect.dc.html:148/151) wants icon-row→waveform
        // at 16pt but waveform→play-row at 12pt, not the same value twice.
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 13) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(hex: "E8E4EF"))
                    .frame(width: 48, height: 48)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(Color(hex: "7A6EA0"))
                    )
                VStack(alignment: .leading, spacing: 3) {
                    Text(displayName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color(hex: "2A2521"))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text("m4a · \(formatFileSize(fileSize))")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color(hex: "a79f93"))
                }
                Spacer(minLength: 0)
            }

            waveform
                .padding(.top, 16)

            HStack(spacing: 12) {
                Button(action: { player.toggle() }) {
                    Circle()
                        .fill(Color(hex: "2A2521"))
                        .frame(width: 38, height: 38)
                        .overlay(
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                        )
                }
                .buttonStyle(.plain)
                .disabled(player.loadFailed)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(hex: "EDE6D8"))
                        Capsule().fill(Color(hex: "2A2521")).frame(width: geo.size.width * player.progress)
                    }
                }
                .frame(height: 4)
                .animation(.linear(duration: 0.2), value: player.progress)

                Text(durationLabel)
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(Color(hex: "8A8175"))
                    .fixedSize()
            }
            .padding(.top, 12)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color(hex: "E8DFD0"), lineWidth: 1))
    }

    /// A fixed sequence of bar heights (v1 placeholder — matches the design's
    /// `.dc.html` static mock, no real sample analysis) rather than a live
    /// waveform derived from the audio samples.
    private var waveform: some View {
        HStack(spacing: 2) {
            ForEach(Array(Self.waveformHeights.enumerated()), id: \.offset) { _, h in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color(hex: "E8DFCF"))
                    .frame(height: 44 * h)
            }
        }
        .frame(height: 44, alignment: .bottom)
    }

    private static let waveformHeights: [CGFloat] = [
        0.30, 0.55, 0.40, 0.75, 0.60, 0.90, 0.50, 0.70, 0.35, 0.80,
        0.45, 0.65, 0.55, 0.85, 0.40, 0.60, 0.30, 0.70,
    ]

    /// Elapsed time whenever there's progress to show — playing OR paused
    /// mid-track (so the label stays consistent with the progress bar, which
    /// also freezes at the paused position rather than resetting). Total
    /// duration only at the very start, before playback has begun.
    private var durationLabel: String {
        player.progress > 0 ? formatDuration(player.progress * player.duration) : formatDuration(player.duration)
    }

    // MARK: - 生成设置

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("生成设置")
                .font(.system(size: 13, weight: .semibold))
                .tracking(1)
                .foregroundStyle(Color(hex: "a79f93"))
                .padding(.top, 20)
                .padding(.bottom, 8)
                .padding(.horizontal, 6)

            VStack(spacing: 0) {
                settingsRow(title: "写作风格", value: styleLabel)
                Rectangle().fill(Color(hex: "F0E8DA")).frame(height: 1)
                settingsRow(title: "识别语言", value: "中文（自动）")
            }
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Color(hex: "ECE3D5"), lineWidth: 1))
        }
    }

    /// Read-only display row — a static label + chevron, no picker (v1; see
    /// task brief). 写作风格's `value` is the user's real style label, fetched by
    /// `loadStyle()`; 识别语言 stays a fixed literal.
    private func settingsRow(title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 15))
                .foregroundStyle(Color(hex: "2A2521"))
            Spacer(minLength: 0)
            Text(value)
                .font(.system(size: 13.5))
                .foregroundStyle(Color(hex: "8A8175"))
                .lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(hex: "CFC6B6"))
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 14)
    }

    // MARK: - Cost line

    private var costLine: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color(hex: "C98A2E"))
                .padding(.top, 1)
            (
                Text("预计消耗约 ")
                    .foregroundStyle(Color(hex: "a79f93"))
                + Text("\(costEstimate) 算力")
                    .fontWeight(.semibold)
                    .foregroundStyle(Color(hex: "C98A2E"))
                + Text(" · 转写 + 成文一步完成")
                    .foregroundStyle(Color(hex: "a79f93"))
            )
            .font(.system(size: 12.5))
        }
        .padding(.top, 12)
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            if uploadFailed {
                Text("上传失败，请重试")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color(hex: "C0682E"))
                    .padding(.bottom, 8)
            }
            Button(action: { Task { await generate() } }) {
                HStack(spacing: 8) {
                    if uploading {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "doc.text")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    Text("开始生成文章")
                        .font(.system(size: 16.5, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color(hex: "D8593B")))
                .shadow(color: Color(hex: "D8593B").opacity(0.28), radius: 10, x: 0, y: 4)
            }
            .buttonStyle(.plain)
            .disabled(uploading || payload.audio == nil)
            .opacity((uploading || payload.audio == nil) ? 0.7 : 1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 30)
        .background(ShareTheme.sheetBG)
        .overlay(alignment: .top) { Rectangle().fill(Color(hex: "EFE7D9")).frame(height: 1) }
    }

    // MARK: - Actions

    private func load() {
        guard let url = payload.audio else { return }
        player.load(url)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), let size = attrs[.size] as? Int {
            fileSize = size
        }
    }

    /// Fetch the user's current 写作风格 and derive the 写作风格 row's label: the
    /// first non-empty line, truncated to ~12 characters + `…` (mirrors
    /// `VoiceDropApp/SettingsView.swift`'s `StyleNaming.name`, not shared into
    /// this target). Leaves `styleLabel` at its neutral "未设置" default — never
    /// a fake placeholder — when there's no style yet or the fetch fails.
    private func loadStyle() async {
        guard let text = await ShareAPI.fetchStyleText() else { return }
        let line = text.split(whereSeparator: \.isNewline).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !line.isEmpty else { return }
        styleLabel = line.count > 12 ? String(line.prefix(12)) + "…" : line
    }

    /// 「开始生成文章」— upload the shared file as a recording-style take, kick
    /// the miner, then close. Never closes on failure (no false success); the
    /// button re-enables with an inline error so the user can retry.
    private func generate() async {
        guard let audioURL = payload.audio, !uploading else { return }
        uploading = true
        uploadFailed = false
        let name = RecordingName.make(start: Date(), duration: player.duration, place: nil)
        let ok = await ShareAPI.putFile(audioURL, name: name, contentType: "audio/mp4")
        guard ok else {
            uploading = false
            uploadFailed = true
            return
        }
        await ShareAPI.triggerMine()
        close()
    }
}

// MARK: - Playback controller

/// Mirrors `VoiceDropApp/Library.swift`'s `AudioPlayer` (same `@MainActor
/// @Observable` + `nonisolated` delegate-hop-to-main-actor pattern under Swift 6
/// strict concurrency) — kept local to this file since the app target isn't
/// compiled into the extension.
@MainActor
@Observable
private final class SharePlaybackController: NSObject, AVAudioPlayerDelegate {
    var isPlaying = false
    var progress: Double = 0   // 0...1
    var duration: TimeInterval = 0
    var loadFailed = false

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func load(_ url: URL) {
        stop()
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        let p = try? AVAudioPlayer(contentsOf: url)
        player = p
        p?.delegate = self
        p?.prepareToPlay()
        duration = p?.duration ?? 0
        loadFailed = (p == nil)
    }

    func toggle() {
        guard let player else { return }
        if player.isPlaying {
            player.pause(); isPlaying = false; timer?.invalidate()
        } else {
            player.play(); isPlaying = true; startTimer()
        }
    }

    func stop() {
        player?.stop(); player = nil
        isPlaying = false; progress = 0; timer?.invalidate()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.player, p.duration > 0 else { return }
                self.progress = p.currentTime / p.duration
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.isPlaying = false; self.progress = 0; self.timer?.invalidate() }
    }
}

// MARK: - Formatting helpers

private func formatFileSize(_ bytes: Int) -> String {
    guard bytes > 0 else { return "0 KB" }
    let mb = Double(bytes) / 1_000_000
    if mb >= 1 { return String(format: "%.1f MB", mb) }
    let kb = max(1, Double(bytes) / 1_000)
    return String(format: "%.0f KB", kb)
}

private func formatDuration(_ t: TimeInterval) -> String {
    guard t.isFinite, t >= 0 else { return "00:00" }
    let total = Int(t.rounded())
    return String(format: "%02d:%02d", total / 60, total % 60)
}
