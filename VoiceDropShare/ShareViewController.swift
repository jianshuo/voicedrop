import UIKit
import SwiftUI

/// The system share-sheet entry point. Accepts links / text / images / files
/// shared from any app (WeChat article links, Safari pages, Files documents,
/// Photos) and hands off to a custom SwiftUI UI (`ShareRootView`) hosted in a
/// plain `UIHostingController` — no more `SLComposeServiceViewController`
/// single-row 用途 picker. `ShareRouter.classify` decides which of the three
/// sheets (音频 / 图片 / 风格语料) to show; the sheet itself drives the upload.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let kind = ShareRouter.classify(items)
        let ctx = extensionContext
        let finish: () -> Void = {
            ctx?.completeRequest(returningItems: [], completionHandler: nil)
        }
        // After 生成文章 (audio / image sheets), open the host app to 我的录音 so the
        // user can watch mining progress. Uses the official NSExtensionContext.open
        // (voicedrop:// scheme); whether iOS actually foregrounds the app from a
        // share extension varies by version, so we always completeRequest too.
        let openApp: () -> Void = {
            guard let ctx, let url = URL(string: "voicedrop://recordings") else {
                ctx?.completeRequest(returningItems: [], completionHandler: nil); return
            }
            ctx.open(url) { _ in
                ctx.completeRequest(returningItems: [], completionHandler: nil)
            }
        }
        let root = ShareRootView(items: items, kind: kind, close: finish, openApp: openApp)
        let host = UIHostingController(rootView: root)
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }
}
