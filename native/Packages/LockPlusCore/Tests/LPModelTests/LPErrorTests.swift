import Foundation
import LPModel
import Testing

@Suite struct LPErrorTests {
    @Test func rawValuesAreStable() {
        #expect(LPErrorCode.timeout.rawValue == 1)
        #expect(LPErrorCode.staleAnswer.rawValue == 11)
        #expect(LPErrorCode.profileNotProvisioned.rawValue == 100)
        #expect(LPErrorCode.authFailed.rawValue == 200)
        #expect(LPErrorCode.endpointInterfaceUnusable.rawValue == 220)
        #expect(LPErrorCode.noNetwork.rawValue == 221)
        #expect(LPErrorCode.anotherTunnelActive.rawValue == 222)
        #expect(LPErrorCode.supersededByKillSwitch.rawValue == 223)
        #expect(LPErrorCode.sessionInterrupted.rawValue == 224)
    }

    @Test func detailIsCapped() {
        let e = LPError(.engineFatal, detail: String(repeating: "x", count: 2000))
        #expect(e.detail?.count == LPError.maxDetailLength)
    }

    @Test func tunnelErrorBridgesToNSError() {
        let ns = LPTunnelError(.authFailed, detail: "d") as NSError
        #expect(ns.domain == LPTunnelError.errorDomain)
        #expect(ns.code == 200)
        #expect(ns.userInfo[LPTunnelError.detailKey] as? String == "d")
    }
}
