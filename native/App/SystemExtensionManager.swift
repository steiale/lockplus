import AppKit
import LPModel
import Observation
import os
import SystemExtensions

/// What the extension lifecycle needs from the tunnel side (§4.2 step 3, §4.6 step 2, §12.3). `ManagerStore` and
/// `UpdateCoordinator` implement it in P2c; until then `NoTunnelsQuiescer` stands in.
@MainActor protocol TunnelQuiescing: AnyObject {
    /// Owned managers with on-demand enabled, or a pendingResume/expectedUpdate marker in settings.json.
    func hasOnDemandOrResumeMarker() async -> Bool
    /// §4.2 step 3: write pendingResume, turn on-demand off, stop and await `.disconnected` (15 s), show "Updating…".
    func quiesce(reason: QuiesceReason) async
    /// §4.2 step 6 / §12.3 step 4: resume after `.completed` when a pendingResume exists.
    func resumeAfterUpdate() async
}

enum QuiesceReason: String, Sendable { case extensionUpdate, reinstall }

@MainActor final class NoTunnelsQuiescer: TunnelQuiescing {
    func hasOnDemandOrResumeMarker() async -> Bool { false }
    func quiesce(reason: QuiesceReason) async {}
    func resumeAfterUpdate() async {}
}

/// The app's system-extension lifecycle (DESIGN §4.1–§4.4, §4.6). GUI context only: never called from the headless
/// `--uninstall-system-components` / `--resume-protection` paths (ref/networkextension §2.3).
///
/// No automatic retries anywhere: "Try again" exists only in the failure UI and is user-initiated (§4.2).
@MainActor @Observable
final class SystemExtensionManager: NSObject, OSSystemExtensionRequestDelegate, OSSystemExtensionsWorkspaceObserver {
    enum State: Equatable, Sendable {
        case unknown, activating, needsUserApproval, needsReboot, ready(version: String)
        /// The user switched it off in System Settings (workspace observer).
        case disabledByUser
        /// §4.2: no enabled entry, owned managers with on-demand (Finder drag-replace).
        case removedDuringUpdate
        /// Terminal until the user acts.
        case failed(ExtensionFailure)
        /// E2E-4 (U12/U14/U15): the replacement activation failed (`code`, e.g. 8 for an invalid signature) while the
        /// previously installed extension (`installed`) stays enabled. It still starts every profile through NE (the
        /// hand-back), but this app can't reach it over XPC (its Mach service name is per build: 4099), so nothing that
        /// needs XPC works until the update completes. Not "damaged", and Connect stays available. Until "Try again".
        case updateFailed(installed: String, code: Int)
        case deactivating, uninstalled
    }

    private(set) var state: State = .unknown
    /// §4.2 step 3.4: "Updating tunnel component…" in the menu bar and window while a replacement is pending.
    private(set) var updateInProgress = false
    /// §4.6 guided manual removal is waiting for the user to switch the extension off.
    private(set) var guidedRemovalActive = false
    /// Set when the approval UI should offer "Show the Switch Again" (persistent while `.needsUserApproval`, D7-13).
    var showsSwitchAgain: Bool { state == .needsUserApproval || guidedRemovalActive }

    let extensionIdentifier: String
    let embeddedVersion: ExtensionVersion?
    /// `NEMachServiceName` read from the EMBEDDED extension's Info.plist (§2.5); nil if the bundle is damaged.
    let machServiceName: String?

    /// Called on `.completed`: the XPC hello and `ProfileStore.reconcile()` (§4.2 table).
    @ObservationIgnored var onReady: (@MainActor () -> Void)?

    /// Opens Login Items & Extensions (injected in tests: no System Settings window from a test run).
    @ObservationIgnored private let openSettings: @MainActor () -> Void
    @ObservationIgnored private let quiescer: any TunnelQuiescing
    @ObservationIgnored private let log = Logger(subsystem: "io.github.steiale.lockplus.mac", category: "sysext")

