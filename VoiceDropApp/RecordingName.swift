import Foundation

/// Builds the enriched, ASCII-only recording filename. Keeps the `VoiceDrop-`
/// prefix and `.m4a` suffix (the mining pipeline filters on those), and packs
/// readable context between them so a file is self-describing in a listing:
///
///   VoiceDrop-2026-06-18-143052-0m33s-Thu-Afternoon-Shanghai-Xuhui.m4a
///
/// Everything is ASCII (letters, digits, hyphens) — no spaces, no CJK, no
/// punctuation — so it round-trips cleanly through URLs, R2 keys and curl.
enum RecordingName {

    /// `place` is an already-clean ASCII tag like "Shanghai-Xuhui" (or nil).
    static func make(start: Date, duration: TimeInterval, place: String?) -> String {
        var parts = ["VoiceDrop", timestamp(start), durationTag(duration), weekday(start), period(start)]
        if let place, !place.isEmpty { parts.append(place) }
        return parts.joined(separator: "-") + ".m4a"
    }

    static func timestamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: d)
    }

    static func durationTag(_ t: TimeInterval) -> String {
        let total = max(0, Int(t.rounded()))
        return "\(total / 60)m\(total % 60)s"
    }

    private static let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    static func weekday(_ d: Date) -> String {
        let wd = Calendar.current.component(.weekday, from: d)   // 1 = Sunday
        return weekdays[(wd - 1) % 7]
    }

    static func period(_ d: Date) -> String {
        switch Calendar.current.component(.hour, from: d) {
        case 5..<9:   return "EarlyMorning"
        case 9..<12:  return "Morning"
        case 12..<14: return "Noon"
        case 14..<18: return "Afternoon"
        case 18..<20: return "Evening"
        case 20..<23: return "Night"
        default:      return "LateNight"
        }
    }
}
