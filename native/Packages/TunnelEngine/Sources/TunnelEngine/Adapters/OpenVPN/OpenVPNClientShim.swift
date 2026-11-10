import Foundation
import LPModel

/// The openvpn3 ClientAPI as TunnelEngine sees it. The LockPlusTunnel target implements it over OpenVPN3Shim
/// (ObjC++, P3 per P2a's shim header; the spike's `lp_engines.h` C API is the model). The shim MUST:
/// - own one `OpenVPNClient` per `OpenVPNClient` object here (single-use, ref/openvpn3 §1 item 1);
/// - override `get_async_stop()` with a shim-owned `openvpn::Stop` that OUTLIVES the client object (declared before
///   the client in the wrapper, or heap-owned and released after it; D73-3, `std::terminate` otherwise);
/// - call every delegate method on the connect thread, synchronously;
/// - copy credentials into `std::string`, call `provide_creds`, then `OPENSSL_cleanse` its buffers (§6.5);
/// - apply `OVPNFixedConfig` verbatim and never set `enableLegacyAlgorithms`.
public protocol OpenVPNClientFactory: Sendable {
    /// `eval_config` on a new client. Throws `.profileInvalid` on an EvalConfig error.
    func makeClient(config: OVPNClientConfig, delegate: any OpenVPNClientDelegate) throws(LPTunnelError) -> any OpenVPNClient
    /// `OpenVPNClientHelper::parse_dynamic_challenge` + `ChallengeResponse(cookie).get_username()`.
    func parseDynamicChallenge(_ cookie: SecretBytes) -> OVPNDynamicChallenge?
}

public protocol OpenVPNClient: AnyObject, Sendable {
    /// `provide_creds`; before `connect()`.
    func provideCredentials(_ c: OVPNProvideCreds) -> Bool
    /// Blocks until the session ends; runs every delegate callback on the calling thread. Dedicated `Thread` only.
    func connect() -> OVPNConnectStatus
    /// `Stop::stop()` on the shim-owned async stop: safe before, during and after `connect()` (sticky).
    func stop()
    func reconnect(seconds: Int)
    func pause(reason: String)
    func resume()
    func transportStats() -> OVPNTransportStats
    /// Cached by the shim inside the CONNECTED callback (cross-thread use is gated in openvpn3, §7.7).
    func connectionInfo() -> OVPNConnectionInfo?
}

/// Callbacks on the connect thread. Implementations are nonisolated and touch only Sendable state (§0 MUST).
public protocol OpenVPNClientDelegate: AnyObject, Sendable {
    func event(name: String, info: String, error: Bool, fatal: Bool)
    func log(_ line: String)
    /// `tun_builder_establish()`: return an fd openvpn3 will own and close (a `dup` or a socketpair end), or -1.
    func establish(_ plan: OVPNTunPlan) -> Int32
}

/// Per-profile values the adapter sets; everything else is `OVPNFixedConfig`.
public struct OVPNClientConfig: Sendable {
    public var content: SecretBytes                 // canonical profile text (§8.1); contains keys
    public var disableClientCert: Bool              // !(cert && key)
    public var enableNonPreferredDCAlgorithms: Bool // legacyCrypto flag (§8.6)
    public var privateKeyPassword: SecretBytes?
    /// `Config.proxyUsername/proxyPassword` (§8.4 "proxy* from inline creds").
    public var proxyUsername: SecretBytes?
    public var proxyPassword: SecretBytes?
    public var guiVersion: String
    public var fixed = OVPNFixedConfig()
    public init(content: SecretBytes, disableClientCert: Bool, enableNonPreferredDCAlgorithms: Bool,
                privateKeyPassword: SecretBytes? = nil, proxyUsername: SecretBytes? = nil, proxyPassword: SecretBytes? = nil,
                guiVersion: String = "LockPlus") {
        self.content = content; self.disableClientCert = disableClientCert
        self.enableNonPreferredDCAlgorithms = enableNonPreferredDCAlgorithms
        self.privateKeyPassword = privateKeyPassword; self.proxyUsername = proxyUsername; self.proxyPassword = proxyPassword
        self.guiVersion = guiVersion
    }
}

/// §8.4 shim `Config`: constants, asserted by tests. `enableLegacyAlgorithms` has no field and is never set (§8.6).
public struct OVPNFixedConfig: Sendable, Equatable {
    public let ssoMethods = ""                       // IV_SSO never advertised
    public let retryOnAuthFailed = false
    public let autologinSessions = true
    public let info = true
    public let echo = false
    public let connTimeout = 0
    public let tunPersist = false                    // S11, final
    public let googleDnsFallback = false
    public let dhcpSearchDomainsAsSplitDomains = false
    public let compressionMode = "asym"
    public let sslDebugLevel = 0
    public init() {}
}

public struct OVPNProvideCreds: Sendable {
    public var username: SecretBytes?
    public var password: SecretBytes?
    public var response: SecretBytes?
    public var dynamicChallengeCookie: SecretBytes?
}

public struct OVPNConnectStatus: Sendable, Equatable {
    public var error: Bool; public var status: String; public var message: String
    public init(error: Bool, status: String = "", message: String = "") { self.error = error; self.status = status; self.message = message }
}

