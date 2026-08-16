import SwiftUI

@main
struct VoiceDropApp: App {
    @StateObject private var router = AppRouter.shared   // shared so App Intents (开始录音) can reach it
    // APNs 注册 + device token 上传（「文章已生成」推送 / 运维报警都靠它）。
    @UIApplicationDelegateAdaptor(PushRegistrar.self) private var pushRegistrar

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
                // 订阅：挂 Transaction.updates 监听 + 把当前有效订阅逐笔 claim
                // （服务端幂等）——续费到账不依赖用户打开算力页。
                .task { StoreService.shared.start() }
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
}
