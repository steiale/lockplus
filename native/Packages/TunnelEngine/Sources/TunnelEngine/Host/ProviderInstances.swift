import Foundation
import Synchronization

/// One `NEPacketTunnelProvider` instance of this process (DESIGN §7.1, the 2.0.1 start guard). A counter, never an
/// address: an `ObjectIdentifier` can be reused by the next provider once the previous one is freed.
public struct ProviderToken: Hashable, Sendable {
    let raw: UInt64
}

/// One `startTunnel` of one provider instance: the instance plus the generation `ProviderInstances.started` gave it.
/// NE may reuse an instance (start, stop, start); a late stop of the earlier generation must not end the later one.
public struct ProviderLease: Hashable, Sendable {
    public let token: ProviderToken
    let generation: UInt64
}

/// Which provider instances are live. Phase 0 (2026-11-10, macOS 26.6.2 and 27.2): macOS runs two LockPlus
/// configurations at once, both providers in this one process, and a second start used to displace the first session
/// while NE kept reporting it Connected. A provider is live from its `startTunnel` until its `stopTunnel` begins (or it
/// is freed). Both marks are synchronous on the provider's queue, so a start that arrives after another provider's
/// stop was delivered never sees that provider as live, whatever the order the two Tasks reach the controller in.
///
/// Review N5: "freed" relies on nothing retaining a provider: `RealProviderHost` and `ProviderRef` hold it
/// weakly, so `deinit` runs (and marks it stopped) when NE lets it go. Anything that retains a provider breaks that rule.
public final class ProviderInstances: Sendable {
    private let state = Mutex<(next: UInt64, generation: UInt64, live: [UInt64: UInt64])>((1, 0, [:]))

    public init() {}

    /// A new token, not yet live.
    public func makeToken() -> ProviderToken {
        state.withLock { s in defer { s.next &+= 1 }; return ProviderToken(raw: s.next) }
    }

    /// `startTunnel` delivered (again, for an instance NE reuses): live under a new generation.
    public func started(_ t: ProviderToken) -> ProviderLease {
        state.withLock { s in
            s.generation &+= 1
            s.live[t.raw] = s.generation
            return ProviderLease(token: t, generation: s.generation)
        }
    }

    /// `stopTunnel` delivered, or the instance is gone.
    public func stopped(_ t: ProviderToken) { _ = state.withLock { $0.live.removeValue(forKey: t.raw) } }

    /// The instance is live (any generation).
    public func isLive(_ t: ProviderToken) -> Bool { state.withLock { $0.live[t.raw] != nil } }

    /// This very `startTunnel` is still the instance's live one (not stopped, not superseded by a reuse).
    public func isCurrent(_ l: ProviderLease) -> Bool { state.withLock { $0.live[l.token.raw] == l.generation } }
}
