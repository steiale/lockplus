import Foundation
import LPModel
import Testing

@Suite struct SystemExtensionPolicyTests {
    static func v(_ s: String, _ b: String) -> ExtensionVersion { ExtensionVersion(shortVersion: s, bundleVersion: b) }
    static let embedded = v("2.0.0", "200000")

    @Test func versionsCompareNumerically() {
        #expect(Self.v("2.0.0", "200000") < Self.v("2.0.0", "200000.29000000"))   // dev stamp sorts above release
        #expect(Self.v("2.0.0", "200000.99") < Self.v("2.0.1", "200001"))
        #expect(Self.v("2.0.10", "1") > Self.v("2.0.9", "1"))                       // numeric, not lexical
        #expect(Self.v("2.0", "200000").numericallyEqual(Self.v("2.0.0", "200000")))
    }

    @Test func replacementIsAPureCompare() {
        #expect(ReplacementPolicy.decide(existing: Self.v("2.0.0", "199999"), embedded: Self.embedded) == .replace)
        #expect(ReplacementPolicy.decide(existing: Self.embedded, embedded: Self.embedded) == .replace)  // dev mode only
        #expect(ReplacementPolicy.decide(existing: Self.v("2.0.1", "200001"), embedded: Self.embedded) == .cancel)
    }

    static func entry(_ ver: ExtensionVersion, enabled: Bool = true, awaiting: Bool = false, uninstalling: Bool = false) -> ExtensionEntry {
        ExtensionEntry(version: ver, isEnabled: enabled, isAwaitingUserApproval: awaiting, isUninstalling: uninstalling)
    }

    /// Review 5 #3: the watchdog hands back only to the extension that was installed, enabled, nothing awaiting approval.
    @Test func theWatchdogHandsBackOnlyToTheInstalledExtension() {
        let old = Self.v("1.9.0", "190000")
        #expect(WatchdogHandBack.allowed(entries: [Self.entry(old)], installed: old))
        #expect(WatchdogHandBack.allowed(entries: [Self.entry(Self.v("1.9", "190000"))], installed: old))     // numeric
        #expect(!WatchdogHandBack.allowed(entries: nil, installed: old))                                    // unknown
        #expect(!WatchdogHandBack.allowed(entries: [], installed: old))                                     // gone
        #expect(!WatchdogHandBack.allowed(entries: [Self.entry(Self.embedded)], installed: old))           // replaced
        #expect(!WatchdogHandBack.allowed(entries: [Self.entry(old, uninstalling: true)], installed: old))
        #expect(!WatchdogHandBack.allowed(entries: [Self.entry(old), Self.entry(Self.embedded, enabled: false, awaiting: true)],
                                          installed: old))                                                  // approval pending
        #expect(WatchdogHandBack.allowed(entries: [Self.entry(Self.embedded)], installed: nil))            // nothing quiesced
        #expect(!WatchdogHandBack.allowed(entries: [Self.entry(Self.embedded, enabled: false)], installed: nil))
    }

    @Test func preflightTimeoutActivatesWithoutQuiesce() {
        let r = ActivationPreflight.decide(entries: nil, embedded: Self.embedded, hasOnDemandOrResumeMarker: true)
        #expect(r.decision == .activate(quiesce: false))
    }

    @Test func preflightNoEnabledEntry() {
        #expect(ActivationPreflight.decide(entries: [], embedded: Self.embedded, hasOnDemandOrResumeMarker: false).decision
                == .activate(quiesce: false))
        #expect(ActivationPreflight.decide(entries: [], embedded: Self.embedded, hasOnDemandOrResumeMarker: true).decision
                == .removedDuringUpdate)
        // An uninstalling entry doesn't count as enabled.
        let e = [Self.entry(Self.v("2.0.0", "199999"), uninstalling: true)]
        #expect(ActivationPreflight.decide(entries: e, embedded: Self.embedded, hasOnDemandOrResumeMarker: true).decision
                == .removedDuringUpdate)
    }

    @Test func preflightVersionCases() {
        func d(_ installed: ExtensionVersion) -> ActivationPreflight.Decision {
            ActivationPreflight.decide(entries: [Self.entry(installed)], embedded: Self.embedded,
                                       hasOnDemandOrResumeMarker: false).decision
        }
        #expect(d(Self.v("2.0.0", "199999")) == .activate(quiesce: true))
        #expect(d(Self.embedded) == .activate(quiesce: false))
        #expect(d(Self.v("2.1.0", "210000")) == .refuseOlderApp(installed: Self.v("2.1.0", "210000")))
    }

    @Test func preflightReportsPendingApproval() {
        let e = [Self.entry(Self.embedded, enabled: false, awaiting: true)]
        let r = ActivationPreflight.decide(entries: e, embedded: Self.embedded, hasOnDemandOrResumeMarker: false)
        #expect(r.awaitingApproval)
        #expect(r.decision == .activate(quiesce: false))
    }

    @Test func errorTable() {
        typealias P = SystemExtensionErrorPolicy
        for c in [1, 2, 5, 6, 7, 8, 9] { #expect(P.outcome(code: c, phase: .activation) == .fail(.broken(code: c))) }
        #expect(P.outcome(code: 3, phase: .activation) == .fail(.notInApplications))
        #expect(P.outcome(code: 4, phase: .activation) == .fail(.broken(code: 4)))
        #expect(P.outcome(code: 4, phase: .deactivation) == .guidedRemoval)
        #expect(P.outcome(code: 10, phase: .activation) == .fail(.managed))
        #expect(P.outcome(code: 11, phase: .activation) == .ignore)
        #expect(P.outcome(code: 12, phase: .deactivation) == .ignore)
        #expect(P.outcome(code: 13, phase: .deactivation) == .fail(.authorizationRequired))
        #expect(P.outcome(code: 99, phase: .activation) == .fail(.broken(code: 99)))
    }

    @Test func deepLink() {
        #expect(SystemSettingsLink.extensions.absoluteString == "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
    }
}

