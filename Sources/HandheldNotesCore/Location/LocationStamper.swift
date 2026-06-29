import CoreLocation
import Foundation

/// One-shot, opt-in location capture: a single fix, reverse-geocoded **on-device**
/// to a human place label. **Best-effort and non-fatal** — any failure (permission
/// denied/restricted, no fix, offline geocoder) yields `nil` and never blocks or
/// fails a note. Only invoked when the user turned geotagging on
/// (`NotesSettings.geotagEnabled`); see `AppModel.stampLocationIfEnabled(for:)`.
///
/// `@MainActor` because `CLLocationManager` expects main-thread use; the async
/// `stamp()` bridges its delegate callbacks to `async`/`await`. The delegate
/// methods are `nonisolated` (the protocol requires that) and hop back to the main
/// actor to touch the stored continuations.
@MainActor
public final class LocationStamper: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var fixContinuation: CheckedContinuation<(latitude: Double, longitude: Double)?, Never>?
    private var authContinuation: CheckedContinuation<CLAuthorizationStatus, Never>?

    public override init() {
        super.init()
        manager.delegate = self
        // Neighborhood-level is plenty for "where was I" — and cheaper/faster than
        // a precise fix.
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// Request authorization (if needed), take one fix, and reverse-geocode it into
    /// a `PlaceStamp`. Returns `nil` on any denial or failure.
    public func stamp() async -> PlaceStamp? {
        guard await ensureAuthorized() else { return nil }
        guard let coord = await oneFix() else { return nil }
        let location = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        let label = await reverseGeocode(location) ?? "Dropped pin"
        return PlaceStamp(label: label, latitude: coord.latitude, longitude: coord.longitude)
    }

    private func ensureAuthorized() async -> Bool {
        let status = manager.authorizationStatus
        if isAuthorized(status) { return true }
        guard status == .notDetermined else { return false }   // denied / restricted
        let newStatus: CLAuthorizationStatus = await withCheckedContinuation { cont in
            authContinuation = cont
            manager.requestWhenInUseAuthorization()
        }
        return isAuthorized(newStatus)
    }

    /// Platform-aware "is this an authorized state". macOS has no
    /// `.authorizedWhenInUse` — `requestWhenInUseAuthorization()` resolves to
    /// `.authorizedAlways` there.
    private nonisolated func isAuthorized(_ status: CLAuthorizationStatus) -> Bool {
        #if os(macOS)
        return status == .authorizedAlways
        #else
        return status == .authorizedWhenInUse || status == .authorizedAlways
        #endif
    }

    private func oneFix() async -> (latitude: Double, longitude: Double)? {
        await withCheckedContinuation { cont in
            fixContinuation = cont
            manager.requestLocation()
        }
    }

    private func reverseGeocode(_ location: CLLocation) async -> String? {
        let placemarks = try? await CLGeocoder().reverseGeocodeLocation(location)
        guard let p = placemarks?.first else { return nil }
        // Prefer a POI/place name, then progressively coarser human labels.
        return p.name ?? p.subLocality ?? p.locality ?? p.administrativeArea
    }

    // MARK: CLLocationManagerDelegate (nonisolated; hop to the main actor for state)

    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            guard status != .notDetermined, let cont = self.authContinuation else { return }
            self.authContinuation = nil
            cont.resume(returning: status)
        }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let coord = locations.last.map { (latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }
        Task { @MainActor in
            self.fixContinuation?.resume(returning: coord)
            self.fixContinuation = nil
        }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.fixContinuation?.resume(returning: nil)
            self.fixContinuation = nil
        }
    }
}
