import Foundation
import LPModel
import LPWire

/// What the XPC handler forwards to (the TunnelController and stores, P2b/P2c). The handler has already enforced the
/// hello gate and the request size cap; the backend decodes with `LPWire.decode(_:_:max: method.requestLimit)`,
/// checks ownership against `peer.uid` (`.notOwner`, §5.4) and returns the encoded result (nil for `LPReply1` methods).
/// It is called under the method's server deadline (1 s below the client's timeout); a late result is dropped.
public protocol TunnelServiceBackend: Sendable {
    /// Capabilities this extension build offers in `ServerHello`.
    var capabilities: Set<Capability> { get }
    func handle(_ method: LPMethod, request: Data, peer: PeerContext) async -> Result<Data?, LPError>
}

/// P2a backend: hello works, every other method answers a well-formed "not available" error. Replaced by the engine's
/// backend in P2b; it exists so the listener, the hello gate and the reply-once rule are testable today.
public struct UnavailableTunnelServiceBackend: TunnelServiceBackend {
    public init() {}
    public var capabilities: Set<Capability> { [] }
    public func handle(_ method: LPMethod, request: Data, peer: PeerContext) async -> Result<Data?, LPError> {
        .failure(LPError(.extensionBusy, detail: "\(method.rawValue) not available in this build"))
    }
}
