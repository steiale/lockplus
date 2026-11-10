import Foundation
import LPModel
import Testing
@testable import TunnelAdapters
@testable import TunnelEngine
import TunnelEngineTestSupport

/// LPWGConfigParser (LPParsing WGConfig → WGSessionConfig) and the UAPI text TunnelEngine builds from it (§9.1, §9.2).
@Suite struct WireGuardSessionTests {
    static let privB64 = Data(repeating: 0x11, count: 32).base64EncodedString()
    static let pubB64 = Data(repeating: 0x22, count: 32).base64EncodedString()
    static let pskB64 = Data(repeating: 0x33, count: 32).base64EncodedString()
    static let pub2B64 = Data(repeating: 0x44, count: 32).base64EncodedString()

    static var conf: String {
        """
        [Interface]
        PrivateKey = \(privB64)
        Address = 10.7.0.2/24, fd00::2
        DNS = 10.7.0.1, corp.example
        MTU = 1380
        ListenPort = 51900

        [Peer]
        PublicKey = \(pubB64)
        PresharedKey = \(pskB64)
        Endpoint = [2001:db8::1]:51820
        AllowedIPs = 0.0.0.0/0, 10.9.0.1/16
        PersistentKeepalive = 25

        [Peer]
        PublicKey = \(pub2B64)
        Endpoint = vpn.example:443
        AllowedIPs = 192.0.2.7
        PersistentKeepalive = off
        """
    }

    @Test func parsesIntoTheSessionConfig() throws {
        let c = try LPWGConfigParser().parse(.text(Self.conf))
        #expect(c.privateKey.bytesForTest == Array(repeating: 0x11, count: 32))
        #expect(c.addresses == ["10.7.0.2/24", "fd00::2/128"])
        #expect(c.dnsServers == ["10.7.0.1"] && c.searchDomains == ["corp.example"])
        #expect(c.mtu == 1380 && c.listenPort == 51900)
        #expect(c.peers.count == 2)
        let p0 = c.peers[0], p1 = c.peers[1]
        #expect(p0.publicKey == Data(repeating: 0x22, count: 32))
        #expect(p0.presharedKey?.bytesForTest == Array(repeating: 0x33, count: 32))
        #expect(p0.endpointHost == "2001:db8::1" && p0.endpointPort == 51820)
        #expect(p0.allowedIPs == ["0.0.0.0/0", "10.9.0.0/16"])          // host bits normalized (§9.1)
        #expect(p0.persistentKeepalive == 25)
        #expect(p1.endpointHost == "vpn.example" && p1.endpointPort == 443)
        #expect(p1.allowedIPs == ["192.0.2.7/32"] && p1.persistentKeepalive == nil && p1.presharedKey == nil)
    }

    @Test func invalidProfilesNeverEchoKeys() {
        let bad = Self.conf.replacingOccurrences(of: "PublicKey = \(Self.pubB64)", with: "PublicKey = notakey")
        do { _ = try LPWGConfigParser().parse(.text(bad)); Issue.record("accepted") } catch {
            #expect(error.code == .profileInvalid)
            #expect(error.detail?.contains("notakey") == false && error.detail?.contains(Self.privB64) == false)
        }
        do { _ = try LPWGConfigParser().parse(.text("[Interface]\nPrivateKey = \(Self.privB64)\n")); Issue.record("accepted") } catch {
            #expect(error.code == .profileInvalid)                       // no peer
        }
        let prefix = Self.conf.replacingOccurrences(of: "10.9.0.1/16", with: "10.9.0.1/33")
        #expect(throws: LPTunnelError.self) { try LPWGConfigParser().parse(.text(prefix)) }
    }

    /// The UAPI wireguard-go receives (IpcSet): hex keys, endpoints from resolution, keepalive, allowed IPs.
    @Test func uapiFromTheParsedProfile() throws {
        let c = try LPWGConfigParser().parse(.text(Self.conf))
        let uapi = WGUAPI.build(c, endpoints: [0: "[2001:db8::1]:51820", 1: "198.51.100.9:443"])
        let text = String(decoding: uapi.bytesForTest, as: UTF8.self)
        let hex = { (b: UInt8) in String(repeating: String(format: "%02x", b), count: 32) }
        #expect(text == """
            private_key=\(hex(0x11))
            listen_port=51900
            replace_peers=true
            public_key=\(hex(0x22))
            preshared_key=\(hex(0x33))
            endpoint=[2001:db8::1]:51820
            persistent_keepalive_interval=25
            replace_allowed_ips=true
            allowed_ip=0.0.0.0/0
            allowed_ip=10.9.0.0/16
            public_key=\(hex(0x44))
            endpoint=198.51.100.9:443
            replace_allowed_ips=true
            allowed_ip=192.0.2.7/32

            """)
    }

    /// The plan the controller applies: routes from AllowedIPs, a /0 as redirect-gateway, DNS, MTU.
    @Test func planFromTheParsedProfile() throws {
        let c = try LPWGConfigParser().parse(.text(Self.conf))
        let p = WireGuardAdapter<ContinuousClock>.plan(c, remote: "2001:db8::1")
        #expect(p.redirectGateway.v4 && !p.redirectGateway.v6)
        #expect(p.includedRoutes4.contains(.init("10.9.0.0", 16)) && p.includedRoutes4.contains(.init("192.0.2.7", 32)))
        #expect(p.dns == DNSPlan(servers: ["10.7.0.1"], searchDomains: ["corp.example"]) && p.mtu == 1380)
    }
}
