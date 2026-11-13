import Foundation
import Testing
@testable import LPParsing
import LPModel

/// 2.0.2 (PLAN §1.5): `OVPNImporter.isCanonicalFixedPoint`, the extension's provision-time check that a payload is exactly
/// what the normaliser emits (so the memory-unsafe [6] differential can stay out of the extension at provision).
@Suite("OpenVPN canonical fixed point (2.0.2)")
struct CanonicalFixedPointTests {
    static func canonical(_ s: String, options: OVPNNormalizerOptions = .init()) throws -> [UInt8] {
        Array(try #require(OVPNFixtures.importing(s, options: options).canonicalText).utf8)
    }

    @Test func everyCorpusCanonicalIsAFixedPoint() throws {
        var accepted = 0
        let inputs = GoVectorFile.shared.configs.map { Array(Data(base64Encoded: $0.input)!) }
            + OVPNCorpusTests.crafted.map { Array(OVPNFixtures.base($0.1).utf8) }
            + [Array(MigrationTests.ovpn.utf8)]
        for bytes in inputs {
            let r = OVPNImporter.importProfile(bytes)
            guard let text = r.canonicalText else { continue }
            accepted += 1
            #expect(OVPNImporter.isCanonicalFixedPoint(Array(text.utf8)), "canonical text of an accepted profile is not a fixed point")
            // The raw input (it needs floors, or dedup, or carries inline credentials...) is not, unless it already was.
            if !r.report.items(in: .note).isEmpty { #expect(!OVPNImporter.isCanonicalFixedPoint(bytes)) }
        }
        #expect(accepted > 60)
    }

    /// Round 1 (Codex 8): every directive that is accepted but not emitted, alone, still gives a fixed point (the floors
    /// follow what is emitted). link-mtu was the case that broke it; a 2.0.1 payload of such a profile (no mssfix) is
    /// not a fixed point and is migrated by the app (`ProfilesStore.migrateNonFixedPointPayloads`).
    @Test func droppedDirectivesDoNotBreakTheFixedPoint() throws {
        for d in ["link-mtu 1500", "tun-mtu-extra 32", "mtu-disc yes", "keepalive 10 60", "ping-restart 60", "ping 15", "route-delay 2"] {
            let c = try Self.canonical(OVPNFixtures.base(d + "\n"))
            #expect(OVPNImporter.isCanonicalFixedPoint(c), "\(d)")
        }
        let stored201 = String(decoding: try Self.canonical(OVPNFixtures.base("link-mtu 1500\n")), as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false).filter { $0 != "mssfix \"1300\"" }.joined(separator: "\n")
        #expect(!OVPNImporter.isCanonicalFixedPoint(Array(stored201.utf8)))
        let migrated = try #require(OVPNImporter.importProfile(Array(stored201.utf8)).canonicalText)
        #expect(OVPNImporter.isCanonicalFixedPoint(Array(migrated.utf8)))
    }

    @Test func otpClassCanonicalIsAFixedPointUnderDefaultOptions() throws {
        for o in [OVPNNormalizerOptions(appendOTP: true), OVPNNormalizerOptions(dynamicChallengeSeen: true), OVPNNormalizerOptions()] {
            let c = try Self.canonical(OVPNFixtures.base("auth-user-pass\nstatic-challenge \"OTP\" 1\n"), options: o)
            #expect(OVPNImporter.isCanonicalFixedPoint(c))
        }
    }

    @Test func rejectsTamperedCanonical() throws {
        let text = String(decoding: try Self.canonical(OVPNFixtures.base("remote-cert-tls server\nauth-user-pass\n")), as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(OVPNImporter.isCanonicalFixedPoint(Array(text.utf8)))
        // A removed floor (the normaliser would append it again).
        // (`ping` and `ping-restart` are one floor: either present suppresses it.)
        for floor in [["ping \"10\"", "ping-restart \"60\""], ["mssfix \"1300\""], ["remote-cert-eku \"TLS Web Server Authentication\""]] {
            let t = lines.filter { !floor.contains($0) }.joined(separator: "\n")
            #expect(t != text, "fixture lost \(floor)")
            #expect(!OVPNImporter.isCanonicalFixedPoint(Array(t.utf8)), "without \(floor)")
        }
        // An extra directive the allowlist refuses, and one it accepts that the normaliser would not emit twice.
        #expect(!OVPNImporter.isCanonicalFixedPoint(Array((text + "up /tmp/x\n").utf8)))
        #expect(!OVPNImporter.isCanonicalFixedPoint(Array((text + "ping \"10\"\n").utf8)))               // a duplicate: dedup changes the stream
        // Inline credentials (extracted at import, never part of a payload).
        #expect(!OVPNImporter.isCanonicalFixedPoint(Array((text + "<auth-user-pass>\nalice\npw\n</auth-user-pass>\n").utf8)))
        // Garbage, empty, a NUL byte.
        #expect(!OVPNImporter.isCanonicalFixedPoint(Array("".utf8)))
        #expect(!OVPNImporter.isCanonicalFixedPoint(Array((text + "\u{0}").utf8)))
        #expect(!OVPNImporter.isCanonicalFixedPoint(Array("<ca>\nunterminated\n".utf8)))
    }

    /// Stored 2.0.1 payloads were emitted by the same normaliser; harmless whitespace and quoting differences that tokenize to
    /// the same stream must not fail (or profiles stop re-provisioning, PLAN R1.2).
    @Test func harmlessWhitespaceAndQuotingDoNotFailIt() throws {
        let text = String(decoding: try Self.canonical(OVPNFixtures.base("cipher AES-256-GCM\n")), as: UTF8.self)
        let spaced = text.replacingOccurrences(of: "cipher \"AES-256-GCM\"", with: "cipher   AES-256-GCM  ")
        #expect(spaced != text)
        #expect(OVPNImporter.isCanonicalFixedPoint(Array(spaced.utf8)))
    }
}
