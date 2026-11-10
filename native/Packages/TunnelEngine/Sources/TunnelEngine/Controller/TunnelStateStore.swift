import os
import Foundation
import LPModel
import LPWire
import Synchronization

/// The extension's `state.plist` (§3.3): latches, last errors, the 60 s AUTH_FAILED resend guard, the last good
/// endpoint resolution per hostname and the 100-entry session ring. Not secret. A newer schema than this build understands is discarded (§4.6).
/// A profile as the engine addresses it: profile UUIDs are unique only inside one uid's namespace (review H1), so every
/// per-profile record (latches, errors, endpoint hosts, sessions) is keyed by the pair.
public struct ProfileKey: Hashable, Codable, Sendable {
    public var ownerUID: uid_t
    public var profileID: UUID
    public init(ownerUID: uid_t, profileID: UUID) { self.ownerUID = ownerUID; self.profileID = profileID }
    public init(_ c: ProviderConfiguration) { self.init(ownerUID: c.ownerUID, profileID: c.profileID) }
}

/// Schema 2: per-profile maps are keyed by `ProfileKey`, and sessions carry their owner (review H1/L1). Schema 3
/// (draft 9, S2 E10): the endpoint cache maps hostname → IPs, so the provider can replace every hostname it would
/// otherwise resolve. Nothing before schema 3 shipped; an older file fails to decode and starts empty.
public struct PersistedTunnelState: Codable, Sendable, Equatable {
    public static let currentSchema = 3
    public struct Latch: Codable, Sendable, Equatable { public var latch: StartLatch; public var interval: TimeInterval? }
    public struct LastError: Codable, Sendable, Equatable { public var error: LPError; public var at: Date }
    public struct OwnedSession: Codable, Sendable, Equatable { public var ownerUID: uid_t; public var summary: SessionSummary }

    public var schema = currentSchema
    public var latches: [ProfileKey: Latch] = [:]
    public var lastErrors: [ProfileKey: LastError] = [:]
    public var authFailedAt: [ProfileKey: Date] = [:]
    /// hostname (lowercased) → IP literals, per profile: the app's start-time resolution and WireGuard's own
    /// (kill switch off only), merged; the fallback when a start carries none (§9.3).
    public var endpointHosts: [ProfileKey: [String: [String]]] = [:]
    public var sessions: [OwnedSession] = []
    public init() {}
}

/// Synchronous on purpose: called from the controller actor with no suspension point (no reentrancy, §7.1 rule 1).
public protocol TunnelStateStore: Sendable {
    func load() -> PersistedTunnelState
    func save(_ s: PersistedTunnelState)
}

public final class InMemoryTunnelStateStore: TunnelStateStore {
    private let s: Mutex<PersistedTunnelState>
    public init(_ initial: PersistedTunnelState = .init()) { s = Mutex(initial) }
    public func load() -> PersistedTunnelState { s.withLock { $0 } }
    public func save(_ v: PersistedTunnelState) { s.withLock { $0 = v } }
}

/// Root-owned 0600 plist in the container (`Application Support/state.plist`), written atomically.
public final class PlistTunnelStateStore: TunnelStateStore {
    private let url: URL
    private let lock = Mutex(())
    public init(url: URL) { self.url = url }
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("state.plist")
    }
    public func load() -> PersistedTunnelState {
        lock.withLock { _ in
            guard let d = try? Data(contentsOf: url),
                  let s = try? PropertyListDecoder().decode(PersistedTunnelState.self, from: d),
                  s.schema == PersistedTunnelState.currentSchema else { return PersistedTunnelState() }
            return s
        }
    }
    public func save(_ s: PersistedTunnelState) {
        lock.withLock { _ in
            guard let d = try? PropertyListEncoder.binary.encode(s) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try d.write(to: url, options: [.atomic])
                chmod(url.path, 0o600)
            } catch {
                engineLog.error("state.plist write failed")
            }
        }
    }
}
