import Foundation
import LPOptionsParser
import LPModel
import LPParsing
import LPWire
import OpenVPN3Shim
import Testing
@testable import TunnelAdapters
@testable import TunnelAdaptersDev
@testable import TunnelEngine
import TunnelEngineTestSupport

/// The [6] option adapter, the extension's payload validator (2.0.2: provision = [1]–[5] + fixed point, start = + [6]),
/// validateProfile answering busy and the shim config mapping.
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

    func code(_ body: () throws(LPTunnelError) -> Void) -> LPErrorCode? {
        do throws(LPTunnelError) { try body(); return nil } catch { return error.code }
    }
    func provision(_ text: String, _ kind: VPNProtocolKind = .openVPN) -> LPErrorCode? {
        code { () throws(LPTunnelError) in try validator.validateForProvision(kind: kind, payload: .text(text)) }
    }
    func start(_ text: String, _ kind: VPNProtocolKind = .openVPN) -> LPErrorCode? {
        code { () throws(LPTunnelError) in try validator.validateForStart(kind: kind, payload: .text(text)) }
    }

    @Test func canonicalPayloadPassesProvisionAndStart() throws {
        let text = try Self.canonical()
        #expect(provision(text) == nil)
        #expect(start(text) == nil)
        let sc = try Self.canonical("static-challenge \"Enter PIN\" 1")
        #expect(provision(sc) == nil && start(sc) == nil)
    }

    /// The raw profile is not what the normaliser emits (it needs the floors): the extension refuses it at provision, so a
    /// payload the app never normalised (and never compared with openvpn3) is not accepted on the strength of parsers alone.
    @Test func aPayloadThatIsNotACanonicalFixedPointIsRefusedAtProvisionAndStart() {
        #expect(provision(Self.raw()) == .profileInvalid)
        #expect(start(Self.raw()) == .profileInvalid)
    }

    @Test func inlineCredentialsInThePayloadAreRejected() throws {
        let text = try Self.canonical() + "<auth-user-pass>\nalice\nhunter2\n</auth-user-pass>\n"
        for c in [provision(text), start(text)] { #expect(c == .profileInvalid) }
        let e: LPTunnelError? = { do throws(LPTunnelError) { try validator.validateForProvision(kind: .openVPN, payload: .text(text)); return nil } catch { return error } }()
        #expect(e?.detail?.contains("hunter2") == false)
    }

    @Test func forbiddenDirectiveIsRejected() throws {
        let text = try Self.canonical() + "up \"/bin/sh\"\n"
        #expect(provision(text) == .unsupportedDirective)
        let e: LPTunnelError? = { do throws(LPTunnelError) { try validator.validateForProvision(kind: .openVPN, payload: .text(text)); return nil } catch { return error } }()
        #expect(e?.detail?.contains("/bin/sh") == false)
    }

    @Test func legacyCipherIsRejectedAsLegacyCrypto() {
        #expect(provision(Self.raw("cipher BF-CBC")) == .legacyCryptoUnavailable)
    }

    @Test func nonCanonicalButParsablePayloadIsRefused() throws {
        // A payload whose bytes tokenize differently than openvpn3 parses them is never accepted.
        let text = try Self.canonical() + "setenv \"A\" \"b c\"\\\n"
        #expect(provision(text) != nil)
        #expect(start(text) != nil)
    }

    @Test func wireGuardPayloads() {
        let ok = WireGuardSessionTests.conf
        #expect(provision(ok, .wireGuard) == nil && start(ok, .wireGuard) == nil)
        #expect(provision("[Interface]\nPrivateKey = x\n", .wireGuard) != nil)
    }

    @Test func engineCategoryNeverQuotesArguments() {
        #expect(ProfileCheckRules.category("UNUSED_OPTIONS: secret-arg here") == "UNUSED_OPTIONS")
        #expect(ProfileCheckRules.category("") == "rejected by openvpn3")
    }

    /// 2.0.2: validateProfile is answered busy (evaluation moved to the app's validator service); other methods are
    /// served by the same backend.
    @Test func backendAnswersValidateProfileBusy() async throws {
        let controller = TunnelController(host: FakeHost(), secrets: InMemorySecretStore(), stateStore: InMemoryTunnelStateStore(),
                                          adapters: FakeAdapterFactory(), validator: FakeValidator(), clock: StrictSuspendingClock())
        let backend = EngineServiceBackend(controller: controller, secrets: InMemorySecretStore(), validator: validator)
        let peer = PeerContext(uid: 501, pid: 1)
        let text = try Self.canonical("static-challenge \"Code\" 0")
        let req = try LPWire.encode(ValidateProfileRequest(kind: .openVPN, payload: Data(text.utf8), disableClientCert: true))
        if case .failure(let e) = await backend.handle(.validateProfile, request: req, peer: peer) { #expect(e.code == .extensionBusy) } else { Issue.record("answered") }
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
