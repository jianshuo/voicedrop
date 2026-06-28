import Social
import UIKit
import UniformTypeIdentifiers

/// The system share-sheet entry point. Accepts links / text / images / files
/// shared from any app (WeChat article links, Safari pages, Files documents,
/// Photos) and PUTs them to the same R2 inbox the in-app `Uploader` uses.
///
/// One sheet, two destinations: the user picks 用途 — 挖文章 (mine) or 训练风格
/// (style) — which only changes the uploaded filename prefix
/// (`VoiceDrop-mine-*` / `VoiceDrop-style-*`). The server routes on that prefix.
final class ShareViewController: SLComposeServiceViewController {

    /// What the shared item is for. The raw value is the user-facing label; the
    /// slug is what gets baked into the filename for the server to route on.
    enum Intent: String, CaseIterable {
        case mine = "挖文章"
        case style = "训练风格"
        var slug: String { self == .mine ? "mine" : "style" }
    }

    /// Defaults to 挖文章; `presentationAnimationDidFinish` may flip it to 训练风格
    /// when the attachment looks like a link or a Word/PDF document.
    private var intent: Intent = .mine

    override func viewDidLoad() {
        super.viewDidLoad()
        placeholder = "加点备注（可选）"
    }

    override func isContentValid() -> Bool { true }

    /// Smart default: a web link or a Word/PDF file is almost always 训练风格;
    /// audio / images / plain text default to 挖文章.
    override func presentationAnimationDidFinish() {
        super.presentationAnimationDidFinish()
        if firstAttachmentSuggestsStyle() {
            intent = .style
            reloadConfigurationItems()
        }
    }

    // MARK: - 用途 picker row

    override func configurationItems() -> [Any]! {
        guard let row = SLComposeSheetConfigurationItem() else { return [] }
        row.title = "用途"
        row.value = intent.rawValue
        row.tapHandler = { [weak self] in
            guard let self else { return }
            let picker = IntentPicker(current: self.intent) { [weak self] picked in
                guard let self else { return }
                self.intent = picked
                self.reloadConfigurationItems()
                self.popConfigurationViewController()
            }
            self.pushConfigurationViewController(picker)
        }
        return [row]
    }

    // MARK: - Post

    override func didSelectPost() {
        let note = contentText ?? ""
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        let chosen = intent
        Task {
            for (i, p) in providers.enumerated() {
                await uploadAttachment(p, index: i, intent: chosen, note: note)
            }
            // A note typed with no attachment is still worth keeping.
            if providers.isEmpty, !note.isEmpty {
                await uploadText(note, index: 0, intent: chosen)
            }
            extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        }
    }

    // MARK: - Attachment routing

