import UniformTypeIdentifiers
import Foundation

/// What `ShareRootView` needs to render + (eventually) upload, gathered from
/// every `NSItemProvider` attached to the share sheet's `NSExtensionItem`s.
/// `note` starts empty — the compose sheets (Task 8/9/10) own the note field
/// the user types into, not the loader.
struct SharePayload {
    var audio: URL?
    var images: [URL] = []
    var webURL: URL?
    var docs: [URL] = []
    var text: String?
    var note: String = ""
}

/// Classifies the incoming share items into a `ShareKind` and loads their
/// `NSItemProvider` attachments into a `SharePayload`. Replaces the old
/// `SLComposeServiceViewController`'s ad-hoc per-attachment upload with a
/// router that just gathers data — `ShareRootView`'s sheets own the upload.
/// `@MainActor`-isolated (not just for tidiness): `NSExtensionItem`/`NSItemProvider`
/// aren't `Sendable`, and `ShareRootView.body` is itself main-actor-isolated (the
/// `View` protocol's `body` is `@MainActor` in the iOS 18 SDK) — keeping the router
/// on the same actor as its caller avoids a cross-actor "sending risks data races"
/// error on `.task { await ShareRouter.loadPayload(items) }` without needing to make
/// Apple's non-Sendable extension types conform to `Sendable` ourselves.
@MainActor
enum ShareRouter {
    private static let docTypeIDs = [
        UTType.pdf.identifier,
        "org.openxmlformats.wordprocessingml.document",
        "com.microsoft.word.doc",
        UTType.rtf.identifier,
    ]

    static func classify(_ items: [NSExtensionItem]) -> ShareKind {
        let ps = items.flatMap { $0.attachments ?? [] }
        func any(_ id: String) -> Bool { ps.contains { $0.hasItemConformingToTypeIdentifier(id) } }
        if any(UTType.audio.identifier) { return .audio }
        if any(UTType.image.identifier) { return .image }
        if any(UTType.url.identifier) && !any(UTType.fileURL.identifier) { return .web }
        if docTypeIDs.contains(where: any) { return .document }
        return .text
    }

    /// Walk every attachment and sort it into `SharePayload`'s buckets — web
    /// link → audio → image → document → any other file → plain text, mirroring
    /// the old `ShareViewController.uploadAttachment`'s priority order but
    /// filling a struct instead of uploading immediately (the sheets upload).
    static func loadPayload(_ items: [NSExtensionItem]) async -> SharePayload {
        var payload = SharePayload()
        let providers = items.flatMap { $0.attachments ?? [] }
        for p in providers {
            // 1) Web link (a URL that is NOT a file URL).
            if p.hasItemConformingToTypeIdentifier(UTType.url.identifier),
               !p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                if payload.webURL == nil { payload.webURL = await loadURL(p) }
                continue
            }
            // 2) Audio.
            if p.hasItemConformingToTypeIdentifier(UTType.audio.identifier) {
                if payload.audio == nil, let file = await loadFile(p, UTType.audio.identifier) {
                    payload.audio = file
                }
                continue
            }
            // 3) Image.
            if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                if let file = await loadFile(p, UTType.image.identifier) { payload.images.append(file) }
                continue
            }
            // 4) Word / PDF / RTF document.
            if let docTypeID = docTypeIDs.first(where: { p.hasItemConformingToTypeIdentifier($0) }) {
                if let file = await loadFile(p, docTypeID) { payload.docs.append(file) }
                continue
            }
            // 5) Any other real file (not a bare url/text marker) — keep it as a
            // doc so it isn't silently dropped.
            if let typeId = bestFileType(p), let file = await loadFile(p, typeId) {
                payload.docs.append(file)
                continue
            }
            // 6) Plain text fallback.
            if let text = await loadText(p) {
                payload.text = payload.text.map { "\($0)\n\n\(text)" } ?? text
            }
        }
        return payload
    }

    /// First registered type that is an actual payload (not a bare url/text
    /// marker) — this is the docx/jpg/m4a/pdf we want to copy out.
    private static func bestFileType(_ p: NSItemProvider) -> String? {
        let skip: Set<String> = [
            UTType.url.identifier, UTType.fileURL.identifier,
            UTType.plainText.identifier, UTType.utf8PlainText.identifier,
            UTType.text.identifier,
        ]
        return p.registeredTypeIdentifiers.first { !skip.contains($0) }
    }

    // MARK: - NSItemProvider loaders (moved verbatim from the old SLCompose ShareViewController)

    private static func loadURL(_ p: NSItemProvider) async -> URL? {
        await withCheckedContinuation { cont in
            p.loadItem(forTypeIdentifier: UTType.url.identifier) { item, _ in
                cont.resume(returning: item as? URL)
            }
        }
    }

    private static func loadText(_ p: NSItemProvider) async -> String? {
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
    private static func loadFile(_ p: NSItemProvider, _ typeId: String) async -> URL? {
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
