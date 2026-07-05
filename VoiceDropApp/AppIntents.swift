import AppIntents

/// App Intents 入口：目前只有「开始录音（可选带标签）」这一个动作，注册为
/// App Shortcut 后可绑到操作按钮（Action Button）、锁屏 Widget、Siri 短语和
/// Shortcuts 自动化。带标签时挖出的文章缺省归入该标签（复用 tag 页录音的
/// .tags 侧车管线——见 RecordSession.defaultTag）。

// MARK: - 标签实体（Shortcuts 参数选择器里的候选）

/// Shortcuts 的标签下拉候选来自本地缓存（LibraryView 每次算出 allTags 顺手
/// 写入 UserDefaults）——intent 配置界面可能在 App 冷启动前打开，不能等网络。
/// 缓存最多滞后一次列表加载，且用户手输新标签同样有效（id 就是标签文字）。
enum CachedTags {
    static let key = "appintents.cachedTags"
    static func load() -> [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }
    static func save(_ tags: [String]) { UserDefaults.standard.set(tags, forKey: key) }
}

struct TagEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "标签")
    static let defaultQuery = TagQuery()

    /// id 就是标签文字本身（服务端的 tag 没有独立 id）。
    var id: String
    var displayRepresentation: DisplayRepresentation { .init(title: "\(id)") }
}

struct TagQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [TagEntity] {
        identifiers.map(TagEntity.init(id:))
    }
    func entities(matching string: String) async throws -> [TagEntity] {
        // 自由输入也接受：没缓存命中就把输入本身当标签（新标签会在成文时创建）。
        let hits = CachedTags.load().filter { $0.localizedCaseInsensitiveContains(string) }
        return (hits.isEmpty ? [string] : hits).map(TagEntity.init(id:))
    }
    func suggestedEntities() async throws -> [TagEntity] {
        CachedTags.load().map(TagEntity.init(id:))
    }
}

// MARK: - 开始录音

struct StartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "开始录音"
    static let description = IntentDescription(
        "打开 VoiceDrop 直接开始录音。可选一个标签，这条录音挖出的文章会自动归入该标签页。")
    /// 录音必须前台（麦克风 + 录音全屏页），所以这是个 open-app intent。
    static let openAppWhenRun = true

    @Parameter(title: "标签")
    var tag: TagEntity?

    @MainActor
    func perform() async throws -> some IntentResult {
        // 和 voicedrop://record?tag=… 完全同一条路：LibraryView 收到后清掉任何
        // 压栈的详情页并弹出全屏录音（见 AppRouter 注释）。
        AppRouter.shared.pending = .record(tag: tag?.id)
        return .result()
    }
}

// MARK: - App Shortcuts（Siri 短语 / 操作按钮 / Spotlight）

struct VoiceDropShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: [
                "用 \(.applicationName) 记一条",
                "\(.applicationName) 记一条",
                "用 \(.applicationName) 记一条 \(\.$tag)",
                "开始 \(.applicationName) 录音",
            ],
            shortTitle: "记一条",
            systemImageName: "mic.fill"
        )
    }
}
