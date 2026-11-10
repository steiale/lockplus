import CoreLocation
import CoreWLAN
import Foundation
import os

/// "Add Current Network" (DESIGN §10.4, UI-CONCEPT §6.7). Location is requested just in time, only from that button
/// (A-OD-1: `ssidMatch` should work without it; S1 decides the app-assisted fallback). macOS reveals the SSID only to
/// apps with Location access; LockPlus reads it once to fill in the name and never stores a location.
@MainActor protocol WiFiLocating: AnyObject {
    var authorization: LocationAuthorization { get }
    /// Shows the system prompt while undecided; returns the resulting state.
    func requestAuthorization() async -> LocationAuthorization
    /// nil without Location access or when not on Wi-Fi.
    func currentSSID() -> String?
}

@MainActor final class LiveWiFiLocator: NSObject, WiFiLocating, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var waiters: [CheckedContinuation<LocationAuthorization, Never>] = []
    private let log = Logger(subsystem: "io.github.steiale.lockplus.mac", category: "ui")

    override init() {
        super.init()
        manager.delegate = self
    }

    var authorization: LocationAuthorization { Self.map(manager.authorizationStatus) }

    nonisolated static func map(_ s: CLAuthorizationStatus) -> LocationAuthorization {
        switch s {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        default: .authorized
        }
    }

    func requestAuthorization() async -> LocationAuthorization {
        guard authorization == .notDetermined else { return authorization }
        return await withCheckedContinuation { (k: CheckedContinuation<LocationAuthorization, Never>) in
            waiters.append(k)
            manager.requestWhenInUseAuthorization()
        }
    }

    func currentSSID() -> String? {
        guard authorization == .authorized else { return nil }
        return CWWiFiClient.shared().interface()?.ssid()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let state = Self.map(manager.authorizationStatus)
        Task { @MainActor in self.authorizationChanged(state) }
    }

    private func authorizationChanged(_ state: LocationAuthorization) {
        guard state != .notDetermined else { return }
        let w = waiters
        waiters.removeAll()
        w.forEach { $0.resume(returning: state) }
        log.notice("location authorization: \(String(describing: state), privacy: .public)")
    }
}

/// Preview mode and tests: no CoreLocation, no CoreWLAN.
@MainActor final class FixtureWiFiLocator: WiFiLocating {
    var authorization: LocationAuthorization
    var afterRequest: LocationAuthorization
    var ssid: String?
    private(set) var requests = 0

    init(authorization: LocationAuthorization = .notDetermined, afterRequest: LocationAuthorization = .authorized, ssid: String? = "Cafe-Guest") {
        self.authorization = authorization
        self.afterRequest = afterRequest
        self.ssid = ssid
    }

    func requestAuthorization() async -> LocationAuthorization {
        if authorization == .notDetermined {
            requests += 1
            authorization = afterRequest
        }
        return authorization
    }

    func currentSSID() -> String? { authorization == .authorized ? ssid : nil }
}
