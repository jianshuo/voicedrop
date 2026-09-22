import SwiftUI
import StoreKit

@main
struct VoiceDropApp: App {
    @StateObject private var router = AppRouter.shared   // shared so App Intents (开始录音) can reach it
    // APNs 注册 + device token 上传（「文章已生成」推送 / 运维报警都靠它）。
    @UIApplicationDelegateAdaptor(PushRegistrar.self) private var pushRegistrar
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Analytics.setup()
        WeChatShare.register()   // 微信 OpenSDK：分享书到好友/朋友圈
        // 后台上传通道尽早就位：上一条命没送完的录音任务由系统接管着，
        // delegate 建好才收得到它们的完成事件（删本地文件/埋点收尾）。
        BackgroundTransfer.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(router)
                // App 内点到自家链接（文章正文 markdown 里的书链接 / 分享链接 / Link 视图）：
                // 默认 openURL 是 UIApplication.open，而这些 universal link 归 App 自己，
                // iOS 不会回拉起自己 → 直接跳 Safari.app。凡 AppRouter 认识的都走路由
                // （书 → 阅读器，分享 id → 原生页，其余 → 站内 Safari），不认识的才交给系统。
                .environment(\.openURL, OpenURLAction { url in
                    guard AppRouter.universalLink(url) != nil else { return .systemAction }
                    router.handle(url)
                    return .handled
                })
                // 订阅：挂 Transaction.updates 监听 + 把当前有效订阅逐笔 claim
                // （服务端幂等）——续费到账不依赖用户打开算力页。
                .task { StoreService.shared.start() }
                // staging 残片兜底：完好的（promote 窗口内被杀）救回上传队列，
                // 半截的（录音中被杀，无 moov）删掉。见 AudioRecorder.recoverStaleStaging。
                .task { await AudioRecorder.recoverStaleStaging() }
                // 线路 = App Store 商店区域：中国区 → voicedrop.cn（EO），
                // 其他区 → 直连 CF。启动取一次 Storefront 即可（区域几乎不变）。
                .task { await Self.noteStorefront() }
                .onOpenURL { url in
                    // 微信 SDK 回调（wx…:// 兜底通道）优先；不是微信的才走深链路由
                    if WeChatShare.handle(url) { return }
                    router.handle(url)   // voicedrop://<page> + universal links — see AppRouter/DeepLink
                }
                #if DEBUG
                // Simulator screenshot rig: SIMCTL_CHILD_VD_OPEN_URL=voicedrop://…
                // navigates in-app on launch, skipping the SpringBoard openurl
                // confirmation dialog simctl can't tap. DEBUG-only.
                .task {
                    if let s = ProcessInfo.processInfo.environment["VD_OPEN_URL"],
                       let u = URL(string: s) {
                        try? await Task.sleep(for: .seconds(12))
                        router.handle(u)
                    }
                }
                #endif
                // Universal links (https://voicedrop.cn/…) arrive as an NSUserActivity;
                // some iOS versions deliver ONLY here, not via onOpenURL. Same handler.
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    // 微信分享回执经 universal link 回跳（主通道），SDK 认领就不进路由
                    if WeChatShare.handle(activity) { return }
                    if let url = activity.webpageURL { router.handle(url) }
                }
        }
    }

    /// 商店区域上报（决定线路：中国区 voicedrop.cn，其他区直连 CF——见 APIRoute）。
    /// 埋点只送区域码，符合隐私红线；顺手可统计各区用户分布。
    private static func noteStorefront() async {
        guard let sf = await Storefront.current else { return }
        APIRoute.noteStorefront(sf.countryCode)
        Analytics.capture("商店区域", ["区域": sf.countryCode,
                                     "线路": APIRoute.currentHost == API.cnHost ? "cn" : "cf"])
    }
}
