import XCTest
@testable import VoiceDrop

/// Prefs.appLanguage ↔ AppleLanguages 覆写契约：选固定语言写入 AppleLanguages
/// （重启后系统按它加载本地化），选「跟随系统」必须清掉覆写键。
@MainActor
final class AppLanguageTests: XCTestCase {

    func testAppLanguageOverridesAppleLanguages() {
        let d = UserDefaults.standard
        let prevPref = Prefs.shared.appLanguage
        let prevOverride = d.object(forKey: "AppleLanguages")
        defer {
            Prefs.shared.appLanguage = prevPref
            if prevPref.isEmpty { d.removeObject(forKey: "AppleLanguages") }
            if let prevOverride { d.set(prevOverride, forKey: "AppleLanguages") }
        }

        Prefs.shared.appLanguage = "en"
        XCTAssertEqual(d.stringArray(forKey: "AppleLanguages"), ["en"])
        XCTAssertEqual(d.string(forKey: "pref.appLanguage"), "en")

        Prefs.shared.appLanguage = "zh-Hans"
        XCTAssertEqual(d.stringArray(forKey: "AppleLanguages"), ["zh-Hans"])

        Prefs.shared.appLanguage = ""
        // 回到跟随系统：覆写键必须被清除（AppleLanguages 恢复系统提供的值，
        // 不再包含我们钉死的单元素数组）。
        XCTAssertNotEqual(d.array(forKey: "AppleLanguages") as? [String], ["zh-Hans"])
        XCTAssertEqual(d.string(forKey: "pref.appLanguage"), "")
    }
}
