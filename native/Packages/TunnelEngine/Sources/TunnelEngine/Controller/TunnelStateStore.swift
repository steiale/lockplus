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
    /// 2.0.2 (PLAN §3): the start each profile's session was admitted under (armed: its nonce; unattended: nil); NE's
    /// restart of that session is honoured against it. Additive: a state file without the key decodes to empty (schema
    /// unchanged), and a 2.0.2 record always carries a nonce or none. Capped at `maxAuthorisedStarts` (oldest out, never
    /// the running session's).
    public var authorisedStarts: [ProfileKey: AuthorisedStart] = [:]
    public static let maxAuthorisedStarts = 256
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case schema, latches, lastErrors, authFailedAt, endpointHosts, sessions, authorisedStarts
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        schema = try c.decode(Int.self, forKey: .schema)
        latches = try c.decode([ProfileKey: Latch].self, forKey: .latches)
        lastErrors = try c.decode([ProfileKey: LastError].self, forKey: .lastErrors)
        authFailedAt = try c.decode([ProfileKey: Date].self, forKey: .authFailedAt)
        endpointHosts = try c.decode([ProfileKey: [String: [String]]].self, forKey: .endpointHosts)
        sessions = try c.decode([OwnedSession].self, forKey: .sessions)
        authorisedStarts = try c.decodeIfPresent([ProfileKey: AuthorisedStart].self, forKey: .authorisedStarts) ?? [:]
    }
}

extension PersistedTunnelState {
    /// Round 4 (Codex r4): the start authorisations of a state file that doesn't decode as a whole (another schema,
    /// another part damaged). Record by record: a damaged one is skipped, the rest kept. Bounded by the cap (kill-switch
    /// records first, newest first).
    static func salvageAuthorisedStarts(_ d: Data) -> [ProfileKey: AuthorisedStart] {
        struct Skip: Decodable { init(from d: Decoder) throws {} }
        struct Lenient: Decodable { let records: [ProfileKey: AuthorisedStart]
            enum K: String, CodingKey { case authorisedStarts }
            init(from d: Decoder) throws {
                let c = try d.container(keyedBy: K.self)
                // A dictionary with a non-String key encodes as [key, value, key, value, …].
                var u = try c.nestedUnkeyedContainer(forKey: .authorisedStarts)
                var out: [ProfileKey: AuthorisedStart] = [:]
                while !u.isAtEnd {
                    guard let k = try? u.decode(ProfileKey.self) else { _ = try? u.decode(Skip.self); _ = try? u.decode(Skip.self); continue }
                    if let v = try? u.decode(AuthorisedStart.self) { out[k] = v } else { _ = try? u.decode(Skip.self) }
                }
                records = out
            }
        }
        guard let all = (try? PropertyListDecoder().decode(Lenient.self, from: d))?.records else { return [:] }
        guard all.count > maxAuthorisedStarts else { return all }
        let kept = all.sorted { ($0.value.killSwitch ? 1 : 0, $0.value.at) > ($1.value.killSwitch ? 1 : 0, $1.value.at) }.prefix(maxAuthorisedStarts)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }
}

/// Synchronous on purpose: called from the controller actor with no suspension point (no reentrancy, §7.1 rule 1).
public protocol TunnelStateStore: Sendable {
    func load() -> PersistedTunnelState
    func save(_ s: PersistedTunnelState)
}

public final class InMemoryTunnelStateStore: TunnelStateStore {
    private let s: Mutex<PersistedTunnelState>
    private let onSave = Mutex<(@Sendable (PersistedTunnelState) -> Void)?>(nil)
    public init(_ initial: PersistedTunnelState = .init()) { s = Mutex(initial) }
    public func load() -> PersistedTunnelState { s.withLock { $0 } }
    public func save(_ v: PersistedTunnelState) {
        s.withLock { $0 = v }
        onSave.withLock { $0 }?(v)
    }
    /// Tests: runs after every save, on the saving thread (a barrier inside the controller's plist I/O).
    public func setOnSave(_ f: (@Sendable (PersistedTunnelState) -> Void)?) { onSave.withLock { $0 = f } }
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
            guard let d = try? Data(contentsOf: url) else { return PersistedTunnelState() }
            guard let s = try? PropertyListDecoder().decode(PersistedTunnelState.self, from: d),
                  s.schema == PersistedTunnelState.currentSchema else {
                // Round 1 (Fable L7): discarding the file used to discard the start authorisations too. Round 4 (Codex r4):
                // the start authorisations are salvaged on their own (each record carries its boot; one of another boot
                // is dropped at load as always), so NE's restart of a running kill-switch session survives a state file
                // of another schema or with another part unreadable.
                var fresh = PersistedTunnelState()
                fresh.authorisedStarts = PersistedTunnelState.salvageAuthorisedStarts(d)
                engineLog.fault("state.plist unreadable or of another schema: starting empty but for \(fresh.authorisedStarts.count) start authorisation(s)")
                return fresh
            }
            return s
        }
    }
    public func save(_ s: PersistedTunnelState) {
        lock.withLock { _ in
            guard let d = try? PropertyListEncoder.binary.encode(s) else {
                engineLog.fault("state.plist encode failed: state not persisted")
                return
            }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try d.write(to: url, options: [.atomic])
                chmod(url.path, 0o600)
            } catch {
                // Round 1 (Fable L7): a lost write can lose a start authorisation, and NE's restart of a kill-switch
                // session would then be refused (225). Fault level so it shows in a sysdiagnose.
                engineLog.fault("state.plist write failed: start authorisations, latches and last errors not persisted; NE's restart of a running session may be refused")
            }
        }
    }
}
