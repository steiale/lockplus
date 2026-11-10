import Foundation
import Testing
@testable import LPParsing
import LPModel

/// Fixture profiles (test material only; placeholder PEM, never a real key).
enum OVPNFixtures {
    static let pem = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n"
    static let key = "-----BEGIN PRIVATE KEY-----\nMIIB\n-----END PRIVATE KEY-----\n"

    /// The S13 base profile (fixtures.py base_profile) with placeholder PKI.
    static func base(_ extra: String = "", proto: String = "udp", withCert: Bool = true) -> String {
        var s = "client\ndev tun\nproto \(proto)\nremote vpn.example.invalid 1194\n" + extra
        if !s.hasSuffix("\n") { s += "\n" }
        s += "<ca>\n\(pem)</ca>\n"
        if withCert { s += "<cert>\n\(pem)</cert>\n<key>\n\(key)</key>\n" }
        return s
    }

    static func importing(_ s: String, options: OVPNNormalizerOptions = .init()) -> OVPNImportResult {
        OVPNImporter.importProfile(Array(s.utf8), options: options)
    }
}

extension OVPNImportResult {
    func reasons(_ g: ImportReportGroup) -> [ImportReason] { report.items(in: g).map(\.reason) }
    var directivesInCanonical: [String] { (stream ?? []).map { $0[0] } }
}

@Suite("OpenVPN normalizer (§8.1 [5], §8.2)")
struct OVPNNormalizerTests {
    // MARK: §8.6 rejections (draft 7): 64-bit-block ciphers, cipher none, digests under 160 bits

    @Test(arguments: ["BF-CBC", "bf-cbc", "DES-CBC", "DES-EDE3-CBC", "DES-EDE-CBC", "DES-EDE3", "3DES", "DESX-CBC",
                      "RC2-CBC", "RC2-40-CBC", "CAST5-CBC", "IDEA-CBC", "BF-CFB", "DES-OFB"])
    func rejects64BitBlockCiphers(_ cipher: String) {
        let r = OVPNFixtures.importing(OVPNFixtures.base("cipher \(cipher)\n"))
        #expect(r.verdict == .rejected)
        #expect(r.reasons(.notSupported) == [.outdatedCipher(name: cipher)])
        #expect(r.canonicalText == nil)
        let msg = r.report.items(in: .notSupported)[0].message(profileName: "office.ovpn")
        #expect(msg == "office.ovpn uses \(cipher), an outdated cipher LockPlus doesn't support. Ask the server's operator to enable AES-GCM.")
    }

    @Test func rejects64BitCipherBehindSetenvOpt() {
        let r = OVPNFixtures.importing(OVPNFixtures.base("setenv opt cipher BF-CBC\n"))
        #expect(r.reasons(.notSupported) == [.outdatedCipher(name: "BF-CBC")])
    }

    @Test func rejectsCipherNone() {
        let r = OVPNFixtures.importing(OVPNFixtures.base("cipher none\n"))
        #expect(r.reasons(.notSupported) == [.cipherNone])
    }

    @Test(arguments: ["MD5", "md5", "MD4", "RIPEMD128"])
    func rejectsDigestsUnder160Bits(_ d: String) {
        let r = OVPNFixtures.importing(OVPNFixtures.base("auth \(d)\n"))
        #expect(r.reasons(.notSupported) == [.weakDigest(name: d)])
    }

    @Test(arguments: ["SHA1", "SHA256", "SHA512", "none"])
    func acceptsDigests(_ d: String) {
        #expect(OVPNFixtures.importing(OVPNFixtures.base("auth \(d)\ncipher AES-256-GCM\n")).verdict != .rejected)
    }

    @Test func unknownCipherRejected() {
        #expect(OVPNFixtures.importing(OVPNFixtures.base("cipher CAMELLIA-256-CBC\n")).reasons(.notSupported) == [.unknownCipher(name: "CAMELLIA-256-CBC")])
    }

    @Test func cipherNameWithheldWhenNotAPlainName() {
        let r = OVPNFixtures.importing(OVPNFixtures.base("cipher \"BF-CBC secret\"\n"))
        #expect(r.reasons(.notSupported) == [.outdatedCipher(name: nil)])
    }