public struct OVPNTransportStats: Sendable, Equatable {
    public var bytesIn: Int64; public var bytesOut: Int64
    /// Milliseconds since the last received packet; -1 undefined (`lastPacketReceived`, binary ms).
    public var lastPacketReceivedMs: Int
    public init(bytesIn: Int64 = 0, bytesOut: Int64 = 0, lastPacketReceivedMs: Int = -1) {
        self.bytesIn = bytesIn; self.bytesOut = bytesOut; self.lastPacketReceivedMs = lastPacketReceivedMs
    }
}

public struct OVPNConnectionInfo: Sendable, Equatable {
    public var serverIP: String; public var vpnIPv4: String?; public var vpnIPv6: String?; public var cipher: String?
    public init(serverIP: String, vpnIPv4: String? = nil, vpnIPv6: String? = nil, cipher: String? = nil) {
        self.serverIP = serverIP; self.vpnIPv4 = vpnIPv4; self.vpnIPv6 = vpnIPv6; self.cipher = cipher
    }
}

public struct OVPNDynamicChallenge: Sendable, Equatable {
    public var challenge: String; public var echo: Bool; public var responseRequired: Bool; public var username: String?
    public init(challenge: String, echo: Bool, responseRequired: Bool, username: String?) {
        self.challenge = challenge; self.echo = echo; self.responseRequired = responseRequired; self.username = username
    }
}

/// What the shim's TunBuilder collected in one session (ref/openvpn3 §4.2), raw. `OVPNPlanMapper` turns it into a
/// `NetworkPlan`.
public struct OVPNTunPlan: Sendable, Equatable {
    public struct Address: Sendable, Equatable { public var address: String; public var prefix: Int; public var ipv6: Bool
        public init(_ a: String, _ p: Int, ipv6: Bool) { address = a; prefix = p; self.ipv6 = ipv6 } }
    public struct Route: Sendable, Equatable { public var address: String; public var prefix: Int; public var ipv6: Bool
        public init(_ a: String, _ p: Int, ipv6: Bool) { address = a; prefix = p; self.ipv6 = ipv6 } }
    public struct DNSServer: Sendable, Equatable {
        public var priority: Int; public var addresses: [String]; public var resolveDomains: [String]
        public init(priority: Int, addresses: [String], resolveDomains: [String] = []) {
            self.priority = priority; self.addresses = addresses; self.resolveDomains = resolveDomains
        }
    }
    public var addresses: [Address] = []
    public var routes: [Route] = []
    public var excludedRoutes: [Route] = []
    public var rerouteIPv4 = false
    public var rerouteIPv6 = false
    public var dnsServers: [DNSServer] = []          // empty = tun_builder_set_dns_options never called
    public var searchDomains: [String] = []
    public var allowIPv4 = true
    public var allowIPv6 = true
    public var remoteAddress = ""
    public var mtu: Int?
    public init() {}
}

/// ref/openvpn3 §4.2/§4.4 + DESIGN §8.5 mapping.
public enum OVPNPlanMapper {
    public static func networkPlan(_ t: OVPNTunPlan) -> NetworkPlan {
        var p = NetworkPlan(remoteAddress: t.remoteAddress)
        for a in t.addresses {
            if a.ipv6 { p.ipv6.append(.init(a.address, a.prefix)) } else { p.ipv4.append(.init(a.address, a.prefix)) }
        }
        p.includedRoutes4 = t.routes.filter { !$0.ipv6 }.map { .init($0.address, $0.prefix) }
        p.includedRoutes6 = t.routes.filter(\.ipv6).map { .init($0.address, $0.prefix) }
        p.excludedRoutes4 = t.excludedRoutes.filter { !$0.ipv6 }.map { .init($0.address, $0.prefix) }
        p.excludedRoutes6 = t.excludedRoutes.filter(\.ipv6).map { .init($0.address, $0.prefix) }
        p.redirectGateway = RedirectGateway(v4: t.rerouteIPv4, v6: t.rerouteIPv6)
        p.allowIPv4 = t.allowIPv4
        p.allowIPv6 = t.allowIPv6
        if !t.dnsServers.isEmpty {
            // Ascending priority; a `:port` suffix is dropped (NE has no per-server port; Go stripDNSPort).
            var servers: [String] = [], split: [String] = []
            for s in t.dnsServers.sorted(by: { $0.priority < $1.priority }) {
                for a in s.addresses { let h = stripPort(a); if !h.isEmpty, !servers.contains(h) { servers.append(h) } }
                for d in s.resolveDomains where !split.contains(d) { split.append(d) }
            }
            if !servers.isEmpty { p.dns = DNSPlan(servers: servers, searchDomains: t.searchDomains, splitDomains: split) }
        }
        p.mtu = t.mtu
        return p
    }

    static func stripPort(_ s: String) -> String {
        if IPAddress.isV4(s) || IPAddress.isV6(s) { return s }
        if let hp = IPAddress.splitHostPort(s) { return hp.host }
        return s.hasSuffix("]") || s.hasPrefix("[") ? s.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) : ""
    }
}
