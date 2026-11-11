import Foundation

/// The bookkeeping of the extension's `ProcessProviderHost` (DESIGN §7.1), NE-free so it is tested (2.0.1 re-check
/// N2). "Current" is the provider the controller's session uses (`apply`, `setReasserting`, the packet flow); every
/// bound start also keeps its own host by token until it unbinds, so a late cancel reaches the ended session's own
/// provider (review M1). Re-check L2: entries carry the binding start's lease, and a cancel or a stop's unbind acts only
/// on that very start: never on a newer start of a reused instance.
public struct ProviderBindings<Host> {
    struct Bound {
        let id: ObjectIdentifier
        let lease: ProviderLease
        let host: Host
    }
    private var current: Bound?
    private var byToken: [ProviderToken: Bound] = [:]

    public init() {}

    /// The controller accepted `lease`'s start of the provider `id`.
    public mutating func bind(id: ObjectIdentifier, lease: ProviderLease, host: Host) {
        let b = Bound(id: id, lease: lease, host: host)
        current = b
        byToken[lease.token] = b
    }

    /// `lease`'s stop completed. True: it was the current binding (the caller detaches the packet flow).
    public mutating func unbind(id: ObjectIdentifier, lease: ProviderLease) -> Bool {
        if let b = byToken[lease.token], b.id == id, b.lease == lease { byToken[lease.token] = nil }
        guard let c = current, c.id == id, c.lease == lease else { return false }
        current = nil
        return true
    }

    /// Codex final 2: `lease`'s `startTunnel` was delivered on its instance. Any older start's dispatch entry of that
    /// instance is retired at once, before the new start is accepted or bound: a late cancel of the older start can't
    /// reach the native provider object that now runs the newer one. ("Current" stays for the session's own calls.)
    public mutating func retire(olderThan lease: ProviderLease) {
        if let b = byToken[lease.token], b.lease != lease { byToken[lease.token] = nil }
    }

    /// The provider `id` is gone (`deinit`): every binding of it goes, whatever its lease. True: it was current.
    public mutating func release(id: ObjectIdentifier, token: ProviderToken) -> Bool {
        if byToken[token]?.id == id { byToken[token] = nil }
        guard current?.id == id else { return false }
        current = nil
        return true
    }

    /// The host a cancel for `owner` goes to: `owner`'s own binding (nil when it is gone or was rebound by a newer
    /// start of the same instance); without an owner, the current one.
    public func host(for owner: ProviderLease?) -> Host? {
        if let owner {
            guard let b = byToken[owner.token], b.lease == owner else { return nil }
            return b.host
        }
        return current?.host
    }

    public var currentHost: Host? { current?.host }

    /// The instances with a dispatch entry (tests: bounded bookkeeping).
    var trackedTokens: Set<ProviderToken> { Set(byToken.keys) }
}