    @Test func aesCBCIsLegacyCryptoWithWarning() {
        let r = OVPNFixtures.importing(OVPNFixtures.base("cipher AES-256-CBC\nauth SHA1\n"))
        #expect(r.verdict == .importedWithWarnings)
        #expect(r.legacyCrypto)
        #expect(r.summary.usesLegacyCrypto)
        #expect(r.reasons(.securityWarning).contains(.legacyCBCEncryption))
    }

    @Test func aeadIsNotLegacy() {
        let r = OVPNFixtures.importing(OVPNFixtures.base("cipher AES-256-GCM\n"))
        #expect(!r.legacyCrypto)
        #expect(!r.reasons(.securityWarning).contains(.legacyCBCEncryption))
    }

    @Test func noCipherImportsNormally() {
        // A non-NCP server's BF-CBC fallback is a runtime error (.legacyCryptoUnavailable), not an import error.
        #expect(OVPNFixtures.importing(OVPNFixtures.base()).verdict != .rejected)
    }

    // MARK: duplicates (draft 7)

    @Test(arguments: [("cipher", "AES-256-GCM", "AES-128-GCM"), ("auth", "SHA256", "SHA512"),
                      ("tls-version-min", "1.2", "1.3"), ("remote-cert-tls", "server", "server"), ("tun-mtu", "1500", "1400"),
                      ("reneg-sec", "0", "3600"), ("route-metric", "1", "2"), ("inactive", "10", "20")])
    func repeatedSingletonKeepsLast(_ c: (String, String, String)) {
        let r = OVPNFixtures.importing(OVPNFixtures.base("\(c.0) \(c.1)\n\(c.0) \(c.2)\n"))
        #expect(r.verdict != .rejected)
        let kept = (r.stream ?? []).filter { $0[0] == c.0 }
        #expect(kept == [[c.0, c.2]])
        #expect(r.report.items(in: .note).contains { $0.reason == .duplicateKeptLast && $0.line == 5 && $0.directive == c.0 })
    }

    @Test func repeatableDirectivesStay() {
        let r = OVPNFixtures.importing(OVPNFixtures.base("route 10.0.0.0 255.0.0.0\nroute 10.1.0.0 255.255.0.0\nremote b.example.invalid 443\n"))
        #expect((r.stream ?? []).filter { $0[0] == "route" }.count == 2)
        #expect((r.stream ?? []).filter { $0[0] == "remote" }.count == 2)
    }

    @Test func repeatedIgnoredDirectiveIsJustIgnored() {
        let r = OVPNFixtures.importing(OVPNFixtures.base("persist-tun\npersist-tun\n"))
        #expect(r.report.items(in: .ignored).filter { $0.directive == "persist-tun" }.count == 2)
        #expect(!r.directivesInCanonical.contains("persist-tun"))
    }

    // MARK: http-proxy (draft 7)

    @Test func httpProxyWithOnlyUDPRemotesRejected() {
        let r = OVPNFixtures.importing(OVPNFixtures.base("http-proxy p.example.invalid 8080\n"))
        #expect(r.reasons(.notSupported) == [.httpProxyNeedsTCPRemote])
    }

    @Test func httpProxyWithTCPRemoteAccepted() {
        let r = OVPNFixtures.importing(OVPNFixtures.base("http-proxy p.example.invalid 8080\nhttp-proxy-option VERSION 1.1\n", proto: "tcp"))
        #expect(r.verdict != .rejected)
        #expect(r.directivesInCanonical.contains("http-proxy"))
        #expect(r.directivesInCanonical.contains("http-proxy-option"))
    }

