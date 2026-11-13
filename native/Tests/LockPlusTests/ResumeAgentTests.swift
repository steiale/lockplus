import Foundation
import LPModel
import LPWire
import Testing
@testable import LockPlus

/// §10.4 resume agent (N3): the headless `--resume-protection` run, the launch re-registration rule and the pause
/// path. Fakes only: no SMAppService, no NE.
@MainActor @Suite("Resume agent (§10.4)", .serialized)
struct ResumeAgentTests {
    func settle(_ ms: Int = 50) async throws { try await Task.sleep(for: .milliseconds(ms)) }

    func write(_ s: AppSettings, _ dir: TestDir) throws { try AtomicFile.saveJSON(s, to: dir.data.settings) }
    func read(_ dir: TestDir) -> AppSettings? { AtomicFile.loadJSON(AppSettings.self, from: dir.data.settings) }

    /// `signed`: the harness whose keychain signs the record's resume intent (round 1, Codex 3); nil = an unsigned record.
    func paused(until: Date, profile: UUID?, onDemand: [UUID], signed h: Harness? = nil) async -> AppSettings {
        let until = ResumeIntent.wholeSeconds(until)
        var s = AppSettings()
        s.autoConnect.pausedUntil = until
        s.pausedState = PausedState(profileID: profile, onDemandEnabledIDs: onDemand, agentBuild: "1")
        if let h { s.pausedState?.intent = await resumeIntent(profile, until: until, keychain: h.keychain, dir: h.dir.data) }
        return s
    }

    @Test func aRunningGUIOwnsExpiry() async throws {
        let dir = TestDir()
        defer { dir.cleanup() }
        let gui = try #require(InstanceLock.tryAcquire(at: dir.data.instanceLock))
        let agent = InertResumeAgent()
        let r = await HeadlessResume.perform(dir: dir.data, managers: FakeVPNManager(), agent: agent, keychain: InMemoryKeychain())
        #expect(r == .guiOwnsExpiry)
        #expect(agent.calls.isEmpty)
        withExtendedLifetime(gui) {}
    }

    @Test func aFuturePauseIsLeftAlone() async throws {
        let dir = TestDir()
        defer { dir.cleanup() }
        try write(await paused(until: Date().addingTimeInterval(600), profile: nil, onDemand: []), dir)
        let agent = InertResumeAgent()
        #expect(await HeadlessResume.perform(dir: dir.data, managers: FakeVPNManager(), agent: agent, keychain: InMemoryKeychain()) == .notExpired)
        #expect(agent.calls.isEmpty)
        #expect(read(dir)?.autoConnect.pausedUntil != nil)
    }

    @Test func noPauseUnregistersAStaleAgent() async throws {
        let dir = TestDir()
        defer { dir.cleanup() }
        let agent = InertResumeAgent()
        #expect(await HeadlessResume.perform(dir: dir.data, managers: FakeVPNManager(), agent: agent, keychain: InMemoryKeychain()) == .nothingPaused)
        #expect(agent.calls == ["unregister"])
    }

