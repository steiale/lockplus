import Foundation
import LPModel
import LPWire
import Observation
import os

/// `AuthCoordinator` (DESIGN §8.4, §11.2): one prompt at a time, keyed by promptID.
/// Draft 9 (S2 E14b: macOS has no start time limit): every prompt the server asks for during a connect (CRV1, a
/// rejected password, NEED_CREDS, AUTH_PENDING) is answered INTO the pending start: the sheet's answer connects that
/// same start, with no "connect again" step. Start options never carry a promptID or an answer (S2 E1 replays them).
/// - Known-interactive profiles (unsaved password, static challenge, unsaved key passphrase): `prepareStartAuth` before
///   the start, so the user types while the Mac is still online; after `answerAuth` the app starts the tunnel and that
///   start takes the answer (`nextStart == true`). Anything still missing is asked inside the start.
/// - Reconnect prompts are answered into the running session.
/// Secrets live in `String`s only between the sheet and the XPC request (§6.5); nothing here stores them.
@MainActor @Observable
final class AuthCoordinator {
    /// The prompt shown (or waiting for a user gesture to be shown).
    private(set) var prompt: AuthPrompt?
    private(set) var expired = false
    private(set) var lastError: LPError?
    /// Bumped when a failed answer puts the same prompt back (review M5), so the UI shows it again.
    private(set) var reshowCount = 0
    /// M5: why the answer failed (interim UI: an alert until AuthUIModel has an error line).
    @ObservationIgnored var onAnswerFailed: ((LPError) -> Void)?

