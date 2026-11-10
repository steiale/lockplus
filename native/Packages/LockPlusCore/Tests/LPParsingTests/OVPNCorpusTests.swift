import Foundation
import Testing
@testable import LPParsing
import LPModel

/// The S13 corpus (native/spike/s13-s8/host/corpus.py; no real profiles) through the native pipeline, plus
/// pipeline-wide invariants over every shared Go vector.
@Suite("OpenVPN corpus (S13) and pipeline invariants")
struct OVPNCorpusTests {
    /// corpus.py crafted(): one case per fatal class / path. Expected native verdict: true = imports.
    static let crafted: [(String, String, Bool)] = [
        ("removed: no-iv", "no-iv\n", false),
        ("server-only: push", "push \"route 10.0.0.0 255.0.0.0\"\n", false),
        ("server-only: auth-gen-token", "auth-gen-token 3600\n", false),
        ("standalone: genkey", "genkey\n", false),
        ("not-impl-fatal: log", "log /x\n", false),
        ("not-impl-fatal: status", "status /x 1\n", false),
        ("not-impl-fatal: daemon", "daemon\n", false),
        ("not-impl-fatal: ping-timer-rem (dropped)", "ping-timer-rem\n", true),
        ("push-only: ifconfig", "ifconfig 10.8.0.2 255.255.255.0\n", false),
        ("push-only: auth-token", "auth-token abc\n", false),
        ("management", "management 127.0.0.1 7505\n", false),
        ("management-hold", "management-hold\n", false),
        ("management-foo", "management-foo\n", false),
        ("unknown: foo-bar", "foo-bar 1\n", false),
        ("unknown: proto-force", "proto-force udp\n", false),
        ("incompatible: secret", "secret /x\n", false),
        ("incompatible: fragment", "fragment 1300\n", false),
        ("incompatible: mode server", "mode server\n", false),
        ("incompatible: key-method 1", "key-method 1\n", false),
        ("meta: <pkcs12>", "<pkcs12>\nMIIBAAAA\n</pkcs12>\n", false),
        ("meta: <foo>", "<foo>\nbar\n</foo>\n", false),
        ("meta: <dh> (dropped)", "<dh>\nx\n</dh>\n", true),
        ("meta: <secret>", "<secret>\nx\n</secret>\n", false),
        ("dup: cipher", "cipher AES-256-GCM\ncipher AES-128-GCM\n", true),
        ("dup: auth", "auth SHA256\nauth SHA512\n", true),
        ("dup: tls-version-min", "tls-version-min 1.2\ntls-version-min 1.3\n", true),
        ("dup: remote-cert-tls", "remote-cert-tls server\nremote-cert-tls server\n", true),
        ("dup: verb", "verb 3\nverb 4\n", true),
        ("dup: tun-mtu", "tun-mtu 1500\ntun-mtu 1400\n", true),
        ("dup: persist-tun", "persist-tun\npersist-tun\n", true),
        ("setenv opt socks-proxy", "setenv opt socks-proxy 127.0.0.1 1080\n", false),
        ("setenv opt management", "setenv opt management 127.0.0.1 7505\n", false),
        ("setenv opt route-gateway", "setenv opt route-gateway 10.0.0.1\n", true),
        ("setenv opt push", "setenv opt push \"route 1.2.3.4\"\n", false),
        ("setenv opt fragment", "setenv opt fragment 1300\n", false),
        ("setenv opt foo-bar", "setenv opt foo-bar\n", false),
        ("ignore-unknown-option foo-bar + foo-bar", "ignore-unknown-option foo-bar\nfoo-bar\n", false),
        ("ignore-unknown-option ping-timer-rem + it", "ignore-unknown-option ping-timer-rem\nping-timer-rem\n", true),
        ("static-challenge concat", "auth-user-pass\nstatic-challenge \"Enter OTP\" 1 concat\n", true),
        ("connection block with extra option", "<connection>\nremote a.example 1194 udp\nconnect-timeout 5\nfoo-bar\n</connection>\n", false),
        ("route with explicit gateway", "route 10.0.0.0 255.0.0.0 10.8.0.5\n", true),
        ("http-proxy + udp remote", "http-proxy p.example 8080\n", false),
        ("cipher none", "cipher none\n", false),
        ("compress lz4 + comp-lzo", "compress lz4\ncomp-lzo yes\n", true),
    ]

