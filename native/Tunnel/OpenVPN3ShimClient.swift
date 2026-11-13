import Foundation
import LPOptionsParser
import LPModel
import OpenVPN3Shim
import TunnelEngine

/// `OpenVPNClientFactory` over OpenVPN3Shim (DESIGN §7.3, §8.4). One `LPOpenVPN3Session` per attempt; the shim
/// owns the `openvpn::Stop` and keeps it alive past the client (D73-3); OVPNFixedConfig is copied verbatim and the
/// shim has no way to set enableLegacyAlgorithms (§8.6).
struct OpenVPN3ShimFactory: OpenVPNClientFactory {
    /// `Config.platformVersion` (sent only with `push-peer-info`).
    let platformVersion: String

    init(platformVersion: String = OpenVPN3ShimFactory.macOSVersion) {
        self.platformVersion = platformVersion
        LPOpenVPN3Core.initializeCrypto()
    }

    static var macOSVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    func makeClient(config: OVPNClientConfig, delegate: any OpenVPNClientDelegate) throws(LPTunnelError) -> any OpenVPNClient {
        let c = Self.sessionConfig(config, platformVersion: platformVersion)
        let bridge = OpenVPN3DelegateBridge(delegate)
        var err: NSString?
        guard let session = LPOpenVPN3Session(config: c, delegate: bridge, error: &err) else {
            // L5: eval_config's raw message can quote option arguments (possibly secrets): only its category reaches
            // LPTunnelError.detail, as in the validator service.
            throw LPTunnelError(.profileInvalid, detail: (err as String?).map(ProfileCheckRules.category))
        }
        return OpenVPN3ShimClient(session)
    }

    func parseDynamicChallenge(_ cookie: SecretBytes) -> OVPNDynamicChallenge? {
        let dc = cookie.withUnsafeBytes { b -> LPOpenVPN3DynamicChallenge? in
            guard let base = b.baseAddress else { return nil }
            return LPOpenVPN3Profile.parseDynamicChallengeBytes(base, length: b.count)
        }
        guard let dc else { return nil }
        return OVPNDynamicChallenge(challenge: dc.challenge, echo: dc.echo, responseRequired: dc.responseRequired, username: dc.username)
    }

    /// OVPNClientConfig → the shim config: per-profile values, secrets as raw bytes, OVPNFixedConfig verbatim.
    static func sessionConfig(_ config: OVPNClientConfig, platformVersion: String) -> LPOpenVPN3SessionConfig {
        let c = LPOpenVPN3SessionConfig()
        set(c, .profile, config.content)
        if let p = config.privateKeyPassword { set(c, .privateKeyPassword, p) }
        if let p = config.proxyUsername { set(c, .proxyUsername, p) }
        if let p = config.proxyPassword { set(c, .proxyPassword, p) }
        c.disableClientCert = config.disableClientCert
        c.enableNonPreferredDCAlgorithms = config.enableNonPreferredDCAlgorithms
        c.guiVersion = config.guiVersion
        c.platformVersion = platformVersion
        let f = config.fixed
        c.ssoMethods = f.ssoMethods
        c.retryOnAuthFailed = f.retryOnAuthFailed
        c.autologinSessions = f.autologinSessions
        c.info = f.info
        c.echo = f.echo
        c.connTimeout = f.connTimeout
        c.tunPersist = f.tunPersist
        c.googleDnsFallback = f.googleDnsFallback
        c.dhcpSearchDomainsAsSplitDomains = f.dhcpSearchDomainsAsSplitDomains
        c.compressionMode = f.compressionMode
        c.sslDebugLevel = f.sslDebugLevel
        return c
    }

    private static func set(_ c: LPOpenVPN3SessionConfig, _ slot: LPOpenVPN3Secret, _ s: SecretBytes) {
        s.withUnsafeBytes { b in
            guard let base = b.baseAddress else { return }
            c.setSecret(slot, bytes: base, length: b.count)
        }
    }

