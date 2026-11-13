import Foundation
import LPModel
import LPWire
import Synchronization
import Testing
@testable import TunnelEngine
import TunnelEngineTestSupport

/// 2.0.2 item 3: the authorisation decision comes BEFORE the 2.0.1 start guard (DESIGN §20 risk 27). These run the guard's
/// own `World` with the owner-authorisation table switched on.
@Suite(.timeLimit(.minutes(1))) struct StartGuardOrderTests {
    typealias World = ControllerProviderGuardTests.World

    /// An armed, connected split session of profile A (the harness profile) on `inst`.
    func connectArmed(_ w: World, _ inst: ProviderLease, other: Bool = false, killSwitch: Bool? = nil) async -> (UUID, FakeAdapter) {
        let nonce = UUID()
        _ = await w.h.controller.armStart(profileID: other ? w.otherPID : w.h.pid, ownerUID: w.h.owner, nonce: nonce)
        let n = w.h.factory.adapters.count
        let t = w.start(inst, other: other, killSwitch: killSwitch, nonce: nonce)
        let a = await w.adapter(n)
        await w.finish(a)
        #expect(w.code(await w.value(t, "armed connect")) == nil)
        #expect(await w.h.waitPhase(.connected))
        return (nonce, a)
    }

    /// The unauthorised kill-switch start (System Settings, `scutil`) beside a split session must NOT trigger the 2.0.1
    /// priority rule: refused with 225, the split session untouched.
    @Test func refusedStartNeverSupersedesASplitSession() async {
        let w = World(authorisation: true)
        await w.provision()
        let a = w.instance(), k = w.instance()
        let (_, adapterA) = await connectArmed(w, a)
        let tk = w.start(k, other: true, killSwitch: true)                         // manual, no nonce
        #expect(w.code(await w.value(tk, "K")) == .startNotAuthorised)
        #expect(adapterA.stopCount == 0)
        #expect(w.h.host.cancelledCodes.isEmpty)
        #expect(await w.h.phase == .connected)
        #expect(w.binds.list == [a.token])                                         // K was never bound
        #expect(w.h.factory.adapters.count == 1)
        #expect(w.h.state.load().lastErrors[w.h.key]?.error.code != .supersededByKillSwitch)
    }

    /// D-2: ANOTHER armed kill-switch start (this one is the same owner's here) keeps the 2.0.1 priority.
    @Test func anArmedKillSwitchStartStillSupersedesASplitSession() async {
        let w = World(authorisation: true)
        await w.provision()
        let a = w.instance(), k = w.instance()
        let (_, adapterA) = await connectArmed(w, a)
        _ = await connectArmed(w, k, other: true, killSwitch: true)
        #expect(adapterA.stopCount == 1)
        #expect(w.h.host.cancelledCodes == [.supersededByKillSwitch])
        #expect(w.h.state.load().lastErrors[w.h.key]?.error.code == .supersededByKillSwitch)
    }

    @Test func refusedStartReadsNoPayload() async {
        let w = World(authorisation: true)
        await w.provision()
        let before = await w.h.secrets.gets
        let t = w.start(w.instance(), killSwitch: true)
        #expect(w.code(await w.value(t, "refused")) == .startNotAuthorised)
        #expect(await w.h.secrets.gets == before)
    }

    @Test func refusalIsRecordedAs225UnderTheAppAssertedKey() async {
        let w = World(authorisation: true)
        await w.provision()
        let t = w.start(w.instance(), other: true)
        #expect(w.code(await w.value(t, "refused")) == .startNotAuthorised)
        let e = w.h.state.load().lastErrors[w.otherKey]?.error
        #expect(e?.code == .startNotAuthorised && (e?.code.rawValue ?? 0) >= 225)
        #expect((LPTunnelError(.startNotAuthorised) as NSError).code == 225)
    }

    /// A second, armed start of the RUNNING kill-switch profile (a duplicate configuration) waits in the guard; it must not
    /// replace the persisted authorisation NE's replay of the running session needs, and its own arm is consumed.
    @Test func aWaitingArmedDuplicateDoesNotOverwriteTheRunningSessionsAuthorisation() async {
        let w = World(killSwitch: true, authorisation: true)
        await w.provision()
        let a1 = w.instance(), a2 = w.instance()
        let (n1, _) = await connectArmed(w, a1)
        let n2 = UUID()
        _ = await w.h.controller.armStart(profileID: w.h.pid, ownerUID: w.h.owner, nonce: n2)
        let t2 = w.start(a2, nonce: n2)
        #expect(!(await waitUntil(timeout: .milliseconds(300)) { w.binds.list.count > 1 }))        // waiting, not admitted
        #expect(w.h.state.load().authorisedStarts[w.h.key]?.nonce == n1)
        t2.cancel()
    }
}