    @Test(arguments: crafted.map(\.0))
    func craftedCase(_ name: String) throws {
        let c = try #require(Self.crafted.first { $0.0 == name })
        let r = OVPNFixtures.importing(OVPNFixtures.base(c.1))
        #expect((r.verdict != .rejected) == c.2, "\(name): \(r.report.plainText())")
    }

    @Test func craftedStructural() {
        #expect(OVPNFixtures.importing(OVPNFixtures.base().replacingOccurrences(of: "client\n", with: "")).verdict == .rejected)
        #expect(OVPNFixtures.importing(OVPNFixtures.base().replacingOccurrences(of: "dev tun\n", with: "dev tap\n")).verdict == .rejected)
        #expect(OVPNFixtures.importing(OVPNFixtures.base().replacingOccurrences(of: "dev tun\n", with: "dev utun3\n")).verdict != .rejected)
        #expect(OVPNFixtures.importing(OVPNFixtures.base("auth-user-pass\n", withCert: false)).verdict != .rejected)
    }

    /// RESULTS-S13-S8 A2: of the Go accept fixtures, `provider` (socks-proxy) and `connection blocks + inline creds`
    /// (connect-timeout / http-proxy inside <connection>) are rejected by the table; the rest import.
    @Test func goAcceptFixtures() {
        for v in GoVectorFile.shared.configs where v.name.hasPrefix("accept/") {
            let r = OVPNImporter.importProfile(Data(base64Encoded: v.input)!)
            let expectReject = ["accept/provider", "accept/connection blocks + inline creds", "accept/long inline line"].contains(v.name)
            #expect((r.verdict == .rejected) == expectReject, "\(v.name): \(r.report.plainText())")
        }
    }

    /// The allowlist stays the gate: every Go reject fixture is rejected natively too.
    @Test func goRejectFixtures() {
        for v in GoVectorFile.shared.configs where v.validate != nil {
            let r = OVPNImporter.importProfile(Data(base64Encoded: v.input)!)
            #expect(r.verdict == .rejected, "\(v.name) is rejected by Go but imports natively")
        }
    }

    /// Canonical text is a fixpoint and re-tokenizes to its own stream (§8.1, §15.4).
    @Test func canonicalIsFixpointForEveryAcceptedVector() throws {
        var accepted = 0
        let inputs = GoVectorFile.shared.configs.map { Array(Data(base64Encoded: $0.input)!) }
            + OVPNCorpusTests.crafted.map { Array(OVPNFixtures.base($0.1).utf8) }
        for bytes in inputs {
            let r = OVPNImporter.importProfile(bytes)
            guard let text = r.canonicalText, let stream = r.stream else { continue }
            accepted += 1
            let again = OVPNImporter.importProfile(Array(text.utf8), options: OVPNNormalizerOptions(dynamicChallengeSeen: r.otpClass))
            #expect(again.canonicalText == text)
            #expect(again.stream == stream)
            #expect(again.report.items(in: .note).filter { $0.reason != .duplicateKeptLast }.isEmpty)
            guard case .success(let ds) = OVPNTokenizer.parse(Array(text.utf8)) else {
                Issue.record("canonical text does not tokenize")
                continue
            }
            #expect(OVPNCanonical.stream(of: ds) == stream)
            // Nothing outside the engine's mapped set reaches it.
            for d in stream {
                #expect(OVPNEngineSupport.table[d[0]] == .mapped, "\(d[0]) reached canonical text")
            }
        }
        #expect(accepted > 60)
    }
}

