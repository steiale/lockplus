import Foundation
import Testing
import LPModel
import LPParsing
import LPWire
@testable import LPEngineCheck
import LPOptionsParser

/// PLAN-2.0.2 §1.8: `OpenVPNEngineCheck.evaluate` / `WireGuardEngineCheck.evaluate` return exactly the verdict of the
/// 2.0.1 `ExtensionPayloadValidator.evaluate` (golden generated once from the 2.0.1 code over `ParityFixtures`).
@Suite("LPEngineCheck parity with 2.0.1")
struct OpenVPNEngineCheckParityTests {
    static let golden: [String: ValidateProfileReply] = {
        let url = Bundle.module.url(forResource: "engine-check-2.0.1", withExtension: "json", subdirectory: "Golden")!
        return try! JSONDecoder().decode([String: ValidateProfileReply].self, from: Data(contentsOf: url))
    }()

    @Test func evaluateMatchesTheOld2_0_1Verdict() throws {
        let inputs = try ParityFixtures.all()
        #expect(Self.golden.count == inputs.count * 3)
        var accepted = 0
        for (name, data) in inputs {
            let p = SecretBytes(copying: data)
            let a = OpenVPNEngineCheck.evaluate(payload: p, disableClientCert: nil)
            #expect(a == Self.golden[name], "\(name)")
            #expect(OpenVPNEngineCheck.evaluate(payload: p, disableClientCert: true) == Self.golden[name + "|dcc=true"], "\(name) dcc")
            #expect(WireGuardEngineCheck.evaluate(payload: p) == Self.golden[name + "|wg"], "\(name) wg")
            if a.isValid { accepted += 1 }
        }
        #expect(accepted > 5, "the accept path must be exercised")
    }
}