    private enum RequestKind { case properties, activation, deactivation }
    /// One in-flight request with its gate. Retained until a terminal callback: `request.delegate` is weak and the
    /// system drops an unretained request.
    private enum Pending {
        case properties(OSSystemExtensionRequest, OneShot<[ExtensionEntry]?>)
        case activation(OSSystemExtensionRequest)
        case deactivation(OSSystemExtensionRequest, OneShot<DeactivationOutcome>)

        var request: OSSystemExtensionRequest {
            switch self {
            case .properties(let r, _), .activation(let r), .deactivation(let r, _): r
            }
        }
        var kind: RequestKind {
            switch self {
            case .properties: .properties
            case .activation: .activation
            case .deactivation: .deactivation
            }
        }
    }
    @ObservationIgnored private var requests: [ObjectIdentifier: Pending] = [:]
    /// Set before `activate()`'s first await so a second caller can't interleave (the request map is only filled at submit).
    @ObservationIgnored private var activateInFlight = false
    @ObservationIgnored private var refusedDowngrade = false
    /// Review 4 #3: no extension is left to hand the tunnels back to (our reinstall removed it, or it was gone at the
    /// preflight): a failed activation then keeps the hand-over (the pane says auto-connect is paused for the update).
    @ObservationIgnored private var noExtensionLeft = false
    /// Review 5 #3: the version the preflight saw enabled when this activation quiesced for an update (nil: nothing was
    /// quiesced). The watchdog hands back only while it is still the enabled entry.
    @ObservationIgnored private var quiescedForVersion: ExtensionVersion?
    /// E2E-4: a different version that the preflight saw enabled (the one a failed replacement leaves running, U14).
    @ObservationIgnored private var installedAtPreflight: ExtensionVersion?
    @ObservationIgnored private var wentInactive = false
    /// The state before `activate()` set `.activating`; restored when the request ends with nothing (canceled with no
    /// successor), so the UI offers its retry action again instead of a dead "Installing…".
    @ObservationIgnored private var stateBeforeActivation: State = .unknown
    /// One watchdog per activation request: no delegate callback within `activationWatchdog` → `.failed(.broken)`.
    @ObservationIgnored private var watchdogs: [ObjectIdentifier: Task<Void, Never>] = [:]
    /// An activation ran and ended without settling anything (canceled, no successor): Try Again is the way on.
    private(set) var activationEndedWithoutResult = false

    /// Submits a request to `OSSystemExtensionManager`. Tests inject a recorder; nothing else may replace it.
    @ObservationIgnored private let submitter: @MainActor (OSSystemExtensionRequest) -> Void
    @ObservationIgnored private let propertiesTimeout: Duration
    @ObservationIgnored private let activationWatchdog: Duration

    nonisolated static let defaultPropertiesTimeout: Duration = .seconds(5)
    /// No activation callback at all for this long (approval arrives as `requestNeedsUserApproval`, a callback).
    nonisolated static let defaultActivationWatchdog: Duration = .seconds(120)
    static let guidedRemovalPoll: Duration = .seconds(2)
    static let guidedRemovalLimit: Duration = .seconds(300)

