import Foundation
import LPModel
import LPParsing
import LPWire
import OpenVPN3Shim
import Testing
@testable import TunnelAdapters
@testable import TunnelAdaptersDev
@testable import TunnelEngine
import TunnelEngineTestSupport

/// The [6] option adapter, the payload validator ([1]–[7]), validateProfile routing and the shim config mapping.
@Suite struct OpenVPNAdapterTests {
    static let ca = """
        <ca>
        -----BEGIN CERTIFICATE-----
        MIIBajCCARCgAwIBAgIUYUlItjXyq/oPL323+UEfBRJHLrwwCgYIKoZIzj0EAwIw
        GzEZMBcGA1UEAwwQTG9ja1BsdXMgVGVzdCBDQTAeFw0yNjEwMjYxOTM0NTJaFw0z
        NjEwMjMxOTM0NTJaMBsxGTAXBgNVBAMMEExvY2tQbHVzIFRlc3QgQ0EwWTATBgcq
        hkjOPQIBBggqhkjOPQMBBwNCAARoBBdY4LSBETF3ZgvNNdg211FfXa971sRwBcHX
        uV+z54nec1GHb3XE+zsrJwlYpWhs0AnjBCNn/MiQeVV9I7HDozIwMDAdBgNVHQ4E
        FgQUBaAoiF6fizNSQckXGQDf4aenn2EwDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjO
        PQQDAgNIADBFAiA/I69WY2zd31DaPMtwK3IyTM4ArJUV3LTEzmErrYOzawIhAOqx
        Ck64Jlgvlq+x8bH9Q60GAgImzeskvCqh2UoX93af
        -----END CERTIFICATE-----
        </ca>
        """

    static func raw(_ extra: String = "") -> String {
        """
        client
        dev tun
        proto udp
        remote vpn.example.invalid 1194
        nobind
        remote-cert-tls server
        cipher AES-256-GCM
        auth-user-pass
        \(extra)
        \(ca)

        """
    }

    /// The canonical payload the app would provision for `raw` (LPParsing [1]–[5], plus [6] with the shim).
    static func canonical(_ extra: String = "") throws -> String {
        let r = OVPNImporter.importProfile(Array(raw(extra).utf8), optionsParser: ShimOptionsParser())
        #expect(r.differential == .passed, "\(r.report.plainText())")
        return try #require(r.canonicalText)
    }

    let validator = ExtensionPayloadValidator()

    @Test func optionAdapterMatchesOurStream() throws {
        let text = try Self.canonical()
        let theirs = try ShimOptionsParser().parse(canonical: text)
        guard case .success(let ds) = OVPNTokenizer.parse(Array(text.utf8)) else { Issue.record("tokenizer"); return }
        #expect(theirs == OVPNCanonical.stream(of: ds))
        #expect(theirs.contains { $0.first == "ca" && $0.count == 2 && $0[1].hasSuffix("-----END CERTIFICATE-----\n") })
    }

    @Test func optionAdapterThrowsOnRefusal() {
        #expect(throws: ShimOptionsParser.Refused.self) { try ShimOptionsParser().parse(canonical: "<ca>\nunterminated\n") }
    }

    @Test func canonicalPayloadPassesAndReportsAuthNeeds() throws {
        let p = SecretBytes(copying: Array(try Self.canonical().utf8))
        try validator.validate(kind: .openVPN, payload: p)
        let r = validator.evaluate(kind: .openVPN, payload: p, disableClientCert: nil)
        #expect(r.error == nil && !r.autologin && r.staticChallenge == nil && !r.privateKeyPasswordRequired)
    }

    @Test func staticChallengeIsReported() throws {
        let p = SecretBytes(copying: Array(try Self.canonical("static-challenge \"Enter PIN\" 1").utf8))
        let r = validator.evaluate(kind: .openVPN, payload: p, disableClientCert: true)
        #expect(r.error == nil && r.staticChallenge == "Enter PIN" && r.staticChallengeEcho)
    }