    private func firstAttachmentSuggestsStyle() -> Bool {
        guard let p = (extensionContext?.inputItems as? [NSExtensionItem])?
            .first?.attachments?.first else { return false }
        // A web link (URL that is NOT a file URL) → 训练风格.
        if p.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           !p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            return true
        }
        // A Word / PDF document → 训练风格.
        for id in ["org.openxmlformats.wordprocessingml.document",
                   "com.microsoft.word.doc", UTType.pdf.identifier] {
            if p.hasItemConformingToTypeIdentifier(id) { return true }
        }
        return false
    }

    private func uploadAttachment(_ p: NSItemProvider, index: Int,
                                  intent: Intent, note: String) async {
        // 1) Web link → upload the URL (plus the note) as text.
        if p.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           !p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let url = await loadURL(p) {
            let body = note.isEmpty ? url.absoluteString : "\(url.absoluteString)\n\n\(note)"
            await uploadText(body, index: index, intent: intent)
            return
        }
        // 2) Any real file (image / audio / video / Word / PDF / …) → upload as-is.
        if let typeId = bestFileType(p), let file = await loadFile(p, typeId) {
            await uploadFile(file, index: index, intent: intent)
            return
        }
        // 3) Plain text fallback.
        if let text = await loadText(p) {
            let body = note.isEmpty ? text : "\(text)\n\n\(note)"
            await uploadText(body, index: index, intent: intent)
        }
    }

    /// First registered type that is an actual payload (not a bare url/text
    /// marker) — this is the docx/jpg/m4a/pdf we want to copy out and upload.
    private func bestFileType(_ p: NSItemProvider) -> String? {
        let skip: Set<String> = [
            UTType.url.identifier, UTType.fileURL.identifier,
            UTType.plainText.identifier, UTType.utf8PlainText.identifier,
            UTType.text.identifier,
        ]
        return p.registeredTypeIdentifiers.first { !skip.contains($0) }
    }

    // MARK: - Upload

    private func uploadText(_ text: String, index: Int, intent: Intent) async {
        let name = filename(intent: intent, index: index, ext: "txt")
        await put(data: Data(text.utf8), name: name, contentType: "text/plain; charset=utf-8")
    }

    private func uploadFile(_ url: URL, index: Int, intent: Intent) async {
        let ext = url.pathExtension.isEmpty ? "bin" : url.pathExtension
        let name = filename(intent: intent, index: index, ext: ext)
        await put(fileURL: url, name: name, contentType: mimeType(forExtension: ext))
        try? FileManager.default.removeItem(at: url)
    }

    private func filename(intent: Intent, index: Int, ext: String) -> String {
        let ts = Int(Date().timeIntervalSince1970)
        let suffix = index == 0 ? "" : "-\(index)"
        return "VoiceDrop-\(intent.slug)-\(ts)\(suffix).\(ext)"
    }

    private func mimeType(forExtension ext: String) -> String {
        UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }

    /// PUT to `…/files/api/upload/<name>` as the mirrored bearer. Silent on
    /// failure: v1 does not retry (a missed share is rare and re-shareable).
    private func put(data: Data? = nil, fileURL: URL? = nil,
                     name: String, contentType: String) async {
        let token = AppGroup.sharedBearer
        guard !token.isEmpty else { return }   // not signed in yet — open the app once
        var req = URLRequest(url: AppGroup.uploadBase.appendingPathComponent(name))
        req.httpMethod = "PUT"
        req.setBearer(token)
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        do {
            if let fileURL {
                _ = try await URLSession.shared.upload(for: req, fromFile: fileURL)
            } else {
                _ = try await URLSession.shared.upload(for: req, from: data ?? Data())
            }
        } catch {
            // swallow — extension has no UI surface to report into post-dismiss
        }
    }

    // MARK: - NSItemProvider loaders

    private func loadURL(_ p: NSItemProvider) async -> URL? {
        await withCheckedContinuation { cont in
            p.loadItem(forTypeIdentifier: UTType.url.identifier) { item, _ in
                cont.resume(returning: item as? URL)
            }
        }
    }

    private func loadText(_ p: NSItemProvider) async -> String? {
        for id in [UTType.plainText.identifier, UTType.utf8PlainText.identifier, UTType.text.identifier] {
            guard p.hasItemConformingToTypeIdentifier(id) else { continue }
            let s: String? = await withCheckedContinuation { cont in
                p.loadItem(forTypeIdentifier: id) { item, _ in
                    if let s = item as? String { cont.resume(returning: s) }
                    else if let d = item as? Data { cont.resume(returning: String(data: d, encoding: .utf8)) }
                    else { cont.resume(returning: nil) }
                }
            }
            if let s { return s }
        }
        return nil
    }

    /// Copy the provider's file out to our own temp dir synchronously — the URL
    /// handed to the completion block is deleted the moment it returns.
    private func loadFile(_ p: NSItemProvider, _ typeId: String) async -> URL? {
        await withCheckedContinuation { cont in
            p.loadFileRepresentation(forTypeIdentifier: typeId) { url, _ in
                guard let url else { cont.resume(returning: nil); return }
                let dst = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
                try? FileManager.default.copyItem(at: url, to: dst)
                cont.resume(returning: FileManager.default.fileExists(atPath: dst.path) ? dst : nil)
            }
        }
    }
}

/// A two-row chooser pushed from the 用途 configuration row.
final class IntentPicker: UITableViewController {
    private let options = ShareViewController.Intent.allCases
    private let current: ShareViewController.Intent
    private let onPick: (ShareViewController.Intent) -> Void

    init(current: ShareViewController.Intent,
         onPick: @escaping (ShareViewController.Intent) -> Void) {
        self.current = current
        self.onPick = onPick
        super.init(style: .plain)
        title = "选择用途"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func tableView(_ t: UITableView, numberOfRowsInSection s: Int) -> Int { options.count }

    override func tableView(_ t: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        let opt = options[ip.row]
        cell.textLabel?.text = opt.rawValue
        cell.accessoryType = (opt == current) ? .checkmark : .none
        return cell
    }

    override func tableView(_ t: UITableView, didSelectRowAt ip: IndexPath) {
        onPick(options[ip.row])
    }
}