    init(bundle: Bundle = .main, quiescer: any TunnelQuiescing,
         submitter: (@MainActor (OSSystemExtensionRequest) -> Void)? = nil,
         propertiesTimeout: Duration = SystemExtensionManager.defaultPropertiesTimeout,
         activationWatchdog: Duration = SystemExtensionManager.defaultActivationWatchdog,
         openSettings: (@MainActor () -> Void)? = nil) {
        self.submitter = submitter ?? { OSSystemExtensionManager.shared.submitRequest($0) }
        self.openSettings = openSettings ?? { NSWorkspace.shared.open(LPModel.SystemSettingsLink.extensions) }
        self.propertiesTimeout = propertiesTimeout
        self.activationWatchdog = activationWatchdog
        let id = bundle.object(forInfoDictionaryKey: "LPTunnelBundleIdentifier") as? String ?? "io.github.steiale.lockplus.mac.tunnel"
        extensionIdentifier = id
        let ext = Bundle(url: bundle.bundleURL.appending(path: "Contents/Library/SystemExtensions/\(id).systemextension"))
        if let ext, let s = ext.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           let b = ext.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
            embeddedVersion = ExtensionVersion(shortVersion: s, bundleVersion: b)
        } else {
            embeddedVersion = nil
        }
        machServiceName = (ext?.object(forInfoDictionaryKey: "NetworkExtension") as? [String: Any])?["NEMachServiceName"] as? String
        self.quiescer = quiescer
        super.init()
    }

    /// Adds the workspace observer (15.1 API, below the 26.0 floor; ref/networkextension C11). Call once at launch.
    func startObserving() {
        do { try OSSystemExtensionsWorkspace.shared.addObserver(self) } catch {
            log.error("workspace observer: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Activation (§4.2)

    /// Idempotent; called on every launch (L-EXT-2). Quiesces before submitting when a replacement is pending, because
    /// the replacement delegate callback is synchronous and can't await a tunnel stop.
    func activate() async {
        guard let embedded = embeddedVersion else { state = .failed(.broken(code: 0)); return }
        guard !activateInFlight, !requests.values.contains(where: { $0.kind == .activation }) else { return }   // never resubmit
        if case .deactivating = state { return }
        activateInFlight = true
        defer { activateInFlight = false }

        if state != .activating { stateBeforeActivation = state }
        activationEndedWithoutResult = false
        state = .activating
        let entries = await fetchProperties()
        if entries == nil { log.notice("properties preflight timed out; activating without quiescing") }
        let r = ActivationPreflight.decide(entries: entries, embedded: embedded,
                                           hasOnDemandOrResumeMarker: await quiescer.hasOnDemandOrResumeMarker())
        if r.awaitingApproval { state = .needsUserApproval }
        quiescedForVersion = nil
        installedAtPreflight = entries?.first { $0.isEnabled && !$0.isUninstalling && $0.version != embedded }?.version
        switch r.decision {
        case .refuseOlderApp(let installed):
            // The newer extension keeps running with its own Mach name; this app is read-only (§4.2 step 2).
            log.notice("installed extension \(installed.description, privacy: .public) is newer than embedded \(embedded.description, privacy: .public)")
            state = .failed(.olderAppThanExtension(installed: installed.description))
            return
        case .removedDuringUpdate:
            state = .removedDuringUpdate
            noExtensionLeft = true
        case .activate(let quiesce):
            if quiesce {
                noExtensionLeft = false               // an older one is installed: a failure hands back to it
                quiescedForVersion = entries?.first { $0.isEnabled && !$0.isUninstalling }?.version
                updateInProgress = true
                await quiescer.quiesce(reason: .extensionUpdate)
            }
        }
        submit(.activation(.activationRequest(forExtensionWithIdentifier: extensionIdentifier, queue: .main)))
    }

    /// "Show the Switch Again" (D7-13) and the approval sheet's "Open System Settings".
    func openExtensionSettings() { openSettings() }

    /// `.notInApplications`: reveal the app so the user can move it.
    func revealAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func setFailed(_ f: ExtensionFailure) { state = .failed(f) }

    /// User-initiated "Try again" from the failure UI. Never called automatically.
    func retryAfterUserAction() async {
        switch state {
        case .failed, .updateFailed: state = .unknown
        default: break
        }
        activationEndedWithoutResult = false
        await activate()
    }

    // MARK: Deactivation (§4.4 step 6) and reinstall (§4.6)

    enum DeactivationOutcome: Sendable, Equatable {
        case completed, afterReboot, guidedRemoval
        /// The request was canceled or superseded (codes 11/12), or the awaiting task was canceled. Nothing was removed.
        case cancelled
        case failed(ExtensionFailure)
    }

    /// In-app uninstall path. GUI context only. On 27 `sysextd` asks for an administrator authorization (D73-13).
    func deactivate() async throws(LPError) {
        let prior = try beginDeactivation()
        defer { if state == .deactivating { state = prior } }   // every exit that didn't settle a new state
        switch await runDeactivation() {
        case .completed: state = .uninstalled
        case .afterReboot: state = .needsReboot
        case .guidedRemoval:
            // §4.6 guided manual removal: the caller's sheet explains; we wait for the switch-off.
            try await guidedRemoval()
            state = .uninstalled
        case .cancelled: throw LPError(.cancelled, detail: "deactivation canceled")
        case .failed(let f): state = .failed(f); throw LPError(.extensionUnavailable, detail: "deactivation \(f)")
        }
    }

    /// User-initiated rollback (§4.6). The caller has already shown the confirmation and passed LAContext.
    func reinstall() async throws(LPError) {
        log.notice("reinstall requested; embedded \(self.embeddedVersion?.description ?? "?", privacy: .public)")
        let prior = try beginDeactivation()
        updateInProgress = true
        defer {
            updateInProgress = false
            if state == .deactivating { state = prior }
        }
        await quiescer.quiesce(reason: .reinstall)
        switch await runDeactivation() {
        case .completed: break
        case .afterReboot:
            state = .needsReboot          // the app resumes at step 4 on the next launch (settings.json marker, P2c)
            return
        case .guidedRemoval:
            do throws(LPError) { try await guidedRemoval() } catch {
                handBackAfterFailure()
                throw error
            }
        case .cancelled:
            handBackAfterFailure()        // nothing was removed: the installed extension keeps the tunnels
            throw LPError(.cancelled, detail: "reinstall canceled")
        case .failed(let f):
            state = .failed(f)
            handBackAfterFailure()
            throw LPError(.extensionUnavailable, detail: "reinstall \(f)")
        }
        noExtensionLeft = true            // removed: a failure from here on has nothing to hand back to
        refusedDowngrade = false
        state = .activating
        submit(.activation(.activationRequest(forExtensionWithIdentifier: extensionIdentifier, queue: .main)))
    }

    /// One deactivation at a time; returns the state to restore if it ends without settling a new one.
    private func beginDeactivation() throws(LPError) -> State {
        if state == .deactivating || requests.values.contains(where: { $0.kind == .deactivation }) {
            throw LPError(.extensionBusy, detail: "deactivation already in progress")
        }
        return state
    }

    private func runDeactivation() async -> DeactivationOutcome {
        state = .deactivating
        let req = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: extensionIdentifier, queue: .main)
        let gate = OneShot<DeactivationOutcome>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { k in
                gate.attach(k, ifCancelled: .cancelled)
                submit(.deactivation(req, gate))
            }
        } onCancel: {
            gate.cancel(.cancelled)                 // a cancelled caller never strands the continuation
        }
    }

    /// Opens Login Items & Extensions and waits until the extension goes inactive: the workspace observer's
    /// `systemExtensionWillBecomeInactive`, or a `propertiesRequest` poll every 2 s, up to 5 min.
    private func guidedRemoval() async throws(LPError) {
        guidedRemovalActive = true
        wentInactive = false
        defer { guidedRemovalActive = false }
        openExtensionSettings()
        let deadline = ContinuousClock.now + Self.guidedRemovalLimit
        while ContinuousClock.now < deadline {
            let entries = await fetchProperties()
            if let entries, !entries.contains(where: { $0.isEnabled && !$0.isUninstalling }) { return }
            if wentInactive { return }
            try? await Task.sleep(for: Self.guidedRemovalPoll)
        }
        throw LPError(.timeout, detail: "guided removal")
    }

    // MARK: Properties preflight (5 s through the one-shot gate)

    private func fetchProperties() async -> [ExtensionEntry]? {
        let req = OSSystemExtensionRequest.propertiesRequest(forExtensionWithIdentifier: extensionIdentifier, queue: .main)
        let gate = OneShot<[ExtensionEntry]?>()
        let timeout = propertiesTimeout
        let r = await withTaskCancellationHandler {
            await withCheckedContinuation { (k: CheckedContinuation<[ExtensionEntry]?, Never>) in
                gate.attach(k, ifCancelled: nil)
                submit(.properties(req, gate))
                Task { @Sendable in
                    try? await Task.sleep(for: timeout)
                    gate.resume(nil)
                }
            }
        } onCancel: {
            gate.cancel(nil)
        }
        finish(ObjectIdentifier(req))
        return r
    }

    // MARK: Requests

    private func submit(_ pending: Pending) {
        let req = pending.request
        req.delegate = self
        let id = ObjectIdentifier(req)
        requests[id] = pending
        if case .activation = pending { armWatchdog(id) }
        submitter(req)
    }

    private func finish(_ id: ObjectIdentifier) {
        requests[id] = nil
        watchdogs.removeValue(forKey: id)?.cancel()
    }

    /// Any delegate callback for the activation request disarms its watchdog.
    private func disarmWatchdog(_ id: ObjectIdentifier) { watchdogs.removeValue(forKey: id)?.cancel() }

    private func armWatchdog(_ id: ObjectIdentifier) {
        let limit = activationWatchdog
        watchdogs[id] = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: limit) } catch { return }
            self?.activationWatchdogFired(id)
        }
    }

    private func activationWatchdogFired(_ id: ObjectIdentifier) {
        watchdogs[id] = nil
        guard kind(id) == .activation, state == .activating else { return }
        log.error("activation request: no delegate callback within \(self.activationWatchdog, privacy: .public)")
        requests[id] = nil        // a late callback for it is ignored (no kind)
        updateInProgress = false
        state = .failed(.broken(code: 0))
        handBackAfterWatchdog()
    }

    /// Review 5 #3: sysextd never answered, so it may still finish the replacement (a late `.completed` is ignored: the
    /// request is dropped). The tunnels go back only to the extension that was installed, still enabled, with nothing
    /// awaiting approval (a fresh properties read); otherwise the hand-over stays and "Try again" settles it.
    private func handBackAfterWatchdog() {
        guard !noExtensionLeft else { return }
        let installed = installedAtPreflight ?? quiescedForVersion       // L4: also when nothing was quiesced
        Task { @MainActor [weak self] in
            guard let self else { return }
            let entries = await self.fetchProperties()
            guard WatchdogHandBack.allowed(entries: entries, installed: installed) else {
                self.log.error("activation watchdog: the installed extension isn't confirmed enabled; the hand-over stays until Try again")
                return
            }
            // E2E-4: the installed one is confirmed enabled, so this is "couldn't update", not "damaged".
            if self.state == .failed(.broken(code: 0)) { self.state = Self.activationFailureState(.broken(code: 0), code: 0, installed: installed) }
            await self.quiescer.resumeAfterUpdate()
        }
    }

    /// Review 4 #3: an activation (or a reinstall's deactivation) that failed after a quiesce leaves the installed
    /// extension running the tunnels, so the hand-over ends: on-demand and the connected profile come back through
    /// `resumeAfterUpdate` (the failure UI stays). Otherwise `pendingResume` would hold every plan forever, silently.
    /// Not when no extension is left (our reinstall removed it, or it was gone at the preflight): the hand-over stays and
    /// the Auto-Connect pane says so until "Try again" succeeds.
    private func handBackAfterFailure() {
        guard !noExtensionLeft else { return }
        Task { await quiescer.resumeAfterUpdate() }
    }

    private func kind(_ id: ObjectIdentifier) -> RequestKind? { requests[id]?.kind }

    // MARK: OSSystemExtensionRequestDelegate
    //
    // Witnesses are nonisolated (a @MainActor witness of this ObjC protocol is a Swift 6 error, SC10). Every request is
    // submitted with queue: .main, so the callbacks run on the main queue and hop with MainActor.assumeIsolated.
    // SAFETY: queue .main [SystemExtensions.h:95,126,142] — activation/deactivation/properties requests deliver their
    // delegate callbacks on the queue passed at creation.

    nonisolated func request(_ request: OSSystemExtensionRequest,
                             actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        // Pure compare on Sendable copies; no side effects beyond remembering a refusal for the failure that follows.
        let old = ExtensionVersion(shortVersion: existing.bundleShortVersion, bundleVersion: existing.bundleVersion)
        let new = ExtensionVersion(shortVersion: ext.bundleShortVersion, bundleVersion: ext.bundleVersion)
        switch ReplacementPolicy.decide(existing: old, embedded: new) {
        case .replace: return .replace
        case .cancel:
            // SAFETY: queue .main (submitted with queue: .main; see the section note above).
            MainActor.assumeIsolated { self.refusedDowngrade = true }
            return .cancel
        }
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        let id = ObjectIdentifier(request)
        // SAFETY: queue .main (requests are submitted with queue: .main).
        MainActor.assumeIsolated {
            guard kind(id) == .activation else { return }
            disarmWatchdog(id)
            // One sheet; keep the request alive until the user acts or the app quits; never resubmit.
            state = .needsUserApproval
            log.notice("activation needs user approval")
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        let id = ObjectIdentifier(request)
        let afterReboot = result == .willCompleteAfterReboot
        // SAFETY: queue .main (requests are submitted with queue: .main).
        MainActor.assumeIsolated { handleFinish(id, afterReboot: afterReboot) }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: any Error) {
        let id = ObjectIdentifier(request)
        let ns = error as NSError
        let code = ns.domain == OSSystemExtensionErrorDomain ? ns.code : SystemExtensionErrorCode.unknown.rawValue
        // SAFETY: queue .main (requests are submitted with queue: .main).
        MainActor.assumeIsolated { handleFailure(id, code: code) }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        let id = ObjectIdentifier(request)
        let entries = properties.map {
            ExtensionEntry(version: ExtensionVersion(shortVersion: $0.bundleShortVersion, bundleVersion: $0.bundleVersion),
                           isEnabled: $0.isEnabled, isAwaitingUserApproval: $0.isAwaitingUserApproval,
                           isUninstalling: $0.isUninstalling)
        }
        // SAFETY: queue .main (requests are submitted with queue: .main).
        MainActor.assumeIsolated { deliverProperties(id, entries) }
    }

    /// The properties answer for request `id` (the delegate; tests answer a recorded request through it).
    func deliverProperties(_ id: ObjectIdentifier, _ entries: [ExtensionEntry]) {
        if case .properties(_, let gate) = requests[id] { gate.resume(entries) }
    }

    private func handleFinish(_ id: ObjectIdentifier, afterReboot: Bool) {
        let k = kind(id)
        defer { if k != .properties { finish(id) } }
        switch k {
        case .activation:
            updateInProgress = false
            if afterReboot {
                state = .needsReboot              // one dialog, "Restart to finish installing", no retry
            } else {
                state = .ready(version: embeddedVersion?.description ?? "?")
                noExtensionLeft = false
                log.notice("extension ready \(self.embeddedVersion?.description ?? "?", privacy: .public)")
                onReady?()
                Task { await quiescer.resumeAfterUpdate() }
            }
        case .deactivation:
            if case .deactivation(_, let gate) = requests[id] { gate.resume(afterReboot ? .afterReboot : .completed) }
        case .properties, nil:
            break
        }
    }

    private func handleFailure(_ id: ObjectIdentifier, code: Int) {
        let k = kind(id)
        log.error("sysext request \(String(describing: k), privacy: .public) failed: \(code, privacy: .public)")
        switch k {
        case .properties:
            // treated as "unknown" by the preflight; fetchProperties() finishes the entry itself
            if case .properties(_, let gate) = requests[id] { gate.resume(nil) }
            return
        case .deactivation:
            let outcome: DeactivationOutcome = switch SystemExtensionErrorPolicy.outcome(code: code, phase: .deactivation) {
            case .fail(let f): .failed(f)
            case .ignore: .cancelled
            case .guidedRemoval: .guidedRemoval
            }
            if case .deactivation(_, let gate) = requests[id] { gate.resume(outcome) }
        case .activation:
            updateInProgress = false
            if code == SystemExtensionErrorCode.requestCanceled.rawValue && refusedDowngrade {
                state = .failed(.downgradeRefused)
                handBackAfterFailure()
            } else {
                switch SystemExtensionErrorPolicy.outcome(code: code, phase: .activation) {
                case .fail(let f):
                    state = Self.activationFailureState(f, code: code, installed: noExtensionLeft ? nil : installedAtPreflight)
                    handBackAfterFailure()
                case .ignore:
                    // Superseded by a newer request of ours: it owns the state. Canceled with no successor: restore the
                    // prior state so the UI offers its retry action again (Fable verification).
                    let successor = requests.contains { $0.key != id && $0.value.kind == .activation }
                    if !successor, state == .activating || state == .needsUserApproval {
                        state = Self.restoredState(after: stateBeforeActivation)
                        activationEndedWithoutResult = true
                        handBackAfterFailure()
                    }
                case .guidedRemoval:
                    state = .failed(.broken(code: code))   // not an activation outcome
                    handBackAfterFailure()
                }
            }
        case nil:
            break
        }
        finish(id)
    }

    #if DEBUG
    /// Tests only: a second activation request of ours in flight (the "superseded, a newer request owns it" path).
    func submitSecondActivationForTesting() -> OSSystemExtensionRequest {
        let r = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: extensionIdentifier, queue: .main)
        submit(.activation(r))
        return r
    }
    #endif

    /// E2E-4 (U14/U15): a replacement that failed as "broken" (signature, validation, …) while another version stays
    /// enabled is "couldn't update": the old extension keeps running the profiles. Other failures keep their own copy
    /// (Move to Applications, managed, …), and with nothing installed it stays `.failed`.
    static func activationFailureState(_ f: ExtensionFailure, code: Int, installed: ExtensionVersion?) -> State {
        if case .broken = f, let installed { return .updateFailed(installed: installed.description, code: code) }
        return .failed(f)
    }

    /// What a canceled activation with no successor goes back to. `.activating` itself is never restored.
    static func restoredState(after prior: State) -> State {
        prior == .activating ? .unknown : prior
    }

    // MARK: OSSystemExtensionsWorkspaceObserver (OSSystemExtensionInfo is Sendable)

    nonisolated func systemExtensionWillBecomeEnabled(_ info: OSSystemExtensionInfo) {
        guard info.bundleIdentifier == extensionIdentifier else { return }
        Task { @MainActor in
            if state == .disabledByUser { await activate() }
        }
    }

    nonisolated func systemExtensionWillBecomeDisabled(_ info: OSSystemExtensionInfo) {
        guard info.bundleIdentifier == extensionIdentifier else { return }
        Task { @MainActor in
            // L6: our own deactivation/reinstall (and the guided removal we asked for) is not "the user turned it off".
            guard state != .deactivating, !updateInProgress, !guidedRemovalActive else { return }
            state = .disabledByUser
        }
    }

    nonisolated func systemExtensionWillBecomeInactive(_ info: OSSystemExtensionInfo) {
        guard info.bundleIdentifier == extensionIdentifier else { return }
        Task { @MainActor in wentInactive = true }
    }
}