    @Test func inlineCredentialsInThePayloadAreRejected() throws {
        let text = try Self.canonical() + "<auth-user-pass>\nalice\nhunter2\n</auth-user-pass>\n"
        #expect(throws: LPTunnelError.self) { try validator.validate(kind: .openVPN, payload: .text(text)) }
        let r = validator.evaluate(kind: .openVPN, payload: .text(text), disableClientCert: nil)
        #expect(r.error != nil && r.error?.detail?.contains("hunter2") == false)
    }

    @Test func forbiddenDirectiveIsRejected() throws {
        let text = try Self.canonical() + "up \"/bin/sh\"\n"
        let r = validator.evaluate(kind: .openVPN, payload: .text(text), disableClientCert: nil)
        #expect(r.error?.code == .unsupportedDirective)
        #expect(r.error?.detail?.contains("/bin/sh") == false)
    }

    @Test func legacyCipherIsRejectedAsLegacyCrypto() {
        let r = validator.evaluate(kind: .openVPN, payload: .text(Self.raw("cipher BF-CBC")), disableClientCert: nil)
        #expect(r.error?.code == .legacyCryptoUnavailable)
    }

    @Test func nonCanonicalButParsablePayloadStillNeedsBothParsersToAgree() throws {
        // A payload whose bytes tokenize differently than openvpn3 parses them must be refused, even if
        // re-normalizing it would produce a clean canonical text.
        let r = validator.evaluate(kind: .openVPN, payload: .text(try Self.canonical() + "setenv \"A\" \"b c\"\\\n"), disableClientCert: nil)
        #expect(r.error != nil)
    }

    @Test func wireGuardPayloads() {
        let ok = WireGuardSessionTests.conf
        #expect(validator.evaluate(kind: .wireGuard, payload: .text(ok), disableClientCert: nil).error == nil)
        let bad = validator.evaluate(kind: .wireGuard, payload: .text("[Interface]\nPrivateKey = x\n"), disableClientCert: nil)
        #expect(bad.error != nil && bad.error?.detail?.contains("x\n") == false)
    }

    @Test func engineCategoryNeverQuotesArguments() {
        #expect(ExtensionPayloadValidator.category("UNUSED_OPTIONS: secret-arg here") == "UNUSED_OPTIONS")
        #expect(ExtensionPayloadValidator.category("") == "rejected by openvpn3")
    }

    /// validateProfile is answered by EngineServiceBackend with the validator's [7a] fields (simplification 5: the
    /// router is gone); other methods are served by the same backend.
    @Test func backendAnswersValidateProfileWithEngineFields() async throws {
        let controller = TunnelController(host: FakeHost(), secrets: InMemorySecretStore(), stateStore: InMemoryTunnelStateStore(),
                                          adapters: FakeAdapterFactory(), validator: FakeValidator(), clock: StrictSuspendingClock())
        let backend = EngineServiceBackend(controller: controller, secrets: InMemorySecretStore(), validator: validator)
        let peer = PeerContext(uid: 501, pid: 1)
        let text = try Self.canonical("static-challenge \"Code\" 0")
        let req = try LPWire.encode(ValidateProfileRequest(kind: .openVPN, payload: Data(text.utf8), disableClientCert: true))
        let data = try #require(try await backend.handle(.validateProfile, request: req, peer: peer).get())
        let reply = try LPWire.decode(ValidateProfileReply.self, data, max: 1 << 16)
        #expect(reply.isValid && reply.staticChallenge == "Code" && !reply.staticChallengeEcho && !reply.autologin)
        let list = try #require(try await backend.handle(.listProvisioned, request: try LPWire.encode(EmptyRequest()), peer: peer).get())
        #expect(try LPWire.decode(ListProvisionedReply.self, list, max: 1 << 16).entries.isEmpty)
    }

