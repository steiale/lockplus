import Foundation
import LPModel
import LPWire
import LPXPCClient

/// The XPC link as the app's stores see it (§5.4, §11.2). Mapped from `TunnelServiceClient.Status`, so fakes can
/// produce it (the client's `Status` has no public initializer).
struct ServiceLinkStatus: Sendable, Equatable {
    enum Link: Sendable, Equatable {
        case idle
        case validated(ServerHello)
        case reconnecting(since: Date)
        case unavailable(LPError)
    }
    var link: Link
    var busy: Bool

    static let idle = ServiceLinkStatus(link: .idle, busy: false)
}

/// The app's view of the extension's XPC service (§5.2). `XPCTunnelService` wraps the real `TunnelServiceClient`;
/// tests and preview mode use fakes. Every call carries its own timeout and the hello gate (in the real client).
protocol TunnelServicing: Sendable {
    func hello() async throws(LPError) -> ServerHello
    func call<Req: Encodable & Sendable, Resp: Decodable & Sendable>(
        _ method: LPMethod, _ request: Req, as: Resp.Type) async throws(LPError) -> Resp
    func callVoid<Req: Encodable & Sendable>(_ method: LPMethod, _ request: Req) async throws(LPError)
    /// The only way out of the 4102 state: an explicit user action.
    func resetAfterUserAction() async
    /// `tunnelEvent`s; one consumer (`AppEnvironment`).
    var events: AsyncStream<TunnelEvent> { get }
    /// Link changes; one consumer (`ExtensionStore`).
    var linkUpdates: AsyncStream<ServiceLinkStatus> { get }
    /// When the XPC link to the extension was last interrupted (its process exited), nil if never. Review PF-R1: the
    /// fresh-crash signal for a `pluginFailed` (`CrashRestartPolicy.isFreshCrash`).
    func lastLinkInterruption() async -> Date?
}

extension TunnelServicing {
    func lastLinkInterruption() async -> Date? { nil }
}

struct XPCTunnelService: TunnelServicing {
    let client: TunnelServiceClient
    let linkUpdates: AsyncStream<ServiceLinkStatus>

    init(client: TunnelServiceClient) {
        self.client = client
        let source = client.statusUpdates
        linkUpdates = AsyncStream(bufferingPolicy: .bufferingNewest(16)) { cont in
            let t = Task { @Sendable in
                for await s in source { cont.yield(Self.map(s)) }
                cont.finish()
            }
            cont.onTermination = { @Sendable _ in t.cancel() }
        }
    }

    static func map(_ s: TunnelServiceClient.Status) -> ServiceLinkStatus {
        let link: ServiceLinkStatus.Link = switch s.link {
        case .idle: .idle
        case .validated(let h): .validated(h)
        case .reconnecting(let since): .reconnecting(since: since)
        case .unavailable(let e): .unavailable(e)
        }
        return ServiceLinkStatus(link: link, busy: s.busy)
    }

    var events: AsyncStream<TunnelEvent> { client.events }

    func hello() async throws(LPError) -> ServerHello { try await client.hello() }

    func call<Req: Encodable & Sendable, Resp: Decodable & Sendable>(
        _ method: LPMethod, _ request: Req, as: Resp.Type) async throws(LPError) -> Resp {
        try await client.call(method, request, as: Resp.self)
    }

    func callVoid<Req: Encodable & Sendable>(_ method: LPMethod, _ request: Req) async throws(LPError) {
        try await client.callVoid(method, request)
    }

    func resetAfterUserAction() async { await client.resetAfterUserAction() }

    func lastLinkInterruption() async -> Date? { await client.lastInterruption }
}

/// No embedded extension (a damaged bundle): every call fails with `.extensionUnavailable`.
struct UnavailableTunnelService: TunnelServicing {
    let events = AsyncStream<TunnelEvent> { $0.finish() }
    let linkUpdates = AsyncStream<ServiceLinkStatus> { $0.finish() }
    private static let error = LPError(.extensionUnavailable, detail: "no Mach service name in the embedded extension")

    func hello() async throws(LPError) -> ServerHello { throw Self.error }
    func call<Req: Encodable & Sendable, Resp: Decodable & Sendable>(
        _ method: LPMethod, _ request: Req, as: Resp.Type) async throws(LPError) -> Resp { throw Self.error }
    func callVoid<Req: Encodable & Sendable>(_ method: LPMethod, _ request: Req) async throws(LPError) { throw Self.error }
    func resetAfterUserAction() async {}
}