    /// PF 51: the accepted proxy lands in the summary, so the app resolves it before each start like the remotes.
    @Test func httpProxyIsInTheSummaryForStartResolution() {
        let r = OVPNFixtures.importing(OVPNFixtures.base("http-proxy p.example.invalid 8080\n", proto: "tcp"))
        #expect(r.summary.proxyEndpoint == "p.example.invalid:8080")
        #expect(r.summary.resolvableEndpoints.last == "p.example.invalid:8080")
        #expect(r.summary.resolvableEndpoints.dropLast() == r.summary.endpoints[...])
        let v6 = OVPNFixtures.importing(OVPNFixtures.base("http-proxy 2001:db8::8 3128\n", proto: "tcp"))
        #expect(v6.summary.proxyEndpoint == "[2001:db8::8]:3128")
        #expect(OVPNFixtures.importing(OVPNFixtures.base("", proto: "tcp")).summary.proxyEndpoint == nil)
        // a rejected proxy line is not a proxy
        #expect(OVPNFixtures.importing(OVPNFixtures.base("http-proxy p.example.invalid 8080\n")).summary.proxyEndpoint == nil)
    }

    /// Additive and optional: summaries stored before PF 51 decode, and a summary without a proxy encodes no key.
    @Test func summaryWithoutProxyKeepsItsEncoding() throws {
        let old = Data(#"{"endpoints":["a:1"],"transport":"udp","addresses":[],"isFullTunnel":true,"dnsServers":[],"usesLegacyCrypto":false}"#.utf8)
        let s = try JSONDecoder().decode(ProfileSummary.self, from: old)
        #expect(s.proxyEndpoint == nil && s.endpoints == ["a:1"])
        #expect(!String(decoding: try JSONEncoder().encode(s), as: UTF8.self).contains("proxyEndpoint"))
    }

    @Test func httpProxyTCPViaConnectionBlock() {
        let r = OVPNFixtures.importing(OVPNFixtures.base("<connection>\nremote b.example.invalid 443 tcp\n</connection>\nhttp-proxy p.example.invalid 8080\n"))
        #expect(r.verdict != .rejected)
    }

    @Test func proxyCredentialsExtracted() throws {
        let r = OVPNFixtures.importing(OVPNFixtures.base("http-proxy p.example.invalid 8080 auto\n<http-proxy-user-pass>\npu\npp\n</http-proxy-user-pass>\n", proto: "tcp"))
        #expect(r.verdict != .rejected)
        #expect(!r.directivesInCanonical.contains("http-proxy-user-pass"))
        let u = try #require(r.credentials.proxyUsername)
        #expect(u.withUnsafeBytes { Array($0) } == Array("pu".utf8))
        #expect(!(r.canonicalText ?? "").contains("pp"))
    }

    @Test func proxyAuthWithoutInlineCredentialsRejected() {
        let r = OVPNFixtures.importing(OVPNFixtures.base("http-proxy p.example.invalid 8080 auto\n", proto: "tcp"))
        #expect(r.reasons(.notSupported) == [.proxyAuthNeedsInlineCredentials])
    }

    @Test func proxyOptionsWithoutProxyRejected() {
        #expect(OVPNFixtures.importing(OVPNFixtures.base("http-proxy-option VERSION 1.1\n")).reasons(.notSupported) == [.proxyOptionWithoutProxy])
        #expect(OVPNFixtures.importing(OVPNFixtures.base("<http-proxy-user-pass>\nu\np\n</http-proxy-user-pass>\n")).reasons(.notSupported) == [.proxyOptionWithoutProxy])
    }

    // MARK: auth-nocache for OTP-class profiles (draft 7, §8.4)

    @Test func authNocacheAppendedForStaticChallenge() {
        let r = OVPNFixtures.importing(OVPNFixtures.base("auth-user-pass\nstatic-challenge \"Enter OTP\" 1 concat\n"))
        #expect(r.otpClass)
        #expect(r.directivesInCanonical.filter { $0 == "auth-nocache" }.count == 1)
        #expect(r.auth.staticChallenge == StaticChallenge(text: "Enter OTP", echo: true, concat: true))
        #expect(r.auth.saveCredentials)   // the profile itself had no auth-nocache
    }

    @Test func authNocacheAppendedForAppendOTPAndCRV1() {
        for o in [OVPNNormalizerOptions(appendOTP: true), OVPNNormalizerOptions(dynamicChallengeSeen: true)] {
            let r = OVPNFixtures.importing(OVPNFixtures.base("auth-user-pass\n"), options: o)
            #expect(r.directivesInCanonical.contains("auth-nocache"))
        }
    }

    @Test func authNocacheNotAppendedOtherwise() {
        let r = OVPNFixtures.importing(OVPNFixtures.base("auth-user-pass\n"))
        #expect(!r.otpClass)
        #expect(!r.directivesInCanonical.contains("auth-nocache"))
        #expect(r.auth.needsUserPass)
    }

    @Test func authNocacheNotDuplicated() {
        let r = OVPNFixtures.importing(OVPNFixtures.base("auth-nocache\nauth-user-pass\nstatic-challenge \"OTP\" 0\n"))
        #expect(r.directivesInCanonical.filter { $0 == "auth-nocache" }.count == 1)
        #expect(!r.auth.saveCredentials)
        #expect(r.auth.staticChallenge?.echo == false)
    }

    // MARK: setenv opt X classified as X by our table (draft 7, S13 fixture list)

    @Test(arguments: [("socks-proxy 127.0.0.1 1080", ImportReportGroup.notSupported), ("management 127.0.0.1 7505", .notSupported),
                      ("register-dns", .ignored), ("ping-timer-rem", .ignored), ("route-gateway 10.0.0.1", .ignored),
                      ("fragment 1300", .notSupported), ("foo-bar", .notSupported), ("push \"route 1.2.3.4\"", .notSupported),
                      ("block-outside-dns", .ignored), ("user nobody", .notSupported), ("up /x", .notSupported)])
    func setenvOptClassifiedAsX(_ c: (String, ImportReportGroup)) {
        let r = OVPNFixtures.importing(OVPNFixtures.base("setenv opt \(c.0)\n"))
        let inner = String(c.0.split(separator: " ")[0])
        #expect(r.report.items.contains { $0.group == c.1 && $0.line == 5 }, "setenv opt \(inner)")
        #expect(!r.directivesInCanonical.contains(inner))
        #expect(!r.directivesInCanonical.contains("setenv") || c.1 != .notSupported)
    }

    @Test func setenvOptMappedEmittedAsDirective() {
        let r = OVPNFixtures.importing(OVPNFixtures.base("setenv opt keepalive 10 60\n"))
        #expect((r.stream ?? []).contains(["keepalive", "10", "60"]))
        #expect(!r.directivesInCanonical.contains("setenv"))
        #expect(!r.directivesInCanonical.contains("ping"))   // keepalive present via setenv opt: no floor
    }

    @Test func setenvIVSSOStripped() {
        let r = OVPNFixtures.importing(OVPNFixtures.base("setenv IV_SSO openurl\nsetenv UV_ID abc\n"))
        #expect(r.reasons(.ignored).contains(.webSignInNotSupported))
        #expect((r.stream ?? []).contains(["setenv", "UV_ID", "abc"]))
        #expect(!(r.canonicalText ?? "").contains("IV_SSO"))
    }

    // MARK: floors and appends (§8.1 [5], §1.3 A4)

    @Test func floorsAppendedWhenAbsent() {
        let r = OVPNFixtures.importing(OVPNFixtures.base())
        let s = r.stream ?? []
        #expect(s.contains(["ping", "10"]) && s.contains(["ping-restart", "60"]) && s.contains(["mssfix", "1300"]))
    }

    @Test func pingDroppedWhenKeepalivePresent() {
        let r = OVPNFixtures.importing(OVPNFixtures.base("keepalive 10 60\nping 10\nping-restart 60\n"))
        #expect(!r.directivesInCanonical.contains("ping") && !r.directivesInCanonical.contains("ping-restart"))
        #expect(r.reasons(.ignored).filter { $0 == .keepaliveTakesPrecedence }.count == 2)
    }

    @Test func pingKeptWithoutKeepalive() {
        let r = OVPNFixtures.importing(OVPNFixtures.base("ping 15\n"))
        #expect((r.stream ?? []).contains(["ping", "15"]))
        #expect(!(r.stream ?? []).contains(["ping", "10"]))
    }

    @Test func noMssfixFloorWithMTUDirective() {
        for d in ["mssfix 1400", "tun-mtu 1400", "link-mtu 1500"] {
            #expect(!(OVPNFixtures.importing(OVPNFixtures.base(d + "\n")).stream ?? []).contains(["mssfix", "1300"]), "\(d)")
        }
    }

    @Test func remoteCertEKUAppendedExactlyWhenNeeded() {
        let a = OVPNFixtures.importing(OVPNFixtures.base("remote-cert-tls server\n"))
        #expect((a.stream ?? []).contains(["remote-cert-eku", "TLS Web Server Authentication"]))
        let b = OVPNFixtures.importing(OVPNFixtures.base("remote-cert-tls server\nremote-cert-eku \"TLS Web Server Authentication\"\n"))
        #expect((b.stream ?? []).filter { $0[0] == "remote-cert-eku" }.count == 1)
        let c = OVPNFixtures.importing(OVPNFixtures.base())
        #expect(!c.directivesInCanonical.contains("remote-cert-eku"))
        #expect(c.reasons(.securityWarning).contains(.serverIdentityNotPinned))
        #expect(!a.reasons(.securityWarning).contains(.serverIdentityNotPinned))
    }

    // MARK: dev, tls-client/pull, <connection>

    @Test(arguments: ["dev tun0", "dev utun", "dev utun3", "dev-type tun"])
    func devRewrittenToTun(_ d: String) {
        let r = OVPNFixtures.importing(OVPNFixtures.base().replacingOccurrences(of: "dev tun\n", with: d + "\n"))
        #expect((r.stream ?? []).filter { $0[0] == "dev" || $0[0] == "dev-type" } == [["dev", "tun"]])
        #expect(r.reasons(.note).contains(.devRewrittenToTun))
    }

    @Test func tapRejectedWithTAPCopy() {
        let r = OVPNFixtures.importing(OVPNFixtures.base().replacingOccurrences(of: "dev tun\n", with: "dev tap\n"))
        #expect(r.reasons(.notSupported) == [.tapNotSupported])
        #expect(r.report.items[0].message() == "It needs a TAP adapter, which macOS doesn't support.")
    }

    @Test func tlsClientNeedsPull() {
        let noClient = OVPNFixtures.base().replacingOccurrences(of: "client\n", with: "")
        #expect(OVPNFixtures.importing(noClient + "tls-client\n").reasons(.notSupported) == [.tlsClientNeedsPull])
        #expect(OVPNFixtures.importing(noClient + "tls-client\npull\n").verdict != .rejected)
    }

    @Test func connectionBlockOnlyRemotePortProto() {
        let ok = OVPNFixtures.importing(OVPNFixtures.base("<connection>\nremote a.example.invalid 1194 udp\nport 443\nproto tcp\n</connection>\n"))
        #expect(ok.verdict != .rejected)
        #expect((ok.stream ?? []).contains(["connection", "remote \"a.example.invalid\" \"1194\" \"udp\"\nport \"443\"\nproto \"tcp\"\n"]))
        let bad = OVPNFixtures.importing(OVPNFixtures.base("<connection>\nremote a.example.invalid 1194 udp\nconnect-timeout 5\n</connection>\n"))
        #expect(bad.reasons(.notSupported) == [.notSupportedInsideConnection])
        #expect(bad.report.items(in: .notSupported)[0].directive == "connect-timeout")
    }

    @Test func connectionEndpointsInSummary() {
        let r = OVPNFixtures.importing(OVPNFixtures.base("<connection>\nremote [fd00::1] 443\nproto tcp-client\n</connection>\n"))
        #expect(r.summary.endpoints == ["vpn.example.invalid:1194", "[fd00::1]:443"])
        #expect(r.endpoints.map(\.transport) == ["udp", "tcp"])
    }

    // MARK: credentials (§6, §8.1 [5])

    @Test func inlineAuthUserPassExtracted() throws {
        let r = OVPNFixtures.importing(OVPNFixtures.base("<auth-user-pass>\nalice\ns3cret pw\n</auth-user-pass>\n"))
        #expect(r.verdict != .rejected)
        #expect((r.stream ?? []).contains(["auth-user-pass"]))
        #expect(!(r.canonicalText ?? "").contains("s3cret"))
        #expect(!(r.canonicalText ?? "").contains("alice"))
        let pw = try #require(r.credentials.password)
        #expect(pw.withUnsafeBytes { Array($0) } == Array("s3cret pw".utf8))
        #expect("\(pw)" == "<redacted>")
        #expect(!r.auth.needsUserPass)
        #expect(r.reasons(.note).contains(.credentialsExtracted))
    }

    @Test func inlineUsernameOnlyNeedsPassword() {
        let r = OVPNFixtures.importing(OVPNFixtures.base("<auth-user-pass>\nalice\n</auth-user-pass>\n"))
        #expect(r.auth.needsUserPass)
        #expect(r.credentials.password == nil && r.credentials.username != nil)
    }

    @Test func credentialsDroppedWhenRejected() {
        let r = OVPNFixtures.importing(OVPNFixtures.base("<auth-user-pass>\nalice\npw\n</auth-user-pass>\nup /x\n"))
        #expect(r.verdict == .rejected)
        #expect(r.credentials.isEmpty)
    }

    @Test func encryptedKeyNeedsPassphrase() {
        let s = OVPNFixtures.base().replacingOccurrences(of: "BEGIN PRIVATE KEY", with: "BEGIN ENCRYPTED PRIVATE KEY")
        #expect(OVPNFixtures.importing(s).auth.needsKeyPassphrase)
    }

    @Test func disableClientCertMirrorsCertAndKey() {
        #expect(!OVPNFixtures.importing(OVPNFixtures.base()).disableClientCert)
        #expect(OVPNFixtures.importing(OVPNFixtures.base("auth-user-pass\n", withCert: false)).disableClientCert)
    }

    // MARK: routes, unsupported table entries, forbidden

    @Test func routeGatewayRewritten() {
        let r = OVPNFixtures.importing(OVPNFixtures.base("route 10.0.0.0 255.0.0.0 10.8.0.5\n"))
        #expect((r.stream ?? []).contains(["route", "10.0.0.0", "255.0.0.0", "vpn_gateway"]))
        #expect(r.reasons(.note).contains(.routeGatewayRewritten))
    }

    @Test(arguments: [("rport 1194", ImportReason.separateRemotePortNotSupported), ("proto-force udp", .protoForceNotSupported),
                      ("socks-proxy 127.0.0.1 1080", .socksProxyNotSupported), ("fragment 1300", .fragmentNotSupported),
                      ("<pkcs12>\nMIIBAAAA\n</pkcs12>", .pkcs12NotSupported)])
    func unsupportedDirectives(_ c: (String, ImportReason)) {
        #expect(OVPNFixtures.importing(OVPNFixtures.base(c.0 + "\n")).reasons(.notSupported) == [c.1])
    }

    @Test func forbiddenNamesLineAndDirectiveNeverArguments() {
        let r = OVPNFixtures.importing(OVPNFixtures.base("verb 3\n\"log\" /secret/path\n"))
        let item = r.report.items(in: .notSupported)[0]
        #expect(item.line == 6 && item.directive == "log")
        #expect(!r.report.plainText().contains("/secret/path"))
    }

    @Test func everyViolationReported() {
        let r = OVPNFixtures.importing(OVPNFixtures.base("up /x\nlog /y\ncipher BF-CBC\n"))
        #expect(r.report.items(in: .notSupported).count == 3)
    }

    @Test func ignoredGroupCopy() {
        let r = OVPNFixtures.importing(OVPNFixtures.base("verb 3\n"))
        let item = r.report.items(in: .ignored)[0]
        #expect(item.line == 5 && item.directive == "verb" && item.message() == "logging is managed by LockPlus")
    }

    @Test func nativeAdditionsAccepted() {
        let r = OVPNFixtures.importing(OVPNFixtures.base("client-cert-not-required\nsni vpn.example.invalid\n"))
        #expect(r.verdict != .rejected)
        #expect(r.directivesInCanonical.contains("sni"))
    }

    @Test func serverConfigRejected() {
        #expect(OVPNFixtures.importing("remote h 1\n").reasons(.notSupported) == [.notAClientProfile])
        #expect(OVPNFixtures.importing("client\n").reasons(.notSupported).contains(.noRemote))
    }

    @Test func compressionWarning() {
        #expect(OVPNFixtures.importing(OVPNFixtures.base("compress lz4\n")).reasons(.securityWarning).contains(.compressionEnabled))
        #expect(!OVPNFixtures.importing(OVPNFixtures.base("comp-lzo no\n")).reasons(.securityWarning).contains(.compressionEnabled))
    }

    @Test func summaryFields() {
        let r = OVPNFixtures.importing(OVPNFixtures.base("redirect-gateway def1\ndhcp-option DNS 10.8.0.1\ndns server 1 address 10.9.0.1:53 [fd00::2]:53\n", proto: "tcp"))
        #expect(r.summary.isFullTunnel)
        #expect(r.summary.dnsServers == ["10.9.0.1", "fd00::2"])
        #expect(r.summary.transport == "tcp")
    }

    @Test func controlCharactersInArgumentRejected() {
        let r = OVPNFixtures.importing(OVPNFixtures.base("verify-x509-name \"a\u{0B}b\" name\n"))
        #expect(r.reasons(.notSupported) == [.controlCharacters])
    }

    @Test func controlCharactersInConnectionChildArgumentRejected() {
        let r = OVPNFixtures.importing(OVPNFixtures.base("<connection>\nremote \"a\u{0B}b.example.invalid\" 1194 udp\n</connection>\n"))
        #expect(r.verdict == .rejected)
        #expect(r.reasons(.notSupported).contains(.controlCharacters))
        #expect(r.canonicalText == nil)
    }

    @Test func invalidUTF8Rejected() {
        var bytes = Array(OVPNFixtures.base().utf8)
        bytes += Array("verify-x509-name ".utf8) + [0xC3, 0x28] + [0x0A]
        let r = OVPNImporter.importProfile(bytes)
        #expect(r.reasons(.notSupported) == [.invalidUTF8])
    }

    @Test func invalidUTF8InCommentIsFine() {
        var bytes = Array(OVPNFixtures.base().utf8)
        bytes += [0x23, 0xFF, 0xFE, 0x0A]
        #expect(OVPNImporter.importProfile(bytes).verdict != .rejected)
    }

    @Test func inlineBodyCloseTagLineRejected() {
        let r = OVPNFixtures.importing(OVPNFixtures.base("<tls-crypt>\nabc\n  </other>\n</tls-crypt>\n"))
        #expect(r.reasons(.notSupported) == [.inlineBodyLineStartsWithCloseTag])
    }

    @Test func crlfBodiesNormalized() {
        let s = OVPNFixtures.base().replacingOccurrences(of: "\n", with: "\r\n")
        let r = OVPNFixtures.importing(s)
        #expect(r.verdict != .rejected, "\(r.report.plainText())")
        #expect(!(r.canonicalText ?? "").utf8.contains(0x0D))
    }
}

@Suite("Fuzz regressions")
struct OVPNFuzzRegressionTests {
    /// fuzz_ovpn_import: a nested `setenv opt setenv opt socks-proxy` was classified as `setenv` (mapped) and
    /// re-emitted, so the canonical text was not a fixpoint and socks-proxy slipped past the table.
    @Test func nestedSetenvOptClassifiedByInnermost() {
        let r = OVPNFixtures.importing(OVPNFixtures.base("setenv opt setenv opt socks-proxy 127.0.0.1 1080\n"))
        #expect(r.reasons(.notSupported) == [.socksProxyNotSupported])
        let ok = OVPNFixtures.importing(OVPNFixtures.base("setenv opt setenv opt keepalive 10 60\n"))
        #expect((ok.stream ?? []).contains(["keepalive", "10", "60"]))
    }
}