    @Test func anExpiredPauseResumesWritesThenUnregisters() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let dir = h.dir
        let p = try await h.add("Work.conf", Harness.wgConf)
        try await h.env.managers.save(ManagerConfiguration(profile: p, onDemand: nil))
        let stranger = UUID()                                   // a manager that no longer exists is skipped
        try write(await paused(until: Date().addingTimeInterval(-5), profile: p.id, onDemand: [p.id, stranger], signed: h), dir)
        let agent = ProbeResumeAgent()
        // At the moment of unregister (which kills the agent process) the restore and the durable write are done.
        agent.probe = { [h] in
            let s = AtomicFile.loadJSON(AppSettings.self, from: dir.data.settings)
            return "cleared=\(s?.autoConnect.pausedUntil == nil && s?.pausedState == nil) started=\(h.managers.starts.count) onDemand=\(h.managers.entries[p.id]?.onDemand == true)"
        }
        // The real watchdog budget (5 s of wall time) ran out under full-suite load (2.0.1 round 3 runs: 15 s for this
        // test); the budget's own behaviour is covered by `aConfigurationThatNeverSettlesIsNoHeadlessStart`.
        let r = await HeadlessResume.perform(dir: dir.data, managers: h.managers, agent: agent, keychain: h.keychain, budget: .seconds(60))
        #expect(r == .resumed(restarted: p.id, onDemand: [p.id]))
        #expect((h.managers.starts.first?.1[StartOptionKey.manual] as? NSNumber)?.intValue == 1)
        #expect(agent.calls == ["unregister:cleared=true started=1 onDemand=true"])
    }

    /// E2E-3: the headless resume restarts a manual profile with the auto profile's on-demand still off (another
    /// configuration's on-demand blocks a kill-switch session after a network change), and RECORDS it so the GUI
    /// restores it when that profile ends; a failed restart restores it at once.
    @Test func anExpiredPauseRestartsAManualProfileWithoutOtherOnDemand() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let dir = h.dir
        let work = try await h.add("Work.conf", Harness.wgConf)
        let auto = try await h.add("Home NAS.conf", Harness.splitConf)
        try write(await paused(until: Date().addingTimeInterval(-5), profile: work.id, onDemand: [auto.id], signed: h), dir)
        let r = await HeadlessResume.perform(dir: dir.data, managers: h.managers, agent: ProbeResumeAgent(), keychain: h.keychain)
        #expect(r == .resumed(restarted: work.id, onDemand: []))
        #expect(h.managers.onDemandAtStart == [[]])
        #expect(h.managers.entries[auto.id]?.onDemand == false)
        #expect(read(dir)?.onDemandPausedByStart == [auto.id])           // owed to the GUI

        try write(await paused(until: Date().addingTimeInterval(-5), profile: work.id, onDemand: [auto.id], signed: h), dir)
        h.managers.startError = LPError(.extensionUnavailable)
        let failed = await HeadlessResume.perform(dir: dir.data, managers: h.managers, agent: ProbeResumeAgent(), keychain: h.keychain)
        #expect(failed == .resumed(restarted: nil, onDemand: [auto.id]))
        #expect(h.managers.entries[auto.id]?.onDemand == true)
    }

    /// Review F11: the restart goes through `prepareForStart`. A kill-switch profile whose manager lost its flags and
    /// can't be repaired is NOT started, and the on-demand configurations paused for the pause come back (the same
    /// fail-closed outcome as a failed start); a profile the headless run can't read fails the same way.
    @Test func theHeadlessRestartVerifiesTheKillSwitchOrDoesNotStart() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let dir = h.dir
        let work = try await h.add("Work.conf", Harness.wgConf, killSwitch: true)
        let auto = try await h.add("Home NAS.conf", Harness.splitConf)
        h.managers.entries[work.id]?.cfg.flags.includeAllNetworks = false      // nehelper dropped it
        h.managers.dropIncludeAllNetworksOnSave = true                          // and keeps dropping it
        try write(await paused(until: Date().addingTimeInterval(-5), profile: work.id, onDemand: [auto.id], signed: h), dir)
        let agent = ProbeResumeAgent()
        let r = await HeadlessResume.perform(dir: dir.data, managers: h.managers, agent: agent, keychain: h.keychain)
        #expect(r == .resumed(restarted: nil, onDemand: [auto.id]))
        #expect(h.managers.starts.isEmpty)
        #expect(h.managers.entries[auto.id]?.onDemand == true)
        #expect(read(dir)?.autoConnect.pausedUntil == nil && read(dir)?.onDemandPausedByStart.isEmpty == true)

        // Repairable: verified, started, with the flag intact.
        h.managers.dropIncludeAllNetworksOnSave = false
        h.managers.entries[work.id]?.cfg.flags.includeAllNetworks = false
        h.managers.entries[auto.id]?.onDemand = false
        try write(await paused(until: Date().addingTimeInterval(-5), profile: work.id, onDemand: [auto.id], signed: h), dir)
        let ok = await HeadlessResume.perform(dir: dir.data, managers: h.managers, agent: agent, keychain: h.keychain)
        #expect(ok == .resumed(restarted: work.id, onDemand: []))
        #expect(h.managers.entries[work.id]?.cfg.flags.includeAllNetworks == true)
        #expect(read(dir)?.onDemandPausedByStart == [auto.id])

        // Unreadable profiles (another keychain: the metadata can't be opened): nothing starts.
        h.managers.starts.removeAll()
        try write(await paused(until: Date().addingTimeInterval(-5), profile: work.id, onDemand: [auto.id], signed: h), dir)
        let blind = await HeadlessResume.perform(dir: dir.data, managers: h.managers, agent: agent, keychain: InMemoryKeychain())
        #expect(blind == .resumed(restarted: nil, onDemand: [auto.id]))
        #expect(h.managers.starts.isEmpty)
    }

    @Test func launchPolicy() {
        let now = Date()
        let future = now.addingTimeInterval(300), past = now.addingTimeInterval(-1)
        typealias P = ResumeAgentLaunchPolicy
        #expect(P.action(pausedUntil: nil, agentBuild: nil, currentBuild: "2", status: .notRegistered, now: now) == .none)
        #expect(P.action(pausedUntil: nil, agentBuild: nil, currentBuild: "2", status: .enabled, now: now) == .unregister)
        #expect(P.action(pausedUntil: future, agentBuild: "1", currentBuild: "2", status: .enabled, now: now) == .reregister)
        #expect(P.action(pausedUntil: future, agentBuild: "2", currentBuild: "2", status: .enabled, now: now) == .none)
        #expect(P.action(pausedUntil: future, agentBuild: "2", currentBuild: "2", status: .notRegistered, now: now) == .reregister)
        #expect(P.action(pausedUntil: future, agentBuild: "2", currentBuild: "2", status: .notFound, now: now) == .none)
        #expect(P.action(pausedUntil: past, agentBuild: "1", currentBuild: "2", status: .enabled, now: now) == .none)
    }

    @Test func pauseRegistersBeforeStoppingAndResumeUnregisters() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let agent = ProbeResumeAgent()
        h.env.connection.resumeAgent = agent
        let p = try await h.add("Work.conf", Harness.wgConf)
        try await h.env.managers.save(ManagerConfiguration(profile: p, onDemand: nil))
        h.env.connection.start()
        h.managers.emit(p.id, .connected)
        // Probed at the call: is the pause already on disk, and has the tunnel been stopped yet?
        agent.probe = { [h] in "durable=\(AtomicFile.loadJSON(AppSettings.self, from: h.dir.data.settings)?.autoConnect.pausedUntil != nil) stops=\(h.managers.stops.count)" }
        await h.env.connection.pause(minutes: 5)
        #expect(await eventually { h.managers.stops == [p.id] })
        await h.env.connection.resume().value
        // Register: durable, not yet stopped. Unregister: after the restore (the tunnel was started again).
        #expect(agent.calls == ["register:durable=true stops=0", "unregister:durable=false stops=1"])
        // The start itself follows asynchronously: a kill-switch profile is re-read and verified first (E2E-1).
        #expect(await eventually { h.managers.starts.count == 1 })
        #expect(h.env.settings.value.pausedState == nil)
        #expect(h.env.connection.resumeAgentStatus == nil)
    }

    @Test func approvalPendingIsReported() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let agent = InertResumeAgent()
        agent.registerResult = .requiresApproval
        h.env.connection.resumeAgent = agent
        await h.env.connection.pause(minutes: 5)
        #expect(h.env.connection.resumeAgentStatus == .requiresApproval)
    }

    @Test func launchReRegistersForANewBinary() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let agent = InertResumeAgent()
        agent.status = .enabled
        h.env.connection.resumeAgent = agent
        h.env.settings.update {
            $0.autoConnect.pausedUntil = Date().addingTimeInterval(600)
            $0.pausedState = PausedState(profileID: nil, onDemandEnabledIDs: [], agentBuild: "41")
        }
        await h.env.connection.reconcileResumeAgent(currentBuild: "42")
        #expect(agent.calls == ["unregister", "register"])
        #expect(h.env.settings.value.pausedState?.agentBuild == "42")
    }

    @Test func theAgentPlistShipsInTheBundle() throws {
        let url = Bundle(for: AppDelegate.self).bundleURL
            .appending(path: "Contents/Library/LaunchAgents/\(ResumeAgentPlist.name)")
        let plist = try #require(NSDictionary(contentsOf: url) as? [String: Any])
        #expect(plist["Label"] as? String == ResumeAgentPlist.label)
        #expect(plist["BundleProgram"] as? String == "Contents/MacOS/LockPlus")
        #expect(plist["ProgramArguments"] as? [String] == ["LockPlus", HeadlessResume.argument])
        #expect((plist["StartCalendarInterval"] as? [String: Any])?.isEmpty == true)
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["ProcessType"] == nil)
    }
}