@Suite("Canonical caps (§8.1 [5], boundary and +1)")
struct OVPNCapsTests {
    @Test func inlineLineAt512AndAbove() {
        let ok = OVPNFixtures.importing(OVPNFixtures.base("<tls-crypt>\n\(String(repeating: "A", count: 512))\n</tls-crypt>\n"))
        #expect(ok.verdict != .rejected)
        let over = OVPNFixtures.importing(OVPNFixtures.base("<tls-crypt>\n\(String(repeating: "A", count: 513))\n</tls-crypt>\n"))
        #expect(over.reasons(.notSupported) == [.limitExceeded(limit: .lineLength)])
    }

    @Test func directiveLineAt254AndAbove() {
        // `verify-x509-name "<n>" "name"`: 17 + 2 + n + 7 bytes.
        func profile(_ n: Int) -> String { OVPNFixtures.base("verify-x509-name \(String(repeating: "x", count: n)) name\n") }
        #expect(OVPNFixtures.importing(profile(254 - 26)).verdict != .rejected)
        #expect(OVPNFixtures.importing(profile(255 - 26)).reasons(.notSupported) == [.limitExceeded(limit: .directiveLineLength)])
    }

    @Test func quotingCountsTowardTheLineCap() {
        // Each `"` costs two bytes once escaped.
        let r = OVPNFixtures.importing(OVPNFixtures.base("verify-x509-name '\(String(repeating: "\"", count: 120))' name\n"))
        #expect(r.reasons(.notSupported) == [.limitExceeded(limit: .directiveLineLength)])
    }

    @Test func connectionBlockAt4096() {
        func block(_ count: Int) -> String {
            "<connection>\n" + Array(repeating: "remote h.example.invalid 1194", count: count).joined(separator: "\n") + "\n</connection>\n"
        }
        // each child line: `remote "h.example.invalid" "1194"` = 33 bytes + "\n" = 34
        #expect(OVPNFixtures.importing(OVPNFixtures.base(block(120))).verdict != .rejected)   // 4080
        #expect(OVPNFixtures.importing(OVPNFixtures.base(block(121))).reasons(.notSupported) == [.limitExceeded(limit: .connectionBlockSize)])   // 4114
    }

    @Test func profileSizeAccounting() {
        // 2200 routes of ~33 bytes + 64 + 16*3 each push the openvpn3 accounting past 262144 well before 1 MiB raw.
        let routes = (0..<2200).map { "route 10.\($0 / 256).\($0 % 256).0 255.255.255.0" }.joined(separator: "\n") + "\n"
        let r = OVPNFixtures.importing(OVPNFixtures.base(routes))
        #expect(r.reasons(.notSupported) == [.limitExceeded(limit: .profileSize)])
        let small = (0..<100).map { "route 10.0.\($0).0 255.255.255.0" }.joined(separator: "\n") + "\n"
        #expect(OVPNFixtures.importing(OVPNFixtures.base(small)).verdict != .rejected)
    }

    @Test func accountingBoundaryIsStrict() {
        let s = [["a", "b"]]
        #expect(OVPNCanonical.accounting(text: "a \"b\"\n", stream: s) == 6 + 64 + 32)
    }

    @Test func rawSizeCap() {
        var big = OVPNFixtures.base()
        big += "#" + String(repeating: "x", count: 200) + "\n"
        while big.utf8.count <= OVPNImportLimits.maxRawBytes { big += "#" + String(repeating: "x", count: 200) + "\n" }
        #expect(OVPNFixtures.importing(big).reasons(.notSupported) == [.fileTooLarge(limitBytes: 1 << 20)])
    }

    @Test func nulRejected() {
        #expect(OVPNImporter.importProfile(Array("client\u{0}\n".utf8)).reasons(.notSupported) == [.containsNULByte])
    }
}

