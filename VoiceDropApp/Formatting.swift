import Foundation

// Small shared formatting/util helpers that were copy-pasted across views.

extension Int {
    /// "%02d:%02d" clock string (mm:ss) for a second count.
    var clockString: String { String(format: "%02d:%02d", self / 60, self % 60) }
}

extension TimeInterval {
    /// "%02d:%02d" clock string (mm:ss); negatives clamp to 0.
    var clockString: String { max(0, Int(self)).clockString }
}

extension DateFormatter {
    /// A zh_CN `DateFormatter` with `format` — centralizes the locale + construction
    /// boilerplate repeated at every call site (the format itself stays per-site).
    static func zh(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = format
        return f
    }
}

extension Data {
    /// Decode a base64url string (`-`/`_` alphabet, optional padding) → Data.
    init?(base64URLEncoded s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        guard let d = Data(base64Encoded: b) else { return nil }
        self = d
    }

    /// Encode as base64url (no padding, `-`/`_` alphabet).
    var base64URLEncodedString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
