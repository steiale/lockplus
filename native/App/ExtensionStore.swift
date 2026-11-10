import Foundation
import LPModel
import LPWire
import Observation

/// What the app root needs from the extension lifecycle (§4, §11.2). `ExtensionStore` is the real one; preview mode
/// uses `PreviewExtensionStore`. Observable implementations only.
@MainActor protocol ExtensionControlling: AnyObject {
    var state: SystemExtensionManager.State { get }
    /// An activation ended with nothing (canceled, no successor): the UI offers Try Again.
    var activationEndedWithoutResult: Bool { get }
    var updateInProgress: Bool { get }
    var link: ServiceLinkStatus { get }
    /// Called on `.completed` (hello + reconcile, §4.2 table).
    var onReady: (@MainActor () -> Void)? { get set }
    /// Called once the launch activation's preflight has finished (its request is submitted, or it ended early).
    /// Sparkle starts here (§12.1).
    var onPreflightFinished: (@MainActor () -> Void)? { get set }
    /// Launch: observe and activate once (L-EXT-2).
    func start()
    /// User-initiated "Try again" / "Approve" (§4.2). Clears the 4102 state first.
    func retryAfterUserAction() async
    /// User-initiated rollback (§4.6).
    func reinstall() async throws(LPError)
    /// In-app uninstall (§4.4 step 6). Throws `.cancelled` when the admin dialog was cancelled.
    func deactivate() async throws(LPError)
    func openExtensionSettings()
}

/// `ExtensionStore` (DESIGN §11.2): `SystemExtensionManager.state` + the XPC link from `hello` and the §5.4
/// interruption / respawn-throttle handling. The derived-state table reads `link` (row 4a "Reconnecting to the tunnel
/// process…" while `.reconnecting`).
@MainActor @Observable
final class ExtensionStore: ExtensionControlling {
    let manager: SystemExtensionManager
    @ObservationIgnored private let service: any TunnelServicing
    @ObservationIgnored private var linkTask: Task<Void, Never>?
    private(set) var link = ServiceLinkStatus.idle
    @ObservationIgnored var onPreflightFinished: (@MainActor () -> Void)?

    init(manager: SystemExtensionManager, service: any TunnelServicing) {
        self.manager = manager
        self.service = service
    }

    var state: SystemExtensionManager.State { manager.state }
    var activationEndedWithoutResult: Bool { manager.activationEndedWithoutResult }
    var updateInProgress: Bool { manager.updateInProgress }
    var onReady: (@MainActor () -> Void)? {
        get { manager.onReady }
        set { manager.onReady = newValue }
    }

    func start() {
        let updates = service.linkUpdates
        linkTask = Task { @MainActor [weak self] in
            for await s in updates { self?.apply(s) }
        }
        manager.startObserving()
        Task { @MainActor [weak self] in
            await self?.manager.activate()
            self?.onPreflightFinished?()
        }
    }

    func stop() { linkTask?.cancel() }

    func apply(_ s: ServiceLinkStatus) {
        link = s
        // 4102: the same wording as the damaged-bundle activation state (§5.4), never an automatic reinstall.
        if case .unavailable(let e) = s.link, e.code == .unauthorizedPeer { manager.setFailed(.unauthorizedPeer) }
    }

    /// User-initiated "Try again". Clears the client's 4102 state (the only way out of it) before re-activating.
    func retryAfterUserAction() async {
        if case .unavailable(let e) = link.link, e.code == .unauthorizedPeer {
            await service.resetAfterUserAction()
        }
        await manager.retryAfterUserAction()
    }

    /// User-initiated rollback (§4.6). Reinstalling is the other way out of the 4102 state.
    func reinstall() async throws(LPError) {
        try await manager.reinstall()
        await service.resetAfterUserAction()
    }

    func deactivate() async throws(LPError) { try await manager.deactivate() }

    func openExtensionSettings() { manager.openExtensionSettings() }
}

/// UI mirrors of the extension state (StateInputs.swift). Pure, tested.
enum ExtensionMapping {
    static func readiness(_ s: SystemExtensionManager.State, endedWithoutResult: Bool) -> ExtensionReadiness {
        switch s {
        case .ready: .ready
        case .unknown: endedWithoutResult ? .failed : .activating
        case .activating: .activating
        case .needsReboot: .rebootRequired
        case .needsUserApproval: .needsUserApproval
        case .disabledByUser: .disabledByUser
        case .removedDuringUpdate: .removedDuringUpdate
        case .failed, .deactivating, .uninstalled: .failed
        case .updateFailed: .updateFailed
        }
    }

    /// `.idle` (no hello yet) is not a problem: row 4a is only for a link that went away.
    static func link(_ l: ServiceLinkStatus.Link) -> XPCLinkState {
        switch l {
        case .idle, .validated: .validated
        case .reconnecting: .reconnecting
        case .unavailable: .unavailable
        }
    }

    static func onboardingStep(_ s: SystemExtensionManager.State, endedWithoutResult: Bool) -> OnboardingUIModel.ExtensionStep {
        switch s {
        case .unknown: endedWithoutResult ? .failed(String(localized: "Installing the tunnel component was cancelled.", comment: "Onboarding step 2, activation cancelled")) : .idle
        case .activating: .requesting
        case .needsUserApproval, .disabledByUser, .removedDuringUpdate: .needsApproval
        case .needsReboot: .rebootRequired
        case .ready: .done
        case .failed(let f): .failed(message(f))
        case .updateFailed(_, let code): .failed(updateFailedMessage(code: code))
        case .deactivating, .uninstalled: .idle
        }
    }

    /// E2E-4 (U15): the one honest line for a failed update while the old extension runs the profiles. The banner, the
    /// onboarding step and everything that needs XPC (sign-in prompts, details) use it.
    static func updateFailedMessage(code: Int? = nil) -> String {
        let base = String(localized: "LockPlus couldn't update its tunnel component. Profiles set up before the update still connect, but LockPlus can't show their details until the update completes.",
                          comment: "Extension update failed while the old one keeps working (E2E-4, U15)")
        guard let code, code != 0 else { return base }
        return base + " (\(code))"
    }

    static func message(_ f: ExtensionFailure) -> String {
        switch f {
        case .olderAppThanExtension(let v):
            String(localized: "A newer tunnel component (\(v)) is installed. Reinstall to use this version.", comment: "Extension failure")
        case .downgradeRefused: String(localized: "A newer tunnel component is installed.", comment: "Extension failure")
        case .broken(let code): String(localized: "This copy of LockPlus is damaged. Reinstall LockPlus. (\(code))", comment: "Extension failure")
        case .managed: String(localized: "Your organization blocks this extension.", comment: "Extension failure")
        case .notInApplications: String(localized: "Move LockPlus to the Applications folder, then open it again.", comment: "Extension failure")
        case .authorizationRequired: String(localized: "Administrator approval required.", comment: "Extension failure")
        case .unauthorizedPeer: String(localized: "The tunnel component is damaged. Reinstall LockPlus.", comment: "Extension failure")
        }
    }
}