/// Review H4/M7: resume restores before it forgets; a second pause keeps the first restore list.
@MainActor @Suite("Pause and resume (H4, M7)", .serialized)
struct PauseResumeTests {
    @Test func pausingTwiceKeepsTheRestoreList() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf)
        h.env.settings.update { $0.autoConnect.enabled = true; $0.autoConnect.profileID = p.id }     // its plan wants on-demand (R5)
        try await h.env.managers.save(ManagerConfiguration(profile: p, onDemand: OnDemandPlan(rules: [], enabled: true)))
        try await h.env.managers.loadAll()
        h.env.connection.start()
        h.managers.emit(p.id, .connected)
        await h.env.connection.pause(minutes: 5)
        #expect(await eventually { h.managers.entries[p.id]?.onDemand == false })
        await h.env.connection.pause(minutes: 60)                      // on-demand is off now; the list must survive
        #expect(h.env.settings.value.pausedState?.onDemandEnabledIDs == [p.id])
        #expect(h.env.settings.value.pausedState?.profileID == p.id)
        await h.env.connection.resume().value
        #expect(await eventually { h.managers.entries[p.id]?.onDemand == true })     // inside its own start (R5)
        #expect(h.env.settings.value.pausedState == nil)
    }

    @Test func disconnectAndWaitReturnsAfterTheStop() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf)
        h.env.connection.start()
        h.managers.emit(p.id, .connected)
        await h.env.connection.disconnectAndWait(timeout: .seconds(2))
        #expect(h.managers.stops == [p.id])
        #expect(h.managers.status(p.id) == .disconnected)
    }
}