@Suite("Engine seams: [6] OpenVPN3Options, [7] validateProfile, RouteProbe")
struct OVPNEngineSeamTests {
    struct EchoParser: OpenVPN3OptionsParsing {
        func parse(canonical: String) throws -> [[String]] {
            guard case .success(let ds) = OVPNTokenizer.parse(Array(canonical.utf8)) else { throw CancellationError() }
            return OVPNCanonical.stream(of: ds)
        }
    }
    struct DisagreeingParser: OpenVPN3OptionsParsing {
        func parse(canonical: String) throws -> [[String]] { [["client"]] }
    }
    struct ThrowingParser: OpenVPN3OptionsParsing {
        func parse(canonical: String) throws -> [[String]] { throw CancellationError() }
    }
    struct FakeValidator: OpenVPN3ProfileValidating {
        var verdict: OVPNEngineEvaluation.Verdict
        func validate(canonical: String, disableClientCert: Bool) async throws -> OVPNEngineEvaluation {
            OVPNEngineEvaluation(verdict: verdict, autologin: false, privateKeyPasswordRequired: true)
        }
    }
    struct FakeProbe: EndpointRouteProbing {
        func nonPrimaryInterface(for endpoint: ImportEndpoint) async -> String? {
            endpoint.host == "192.168.64.2" ? "bridge100" : nil
        }
    }

    @Test func differentialPasses() {
        let r = OVPNImporter.importProfile(Array(OVPNFixtures.base().utf8), optionsParser: EchoParser())
        #expect(r.differential == .passed)
        #expect(r.verdict != .rejected)
    }

    @Test func differentialDisagreementRejects() {
        for p: any OpenVPN3OptionsParsing in [DisagreeingParser(), ThrowingParser()] {
            let r = OVPNImporter.importProfile(Array(OVPNFixtures.base("<auth-user-pass>\nu\np\n</auth-user-pass>\n").utf8), optionsParser: p)
            #expect(r.differential == .failed)
            #expect(r.verdict == .rejected)
            #expect(r.reasons(.notSupported) == [.parserDisagreement])
            #expect(r.canonicalText == nil && r.credentials.isEmpty)
        }
    }

    @Test func withoutParserNotChecked() {
        #expect(OVPNImporter.importProfile(Array(OVPNFixtures.base().utf8)).differential == .notChecked)
    }

    @Test func engineValidation() async {
        let base = OVPNImporter.importProfile(Array(OVPNFixtures.base().utf8))
        let ok = await OVPNImporter.validateWithEngine(base, validator: FakeValidator(verdict: .accepted))
        #expect(ok.engineValidation == .passed)
        #expect(ok.auth.needsKeyPassphrase && ok.auth.needsUserPass)
        let bad = await OVPNImporter.validateWithEngine(base, validator: FakeValidator(verdict: .rejected(category: "UNKNOWN/UNSUPPORTED OPTIONS")))
        #expect(bad.engineValidation == .failed && bad.verdict == .rejected)
        #expect(bad.reasons(.notSupported) == [.engineValidationFailed(category: "UNKNOWN/UNSUPPORTED OPTIONS")])
    }

    @Test func routeProbeWarnsNeverRejects() async {
        let base = OVPNImporter.importProfile(Array(OVPNFixtures.base("remote 192.168.64.2 1194\n").utf8))
        let r = await OVPNImporter.probeRoutes(base, probe: FakeProbe())
        #expect(r.verdict == .importedWithWarnings)
        #expect(r.reasons(.securityWarning).contains(.serverOnOtherNetwork(interface: "bridge100")))
        #expect(r.report.items(in: .securityWarning).first { $0.reason == .serverOnOtherNetwork(interface: "bridge100") }!.message()
                == "This server is reached through bridge100. LockPlus's tunnel can only use your main network (Wi-Fi or Ethernet), so it may not connect.")
    }
}
