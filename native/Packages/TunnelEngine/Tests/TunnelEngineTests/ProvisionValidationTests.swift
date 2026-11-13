import Foundation
import LPModel
import LPWire
import Testing
@testable import TunnelEngine
import TunnelEngineTestSupport

/// 2.0.2 (PLAN §1.5): provision runs the memory-safe checks only; the start runs the start checks on the session's payload.
@Suite struct ProvisionValidationTests {
    let alice = PeerContext(uid: 501, pid: 1)

    @Test func provisionRunsOnlyProvisionChecks() async {
        let h = Harness()
        let v = FakeValidator()
        let b = EngineServiceBackend(controller: h.controller, secrets: h.secrets, validator: v)
        let r = await b.handle(.provisionProfile, request: try! LPWire.encode(ProvisionRequest(
            profileID: h.pid, kind: .openVPN, revision: 1, payload: Data("client\n".utf8), credentials: nil)), peer: alice)
        if case .failure(let e) = r { Issue.record("provision failed: \(e.code)") }
        #expect(v.provisionCalls == 1)
        #expect(v.startCalls == 0)                                       // [6] on the payload / anything start-only never runs at provision
    }

    @Test func aRejectedProvisionStoresNothing() async {
        let h = Harness()
        let b = EngineServiceBackend(controller: h.controller, secrets: h.secrets, validator: FakeValidator(reject: true))
        let r = await b.handle(.provisionProfile, request: try! LPWire.encode(ProvisionRequest(
            profileID: h.pid, kind: .openVPN, revision: 1, payload: Data("client\n".utf8), credentials: nil)), peer: alice)
        if case .failure(let e) = r { #expect(e.code == .profileInvalid) } else { Issue.record("accepted") }
        #expect(await h.secrets.bytes(.payload, h.pid) == nil)
    }

    @Test func startRunsStartChecks() async {
        let h = Harness()
        await h.provision()
        await h.connect()
        #expect(h.validator.startCalls == 1)
        #expect(h.validator.provisionCalls == 0)
    }

    @Test func aStartWhoseStartCheckFailsEndsProfileInvalidBeforeAnyEngine() async {
        let h = Harness(rejectPayload: true)
        await h.provision()
        let r = await h.start().value
        #expect(h.code(r) == .profileInvalid)                              // no kill switch: failed, never an engine
        #expect(h.factory.adapters.isEmpty)
    }
}
