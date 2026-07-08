import SwiftUI

@main
struct VoiceDropApp: App {
    @StateObject private var router = AppRouter.shared   // shared so App Intents (开始录音) can reach it
    // APNs 注册 + device token 上传（「文章已生成」推送 / 运维报警都靠它）。
    @UIApplicationDelegateAdaptor(PushRegistrar.self) private var pushRegistrar

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(router)
                .onOpenURL { router.handle($0) }   // voicedrop://<page> — see AppRouter/DeepLink
        }
    }
}