    @ObservationIgnored private let service: any TunnelServicing
    @ObservationIgnored private let profiles: ProfilesStore
    @ObservationIgnored private let connection: ConnectionStore
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "io.github.steiale.lockplus.mac", category: "auth")
    /// A new prompt is waiting (the user notification when no window is key, §8.4).
    @ObservationIgnored var onPromptShown: ((AuthPrompt) -> Void)?

    init(service: any TunnelServicing, profiles: ProfilesStore, connection: ConnectionStore) {
        self.service = service
        self.profiles = profiles
        self.connection = connection
        connection.onObservedDisconnect = { [weak self] id, _ in
            // A prompt of a session that ended died with it (there is no stash to pull any more).
            guard let self, self.prompt?.profileID == id, self.prompt?.nextStart == false else { return }
            self.clear()
        }
        connection.onStatus = { [weak self] id, status in
            guard let self else { return }
            if status == .connecting || status == .reasserting { Task { await self.pullPending(id) } }
            if status == .connected, self.prompt?.profileID == id, self.prompt?.kind == .pendingApproval { self.clear() }
        }
    }

    // MARK: Connect

    /// The connect intent: known-interactive profiles prompt first (draft 6), everything else starts directly.
    func connect(_ id: UUID) {
        guard let p = profiles.profile(id) else {
            log.notice("connect of \(id.uuidString.prefix(8), privacy: .public) ignored: no such profile")
            return
        }
        let facts = profiles.credentials[id]
        guard let kind = p.preStartAuthKind(hasSavedPassword: facts?.passwordSaved ?? false,
                                            hasSavedPassphrase: facts?.passphraseSaved ?? false) else {
            connection.connect(id)
            return
        }
        Task { @MainActor in
            do throws(LPError) {
                let pr = try await service.call(.prepareStartAuth, PrepareStartAuth(profileID: id, kind: kind), as: AuthPrompt.self)
                show(pr)
            } catch {
                log.error("prepareStartAuth failed: \(error.code.rawValue, privacy: .public)")
                // Start anyway: the extension asks for what's missing inside the start.
                connection.connect(id)
            }
        }
    }

    // MARK: Prompts

    func handle(_ e: TunnelEvent) {
        switch e.kind {
        case .authRequired:
            if let p = e.prompt { show(p) }
        case .promptResolved:
            if let id = e.promptID, prompt?.promptID == id { clear() }
        case .snapshotChanged, .anyTunnelStateChanged, .sessionEnded:
            break
        }
    }

    /// `pendingAuthPrompt` (launch, `.connecting`/`.reasserting`, a disconnect with an auth code, an interruption).
    func pullPending(_ id: UUID) async {
        do throws(LPError) {
            let r = try await service.call(.pendingAuthPrompt, ProfileRequest(profileID: id), as: PendingAuthPromptReply.self)
            if let p = r.prompt { show(p) }
        } catch {
            log.notice("pendingAuthPrompt: \(error.code.rawValue, privacy: .public)")
        }
    }

    private func show(_ p: AuthPrompt) {
        guard p.expiresAt > Date() else { return }
        if prompt?.promptID == p.promptID { return }
        prompt = p
        expired = false
        lastError = nil
        connection.awaitingApproval = p.kind == .pendingApproval
        onPromptShown?(p)
        expiryTask?.cancel()
        let delay = p.expiresAt.timeIntervalSinceNow
        expiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0, delay)))
            guard !Task.isCancelled, let self, self.prompt?.promptID == p.promptID else { return }
            self.expired = true
        }
    }

    private func clear() {
        prompt = nil
        expired = false
        connection.awaitingApproval = false
        expiryTask?.cancel()
    }

    /// The answer as it goes on the wire (pure; tested). appendOTP: password = base + code, `save` never sends the
    /// concatenation (the base password is saved separately). Static challenge: the response field. CRV1: response.
    static func wireAnswer(_ a: AuthAnswer, prompt: AuthPrompt, appendOTP: Bool) -> WireAuthAnswer {
        func data(_ s: String) -> Data? { s.isEmpty ? nil : Data(s.utf8) }
        switch prompt.kind {
        case .userPass:
            if appendOTP {
                return WireAuthAnswer(promptID: a.promptID, username: data(a.username), password: data(a.password + a.response),
                                         response: nil, save: false)
            }
            return WireAuthAnswer(promptID: a.promptID, username: data(a.username), password: data(a.password),
                                     response: nil, save: a.savePassword)
        case .staticChallenge:
            return WireAuthAnswer(promptID: a.promptID, username: data(a.username), password: data(a.password),
                                     response: data(a.response), save: a.savePassword)
        case .dynamicChallenge:
            return WireAuthAnswer(promptID: a.promptID, username: nil, password: nil, response: data(a.response), save: false)
        case .keyPassphrase:
            return WireAuthAnswer(promptID: a.promptID, username: nil, password: data(a.password), response: nil, save: a.savePassword)
        case .pendingApproval:
            return WireAuthAnswer(promptID: a.promptID, username: nil, password: nil, response: nil, save: false)
        }
    }

    /// submitAuth: `answerAuth` on the hello-validated connection. An in-start or reconnect prompt needs nothing more:
    /// the answer goes into the running start/session. A `prepareStartAuth` prompt then starts the tunnel (the start
    /// takes the answer). `.staleAnswer` discards the form.
    func submit(_ a: AuthAnswer) {
        guard let pr = prompt, pr.promptID == a.promptID else { return }
        let profile = profiles.profile(pr.profileID)
        let appendOTP = profile?.auth?.appendOTP ?? false
        let wire = Self.wireAnswer(a, prompt: pr, appendOTP: appendOTP)
        let saveBase = appendOTP && a.savePassword && pr.kind == .userPass
        let baseUser = a.username, basePassword = a.password
        clear()
        Task { @MainActor in
            do throws(LPError) {
                try await service.callVoid(.answerAuth, wire)
            } catch {
                lastError = error
                if error.code == .staleAnswer {
                    log.notice("stale answer discarded")
                    return
                }
                // M5: the answer never arrived (busy, link down): the prompt comes back with the error, still valid.
                log.error("answerAuth failed: \(error.code.rawValue, privacy: .public)")
                if pr.expiresAt > Date(), prompt == nil {
                    show(pr)
                    lastError = error           // after show(), which clears it for a new prompt
                    reshowCount += 1
                }
                onAnswerFailed?(error)
                return
            }
            if saveBase {
                do throws(LPError) {
                    var rec = try await profiles.loadCredentials(pr.profileID) ?? CredentialRecord()   // L10
                    rec.username = baseUser.isEmpty ? rec.username : Data(baseUser.utf8)
                    rec.password = Data(basePassword.utf8)
                    try await profiles.saveCredentials(pr.profileID, rec)
                } catch {
                    profiles.note("The password wasn't saved (\(error.code)).")
                }
            }
            if pr.nextStart { connection.connect(pr.profileID) }
        }
    }

    /// Cancel leaves the profile disconnected with no error (UI-CONCEPT §6.5). A prompt inside a pending start is also
    /// a user stop: with the kill switch the extension would otherwise keep the start held (blocked, S2 E14).
    func cancel(_ promptID: UUID) { cancel(promptID, stopsStart: true) }
    /// Disconnect closes the prompt; the Disconnect itself is the stop.
    func cancelForDisconnect(_ promptID: UUID) { cancel(promptID, stopsStart: false) }

    /// `stopsStart: false`: the caller stops the start itself (Try Again, Disconnect).
    private func cancel(_ promptID: UUID, stopsStart: Bool) {
        guard let pr = prompt, pr.promptID == promptID else { return }
        clear()
        let inStart = stopsStart && !pr.nextStart && connection.statuses[pr.profileID] == .connecting
        // The user stop is registered FIRST (synchronously): without the kill switch `cancelAuth` fails the start at
        // once, and its `.disconnected` must already read as a user stop, never as "stopped with an error" (review L1).
        if inStart, connection.currentID == pr.profileID { connection.disconnect() }
        Task { @MainActor in
            try? await service.callVoid(.cancelAuth, CancelAuthRequest(promptID: promptID))
        }
    }

    /// "Waiting for approval… Try Again": cancel the wait and start a new attempt.
    func retryApproval(_ promptID: UUID) {
        guard let pr = prompt, pr.promptID == promptID else { return }
        cancel(promptID, stopsStart: false)
        Task { @MainActor in
            // L5: start again once the old attempt is really down (≤ 10 s), not after a guessed second.
            await connection.disconnectAndWait(timeout: .seconds(10))
            connect(pr.profileID)
        }
    }

    /// The UI's prompt state (§6.5). Pure; tested.
    static func uiState(_ p: AuthPrompt, profile: Profile?) -> AuthPromptState {
        let appendOTP = profile?.auth?.appendOTP ?? false
        let kind: AuthPromptState.Kind
        var notice: AuthPromptState.Notice?
        switch p.kind {
        case .userPass:
            kind = p.reason == .rejected ? .rejected(serverReason: p.challengeText, oneTimeCode: appendOTP)
                                         : .password(oneTimeCode: appendOTP)
        case .staticChallenge:
            let sc = profile?.auth?.staticChallenge
            kind = .staticChallenge(StaticChallenge(text: p.challengeText ?? sc?.text ?? "", echo: p.echo, concat: sc?.concat ?? false))
        case .dynamicChallenge:
            kind = .dynamicChallenge(text: p.challengeText ?? "", echo: p.echo)
            if p.reason == .rejected { notice = .codeExpiredFreshChallenge }
        case .keyPassphrase:
            kind = .keyPassphrase
        case .pendingApproval:
            kind = .waitingForApproval(tooLate: false)
        }
        let canSave = (profile?.auth?.saveCredentials ?? true) && p.kind != .dynamicChallenge && p.kind != .pendingApproval
        return AuthPromptState(id: p.promptID, profileName: profile?.name ?? "", kind: kind,
                               username: p.lockedUsername ?? p.savedUsername ?? "", canSavePassword: canSave,
                               expiresAt: p.expiresAt, notice: notice)
    }
}
