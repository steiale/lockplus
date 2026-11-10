import Foundation
import LPModel
import LPWire
import os
import Synchronization

/// One accepted app connection's identity, captured in `shouldAcceptNewConnection` (DESIGN §5.2, §5.3).
public struct PeerContext: Sendable, Hashable {
    /// `effectiveUserIdentifier`: EUID at connection time. Keys ownership and event filtering.
    public let uid: uid_t
    /// Logs only: PID reuse makes it unfit for any decision.
    public let pid: pid_t
    public let connectionID: UUID

    public init(uid: uid_t, pid: pid_t, connectionID: UUID = UUID()) {
        self.uid = uid; self.pid = pid; self.connectionID = connectionID
    }
}

/// SAFETY: `NSXPCConnection` is not Sendable-annotated, but its proxy creation and `invalidate()` are documented as
/// callable from any thread [NSXPCConnection.h]. The box exposes only those two operations.
final class ConnectionBox: @unchecked Sendable {
    private let connection: NSXPCConnection
    init(_ c: NSXPCConnection) { connection = c }

    /// Sends one `tunnelEvent`; `completion` runs exactly once (on `done` or on the proxy error).
    func sendEvent(_ data: Data, completion: @escaping @Sendable () -> Void) {
        let once = Mutex(false)
        let finish: @Sendable () -> Void = {
            if once.withLock({ fired in defer { fired = true }; return !fired }) { completion() }
        }
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable _ in finish() })
                as? any LPAppCallbackXPC else { finish(); return }
        proxy.tunnelEvent(data, done: finish)
    }

    func invalidate() { connection.invalidate() }
}

/// The extension's view of every connected app instance (§5.2 "Event delivery"; ref/xpc-servicemanagement §2).
///
/// - Profile-scoped events reach only connections whose uid equals the profile's `ownerUID`; every other connection
///   receives the content-free `.anyTunnelStateChanged`. uid filtering is the ONLY control against another user's
///   validly signed LockPlus (§1.3 A2).
/// - One event in flight per connection; newer events coalesce (latest wins), so a hung app can't make the extension
///   queue without bound. The app re-pulls snapshot and prompts on every status change.
/// - Entries are removed in the server-side `invalidationHandler`, the only event a listener-side connection gets.
///
/// A `Mutex`-guarded class rather than an actor: registration happens synchronously inside the delegate callback, so an
/// early invalidation can never be processed before its add (an actor hop could reorder them).
public final class ConnectionRegistry: Sendable {
    private struct Entry {
        let peer: PeerContext
        let box: ConnectionBox
        var inFlight = false
        /// FIFO of events waiting behind the one in flight. State-only kinds (snapshot, content-free) coalesce: a
        /// newer one replaces the queued one. `authRequired`/`promptResolved`/`sessionEnded` are never dropped (T8),
        /// up to `maxQueued` (a hung app then loses the oldest, but the app re-pulls state on reconnect).
        var pending: [(data: Data, coalescible: Bool)] = []
    }
    static let maxQueued = 32

    private static let log = Logger(subsystem: "io.github.steiale.lockplus.mac.tunnel", category: "xpc")
    private let entries = Mutex<[UUID: Entry]>([:])

    public init() {}

    func add(_ peer: PeerContext, _ box: ConnectionBox) {
        entries.withLock { $0[peer.connectionID] = Entry(peer: peer, box: box) }
    }

    func remove(_ id: UUID) {
        _ = entries.withLock { $0.removeValue(forKey: id) }
    }

    /// Currently connected peers (diagnostics, `wipeAllSecrets` bookkeeping).
    public var peers: [PeerContext] { entries.withLock { $0.values.map(\.peer) } }

    /// Publishes a profile-scoped event to its owner's connections and the redacted form to everyone else.
    /// - Parameter ownerUID: the profile's `ownerUID`; nil sends the content-free event to everyone.
    public func publish(_ event: TunnelEvent, ownerUID: uid_t?) {
        let full: Data
        let redacted: Data
        do {
            full = try LPWire.encode(event)
            redacted = try LPWire.encode(event.redactedForNonOwner)
        } catch {
            Self.log.error("event encode failed: \(error.code.rawValue, privacy: .public)")
            return
        }
        let fullCoalesces = event.kind == .snapshotChanged || event.kind == .anyTunnelStateChanged
        let sends: [(UUID, ConnectionBox, Data)] = entries.withLock { map in
            var out: [(UUID, ConnectionBox, Data)] = []
            for (id, var e) in map {
                let owner = ownerUID != nil && e.peer.uid == ownerUID
                let payload = owner ? full : redacted
                let coalescible = owner ? fullCoalesces : true
                if e.inFlight {
                    if coalescible { e.pending.removeAll { $0.coalescible } }
                    e.pending.append((payload, coalescible))
                    if e.pending.count > Self.maxQueued { e.pending.removeFirst(e.pending.count - Self.maxQueued) }
                } else {
                    e.inFlight = true; out.append((id, e.box, payload))
                }
                map[id] = e
            }
            return out
        }
        for (id, box, data) in sends { deliver(id, box, data) }
    }

    private func deliver(_ id: UUID, _ box: ConnectionBox, _ data: Data) {
        box.sendEvent(data) { [weak self] in self?.delivered(id) }
    }

    /// `done` (or the proxy error) for the event in flight: send the coalesced next one, if any.
    private func delivered(_ id: UUID) {
        let next: (ConnectionBox, Data)? = entries.withLock { map in
            guard var e = map[id] else { return nil }
            defer { map[id] = e }
            guard !e.pending.isEmpty else { e.inFlight = false; return nil }
            return (e.box, e.pending.removeFirst().data)
        }
        if let (box, data) = next { deliver(id, box, data) }
    }
}
