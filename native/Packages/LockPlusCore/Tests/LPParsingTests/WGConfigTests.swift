import Foundation
import Testing
@testable import LPParsing
import LPModel

/// Port of internal/config/parser_test.go and validator_dns_test.go, plus the §15.1 additions.
/// Keys are the Go tests' public test keys (no real profile).
@Suite("WireGuard parser and validator (§9.1)")
struct WGConfigTests {
    static let priv = "yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk="
    static let pub = "xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg="
    static let pub2 = "TrMvSoP4jYQlY6RIzBgbssQqY3vxI2piVFBs2LPqG08="
    static let validConf = """
    [Interface]
    PrivateKey = \(priv)
    Address = 10.0.0.2/24
    DNS = 1.1.1.1, 8.8.8.8
    MTU = 1420

    [Peer]
    PublicKey = \(pub)
    Endpoint = vpn.example.com:51820
    AllowedIPs = 0.0.0.0/0, ::/0
    PersistentKeepalive = 25

    """

    static func parse(_ s: String) -> Result<WGParser.Parsed, WGParseError> { WGParser.parse(Array(s.utf8)) }
    static func cfg(_ s: String) throws -> WGConfig { try parse(s).get().config }
    static func fields(_ s: String) throws -> [String] { WGValidator.validate(try cfg(s)).map(\.field) }
    static func conf(iface: String = "", peer: String = "AllowedIPs = 0.0.0.0/0") -> String {
        "[Interface]\nPrivateKey = \(priv)\nAddress = 10.0.0.2/24\n\(iface)\n[Peer]\nPublicKey = \(pub)\n\(peer)\n"
    }

    // MARK: parser_test.go

    @Test func parseValidConfig() throws {
        let c = try Self.cfg(Self.validConf)
        #expect(c.interface.privateKey == Self.priv)
        #expect(c.interface.addresses == ["10.0.0.2/24"])
        #expect(c.interface.dns.count == 2)
        #expect(c.interface.mtu == 1420)
        #expect(c.peers.count == 1)
        #expect(c.peers[0].publicKey == Self.pub)
        #expect(c.peers[0].endpoint == "vpn.example.com:51820")
        #expect(c.peers[0].allowedIPs.count == 2)
        #expect(c.peers[0].persistentKeepalive == 25)
        #expect(WGValidator.validate(c).isEmpty)
    }

    @Test func parseMultiplePeers() throws {
        let c = try Self.cfg("[Interface]\nPrivateKey = \(Self.priv)\nAddress = 10.0.0.2/24\n\n[Peer]\nPublicKey = \(Self.pub)\nAllowedIPs = 10.0.0.0/24\n\n[Peer]\nPublicKey = \(Self.pub2)\nEndpoint = 192.168.1.1:51820\nAllowedIPs = 192.168.1.0/24\n")
        #expect(c.peers.count == 2)
        #expect(c.peers[1].endpoint == "192.168.1.1:51820")
    }

    @Test func parseWithScripts() throws {
        let c = try Self.cfg(Self.conf(iface: "PostUp = iptables -A FORWARD -i %i -j ACCEPT\nPreDown = iptables -D FORWARD -i %i -j ACCEPT"))
        #expect(c.interface.hasScripts)
        #expect(!c.interface.postUp.isEmpty && !c.interface.preDown.isEmpty && c.interface.preUp.isEmpty)
    }

    @Test func invalidSyntaxAndEmpty() {
        #expect((try? Self.cfg("not a valid config")) == nil)
        #expect((try? Self.cfg("")) == nil)
    }

    @Test func commentsAndEmptyLines() throws {
        let r = try Self.parse("# c\n; also\n\n[Interface]\nPrivateKey = \(Self.priv)\nAddress = 10.0.0.2/24\n\n# Peer\n[Peer]\nPublicKey = \(Self.pub)\nAllowedIPs = 0.0.0.0/0\n").get()
        #expect(r.config.peers.count == 1)
        #expect(r.notes.map(\.reason) == [.wgSemicolonLineSkipped])
        #expect(r.notes[0].line == 2)
    }

    @Test func missingPrivateKeyIsParseError() {
        #expect((try? Self.cfg("[Interface]\nAddress = 10.0.0.2/24\n\n[Peer]\nPublicKey = \(Self.pub)\nAllowedIPs = 0.0.0.0/0\n")) == nil)
    }

