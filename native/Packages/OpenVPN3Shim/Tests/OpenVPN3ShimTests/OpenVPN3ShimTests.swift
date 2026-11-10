import Foundation
import OpenVPN3Options
import OpenVPN3Shim
import Testing

@Suite struct OpenVPN3ShimTests {
    static let profile = """
        client
        dev tun
        proto udp
        remote vpn.example.invalid 1194
        remote-cert-tls server
        cipher AES-256-GCM
        """

    @Test func coreLinksAgainstOpenSSL35() {
        #expect(LPOpenVPN3Core.opensslVersion.hasPrefix("OpenSSL 3.5"))
        #expect(LPOpenVPN3Core.coreCopyright.contains("OpenVPN"))
    }

    @Test func evalConfigReadsRemote() {
        let bytes = Array(Self.profile.utf8)
        let r = bytes.withUnsafeBytes { LPOpenVPN3Profile.evaluateBytes($0.baseAddress!, length: $0.count, disableClientCert: true) }
        #expect(r.remote == "vpn.example.invalid:1194/udp")
    }

    @Test func optionsParserListsDirectives() {
        let bytes = Array(Self.profile.utf8)
        let r = bytes.withUnsafeBytes { LPOpenVPN3Options.parseProfileBytes($0.baseAddress!, length: $0.count) }
        #expect(r["ok"] as? Bool == true)
        #expect(r["names"] as? [String] == ["client", "dev", "proto", "remote", "remote-cert-tls", "cipher"])
    }
}