    /// OVPNClientConfig → shim config: per-profile flags and OVPNFixedConfig copied verbatim.
    @Test func shimConfigCopiesTheFixedConfigVerbatim() {
        let cfg = OVPNClientConfig(content: .text("client\n"), disableClientCert: false, enableNonPreferredDCAlgorithms: true,
                                   guiVersion: "LockPlus 2.0")
        let c = OpenVPN3ShimFactory.sessionConfig(cfg, platformVersion: "macOS 27.0.1")
        let f = OVPNFixedConfig()
        #expect(!c.disableClientCert && c.enableNonPreferredDCAlgorithms && c.guiVersion == "LockPlus 2.0")
        #expect(c.platformVersion == "macOS 27.0.1")
        #expect(c.ssoMethods == f.ssoMethods && c.retryOnAuthFailed == f.retryOnAuthFailed && c.autologinSessions == f.autologinSessions)
        #expect(c.info == f.info && c.echo == f.echo && c.connTimeout == f.connTimeout && c.tunPersist == f.tunPersist)
        #expect(c.googleDnsFallback == f.googleDnsFallback && c.dhcpSearchDomainsAsSplitDomains == f.dhcpSearchDomainsAsSplitDomains)
        #expect(c.compressionMode == f.compressionMode && c.sslDebugLevel == f.sslDebugLevel)
        #expect(!Mirror(reflecting: c).children.contains { $0.label?.lowercased().contains("legacy") == true })
        #expect(!c.responds(to: NSSelectorFromString("setEnableLegacyAlgorithms:")))
    }

    @Test func eventLoopTimeUnits() {
        #expect(OpenVPN3ShimFactory.milliseconds(binary: -1) == -1)
        #expect(OpenVPN3ShimFactory.milliseconds(binary: 1024) == 1000)
    }

    /// A real shim session through the factory: eval error → .profileInvalid without profile text.
    @Test func factoryMapsEvalErrors() {
        final class D: OpenVPNClientDelegate, @unchecked Sendable {
            func event(name: String, info: String, error: Bool, fatal: Bool) {}
            func log(_ line: String) {}
            func establish(_ plan: OVPNTunPlan) -> Int32 { -1 }
            func teardown(disconnect: Bool) {}
        }
        let d = D()
        do {
            _ = try OpenVPN3ShimFactory().makeClient(config: OVPNClientConfig(content: .text("client\nremote\nsecret-token-xyz\n"),
                                                                             disableClientCert: true, enableNonPreferredDCAlgorithms: false),
                                                     delegate: d)
            Issue.record("accepted")
        } catch {
            #expect(error.code == .profileInvalid && error.detail?.contains("secret-token-xyz") == false)
        }
        let dc = OpenVPN3ShimFactory().parseDynamicChallenge(.text("CRV1:R,E:Om01u7Fh4LrGBS7uh0SWmzwabUiGiW6l:Y3Ex:Enter PIN"))
        #expect(dc == OVPNDynamicChallenge(challenge: "Enter PIN", echo: true, responseRequired: true, username: "cq1"))
    }
}

/// The dev/release service prefix (§6.3), as the Release and Debug/FaultInjection configurations compile it.
@Suite struct SecretStorePrefixTests {
    @Test func releaseAndDevPrefixes() async throws {
        #expect(TunnelAdapters.TunnelSecretStore.servicePrefix == "io.github.steiale.lockplus.mac.tunnel.")
        #expect(TunnelAdaptersDev.TunnelSecretStore.servicePrefix == "io.github.steiale.lockplus.mac.tunnel.dev.")
        let be = FakeKeychainBackend()
        let store = TunnelAdaptersDev.TunnelSecretStore.make(backend: be)
        #expect(await store.service(.payload) == "io.github.steiale.lockplus.mac.tunnel.dev.payload")
        #expect(await TunnelAdapters.TunnelSecretStore.make(backend: be).service(.credential) == "io.github.steiale.lockplus.mac.tunnel.cred")
    }
}