    /// The shim's TunBuilder plan → TunnelEngine's raw `OVPNTunPlan` (OVPNPlanMapper builds the NetworkPlan).
    static func tunPlan(_ p: LPOpenVPN3TunPlan) -> OVPNTunPlan {
        var t = OVPNTunPlan()
        t.addresses = p.addresses.map { .init($0.address, $0.prefix, ipv6: $0.ipv6) }
        t.routes = p.routes.map { .init($0.address, $0.prefix, ipv6: $0.ipv6) }
        t.excludedRoutes = p.excludedRoutes.map { .init($0.address, $0.prefix, ipv6: $0.ipv6) }
        t.rerouteIPv4 = p.rerouteIPv4
        t.rerouteIPv6 = p.rerouteIPv6
        t.dnsServers = p.dnsServers.map { .init(priority: $0.priority, addresses: $0.addresses, resolveDomains: $0.resolveDomains) }
        t.searchDomains = p.searchDomains
        t.allowIPv4 = p.allowIPv4
        t.allowIPv6 = p.allowIPv6
        t.remoteAddress = p.remoteAddress
        t.mtu = p.mtu > 0 ? p.mtu : nil
        return t
    }

    /// `lastPacketReceived` is in binary milliseconds (1/1024 s); -1 stays undefined.
    static func milliseconds(binary: Int32) -> Int { binary < 0 ? -1 : Int(binary) * 1000 / 1024 }
}

/// One attempt's client. SAFETY (@unchecked Sendable): `LPOpenVPN3Session` is used by the connect thread
/// (`connect`) and, through the thread-safe calls only (stop/reconnect/pause/resume/stats/info), from elsewhere;
/// openvpn3 documents those as callable from any thread, and the shim's Stop and info cache are internally locked.
final class OpenVPN3ShimClient: OpenVPNClient, @unchecked Sendable {
    private let session: LPOpenVPN3Session
    init(_ session: LPOpenVPN3Session) { self.session = session }

    func provideCredentials(_ c: OVPNProvideCreds) -> Bool {
        let creds = LPOpenVPN3Credentials()
        func set(_ slot: LPOpenVPN3Secret, _ s: SecretBytes?) {
            s?.withUnsafeBytes { b in
                guard let base = b.baseAddress else { return }
                creds.setSecret(slot, bytes: base, length: b.count)
            }
        }
        set(.username, c.username)
        set(.password, c.password)
        set(.response, c.response)
        set(.dynamicChallengeCookie, c.dynamicChallengeCookie)
        return session.provideCredentials(creds)
    }

    func connect() -> OVPNConnectStatus {
        let s = session.connect()
        return OVPNConnectStatus(error: s.error, status: s.status, message: s.message)
    }

    func stop() { session.stop() }
    func reconnect(seconds: Int) { session.reconnect(seconds) }
    func pause(reason: String) { session.pause(reason) }
    func resume() { session.resume() }

    func transportStats() -> OVPNTransportStats {
        let t = session.transportStats()
        return OVPNTransportStats(bytesIn: t.bytesIn, bytesOut: t.bytesOut,
                                  lastPacketReceivedMs: OpenVPN3ShimFactory.milliseconds(binary: t.lastPacketReceived))
    }

    func connectionInfo() -> OVPNConnectionInfo? {
        guard let i = session.connectionInfo() else { return nil }
        // openvpn3's ConnectionInfo has no cipher; the detail panel's cipher stays nil (reported).
        return OVPNConnectionInfo(serverIP: i.serverIP, vpnIPv4: i.vpnIPv4, vpnIPv6: i.vpnIPv6, cipher: nil)
    }
}

/// The shim's ObjC delegate → TunnelEngine's `OpenVPNClientDelegate` (the adapter's `Attempt`). Held strongly by
/// the session; holds the attempt weakly (the attempt owns the client, so a strong reference would be a cycle).
/// SAFETY (@unchecked Sendable): `delegate` is a weak let to a Sendable object; every call arrives on the connect
/// thread (§7.3) and is forwarded synchronously.
final class OpenVPN3DelegateBridge: NSObject, LPOpenVPN3SessionDelegate, @unchecked Sendable {
    private weak var delegate: (any OpenVPNClientDelegate)?
    init(_ d: any OpenVPNClientDelegate) { delegate = d }

    func sessionEvent(_ name: String, info: String, error: Bool, fatal: Bool) {
        delegate?.event(name: name, info: info, error: error, fatal: fatal)
    }
    func sessionLog(_ line: String) { delegate?.log(line) }
    func sessionEstablish(_ plan: LPOpenVPN3TunPlan) -> Int32 {
        delegate?.establish(OpenVPN3ShimFactory.tunPlan(plan)) ?? -1
    }
}
