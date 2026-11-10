import Foundation
import LPModel
import LPWire

/// DESIGN §7.1 AuthBroker: prompt minting, promptID matching, prompt deadlines, the `prepareStartAuth` answers and the
/// 3-rejections-in-10-min counter. A value type owned by the controller actor; secrets stay in `SecretBytes` and never
/// reach `state.plist` (§6.5).
///
/// Draft 9 (S2 E14b: macOS has no start time limit): every first-connect prompt is answered INTO the pending start
/// (`live`, `beforeConnected`). There is no cross-start stash any more: a failed start leaves nothing behind, and no
/// start option names a prompt. What remains outside a start is a `prepareStartAuth` answer for a known-interactive
/// profile, which the next manual start of that (owner, profile) takes, once.
struct AuthBroker {
    /// Prompt deadlines (the former stash TTLs): 10 min; CRV1 5 min (the test server's state lifetime, S8).
    static let promptTTL: TimeInterval = 600
    static let crv1TTL: TimeInterval = 300
    static let rejectionWindow: TimeInterval = 600
    static let rejectionLimit = 3

    static func ttl(for kind: AuthKind) -> TimeInterval { kind == .dynamicChallenge ? crv1TTL : promptTTL }

    /// A `prepareStartAuth` prompt (`nextStart == true`) and, once answered, its answer.
    struct Prepared {
        var promptID: UUID
        var profileID: UUID
        var ownerUID: uid_t
        var kind: AuthKind
        var savedUsername: String?
        var answer: AuthAnswerSecrets?
        var expiresAt: Date

        var key: ProfileKey { ProfileKey(ownerUID: ownerUID, profileID: profileID) }
        var prompt: AuthPrompt {
            AuthPrompt(promptID: promptID, profileID: profileID, kind: kind, challengeText: nil, echo: false, lockedUsername: nil,
                       reason: .initial, savedUsername: savedUsername, nextStart: true, expiresAt: expiresAt)
        }
    }

    /// The `awaitingAuth` prompt of the running session (in the pending start or after Connected); `nextStart == false`.
    struct LivePrompt {
        var prompt: AuthPrompt
        var ownerUID: uid_t
        var beforeConnected: Bool
        var challenge: AuthChallenge
        /// true: the engine attempt ended with this prompt (`adapter.start` threw `.auth`), so the answer starts a new
        /// attempt inside the same pending start. false: the attempt is still running (`AUTH_PENDING`, or after
        /// Connected) and the answer goes to `adapter.provideAuth`.
        var restartsEngine: Bool
    }

    private(set) var prepared: [ProfileKey: Prepared] = [:]    // at most one per (owner, profile)
    var live: LivePrompt?
    private var rejections: [ProfileKey: [Date]] = [:]

    // MARK: prepareStartAuth

    /// `prepareStartAuth` (§8.4 known-interactive profiles): a prompt before the first start. A newer one replaces
    /// the older one of the same profile.
    mutating func prepare(profileID: UUID, ownerUID: uid_t, kind: AuthKind, savedUsername: String?, now: Date) -> AuthPrompt {
        let p = Prepared(promptID: UUID(), profileID: profileID, ownerUID: ownerUID, kind: kind, savedUsername: savedUsername,
                         answer: nil, expiresAt: now.addingTimeInterval(Self.promptTTL))
        prepared[p.key] = p
        return p.prompt
    }

    /// The live prompt of this profile, else its unanswered prepared prompt.
    func pendingPrompt(_ key: ProfileKey, now: Date) -> AuthPrompt? {
        if let l = live, l.prompt.profileID == key.profileID, l.ownerUID == key.ownerUID { return l.prompt }
        guard let e = prepared[key], e.expiresAt > now, e.answer == nil else { return nil }
        return e.prompt
    }

    func prepared(promptID: UUID) -> Prepared? { prepared.values.first { $0.promptID == promptID } }

    enum AttachResult: Equatable { case prepared, live, stale }

    /// `answerAuth`: identifies the live prompt, or attaches the answer to a prepared prompt (which starts nothing).
    /// Unknown, expired or already answered → stale.
    mutating func attach(promptID: UUID, answer: AuthAnswerSecrets, now: Date) -> AttachResult {
        if let l = live, l.prompt.promptID == promptID { return .live }
        guard var e = prepared(promptID: promptID), e.expiresAt > now, e.answer == nil else { return .stale }
        e.answer = answer
        prepared[e.key] = e
        return .prepared
    }

    /// The answered, unexpired prepared answer of this profile for its next MANUAL start, removed on the way out
    /// (one start, once: a start that fails before `provide_creds` simply asks again in-start).
    mutating func takePrepared(_ key: ProfileKey, now: Date) -> StashBinding? {
        guard let e = prepared[key], e.expiresAt > now, let a = e.answer else { return nil }
        prepared[key] = nil
        return StashBinding(promptID: e.promptID, answer: a, carriedUsername: nil, carriedPassword: nil, cookie: nil)
    }

    mutating func expire(now: Date) {
        prepared = prepared.filter { $0.value.expiresAt > now }
    }

    @discardableResult mutating func cancel(promptID: UUID) -> Bool {
        guard let e = prepared(promptID: promptID) else { return false }
        prepared[e.key] = nil
        return true
    }

    /// Only prepared answers. The `live` prompt belongs to the running session and ends with it (review L6): before
    /// Connected the controller ends the pending start first (`endWaitingStart`), after Connected it stays answerable
    /// until the session's own stop or deadline, so `cancelAuth`/`promptResolved` never lose track of it.
    mutating func dropPrepared(_ key: ProfileKey) { prepared[key] = nil }
    mutating func dropPrepared(ownerUID: uid_t) {
        prepared = prepared.filter { $0.value.ownerUID != ownerUID }
    }

    // MARK: rejections

    /// Records a rejection; returns how many fall inside the 10 min window (this one included).
    mutating func recordRejection(_ key: ProfileKey, now: Date) -> Int {
        var r = (rejections[key] ?? []).filter { now.timeIntervalSince($0) < Self.rejectionWindow }
        r.append(now)
        rejections[key] = r
        return r.count
    }
    mutating func clearRejections(_ key: ProfileKey) { rejections[key] = nil }
}
