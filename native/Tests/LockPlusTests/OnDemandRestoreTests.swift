import Foundation
import LPModel
import LPWire
import Testing
@testable import LockPlus

/// Review H2 (§10.4): a user Disconnect turns on-demand off only until the next network change; a manual profile's
/// disconnect re-enables the auto profile; interactive profiles never get on-demand (L8).
@MainActor @Suite("On-demand restore (H2)", .serialized)
struct OnDemandRestoreTests {
    func autoProfile(_ h: Harness) async throws -> Profile {
        let p = try await h.add("Home NAS.conf", Harness.splitConf)
        h.env.settings.update {
            $0.autoConnect.enabled = true
            $0.autoConnect.profileID = p.id
        }
        await h.env.profiles.resaveOnDemand()
        try await h.env.managers.loadAll()
        return p
    }

    /// E2E-2 bug 1 (26): a render between the user's click and its persistence reverted the click (render pushed the
    /// old settings into the editable model), and a click made while the on-demand re-save ran was never observed.
    @Test func autoConnectClicksSurviveARenderAndAreAllSaved() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Home NAS.conf", Harness.splitConf)
        UIBinder.bind(h.env)
        h.env.ui.autoConnect.profileID = p.id
        h.env.ui.autoConnect.enabled = true
        UIBinder.render(h.env)                                          // something else re-renders first
        #expect(h.env.ui.autoConnect.enabled && h.env.ui.autoConnect.profileID == p.id)
        #expect(await eventually { h.env.settings.value.autoConnect.enabled && h.env.settings.value.autoConnect.profileID == p.id })
        let wifi = !h.env.ui.autoConnect.onUntrustedWiFi
        h.env.ui.autoConnect.onUntrustedWiFi = wifi                    // while the first re-save may still run
        UIBinder.render(h.env)
        #expect(await eventually { h.env.settings.value.autoConnect.connectOnUntrustedWiFi == wifi })
        #expect(await eventually { h.managers.entries[p.id]?.onDemand == true })
        #expect(h.env.ui.autoConnect.onUntrustedWiFi == wifi)
        // A write by the app itself still reaches the editable model.
        h.env.settings.update { $0.autoConnect.enabled = false }
        UIBinder.render(h.env)
        #expect(!h.env.ui.autoConnect.enabled)
    }

    @Test func disconnectSuspendsUntilTheNetworkChanges() async throws {
        let net = FixtureNetworkWatcher()
        let h = Harness(network: net)
        defer { h.dir.cleanup() }
        let p = try await autoProfile(h)
        #expect(h.managers.entries[p.id]?.onDemand == true)
        h.env.connection.start()                                        // (env.start() resets a preview-mode data dir)
        net.onChange = { h.env.connection.networkChanged($0) }
        net.start()
        h.managers.emit(p.id, .connected)
        h.env.connection.disconnect()
        #expect(await eventually { h.managers.entries[p.id]?.onDemand == false })
        h.managers.emit(p.id, .disconnected)                            // NE reports the stop (nothing restores while active)
        #expect(h.env.settings.value.onDemandSuspended == [p.id])
        await h.env.profiles.resaveOnDemand()                           // a settings re-save keeps it suspended
        #expect(h.managers.entries[p.id]?.onDemand == false)
        net.change(to: net.current)                                     // same network: nothing
        #expect(h.env.settings.value.onDemandSuspended == [p.id])
        net.change(to: "satisfied|wifi:en0,wiredEthernet:en7")         // another network
        #expect(await eventually { h.managers.entries[p.id]?.onDemand == true })
        #expect(h.env.settings.value.onDemandSuspended.isEmpty)
    }

    /// E2E-2: turning Auto-Connect on for a profile a Disconnect suspended ends the suspension at once, and the pane
    /// says that it is suspended, and why, while it is.
    @Test func turningAutoConnectOnEndsASuspensionAndThePaneShowsIt() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await autoProfile(h)
        h.env.connection.start()
        h.managers.emit(p.id, .connected)
        h.env.connection.disconnect()
        #expect(await eventually { h.managers.entries[p.id]?.onDemand == false })
        h.managers.emit(p.id, .disconnected)                            // NE reports the stop (nothing restores while active)
        UIBinder.bind(h.env)
        let line = try #require(h.env.ui.autoConnect.statusLine)
        #expect(line.contains(p.name) && line.contains("because you disconnected it"))

        h.env.ui.autoConnect.enabled = false
        #expect(await eventually { !h.env.settings.value.autoConnect.enabled })
        #expect(h.env.settings.value.onDemandSuspended == [p.id])        // off alone ends nothing
        #expect(UIBinder.autoConnectStatusLine(h.env) == nil)
        h.env.ui.autoConnect.enabled = true
        #expect(await eventually { h.env.settings.value.onDemandSuspended.isEmpty })
        #expect(h.env.settings.value.onDemandSuspendedNetwork == nil)
        #expect(await eventually { h.managers.entries[p.id]?.onDemand == true })
        UIBinder.render(h.env)
        #expect(h.env.ui.autoConnect.statusLine == nil)
        #expect(h.env.ui.autoConnect.enabled)
    }

    @Test func turnedOnIsTheToggleGoingOnOrAnotherProfilePicked() {
        let a = UUID(), b = UUID()
        var off = AutoConnectRules(); off.profileID = a
        var on = off; on.enabled = true
        var onB = on; onB.profileID = b
        var noProfile = on; noProfile.profileID = nil
        var wifi = on; wifi.connectOnUntrustedWiFi.toggle()
        #expect(AutoConnectRules.turnedOn(from: off, to: on) == a)
        #expect(AutoConnectRules.turnedOn(from: on, to: onB) == b)
        #expect(AutoConnectRules.turnedOn(from: on, to: wifi) == nil)     // a trigger change is not a turn-on
        #expect(AutoConnectRules.turnedOn(from: on, to: off) == nil)
        #expect(AutoConnectRules.turnedOn(from: off, to: noProfile) == nil)
    }

    @Test func aSuspensionFromAnotherNetworkEndsAtLaunch() async throws {
        let net = FixtureNetworkWatcher()
        let h = Harness(network: net)
        defer { h.dir.cleanup() }
        let p = try await autoProfile(h)
        h.env.settings.update {
            $0.onDemandSuspended = [p.id]
            $0.onDemandSuspendedNetwork = "satisfied|wifi:en0-hotel"
        }
        await h.env.profiles.resaveOnDemand()
        #expect(h.managers.entries[p.id]?.onDemand == false)
        h.env.connection.networkChanged(net.current)                    // the launch callback with the current network
        #expect(await eventually { h.managers.entries[p.id]?.onDemand == true })
    }

    /// §10.4: the user's Disconnect of the manual profile ends its run; the auto profile its start paused comes back.
    @Test func disconnectingAManualProfileReEnablesTheAutoProfile() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let auto = try await autoProfile(h)
        let work = try await h.add("Work.conf", Harness.wgConf)
        try await h.env.managers.loadAll()
        h.managers.onDemandChanges = [:]
        h.env.connection.start()
        h.env.connection.connect(work.id)
        #expect(await eventually { h.managers.starts.count == 1 })
        h.managers.emit(work.id, .connected)
        #expect(h.env.settings.value.onDemandPausedByStart == [auto.id])
        h.env.connection.disconnect()
        h.managers.emit(work.id, .disconnected)
        #expect(await eventually { h.managers.entries[auto.id]?.onDemand == true })
        #expect(h.managers.onDemandChanges[auto.id] == [false, true])
        #expect(await eventually { h.env.settings.value.onDemandPausedByStart.isEmpty })
    }

    /// E2E-3 (26, PF 50): another configuration's on-demand left a held or connected kill-switch session blocked after a
    /// network change (nesessionmanager never saw en0 return; NECP defuncted every new tunnel-process socket). Starting
    /// any other profile pauses the auto profile's on-demand BEFORE the start; it comes back when that profile ends.
    @Test func startingAnotherProfilePausesTheAutoProfileUntilItEnds() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let auto = try await autoProfile(h)
        let work = try await h.add("Work.conf", Harness.wgConf, killSwitch: true)
        try await h.env.managers.loadAll()
        h.managers.onDemandChanges = [:]
        h.env.connection.start()
        h.env.connection.connect(work.id)
        #expect(await eventually { h.managers.starts.count == 1 })
        #expect(h.managers.onDemandAtStart == [[]])                      // off before NE saw the start
        #expect(h.managers.onDemandChanges[auto.id] == [false])
        #expect(h.env.settings.value.onDemandSuspended.isEmpty)         // a pause, not a Disconnect's suspension
        h.managers.emit(work.id, .connecting)
        h.managers.emit(work.id, .connected)
        #expect(h.managers.entries[auto.id]?.onDemand == false)
        #expect(h.env.settings.value.onDemandPausedByStart == [auto.id])   // recorded before the pause
        h.managers.onDemandChanges = [:]
        h.env.connection.disconnect()
        h.managers.emit(work.id, .disconnected)
        #expect(await eventually { h.managers.entries[auto.id]?.onDemand == true })
        #expect(h.managers.onDemandChanges[auto.id] == [true])
        #expect(await eventually { h.env.settings.value.onDemandPausedByStart.isEmpty })
    }

    /// E2E-3 (200003): nothing re-enables the auto profile's on-demand while another profile runs: not the end of a
    /// suspension on a network change (the en0 bounce itself did it), not a settings re-save.
    @Test func nothingReEnablesTheAutoProfileWhileAnotherRuns() async throws {
        let net = FixtureNetworkWatcher()
        let h = Harness(network: net)
        defer { h.dir.cleanup() }
        let auto = try await autoProfile(h)
        let work = try await h.add("Work.conf", Harness.wgConf, killSwitch: true)
        try await h.env.managers.loadAll()
        let timers = FakeTimers()
        h.env.connection.timerSleep = timers.sleeper
        h.env.connection.start()
        net.onChange = { h.env.connection.networkChanged($0) }
        net.start()
        h.managers.emit(auto.id, .connected)
        h.env.connection.disconnect()                                   // suspended until the next network change
        h.managers.emit(auto.id, .disconnected)
        #expect(await eventually { h.env.settings.value.onDemandSuspended == [auto.id] })
        h.env.connection.connect(work.id)
        #expect(await eventually { h.managers.starts.count == 1 })
        #expect(h.env.connection.holdsBackOnDemand(of: auto.id))
        h.managers.emit(work.id, .connecting)
        net.change(to: "unsatisfied|wifi:en0,wifi:en0")                 // our own kill-switch start: not a change
        #expect(h.env.settings.value.onDemandSuspended == [auto.id])
        net.change(to: "unsatisfied|")                                  // the bounce
        #expect(await eventually { h.env.settings.value.onDemandSuspended.isEmpty })
        await h.env.profiles.resaveOnDemand()
        #expect(h.managers.entries[auto.id]?.onDemand == false)
        h.managers.emit(work.id, .disconnected)                         // ended by the system (E2E-4 200009: NE may restart a
        #expect(await eventually { h.env.connection.startHold?.reason == .mayRestart })   // kill-switch session killed while connecting)
        await timers.fire(h.env.connection.systemRestartTimeout)        // it didn't: the auto profile returns
        #expect(await eventually { h.managers.entries[auto.id]?.onDemand == true })
        #expect(!h.env.connection.holdsBackOnDemand(of: auto.id))
    }

    @Test func networkIdentityIgnoresStatusAndDuplicates() {
        #expect(ConnectionStore.networkIdentity("satisfied|wiredEthernet:en0") == ConnectionStore.networkIdentity("unsatisfied|wiredEthernet:en0,wiredEthernet:en0"))
        #expect(ConnectionStore.networkIdentity("unsatisfied|") == "none")
        #expect(ConnectionStore.networkIdentity("satisfied|wifi:en0") != ConnectionStore.networkIdentity("satisfied|wifi:en0,wiredEthernet:en7"))
    }

    @Test func theAutoProfilesOwnStartKeepsItsOnDemand() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let auto = try await autoProfile(h)
        h.env.connection.start()
        h.env.connection.connect(auto.id)
        #expect(await eventually { h.managers.starts.count == 1 })
        #expect(h.managers.onDemandAtStart == [[auto.id]])
    }

    @Test func aStartThatFailsAtOnceRestoresTheAutoProfile() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let auto = try await autoProfile(h)
        let work = try await h.add("Work.conf", Harness.wgConf)
        try await h.env.managers.loadAll()
        h.env.connection.start()
        h.managers.startError = LPError(.extensionUnavailable, detail: "startVPNTunnel")
        h.managers.onDemandChanges = [:]
        h.env.connection.connect(work.id)
        #expect(await eventually { h.env.connection.observedError?.code == .extensionUnavailable })
        #expect(await eventually { h.managers.entries[auto.id]?.onDemand == true })
        #expect(h.managers.onDemandChanges[auto.id] == [false, true])    // the pause did happen, and was undone
        #expect(await eventually { h.env.settings.value.onDemandPausedByStart.isEmpty })
    }

    /// E2E-3: the profile that paused the auto profile ended while LockPlus wasn't running: on-demand returns at launch,
    /// unless another profile is still active.
    @Test func aPausedAutoProfileReturnsAtLaunchWhenNothingElseIsActive() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let auto = try await autoProfile(h)
        let work = try await h.add("Work.conf", Harness.wgConf)
        h.managers.entries[auto.id]?.onDemand = false
        h.managers.entries[work.id]?.status = .connected
        h.env.settings.update { $0.onDemandPausedByStart = [auto.id] }   // what the start that paused it recorded
        try await h.env.managers.loadAll()
        h.env.connection.start()
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.managers.entries[auto.id]?.onDemand == false)        // work is active: stays recorded
        h.managers.emit(work.id, .disconnected)                         // observed: it comes back now
        #expect(await eventually { h.managers.entries[auto.id]?.onDemand == true })

        let h2 = Harness()
        defer { h2.dir.cleanup() }
        let auto2 = try await autoProfile(h2)
        h2.managers.entries[auto2.id]?.onDemand = false
        h2.env.settings.update { $0.onDemandPausedByStart = [auto2.id] }
        try await h2.env.managers.loadAll()
        h2.env.connection.start()
        #expect(await eventually { h2.managers.entries[auto2.id]?.onDemand == true })
    }

    @Test func aFailedDisableIsReported() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await autoProfile(h)
        h.env.connection.start()
        h.managers.emit(p.id, .connected)
        h.managers.onDemandError = LPError(.extensionUnavailable, detail: "x")
        h.env.connection.disconnect()
        #expect(await eventually { h.env.profiles.problems.contains { $0.message.contains("Auto-connect couldn't be paused") } })
    }

    @Test func interactiveProfilesNeverGetOnDemand() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let office = try await h.add("Office.ovpn", PreviewSeed.officeOvpn)   // auth-user-pass, nothing saved
        var rules = AutoConnectRules()
        rules.enabled = true
        rules.profileID = office.id
        #expect(OnDemandPlan.plan(for: office, rules: rules, paused: false, hasSavedPassword: false) == nil)
        #expect(OnDemandPlan.plan(for: office, rules: rules, paused: false, hasSavedPassword: true) != nil)
        var stay = office
        stay.policy.stayConnected = true
        #expect(OnDemandPlan.plan(for: stay, rules: AutoConnectRules(), paused: false, hasSavedPassword: false) == nil)
    }
}
