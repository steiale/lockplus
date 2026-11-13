import Foundation
import Testing
import LPModel
import LPParsing
import LPWire
@testable import LPEngineCheck
import LPOptionsParser

@Suite("LPEngineCheck")
struct OpenVPNEngineCheckTests {
    static func verdict(_ extra: String) -> ValidateProfileReply {
        OpenVPNEngineCheck.evaluate(payload: SecretBytes(copying: Data((ParityFixtures.base + extra).utf8)), disableClientCert: nil)
    }

    @Test func acceptsTheBaseProfile() {
        #expect(Self.verdict("").isValid)
    }

    @Test func rejectsPkcs12MetaOption() {
        let r = Self.verdict("<pkcs12>\nMIIBAAAA\n</pkcs12>\n")
        #expect(!r.isValid)
        #expect(r.error?.code != nil)
    }

    @Test func rejectsUnusedOptionsCategory() {
        let ev = OpenVPNEngineCheck.rejectingCategories
        #expect(ev.contains("Unused ignored meta options"))
        #expect(ev.contains("Unused options, probably specified multiple times"))
        #expect(!Self.verdict("foo-bar 1\n").isValid)
    }

    @Test func categoryNeverQuotesArguments() {
        #expect(OpenVPNEngineCheck.category("UNUSED_OPTIONS: secret-argument-xyz") == "UNUSED_OPTIONS")
        #expect(OpenVPNEngineCheck.category("   : x") == "rejected by openvpn3")
        #expect(OpenVPNEngineCheck.category(String(repeating: "a", count: 500)).count == 120)
        #expect(OpenVPNEngineCheck.category("") == "rejected by openvpn3")
    }

    @Test func refusalCarriesReasonOnly() {
        // An over-long line is refused by openvpn3's profile limits; the thrown reason is its short message.
        let big = Array(("remote " + String(repeating: "a", count: 70_000) + " 1194\n").utf8)
        do {
            _ = try ShimOptionsParser.parse(bytes: big)
            Issue.record("expected a refusal")
        } catch let e as ShimOptionsParser.Refused {
            #expect(!e.reason.contains("aaaaaaaa"))
        } catch {
            Issue.record("wrong error \(error)")
        }
    }

    @Test func shimParserAgreesWithTheTokenizerOnTheBase() throws {
        let theirs = try ShimOptionsParser.parse(bytes: Array(ParityFixtures.base.utf8))
        guard case .success(let ds) = OVPNTokenizer.parse(Array(ParityFixtures.base.utf8)) else { Issue.record("tokenizer"); return }
        #expect(theirs == OVPNCanonical.stream(of: ds))
    }

    @Test func certAndKeyDetectionIgnoresLongLines() {
        func p(_ s: String) -> SecretBytes { SecretBytes(copying: Data(s.utf8)) }
        #expect(OpenVPNEngineCheck.hasCertAndKey(p("<cert>\nx\n</cert>\n<key>\ny\n</key>\n")))
        #expect(!OpenVPNEngineCheck.hasCertAndKey(p("<cert>\nx\n</cert>\n")))
        #expect(!OpenVPNEngineCheck.hasCertAndKey(p("<cert> " + String(repeating: "a", count: 100) + "\n<key>\n")))
    }

    @Test func wireGuardRejectsGarbageAndAcceptsNothingEmpty() {
        #expect(!WireGuardEngineCheck.evaluate(payload: SecretBytes(copying: Data("nonsense".utf8))).isValid)
        #expect(!WireGuardEngineCheck.evaluate(payload: SecretBytes(copying: Data())).isValid)
    }
}
