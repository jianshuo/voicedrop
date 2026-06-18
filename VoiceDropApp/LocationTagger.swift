import Foundation
import CoreLocation

/// Collects a coarse location fix while recording and turns it into an
/// ASCII "City-District" tag for the filename. Permission and geocoding are
/// best-effort — they NEVER block or delay recording. If location is denied,
/// indoors, or geocoding times out, the tag is simply omitted.
@MainActor
final class LocationTagger: NSObject, CLLocationManagerDelegate {

    private let manager = CLLocationManager()
    private var lastLocation: CLLocation?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// Ask for permission (first launch) and start collecting fixes.
    func start() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
        default:
            break
        }
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        let status = m.authorizationStatus
        Task { @MainActor in
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                self.manager.startUpdatingLocation()
            }
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let last = locs.last else { return }
        Task { @MainActor in self.lastLocation = last }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}

    // MARK: - Geocoding

    /// Reverse-geocode the latest fix to an ASCII "City-District" tag, or nil.
    /// Races a 3s timeout so it never holds up the upload.
    func placeTag() async -> String? {
        guard let loc = lastLocation else { return nil }
        let lat = loc.coordinate.latitude
        let lon = loc.coordinate.longitude
        return await withTaskGroup(of: String?.self) { group in
            group.addTask { await Self.reverseGeocode(lat: lat, lon: lon) }
            group.addTask { try? await Task.sleep(for: .seconds(3)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    nonisolated private static func reverseGeocode(lat: Double, lon: Double) async -> String? {
        let geocoder = CLGeocoder()
        let loc = CLLocation(latitude: lat, longitude: lon)
        // English locale -> ASCII place names (Shanghai, Xuhui) instead of CJK.
        let placemarks = try? await geocoder.reverseGeocodeLocation(
            loc, preferredLocale: Locale(identifier: "en_US"))
        guard let p = placemarks?.first else { return nil }
        let tokens = [p.locality, p.subLocality].compactMap { $0 }.compactMap(asciiLetters)
        let joined = tokens.joined(separator: "-")
        return joined.isEmpty ? nil : joined
    }

    /// Keep ASCII letters only; drop spaces, digits, punctuation, accents, CJK.
    nonisolated static func asciiLetters(_ s: String) -> String? {
        let kept = s.unicodeScalars.filter { $0.isASCII && CharacterSet.letters.contains($0) }
        let out = String(String.UnicodeScalarView(kept))
        return out.isEmpty ? nil : out
    }
}