    @Test func validationErrors() throws {
        #expect(try Self.fields("[Interface]\nPrivateKey = \(Self.priv)\n\n[Peer]\nPublicKey = \(Self.pub)\nAllowedIPs = 0.0.0.0/0\n").contains("Interface.Address"))
        #expect(WGValidator.validate(try Self.cfg(Self.validConf.replacingOccurrences(of: Self.priv, with: "not-a-valid-base64-key!!!")))
                .contains(ValidationIssue(field: "Interface.PrivateKey", problem: .invalidKey)))
        #expect(WGValidator.validate(try Self.cfg(Self.validConf.replacingOccurrences(of: "10.0.0.2/24", with: "10.0.0/24"))).map(\.problem).contains(.invalidCIDR))
        #expect(try Self.fields(Self.conf(peer: "Endpoint = invalid-endpoint\nAllowedIPs = 0.0.0.0/0")).contains("Peer[0].Endpoint"))
        #expect(try Self.fields("[Interface]\nPrivateKey = \(Self.priv)\nAddress = 10.0.0.2/24\n").contains("Peer"))
        #expect(try Self.fields("[Interface]\nPrivateKey = \(Self.priv)\nAddress = 10.0.0.2/24\n[Peer]\nAllowedIPs = 0.0.0.0/0\n").contains("Peer[0].PublicKey"))
        let many = try Self.cfg("[Interface]\nPrivateKey = not-a-valid-key\nAddress = bad-cidr\n\n[Peer]\nEndpoint = no-port\nAllowedIPs = also-bad\n")
        #expect(WGValidator.validate(many).count >= 3)
    }

    @Test func serializeRoundTrip() throws {
        let c = try Self.cfg(Self.validConf)
        let c2 = try Self.cfg(WGSerializer.serialize(c))
        #expect(c2 == c)
    }

    @Test func fullTunnel() throws {
        #expect(try Self.cfg(Self.validConf).isFullTunnel)
        #expect(try !Self.cfg(Self.conf(peer: "AllowedIPs = 10.0.0.0/24")).isFullTunnel)
    }

    @Test func wgQuickCompat() throws {
        let conf = "[Interface] # trailing comment\nPrivateKey = \(Self.priv) # key comment\nAddress = 10.0.0.2, fd00::2 # bare IPs\nZeta = 1\nAlpha = a\nZeta = 2\n\n[Peer]\nPublicKey = \(Self.pub)\nAllowedIPs = 10.0.0.1, 10.1.0.0/16#no space\n"
        let c = try Self.cfg(conf)
        #expect(c.interface.privateKey == Self.priv)
        #expect(c.interface.addresses == ["10.0.0.2/32", "fd00::2/128"])
        #expect(c.peers[0].allowedIPs == ["10.0.0.1/32", "10.1.0.0/16"])
        #expect(WGValidator.validate(c).isEmpty)
        let out = WGSerializer.serialize(c)
        #expect(out.contains("Alpha = a\nZeta = 1\nZeta = 2\n"))
        #expect(WGSerializer.serialize(try Self.cfg(out)) == out)
    }

    // MARK: validator_dns_test.go

    @Test(arguments: [(["1.1.1.1"], false), (["corp.example.com"], false), (["1.1.1.1", "corp.example.com"], false),
                      (["2606:4700:4700::1111"], false), (["not a hostname"], true), (["-bad.example.com"], true)])
    func mixedDNS(_ c: ([String], Bool)) {
        var cfg = WGConfig()
        cfg.interface.privateKey = "cGFzc3dvcmRwYXNzd29yZHBhc3N3b3JkcGFzc3dvcmQ="
        cfg.interface.addresses = ["10.0.0.2/24"]
        cfg.interface.dns = c.0
        var p = WGPeer()
        p.publicKey = "cGFzc3dvcmRwYXNzd29yZHBhc3N3b3JkcGFzc3dvcmQ="
        p.allowedIPs = ["0.0.0.0/0"]
        cfg.peers = [p]
        #expect(WGValidator.validate(cfg).contains { $0.field == "Interface.DNS" } == c.1)
    }

    // MARK: §15.1 additions

    @Test func hooksKeepHashUnstripped() throws {
        let c = try Self.cfg(Self.conf(iface: "PostUp = echo '#not a comment' # still part of the hook"))
        #expect(c.interface.postUp == ["echo '#not a comment' # still part of the hook"])
    }

    @Test func crlfLines() throws {
        let c = try Self.cfg(Self.validConf.replacingOccurrences(of: "\n", with: "\r\n"))
        #expect(WGValidator.validate(c).isEmpty)
        #expect(c.peers[0].endpoint == "vpn.example.com:51820")
    }

    @Test func bomStripped() throws {
        #expect(try Self.cfg("\u{FEFF}" + Self.validConf).interface.privateKey == Self.priv)
    }

    @Test func persistentKeepaliveOff() throws {
        let c = try Self.cfg(Self.conf(peer: "AllowedIPs = 0.0.0.0/0\nPersistentKeepalive = off"))
        #expect(c.peers[0].persistentKeepalive == 0)
        #expect(WGValidator.validate(c).isEmpty)
    }

    @Test(arguments: ["10.0.0.0/33", "fd00::/129"])
    func prefixTooLongRejectedNotClamped(_ p: String) throws {
        let c = try Self.cfg(Self.conf(peer: "AllowedIPs = \(p)"))
        #expect(WGValidator.validate(c) == [ValidationIssue(field: "Peer[0].AllowedIPs", problem: .prefixTooLong)])
    }

    @Test(arguments: ["PrivateKey = \(priv)", "MTU = 1400", "ListenPort = 51820", "Table = off", "FwMark = 0x10"])
    func duplicateScalarRejected(_ line: String) {
        let s = Self.conf(iface: line + "\n" + line)
        guard case .failure(let e) = Self.parse(s) else { Issue.record("accepted duplicate"); return }
        #expect(e.message.contains("duplicate key"))
        #expect(!e.message.contains(Self.priv))
    }

    @Test func duplicatePeerScalarRejected() {
        guard case .failure = Self.parse(Self.conf(peer: "AllowedIPs = 0.0.0.0/0\nEndpoint = a.example:1\nEndpoint = b.example:2")) else {
            Issue.record("accepted"); return
        }
    }

    @Test func listKeysAccumulate() throws {
        let c = try Self.cfg(Self.conf(iface: "Address = fd00::2/64\nDNS = 1.1.1.1\nDNS = corp.example\nPostUp = a\nPostUp = b",
                                       peer: "AllowedIPs = 10.0.0.0/8\nAllowedIPs = 192.168.0.0/16"))
        #expect(c.interface.addresses == ["10.0.0.2/24", "fd00::2/64"])
        #expect(c.interface.dns == ["1.1.1.1", "corp.example"])
        #expect(c.interface.postUp == ["a", "b"])
        #expect(c.peers[0].allowedIPs == ["10.0.0.0/8", "192.168.0.0/16"])
    }

    @Test func multipleInterfacesAndDuplicatePeers() throws {
        #expect((try? Self.cfg(Self.validConf + "\n[Interface]\nMTU = 1\n")) == nil)
        let dupPeer = try Self.cfg(Self.validConf + "\n[Peer]\nPublicKey = \(Self.pub)\nAllowedIPs = 10.0.0.0/8\n")
        #expect(WGValidator.validate(dupPeer).contains(ValidationIssue(field: "Peer[1].PublicKey", problem: .duplicatePeer)))
    }

    @Test func hostBitsNormalizedWithWarning() {
        let r = WGImporter.importProfile(Array(Self.conf(peer: "AllowedIPs = 10.0.0.1/24, 0.0.0.0/0").utf8))
        #expect(r.config?.peers[0].allowedIPs == ["10.0.0.0/24", "0.0.0.0/0"])
        #expect(r.report.items.contains { $0.reason == .wgHostBitsNormalized })
        #expect(r.config?.interface.addresses == ["10.0.0.2/24"])   // interface addresses keep their host bits
    }

    @Test(arguments: ["0x1F", "0X10", "off", "OFF", "51820"])
    func fwMarkValid(_ v: String) throws {
        #expect(WGValidator.validate(try Self.cfg(Self.conf(iface: "FwMark = \(v)"))).isEmpty)
    }

    @Test(arguments: ["0x", "0xZZ", "mark", "-"])
    func fwMarkInvalid(_ v: String) throws {
        #expect(WGValidator.validate(try Self.cfg(Self.conf(iface: "FwMark = \(v)"))).map(\.problem) == [.invalidFwMark])
    }

    @Test(arguments: [("off", true), ("auto", true), ("1234", true), ("main", false)])
    func tableSyntax(_ c: (String, Bool)) throws {
        #expect(WGValidator.validate(try Self.cfg(Self.conf(iface: "Table = \(c.0)"))).isEmpty == c.1)
    }

    @Test(arguments: [("[fd00::1]:51820", true), ("1.2.3.4:1", true), ("h.example:65535", true), ("h.example:0", false),
                      ("h.example:65536", false), ("fd00::1:51820", false), ("h_x.example:1", false), (":1", false),
                      ("1.2.3.4\nPostUp = evil:1", false)])
    func endpointSyntax(_ c: (String, Bool)) {
        #expect((WGValidator.endpointProblem(c.0) == nil) == c.1, "\(c.0)")
    }

    @Test func mtuRangeAndWarning() throws {
        #expect(WGValidator.validate(try Self.cfg(Self.conf(iface: "MTU = 575"))).map(\.problem) == [.mtuOutOfRange])
        let r = WGImporter.importProfile(Array(Self.conf(iface: "MTU = 9001").utf8))
        #expect(r.verdict == .importedWithWarnings)
        #expect(r.report.items.contains { $0.reason == .wgMTUAbove9000 })
    }

    @Test func nonNumericMTUIsImportErrorWithoutEcho() {
        guard case .failure(let e) = Self.parse(Self.conf(iface: "MTU = secretvalue")) else { Issue.record("accepted"); return }
        #expect(!e.message.contains("secretvalue"))
    }

    @Test func errorsNeverEchoLineContents() {
        guard case .failure(let e) = Self.parse("[Interface]\nPrivateKey secretvalue\n") else { Issue.record("accepted"); return }
        #expect(e.message == "line 2: expected \"key = value\" syntax")
        // A typo'd key line whose value ends in "=" becomes an unknown key; the report must not show it.
        let r = WGImporter.importProfile(Array(Self.conf(iface: "PresharedKey \(Self.pub)").utf8))
        #expect(!r.report.plainText().contains(String(Self.pub.prefix(20))))
    }

    @Test func importReportListsIgnoredKeys() {
        let r = WGImporter.importProfile(Array(Self.conf(iface: "PostUp = x\nTable = off\nSaveConfig = true\nFoo = bar").utf8))
        #expect(r.verdict == .importedWithWarnings)
        let ignored = r.report.items(in: .ignored)
        #expect(ignored.map(\.reason) == [.wgHookNeverRun, .wgSettingNotApplied, .wgSettingNotApplied, .wgUnknownKeyPreserved])
        #expect(r.canonicalText?.contains("PostUp = x") == true)
        #expect(r.canonicalText?.contains("Foo = bar") == true)
    }

    @Test func keepaliveSuggestedForFullTunnel() {
        let r = WGImporter.importProfile(Array(Self.conf().utf8))
        #expect(r.report.items.contains { $0.reason == .wgKeepaliveSuggested })
        #expect(r.summary.isFullTunnel)
    }

    @Test func importSummary() {
        let r = WGImporter.importProfile(Array(Self.validConf.utf8))
        #expect(r.verdict == .imported)
        #expect(r.summary.endpoints == ["vpn.example.com:51820"])
        #expect(r.summary.addresses == ["10.0.0.2/24"])
        #expect(r.summary.dnsServers == ["1.1.1.1", "8.8.8.8"])
        #expect(r.endpoints == [ImportEndpoint(host: "vpn.example.com", port: "51820", transport: "udp")])
    }

    @Test func importRejectsInvalidWithFieldIssues() {
        let r = WGImporter.importProfile(Array(Self.conf(peer: "Endpoint = nope").utf8))
        #expect(r.verdict == .rejected)
        #expect(r.issues.map(\.field).contains("Peer[0].AllowedIPs"))
        #expect(r.canonicalText == nil)
    }

    @Test func sizeCap() {
        let big = Self.validConf + String(repeating: "# pad\n", count: 11_000)
        #expect(WGImporter.importProfile(Array(big.utf8)).report.items.first?.reason == .fileTooLarge(limitBytes: 65536))
    }

    @Test func canonicalIsFixpoint() throws {
        let r = WGImporter.importProfile(Array(Self.conf(iface: "PostUp = a # b\nZ = 1\nTable = off", peer: "AllowedIPs = 10.0.0.1/24\nPersistentKeepalive = off").utf8))
        let text = try #require(r.canonicalText)
        #expect(WGImporter.importProfile(Array(text.utf8)).canonicalText == text)
    }
}
