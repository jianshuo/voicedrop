import Foundation
import PDFKit
import UIKit

// Pure extraction helpers for the Share Extension's incoming-item router (a
// later task). No UI, no third-party deps — PDFKit/Foundation/UIKit only.

/// What kind of thing the user shared — drives the later router's default
/// 用途 (mine vs style) and upload naming, mirroring `ShareViewController`'s
/// own ad-hoc type sniffing but as a first-class value the router can switch on.
enum ShareKind {
    case audio, image, web, document, text
}

// MARK: - PDF / rich document extraction

/// Extract plain text from a PDF at `url`, or nil if unreadable/empty.
func extractPDF(_ url: URL) -> String? {
    guard let doc = PDFDocument(url: url), let s = doc.string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
    return s
}

/// Extract plain text from a rich document (docx/rtf/…) at `url` via
/// `NSAttributedString`'s document-type auto-detection, or nil if unreadable/empty.
// docx / rtf / plain-text only — do NOT pass .html here (HTML import must run on the
// main thread; route web content through Readability.fetch instead).
func extractRichDocument(_ url: URL) -> String? {
    guard let a = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) else { return nil }
    let s = a.string.trimmingCharacters(in: .whitespacesAndNewlines)
    return s.isEmpty ? nil : s
}

/// The first non-empty line of `text` (trimmed, capped at 40 chars), or `fallback`
/// if `text` has no usable first line.
func firstLineTitle(_ text: String, fallback: String) -> String {
    let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
    let t = line.isEmpty ? fallback : line
    return String(t.prefix(40))
}

// MARK: - Readability (shared web link → title + article text)

/// Minimal readability: fetch a URL with a browser UA and pull out a title +
/// article body. 微信 (`mp.weixin.qq.com`) gets a `#js_content` special-case;
/// everything else falls back to `<article>` then `<body>`.
enum Readability {
    static func fetch(_ url: URL) async -> (title: String?, text: String)? {
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        // og:title's two attributes appear in either order in the wild (`property` then
        // `content`, or `content` then `property`) — try both.
        let title = firstMatch(html, #"<meta[^>]+property=[\"']og:title[\"'][^>]+content=[\"']([^\"']+)"#)
            ?? firstMatch(html, #"<meta[^>]+content=[\"']([^\"']+)[\"'][^>]+property=[\"']og:title[\"']"#)
            ?? firstMatch(html, #"<title[^>]*>([^<]+)</title>"#)
        var body = html
        // Greedy `(.*)` (not `.*?`) so these capture through the LAST matching close tag —
        // WeChat articles (秀米/135编辑器) nest many <div>s inside #js_content, and a
        // non-greedy capture would stop at the first nested </div> and drop most of the
        // article. Over-capturing a trailing footer is fine; under-capturing isn't.
        if url.host?.contains("mp.weixin.qq.com") == true, let m = firstMatch(html, #"(?s)<div[^>]+id=[\"']js_content[\"'][^>]*>(.*)</div>"#) { body = m }
        else if let m = firstMatch(html, #"(?s)<article[^>]*>(.*)</article>"#) { body = m }
        else if let m = firstMatch(html, #"(?s)<body[^>]*>(.*)</body>"#) { body = m }
        let text = stripTags(body)
        if text.count < 40 {
            // No usable body. Only "succeed" if we at least have a real title — otherwise
            // this is a genuine failure the caller should detect and fall back to 仅存链接.
            if let t = title, !t.isEmpty { return (t, t) }
            return nil
        }
        return (title, text)
    }
    private static func firstMatch(_ s: String, _ pat: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func stripTags(_ h: String) -> String {
        var s = h
        for p in [#"(?s)<script.*?</script>"#, #"(?s)<style.*?</style>"#] { s = s.replacingOccurrences(of: p, with: " ", options: .regularExpression) }
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "\n", options: .regularExpression)
        s = decodeEntities(s)
        return s.replacingOccurrences(of: #"\n[ \t]*\n(\s*\n)+"#, with: "\n\n", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// Decode HTML entities as an ORDERED sequence (not a `Dictionary` — Swift dict
    /// iteration order is unspecified and `&amp;` must decode last). Named entities first
    /// (widened for Chinese web content: curly quotes, em-dash, ellipsis), then numeric
    /// entities (`&#NNN;` / `&#xHHHH;`) decoded generically via their code point, then
    /// `&amp;` last so a doubly-escaped `&amp;lt;` doesn't collapse wrongly.
    private static func decodeEntities(_ s: String) -> String {
        let namedEntities: [(String, String)] = [
            ("&nbsp;", " "),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&apos;", "'"),
            ("&rsquo;", "\u{2019}"),
            ("&lsquo;", "\u{2018}"),
            ("&rdquo;", "\u{201D}"),
            ("&ldquo;", "\u{201C}"),
            ("&mdash;", "\u{2014}"),
            ("&hellip;", "\u{2026}"),
        ]
        var result = s
        for (e, c) in namedEntities { result = result.replacingOccurrences(of: e, with: c) }
        result = decodeNumericEntities(result)
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        return result
    }
    /// Decode `&#NNN;` (decimal) and `&#xHHHH;` (hex) numeric character references generically
    /// by mapping the code point to its `Character`. Leaves malformed/out-of-range refs as-is.
    private static func decodeNumericEntities(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"&#x([0-9A-Fa-f]+);|&#([0-9]+);"#) else { return s }
        let ns = s as NSString
        var result = ""
        var lastEnd = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: lastEnd, length: m.range.location - lastEnd))
            let hexRange = m.range(at: 1)
            let decRange = m.range(at: 2)
            var value: UInt32?
            if hexRange.location != NSNotFound { value = UInt32(ns.substring(with: hexRange), radix: 16) }
            else if decRange.location != NSNotFound { value = UInt32(ns.substring(with: decRange)) }
            if let v = value, let scalar = Unicode.Scalar(v) { result += String(Character(scalar)) }
            else { result += ns.substring(with: m.range) }
            lastEnd = m.range.location + m.range.length
        }
        result += ns.substring(with: NSRange(location: lastEnd, length: ns.length - lastEnd))
        return result
    }
}