@Suite struct OneShotTests {
    @Test func firstResumeWins() async {
        let gate = OneShot<Int>()
        let v = await withCheckedContinuation { k in
            gate.attach(k, ifCancelled: -1)
            #expect(gate.resume(1))
            #expect(!gate.resume(2))
            gate.cancel(3)
        }
        #expect(v == 1)
    }

    @Test func cancelBeforeAttachResumesOnAttach() async {
        let gate = OneShot<Int>()
        gate.cancel(-1)
        let v = await withCheckedContinuation { k in gate.attach(k, ifCancelled: -7) }
        #expect(v == -7)
    }

    /// The deadline's sleep is injected: it elapses at once while the body is still held (it ignores cancellation and
    /// is released only after `withDeadline` returned), so the outcome doesn't depend on the machine's speed.
    @Test(.timeLimit(.minutes(1))) func deadlineFiresWithoutWaitingForTheBody() async {
        let (held, release) = AsyncStream<Void>.makeStream()
        let v = await withDeadline(.seconds(3600), onTimeout: "timeout", sleep: { _ in }) {
            for await _ in held {}
            return "late"
        }
        #expect(v == "timeout")
        release.finish()
    }

    /// And a body that finishes first wins against a deadline that hasn't elapsed (held until the test ends it).
    @Test(.timeLimit(.minutes(1))) func bodyBeatsAPendingDeadline() async {
        let (pending, elapse) = AsyncStream<Void>.makeStream()
        #expect(await withDeadline(.milliseconds(1), onTimeout: 0, sleep: { _ in for await _ in pending {} }) { 42 } == 42)
        elapse.finish()
    }

    /// Review on-demand 4 #4: when the body wins, the deadline's sleeper is cancelled (it used to sleep out the whole
    /// timeout, one Task per call). The injected sleep reports whether it ended by cancellation.
    @Test(.timeLimit(.minutes(1))) func theSleeperIsCancelledWhenTheBodyWins() async {
        let (ended, report) = AsyncStream<Bool>.makeStream()
        let v = await withDeadline(.seconds(3600), onTimeout: 0, sleep: { d in
            do { try await Task.sleep(for: d) } catch {
                report.yield(Task.isCancelled)
                throw error
            }
        }) { 42 }
        #expect(v == 42)
        var it = ended.makeAsyncIterator()
        #expect(await it.next() == true)
    }
}
