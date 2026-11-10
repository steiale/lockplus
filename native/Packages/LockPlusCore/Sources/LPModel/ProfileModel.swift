import Foundation

// DESIGN §3.1 profile model parts produced at import (moved from LPParsing unchanged).

/// Derived, non-secret summary for the list and detail views (§3.1).
public struct ProfileSummary: Codable, Sendable, Equatable, Hashable {
    /// "host:port" as written, IPv6 hosts bracketed; the first is primary.
    public var endpoints: [String]
    /// "udp" | "tcp" (of the primary endpoint).
    public var transport: String
    /// WG `Address`; empty for OpenVPN (unknown until connect).
    public var addresses: [String]
    /// WG 0/0 or ::/0; OVPN `redirect-gateway` in the profile.
    public var isFullTunnel: Bool
    public var dnsServers: [String]
    public var usesLegacyCrypto: Bool
    /// PENDING-FOLD 51: the OpenVPN `http-proxy` as "host:port" (IPv6 bracketed), nil without one. The app resolves a
    /// hostname here before each start, like the remotes (`lp.endpoints`), because under `includeAllNetworks`
    /// neither the provider nor openvpn3 may resolve it (S2 E10). Optional and additive: older metadata decodes as nil.
    public var proxyEndpoint: String?

    public init(endpoints: [String] = [], transport: String = "udp", addresses: [String] = [], isFullTunnel: Bool = false,
                dnsServers: [String] = [], usesLegacyCrypto: Bool = false, proxyEndpoint: String? = nil) {
        self.endpoints = endpoints
        self.transport = transport
        self.addresses = addresses
        self.isFullTunnel = isFullTunnel
        self.dnsServers = dnsServers
        self.usesLegacyCrypto = usesLegacyCrypto
        self.proxyEndpoint = proxyEndpoint
    }

    /// Every "host:port" the app resolves before a start (§9.3): the remotes, then the proxy.
    public var resolvableEndpoints: [String] { endpoints + (proxyEndpoint.map { [$0] } ?? []) }
}

/// `static-challenge "text" echo [concat]` (§3.1, §8.4).
public struct StaticChallenge: Codable, Sendable, Equatable, Hashable {
    public var text: String
    /// openvpn3 echoes only for "1".
    public var echo: Bool
    /// Third argument `concat`: the shim sends password + response as the password (Go `combineStaticChallenge`).
    public var concat: Bool

    public init(text: String, echo: Bool, concat: Bool) {
        self.text = text
        self.echo = echo
        self.concat = concat
    }
}

/// OpenVPN auth needs, derived at import (§3.1). `appendOTP` is the user's choice; import always sets false.
public struct AuthPolicy: Codable, Sendable, Equatable, Hashable {
    public var needsUserPass: Bool
    public var appendOTP: Bool
    /// false when the profile itself has `auth-nocache`.
    public var saveCredentials: Bool
    public var staticChallenge: StaticChallenge?
    public var needsKeyPassphrase: Bool

    public init(needsUserPass: Bool = false, appendOTP: Bool = false, saveCredentials: Bool = true,
                staticChallenge: StaticChallenge? = nil, needsKeyPassphrase: Bool = false) {
        self.needsUserPass = needsUserPass
        self.appendOTP = appendOTP
        self.saveCredentials = saveCredentials
        self.staticChallenge = staticChallenge
        self.needsKeyPassphrase = needsKeyPassphrase
    }
}
