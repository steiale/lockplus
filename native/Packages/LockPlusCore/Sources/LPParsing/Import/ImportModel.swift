import Foundation
import LPModel

// Import-pipeline types that stay in LPParsing. ProfileSummary, AuthPolicy, StaticChallenge, ImportReport and
// OVPNImportLimits live in LPModel (DESIGN §3.1, §3.5), shared with the app UI and the XPC layer.

/// Credentials extracted from an inline `<auth-user-pass>` / `<http-proxy-user-pass>` block (§8.1 [5], §8.2 Proxy).
/// They are removed from the canonical text; the app stores them as its `CredentialRecord` (§6.1).
/// NOTE for P2a: LPWire's `CredentialRecord` has no proxy fields yet; `proxyUsername`/`proxyPassword` need a home
/// there (openvpn3 `Config.proxyUsername/proxyPassword`, §8.4).
public struct ExtractedCredentials: Sendable {
    public var username: SecretBytes?
    public var password: SecretBytes?
    public var proxyUsername: SecretBytes?
    public var proxyPassword: SecretBytes?

    public init(username: SecretBytes? = nil, password: SecretBytes? = nil, proxyUsername: SecretBytes? = nil,
                proxyPassword: SecretBytes? = nil) {
        self.username = username
        self.password = password
        self.proxyUsername = proxyUsername
        self.proxyPassword = proxyPassword
    }

    public var isEmpty: Bool { username == nil && password == nil && proxyUsername == nil && proxyPassword == nil }
}

/// An endpoint found at import, for the RouteProbe hook (§9.3).
public struct ImportEndpoint: Sendable, Equatable, Hashable {
    /// Hostname or IP literal, unbracketed.
    public var host: String
    public var port: String
    /// "udp" | "tcp"
    public var transport: String

    public init(host: String, port: String, transport: String) {
        self.host = host
        self.port = port
        self.transport = transport
    }

    /// "host:port", IPv6 bracketed.
    public var display: String { (host.contains(":") ? "[\(host)]" : host) + ":" + port }
}
