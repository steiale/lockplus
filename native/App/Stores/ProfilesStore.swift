import Foundation
import LPParsing
import LPModel
import LPWire
import Observation
import os

/// A profile ready to be created: the output of the import pipeline (§8.1, §9.1) or the Go migration (§13.1).
struct ProfileDraft: Sendable {
    var name: String
    var kind: VPNProtocolKind
    /// Canonical text, sealed by the repository and provisioned to the extension.
    var payload: SecretBytes
    var summary: ProfileSummary
    var auth: AuthPolicy?
    var report: ImportReport
    var policy: NetworkPolicy
    var credentials: CredentialRecord?
    var engineVerified: Bool
    var origin: ProfileOrigin
    var notes: String = ""
}

/// What the app keeps in memory about the saved credentials (never the secrets themselves).
struct CredentialFacts: Codable, Sendable, Equatable {
    var username: String?
    var passwordSaved: Bool
    var passphraseSaved: Bool
}

/// The app-side ProfileStore (DESIGN §3.4, §6.4, §6.6): profile files + NE managers + the extension's copy.
/// The repository (an actor) does files and crypto; this main-actor store coordinates and owns the in-memory list.
@MainActor @Observable
final class ProfilesStore {
    private(set) var profiles: [Profile] = []
    /// §3.4 A1/N6: profiles whose metadata failed the HMAC or replay check.
    private(set) var tampered: [UUID] = []
    /// `flagsDrifted` heals done at idle this run: profile → the metadata revision that was re-saved.
    private var healedDrift: [UUID: UInt64] = [:]
    /// E2E-4 review M1: the same for the heal on a `.connected` session. Separate from `healedDrift`, so a live heal
    /// the system undid leaves the idle path its own attempt (an on-demand start doesn't go through `prepareForStart`).
    private var healedLiveDrift: [UUID: UInt64] = [:]
    /// Review N3: drifts of a live session noted this run (profile → metadata revision), so a reload doesn't repeat it.
    private var notedLiveDrift: [UUID: UInt64] = [:]
    /// E2E-4: a protective heal in flight (a second trigger meanwhile is not a "repeat").
    @ObservationIgnored private var healingDrift: Set<UUID> = []
    /// The wait between a manager save and the reload that verifies it (`prepareForStart`). Tests set it to zero.
    var settleAfterSave: Duration = .milliseconds(500)
    /// E2E-3: true while ANOTHER profile is starting or active (ConnectionStore). Its on-demand then stays off: another
    /// configuration's on-demand blocks a kill-switch session after a network change.
    @ObservationIgnored var onDemandHeldBack: @MainActor (UUID) -> Bool = { _ in false }
    /// Review F5/R3 (2026-10-30): a mutation of this profile's manager must wait (`ConnectionStore.mutationBlocked`):
    /// a start or session is under way, and a save of another configuration while a kill-switch start is pending is the
    /// PF 50 failure mode. `load()` and `resaveOnDemand()` then skip it; it runs when idle (`hasDeferredSync`). The
    /// headless agent blocks everything (it only reads).
    @ObservationIgnored var mutationBlocked: @MainActor (UUID) -> Bool = { _ in false }
    /// Round 7 (Fable L3): the one predicate for a start's own configuration work (`prepareForStart`'s saves, its own
    /// on-demand restore, the pause of the others): another configuration (ours, any user's, a stray) is in a pending
    /// start (`ConnectionStore.otherStartPending`). A merely connected one doesn't block them.
    @ObservationIgnored var otherStartPending: @MainActor (UUID) -> Bool = { _ in false }
    /// Review e321e10: `delete` stops a live session through this (`ConnectionStore.stopAndWait`: a user stop, waited
    /// for, bounded) before it removes the configuration. Nil (headless, previews): a plain `stop`.
    @ObservationIgnored var stopSessionBeforeRemoval: (@MainActor (UUID) async -> Void)?
    /// Review 5c3a899/f18c0d6 M-1: profiles whose `delete` is under way. No configuration is (re-)created for one
    /// (`syncManager`, `prepareForStart`), and its on-demand plan is nil: a start's prepare that outlives the Delete
    /// must not bring the removed manager back with on-demand on.
    @ObservationIgnored private var deleting: Set<UUID> = []
    /// Something `load()` or `resaveOnDemand()` skipped while busy; `runDeferredSync()` runs at idle (the only flag).
    @ObservationIgnored private(set) var hasDeferredSync = false
    /// The headless agent reads profiles only; it neither needs nor rebuilds the credential facts (review nit).
    @ObservationIgnored var readsCredentialFacts = true
    /// The wait between the last manager mutation and `startVPNTunnel` (E2E-3, 200003: 1 s was verified).
    var settleBeforeStart: Duration { settleAfterSave * 2 }
    private(set) var credentials: [UUID: CredentialFacts] = [:]
    /// The last `load()` read the profile directory successfully. Reconcile only runs then: a failed read would
    /// otherwise look like "no profiles" and remove every extension copy (review M2).
    private(set) var loaded = false
    /// §6.8 "Profiles from another Mac are locked": names from unverified metadata (display only). nil = not locked.
    private(set) var locked: [String]?
    /// E2E-4: the last `load()` failed for another reason than "locked" (the reason; nil after a successful read). The
    /// list then shows that, never an empty "No Profiles".
    private(set) var loadError: String?
    /// Background failures for Diagnostics › Problems (§11.7), newest last.
    struct Problem: Identifiable, Sendable, Equatable { let id = UUID(); var date: Date; var message: String }
    private(set) var problems: [Problem] = []

    @ObservationIgnored let repository: ProfileRepository
    @ObservationIgnored let credentialStore: CredentialStore
    @ObservationIgnored let managers: any VPNManaging
    @ObservationIgnored let service: any TunnelServicing
    @ObservationIgnored let settings: SettingsStore
    @ObservationIgnored let ownerUID: uid_t
    /// credential-facts.json (non-secret; Fable L3). nil in some tests: facts then live in memory.
    @ObservationIgnored let factsFile: URL?
    @ObservationIgnored private var reconciling = false
    @ObservationIgnored private let log = Logger(subsystem: "io.github.steiale.lockplus.mac", category: "profiles")

    init(repository: ProfileRepository, credentialStore: CredentialStore, managers: any VPNManaging,
         service: any TunnelServicing, settings: SettingsStore, ownerUID: uid_t = getuid(), factsFile: URL? = nil) {
        self.factsFile = factsFile
        self.repository = repository
        self.credentialStore = credentialStore
        self.managers = managers
        self.service = service
        self.settings = settings
        self.ownerUID = ownerUID
        settings.onAutoConnectChoiceChange = { [weak self] in self?.autoConnectChoiceChanged() }
    }

    // MARK: Auto-Connect choice (round 2, Fable M1b)

    /// Whether the Auto-Connect choice in `settings` may give a plan. `.unverified` until `load()` checked the tag of
    /// the value read from disk (an enabled choice then gives no plan); every in-process change is `.trusted`.
    enum AutoConnectTrust: Sendable, Equatable { case unverified, trusted }
    @ObservationIgnored private(set) var autoConnectTrust = AutoConnectTrust.unverified
    @ObservationIgnored private var choiceSeal: Task<Void, Never>?

    /// The user (or LockPlus itself: a delete, the Go migration) changed the choice in this process: trusted, and sealed
    /// for the next launch. One seal at a time, each of the value current when it runs (the last one written wins).
    private func autoConnectChoiceChanged() {
        autoConnectTrust = .trusted
        let previous = choiceSeal
        choiceSeal = Task { @MainActor [weak self] in
            await previous?.value
            await self?.sealAutoConnectChoice()
        }
    }

    /// Round 6 (Codex r6 #3): `ConnectionStore`'s retry of an owed pause value, at each `load()`.
    @ObservationIgnored var onLoad: (@MainActor () -> Void)?

    /// Round 4 (Fable N4): an "off" whose seal failed is sealed again later.
    @ObservationIgnored private(set) var autoConnectSealOwed = false
    @ObservationIgnored var sealRetryDelay: Duration = .seconds(30)
    @ObservationIgnored var sealRetrySleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    @ObservationIgnored private var sealRetry: Task<Void, Never>?
    @ObservationIgnored private var sealRetries = 0
    static let maxSealRetries = 10
    private func scheduleOwedSeal() {
        autoConnectSealOwed = true
        guard sealRetry == nil, sealRetries < Self.maxSealRetries else { return }     // then at the next `load()` only
        sealRetries += 1
        let sleep = sealRetrySleep, delay = sealRetryDelay
        sealRetry = Task { @MainActor [weak self] in
            await sleep(delay)
            self?.sealRetry = nil
            self?.retryOwedSeal()
        }
    }
    /// Seals the current choice again if a seal is owed (and nothing newer is being sealed).
    func retryOwedSeal() {
        guard autoConnectSealOwed else { return }
        autoConnectSealOwed = false
        let previous = choiceSeal                     // the trust is left as it is: only the seal is redone
        choiceSeal = Task { @MainActor [weak self] in
            await previous?.value
            // Never a seal of an enabled choice that isn't trusted (that would launder one read from disk).
            guard let self, !self.settings.value.autoConnect.enabled || self.autoConnectTrust == .trusted else { return }
            await self.sealAutoConnectChoice()
        }
    }

    /// Waits for the choice's tag to be written (tests; the quit path doesn't need it: a lost tag turns Auto-Connect off).
    func awaitAutoConnectSeal() async { await choiceSeal?.value }

    /// Round 3 (Fable M1, Codex r3 #2): every state, "off" included: each seal replaces the one-time value, so a tag of an
    /// earlier (enabled) choice stops verifying.
    private func sealAutoConnectChoice() async {
        let c = settings.value.autoConnect
        do throws(LPError) {
            let tag = try await repository.sealRecord(.autoConnectChoice, AutoConnectRules.choiceMessage(enabled: c.enabled, profileID: c.profileID))
            settings.update {
                if $0.autoConnect.enabled == c.enabled, $0.autoConnect.profileID == c.profileID { $0.autoConnect.choiceTag = tag }
            }
        } catch {
            log.error("Auto-Connect choice not sealed: \(error.code.rawValue, privacy: .public)")
            // An "off" that couldn't be sealed: the tag goes (an old enabled tag must not stay beside it), nothing to say.
            // Round 4 (Fable N4): the old one-time value is still there, so a copied enabled choice would still verify at
            // the next launch: the seal is owed and retried (`sealRetryDelay`, and at every `load()`) until it lands or
            // the choice changes (a quit before then: the next launch seals an untagged "off" anyway).
            guard c.enabled else {
                settings.update { if !$0.autoConnect.enabled { $0.autoConnect.choiceTag = nil } }
                scheduleOwedSeal()
                return
            }
            note(String(localized: "LockPlus couldn't secure the Auto-Connect setting (\(error.code.rawValue)). It works now, but is turned off at the next launch unless you set it again.",
                        comment: "Problems line (2.0.2 round 2): the Auto-Connect choice couldn't be sealed in the keychain"))
        }
    }

    /// Checks the choice read from disk (once per run, before anything is saved). Valid: trusted. Written by a build
    /// before 2.0.2 (no record of the kind was ever sealed here): trusted once and sealed. Invalid: Auto-Connect is
    /// turned off and the user told. The keychain unreadable: stays unverified (no plan for it) until a later `load()`.
    /// Round 3 (Fable M1, Codex r3 #2): a disabled choice gives no plan whatever its tag, but it is sealed whenever its tag
    /// doesn't verify, the first 2.0.2 launch included: from then on the one-time value exists, so `.neverSealed` (the
    /// trust-once migration) happens at most once per Mac, not until the user first turns Auto-Connect on.
    private func verifyAutoConnectChoice() async {
        guard autoConnectTrust == .unverified else { return }
        let c = settings.value.autoConnect
        let check = await repository.checkRecord(.autoConnectChoice, tag: c.choiceTag,
                                                 AutoConnectRules.choiceMessage(enabled: c.enabled, profileID: c.profileID))
        guard c.enabled else {
            autoConnectTrust = .trusted
            // Round 5 (Codex r5 #7): also when it couldn't be checked: an "off" whose seal a quit cut short is sealed
            // (owed and retried, at the latest at the next `load()`), never left beside an older enabled tag's value.
            if check != .valid { autoConnectChoiceChanged() }
            return
        }
        switch check {
        case .valid:
            autoConnectTrust = .trusted
        case .neverSealed:
            log.notice("Auto-Connect choice from a build before 2.0.2: trusted once and sealed")
            autoConnectChoiceChanged()
        case .invalid:
            log.fault("Auto-Connect choice in settings.json doesn't verify; turned off")
            settings.update {
                $0.autoConnect.enabled = false
                $0.autoConnect.profileID = nil
                $0.autoConnect.choiceTag = nil
            }
            note(String(localized: "The Auto-Connect setting was changed outside LockPlus, so Auto-Connect was turned off. Turn it on again if you want it.",
                        comment: "Problems line (2.0.2 round 2): the Auto-Connect choice in settings.json failed its authentication check"))
        case .unavailable:
            log.error("Auto-Connect choice not checked: keychain unavailable; no plan until it can be")
        }
    }

    func profile(_ id: UUID?) -> Profile? {
        guard let id else { return nil }
        return profiles.first { $0.id == id }
    }

    /// Sidebar order: the user's drag order, then alphabetical.
    var ordered: [Profile] {
        let order = settings.value.profileOrder
        return profiles.sorted { a, b in
            let ia = order.firstIndex(of: a.id) ?? Int.max, ib = order.firstIndex(of: b.id) ?? Int.max
            if ia != ib { return ia < ib }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Problems are shown to the user verbatim; the unified log gets them hashed, because they can name profiles
    /// (Fable L1).
    func note(_ message: String) {
        log.error("problem: \(message, privacy: .private(mask: .hash))")
        problems.append(Problem(date: Date(), message: message))
        if problems.count > 50 { problems.removeFirst(problems.count - 50) }
    }

    // MARK: Load

    func load() async {
        await verifyAutoConnectChoice()
        retryOwedSeal()                               // round 4 (Fable N4)
        onLoad?()                                     // round 6 (Codex r6 #3): an owed pause value
        do throws(LPError) {
            let r = try await repository.list()
            var ok: [Profile] = []
            var bad = r.tampered
            let stored = Dictionary(managers.managers.map { ($0.profileID, $0) }, uniquingKeysWith: { a, _ in a })
            for p in r.profiles where p.ownerUID == ownerUID {
                if let m = stored[p.id], Self.isReplay(p, manager: m), !rollbackPending(p, m) {
                    await repository.quarantine(p.id)
                    bad.append(p.id)
                    note("Profile \(p.id.uuidString.prefix(8)): settings were changed outside LockPlus")
                } else {
                    ok.append(p)
                }
            }
            profiles = ok
            tampered = bad
            // M3: this user's managers whose profile no longer exists (a failed remove, a deleted profile) go.
            // Review R10: deferral is re-checked before EVERY mutation (a start can begin during an earlier save).
            let known = Set(ok.map(\.id)).union(bad)
            // Round 6 (Codex M1): every idle-path mutation re-checks its deferral inside the serialization too (a start
            // can begin while it waits for an earlier mutation); skipped: deferred like any other.
            for m in managers.managers where m.stored?.ownerUID == ownerUID && !known.contains(m.profileID) {
                if mutationBlocked(m.profileID) || isLive(m.profileID) { hasDeferredSync = true; continue }
                // Round 4 (Fable N5): an orphaned kill-switch configuration may be in NE's restart gap that this app
                // doesn't track (launched inside it, or its `.awaitingRestart` timed out): removing it now would end that
                // restart. It goes only after `orphanKillSwitchGrace` since this run first saw it orphaned (NE's crash
                // restart comes within seconds and then reads as live); its extension copy waits for it (`reconcile`).
                if !deletedByUser.contains(m.profileID), m.flags.map({ $0.includeAllNetworks || $0.enforceRoutes }) ?? true {
                    let first = orphanSeenAt[m.profileID] ?? now()
                    orphanSeenAt[m.profileID] = first
                    if now().timeIntervalSince(first) < Self.orphanKillSwitchGrace { hasDeferredSync = true; continue }
                }
                let id = m.profileID
                do throws(LPError) {
                    if try await !managers.remove(id, onlyIf: idleAllowed(id)) { hasDeferredSync = true }
                } catch { note("Orphaned VPN configuration not removed: \(error.code)") }
            }
            // E2E-4: unaddressable configurations (no profile ID, an older duplicate) of THIS user only, and only through
            // the same deferral as every other mutation: never while anything at all starts or runs, another user's
            // session included (U2/U13: a removal inside a pending kill-switch start breaks it). One whose owner can't
            // be read may be another user's (U3): never removed.
            for s in managers.strays where s.ownerUID == ownerUID {
                if mutationBlocked(s.key) || s.status.isLive { hasDeferredSync = true; continue }
                let key = s.key, managers = managers, blocked = mutationBlocked
                do throws(LPError) {
                    let removed = try await managers.removeStray(key, onlyIf: {
                        // Round 7 (Fable N4): a key a reload re-minted is gone: skipped (deferred), not "removed".
                        guard let st = managers.strays.first(where: { $0.key == key }) else { return false }
                        return !blocked(key) && !st.status.isLive
                    })
                    if !removed { hasDeferredSync = true }
                } catch { note("Stray VPN configuration not removed: \(error.code)") }
            }
            // A newer local write the manager never got (H1), or flags the system changed under our revision
            // (`flagsDrifted`): bring the manager up to date from the authenticated metadata. A drift is healed once
            // per profile revision per run, so a configuration the system keeps rewriting can't loop the reload.
            for p in ok where stored[p.id] != nil && managerIsBehind(p) {
                if isLive(p.id) {
                    // E2E-4 (U7 reversal): a drift that WEAKENS the running session (NE applies a flag save to a
                    // connected session at once, U7) is healed now when it is `.connected` and nothing else is busy
                    // (E9 + U7: an own connected manager's save is safe and takes effect at once); while `.connecting`
                    // it waits for `.connected` (`healProtectiveDrift`, from the status event). Anything else on a live
                    // session (a revision behind, a drift that only adds protection) waits for the session to end
                    // (L-KS-2, review N3): `runDeferredSync` at idle, or `prepareForStart` at its next start.
                    if await healProtectiveDrift(p.id) { continue }
                    hasDeferredSync = true
                    if let m = stored[p.id], Self.flagsDrifted(p, manager: m), notedLiveDrift[p.id] != p.metaRevision {
                        notedLiveDrift[p.id] = p.metaRevision
                        let weakens = Self.driftWeakens(p, manager: m)
                        if weakens, managers.status(p.id) != .connected {
                            log.fault("protocol flags of \(p.id.uuidString.prefix(8), privacy: .public) weakened while its session starts; healed at .connected")
                            note("The system changed the protection settings of \(p.name) while it was connecting. LockPlus restores them as soon as it is connected.")
                        } else if weakens {
                            // Connected, but another profile's start or restart is under way (`mutationBlocked`).
                            log.fault("protocol flags of the connected \(p.id.uuidString.prefix(8), privacy: .public) weakened while another start is under way; healed when it can be")
                            note("The system changed the protection settings of \(p.name) while it was connected. LockPlus restores them as soon as no other connection is starting.")
                        } else {
                            log.fault("protocol flags drifted for \(p.id.uuidString.prefix(8), privacy: .public) while its session runs; healed when it ends")
                            note("The system changed the protection settings of \(p.name) while it was connected. LockPlus restores them before it connects again.")
                        }
                    }
                    continue
                }
                if mutationBlocked(p.id) { hasDeferredSync = true; continue }
                if let m = stored[p.id], Self.flagsDrifted(p, manager: m) {
                    if healedDrift[p.id] == p.metaRevision {
                        note("The system changed the protection settings of \(p.name) and they couldn't be restored. Turn the kill switch off and on again.")
                        continue
                    }
                    healedDrift[p.id] = p.metaRevision
                    log.fault("protocol flags drifted for \(p.id.uuidString.prefix(8), privacy: .public) at the same revision; restoring from metadata")
                }
                if deleting.contains(p.id) { continue }           // a Delete is under way: nothing to sync (and no note)
                do throws(LPError) {
                    if try await !syncManager(p, onlyIf: idleAllowed(p.id)) {
                        hasDeferredSync = true
                        healedDrift[p.id] = nil                 // round 7 (Codex L5): not attempted, so not used up
                    }
                } catch { note("VPN configuration for \(p.id.uuidString.prefix(8)) not updated: \(error.code)") }
            }
            // Round 8 (Codex M3): a pending rollback is forgotten only on positive confirmation: the manager is seen
            // carrying the metadata revision again (saved), or the metadata moved on (a later commit). A manager missing
            // from one reload is no evidence; a deleted profile is forgotten by `delete`.
            let byID = Dictionary(ok.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let current = Dictionary(managers.managers.map { ($0.profileID, $0) }, uniquingKeysWith: { a, _ in a })
            for (id, r) in pendingRollbacks {
                if let p = byID[id], p.metaRevision != r.metaRevision { pendingRollbacks[id] = nil }
                else if let s = current[id]?.stored, s.metaRev == r.metaRevision { pendingRollbacks[id] = nil }
            }
            locked = nil
            loadError = nil
            loaded = true
        } catch {
            loaded = false
            if ProfileRepository.isLocked(error) {
                locked = await repository.lockedNames()
                profiles = []
            } else {
                let reason = "\(error.code)\(error.detail.map { " \($0)" } ?? "")"
                if loadError != reason { note("Profiles could not be read: \(reason)") }
                loadError = reason
            }
        }
        if readsCredentialFacts { await refreshCredentialFacts() }
    }

    /// The drifted manager protects less than the profile's plan (`ProtocolFlags.isWeaker`).
    static func driftWeakens(_ p: Profile, manager m: ManagerSnapshot) -> Bool {
        guard flagsDrifted(p, manager: m), let f = m.flags else { return false }
        return f.isWeaker(than: ProtocolFlags(policy: p.policy, isFullTunnel: p.summary.isFullTunnel))
    }

    /// E2E-4 (U7 reversal): restores the plan's flags on the running profile's OWN manager when the system weakened them
    /// (kill switch, local-network or other exclusions) and the session is `.connected`, nothing else is busy
    /// (`mutationBlocked`), at most once per metadata revision per run (a configuration the system keeps rewriting is
    /// reported, not looped). Never while `.connecting`: NE's pending start (E2E-3); `ConnectionStore` calls this again
    /// at `.connected`. Only the protective direction: the user's own weakening change needs a disconnected profile
    /// (L-KS-2, `updatePolicy`). True: healed (or the repeat was reported).
    @discardableResult
    func healProtectiveDrift(_ id: UUID) async -> Bool {
        guard let p = profile(id), !tampered.contains(id),
              let m = managers.managers.first(where: { $0.profileID == id }), Self.driftWeakens(p, manager: m),
              m.status == .connected, managers.status(id) == .connected, !mutationBlocked(id) else { return false }
        guard !deleting.contains(id) else { return false }
        guard !healingDrift.contains(id) else { return true }           // one in flight: not a repeat
        healingDrift.insert(id)
        defer { healingDrift.remove(id) }
        if healedLiveDrift[id] == p.metaRevision {
            if notedLiveDrift[id] != p.metaRevision {
                notedLiveDrift[id] = p.metaRevision
                note("The system changed the protection settings of \(p.name) again while it was connected. LockPlus tries once more when it disconnects.")
            }
            hasDeferredSync = true                                      // M1: the idle path gets its attempt
            return true
        }
        healedLiveDrift[id] = p.metaRevision
        log.fault("protocol flags of the connected \(id.uuidString.prefix(8), privacy: .public) weakened; restoring them on the live session (U7)")
        do throws(LPError) {
            // 2.0.1 round 4 (Codex 2): a flag save reaches a live session only while it is `.connected`, checked again
            // when the save is issued (after any wait for an earlier mutation): never while it reasserts, ends or starts,
            // where the extension's hold-vs-cancel decisions read the live flags (DESIGN §20 risk 27).
            let managers = managers, blocked = mutationBlocked
            let saved = try await managers.save(ManagerConfiguration(profile: p, onDemand: onDemandPlan(for: p)), onlyIf: {
                managers.status(id) == .connected && !blocked(id)
            })
            guard saved else {
                healedLiveDrift[id] = nil                               // not a repeat: tried again at the next `.connected`
                hasDeferredSync = true
                log.notice("protective flag heal of \(id.uuidString.prefix(8), privacy: .public) skipped: no longer connected")
                return true
            }
            note("The system weakened the protection settings of \(p.name) while it was connected. LockPlus restored them.")
        } catch {
            note("The system weakened the protection settings of \(p.name) while it was connected, and LockPlus couldn't restore them (\(error.code)). Disconnect and connect again.")
        }
        return true
    }

    /// The manager's session is live (anything but disconnected or invalid): its flags are never saved (L-KS-2, N3).
    private func isLive(_ id: UUID) -> Bool {
        managers.status(id).isLive
    }

    /// Review 4 #8: a manager save outside `load()`/`resaveOnDemand()` (an import, the editor, a policy or rename, the
    /// onboarding's first save) waits while `mutationBlocked` (another profile's start or session is under way: a save
    /// of another manager inside a pending kill-switch start is the E2E-3 failure mode), and never carries flags or a
    /// revision onto a live session (L-KS-2). The caller has saved the metadata; the manager is then "behind", which
    /// `runDeferredSync` (at idle) or `prepareForStart` (before its start) heals. False: deferred.
    @discardableResult
    func saveManagerUnlessBlocked(_ p: Profile) async throws(LPError) -> Bool {
        try refuseIfDeleting(p)
        if mutationBlocked(p.id) || (isLive(p.id) && managerIsBehind(p)) {
            hasDeferredSync = true
            log.notice("manager save of \(p.id.uuidString.prefix(8), privacy: .public) deferred: a start or session is under way")
            return false
        }
        // Round 7 (Codex M4, Fable L2): the same deferral re-checked inside the serialization, "behind" recomputed there.
        guard try await managers.save(ManagerConfiguration(profile: p, onDemand: onDemandPlan(for: p)), onlyIf: liveSafe(p)) else {
            hasDeferredSync = true
            log.notice("manager save of \(p.id.uuidString.prefix(8), privacy: .public) deferred: a start began meanwhile")
            return false
        }
        return true
    }

    /// Round 7 (Codex M2): a save of `p`'s configuration may land: nothing else is busy for it (`mutationBlocked`), and
    /// it carries no flags or revision onto a live session (L-KS-2). Evaluated on every invocation inside the
    /// serialization (stale retries included), "behind" against the manager as it is THEN.
    private func liveSafe(_ p: Profile) -> @MainActor () -> Bool {
        let blocked = mutationBlocked, safe = behindSafe(p)
        return { !blocked(p.id) && safe() }
    }

    /// Only the "no flags or revision onto a live session" half (L-KS-2), recomputed on every invocation.
    private func behindSafe(_ p: Profile) -> @MainActor () -> Bool {
        { [weak self] in
            guard let self else { return false }
            return !(self.isLive(p.id) && self.managerIsBehind(p))
        }
    }

    /// What was skipped while busy (`load`, `resaveOnDemand`), at idle. The flag is cleared first: whatever is still
    /// blocked sets it again.
    func runDeferredSync() async {
        hasDeferredSync = false
        await load()
        await resaveOnDemand()
    }

    /// §6.8 Re-import while locked: no key can open (or be created over) the locked files, so re-importing first needs
    /// an explicit, user-confirmed "start over". The locked files are MOVED ASIDE (kept, never deleted); their saved
    /// passwords stay too (they're keyed by profile ID and unreachable without the files). Returns the folder.
    @discardableResult
    func startOverMovingLockedAside() async throws(LPError) -> URL {
        guard locked != nil else { throw LPError(.profileInvalid, detail: "not locked") }
        let dest = try await repository.moveAllFilesAside()
        locked = nil
        await load()
        return dest
    }

    /// §6.8 "Remove locked profiles": the unreadable files and their saved passwords go; a fresh key follows.
    func removeLockedProfiles() async {
        guard locked != nil else { return }
        await repository.removeAllFiles()
        for id in (try? await credentialStore.ids()) ?? [] { try? await credentialStore.delete(id) }
        locked = nil
        await load()
    }

    /// §3.4 N6: metadata older than the NE manager's copy is a replay.
    ///
    /// An equal revision whose policy differs from the manager's protocol flags is NOT a replay (E2E-1, 2026-10-27):
    /// HMAC-valid metadata at the manager's own revision is the copy we wrote, and only the NE side can have moved.
    /// macOS does move it: right after the first VPN configuration is saved, nehelper re-derives it from the
    /// SCNetworkService ("SCPreferences signature … does not match saved signature ((null)) … Updating configuration
    /// … from the corresponding SCNetworkService") and drops includeAllNetworks. Treating that as tampering
    /// quarantined the user's first profile and left the weakened configuration in place. It is `flagsDrifted`
    /// instead, and `load()` re-saves the manager from the metadata (`managerIsBehind` → `syncManager`).
    /// Round 7, round 8 (Codex H1, Fable M1): rollbacks of `updateMetadata` that were skipped (a start began meanwhile):
    /// profile → the metadata revision the manager goes back to, and the revision the skipped rollback left the manager
    /// at. IN MEMORY ONLY: nothing same-user code can write may exempt a profile from replay detection (a durable record
    /// was the round 8 finding). After a relaunch in that state the profile is quarantined (fail closed).
    @ObservationIgnored private var pendingRollbacks: [UUID: PendingRollback] = [:]

    struct PendingRollback: Equatable {
        /// The committed metadata revision (the rollback's target).
        var metaRevision: UInt64
        /// 2.0.2 (Fable final spot check, LOW): the manager's revision when its rollback was skipped. Old+1 after one
        /// failed edit, old+2 after a second one (round 9 skips the burned revision); the marker no longer assumes +1.
        var managerRevision: UInt64
    }

    /// The manager is exactly the state a skipped rollback of `p` left behind: the revision the failed edit saved, the
    /// same payload revision. Not a replay, and behind (re-saved from the metadata).
    func rollbackPending(_ p: Profile, _ m: ManagerSnapshot) -> Bool {
        guard let r = pendingRollbacks[p.id], r.metaRevision == p.metaRevision, let s = m.stored else { return false }
        return s.metaRev == r.managerRevision && s.revision == p.payloadRevision
    }

    static func isReplay(_ p: Profile, manager m: ManagerSnapshot) -> Bool {
        guard let s = m.stored else { return false }
        return p.metaRevision < s.metaRev || p.payloadRevision < s.revision
    }

    /// The manager has our revision but different protocol flags: the system (or an administrator) changed it.
    static func flagsDrifted(_ p: Profile, manager m: ManagerSnapshot) -> Bool {
        guard let s = m.stored, p.metaRevision == s.metaRev, p.payloadRevision == s.revision, let f = m.flags else { return false }
        return f != ProtocolFlags(policy: p.policy, isFullTunnel: p.summary.isFullTunnel)
    }

    /// Fable L3: the facts the UI needs (user name, "saved" flags) are kept in a non-secret file, so a load doesn't
    /// read every secret out of the keychain. Secrets are read only for show/change/provision. A missing or damaged
    /// file is rebuilt once from the keychain.
    private func refreshCredentialFacts() async {
        let ids = Set(profiles.filter { $0.kind == .openVPN }.map(\.id))
        if let factsFile, let data = AtomicFile.read(factsFile, maxBytes: 1 << 20),
           let stored = try? JSONDecoder().decode([UUID: CredentialFacts].self, from: data) {
            credentials = stored.filter { ids.contains($0.key) }
            return
        }
        var facts: [UUID: CredentialFacts] = [:]
        for id in ids {
            if let r = try? await credentialStore.load(id) { facts[id] = Self.facts(r) }
        }
        credentials = facts
        saveFacts()
    }

    static func facts(_ r: CredentialRecord?) -> CredentialFacts {
        CredentialFacts(username: r?.username.map { String(decoding: $0, as: UTF8.self) },
                        passwordSaved: r?.password?.isEmpty == false, passphraseSaved: r?.keyPassphrase?.isEmpty == false)
    }

    private func setFacts(_ id: UUID, _ r: CredentialRecord?) {
        credentials[id] = r.map(Self.facts)
        saveFacts()
    }

    private func saveFacts() {
        guard let factsFile, let d = try? JSONEncoder().encode(credentials) else { return }
        try? AtomicFile.write(d, to: factsFile)
    }

    // MARK: Create / update / delete

    @discardableResult
    func create(_ d: ProfileDraft) async throws(LPError) -> Profile {
        let name = ProfileNameRules.unique(d.name, existing: profiles.map(\.name))
        let digest = d.payload.withUnsafeBytes { PayloadDigest.sha256Hex(bytes: $0) }
        let now = Date()
        let p = Profile(id: UUID(), name: name, kind: d.kind, policy: d.policy, auth: d.auth,
                        notes: String(d.notes.utf8.prefix(Profile.maxNotesBytes)) ?? "", summary: d.summary,
                        payloadRevision: 1, payloadDigest: digest, metaRevision: 1, ownerUID: ownerUID,
                        createdAt: now, updatedAt: now, origin: d.origin, importReport: d.report,
                        engineVerified: d.engineVerified || d.kind == .wireGuard)
        try await repository.savePayload(d.payload, for: p)
        try await repository.saveMetadata(p)
        if let c = d.credentials, c.username != nil || c.password != nil || c.keyPassphrase != nil || c.proxyPassword != nil {
            do throws(KeychainError) {
                try await credentialStore.save(p.id, c)
                setFacts(p.id, c)
            } catch { note("Credentials for \(name) weren't saved: \(error)") }
        }
        profiles.append(p)
        // The first save triggers the system's "add VPN configurations" prompt (§11.1 onboarding step 3). A failed
        // save doesn't fail the import (the profile exists; a retry would duplicate it, review M1): the manager is
        // created at the first connect (syncManager), which surfaces a denial there. Review 4 #8: while another start or
        // session is under way it is created at idle (`resaveOnDemand` in `runDeferredSync`) or at that first connect.
        do throws(LPError) { try await saveManagerUnlessBlocked(p) } catch {
            note("The VPN configuration for \(p.id.uuidString.prefix(8)) wasn't saved yet (\(error.code)); it will be at the first connect.")
        }
        if p.engineVerified { await provisionQuietly(p) }
        return p
    }

    /// The editor's Save (§11.4, §8.1): the re-imported text replaces the payload. New payload revision and digest,
    /// summary/auth/report from the new import, a validated name; then the manager and the extension's copy.
    @discardableResult
    func replacePayload(_ id: UUID, with d: ProfileDraft) async throws(LPError) -> Profile {
        guard var p = profile(id), p.kind == d.kind else { throw LPError(.profileInvalid, detail: "unknown profile or kind change") }
        if d.name != p.name {
            switch ProfileNameRules.validate(d.name, existing: profiles.filter { $0.id != id }.map(\.name)) {
            case .success(let n): p.name = n
            case .failure(let e): throw LPError(.profileInvalid, detail: "name \(e)")
            }
        }
        p.payloadRevision += 1
        p.payloadDigest = d.payload.withUnsafeBytes { PayloadDigest.sha256Hex(bytes: $0) }
        p.summary = d.summary
        p.auth = d.auth
        p.importReport = d.report
        p.engineVerified = d.engineVerified || d.kind == .wireGuard
        p.metaRevision += 1
        p.updatedAt = Date()
        // M4: the new revision gets its own sealed file; the old one stays valid until the metadata commit.
        try await repository.savePayload(d.payload, for: p)
        try await repository.saveMetadata(p)
        pendingRollbacks[p.id] = nil                       // round 8: a later commit supersedes a pending rollback
        await repository.pruneSealed(p.id, keep: p.payloadRevision)
        replace(p)
        try await saveManagerUnlessBlocked(p)              // review 4 #8: deferred while busy (healed as "behind")
        if p.engineVerified { await provisionQuietly(p) }
        return p
    }

    func onDemandPlan(for p: Profile) -> OnDemandPlan? {
        guard !deleting.contains(p.id) else { return nil }
        var s = settings.value.autoConnect
        // Round 2 (Fable M1b): an enabled choice read from disk gives a plan only once its tag verified.
        if s.enabled, autoConnectTrust != .trusted { s.enabled = false }
        let paused = s.pausedUntil.map { $0 > Date() } ?? false
        let suspended = settings.value.onDemandSuspended.contains(p.id)
        let handOver = settings.value.extensionHandOver        // review N2: an extension update/reinstall is under way
        return OnDemandPlan.plan(for: p, rules: s, paused: paused || suspended || handOver || onDemandHeldBack(p.id),
                                 hasSavedPassword: credentials[p.id]?.passwordSaved ?? false)
    }

    /// Metadata changes (rename, notes, policy): bump metaRevision; the NE manager (which carries the kill-switch
    /// flags) is saved FIRST, then the metadata. If the metadata write fails the manager is rolled back, so the two
    /// never disagree (review H1). Notes don't touch the manager at all (L11).
    func updateMetadata(_ id: UUID, _ change: (inout Profile) -> Void) async throws(LPError) {
        guard let old = profile(id) else { throw LPError(.profileNotProvisioned, detail: "unknown profile") }
        var p = old
        change(&p)
        // Round 9 (Fable N1): while a rollback is pending the manager holds the failed change at old+1: skip that
        // revision, so a deferred manager save leaves it plainly behind (never equal revisions with other content).
        if pendingRollbacks[id] != nil { p.metaRevision += 1 }
        p.metaRevision += 1
        p.updatedAt = Date()
        // A rename on a live tunnel waits for the next start (syncManager), so a running session's configuration
        // isn't re-saved (L11).
        let idle = [.disconnected, .invalid].contains(managers.status(id))
        // Round 8 (Fable N4): while a rollback is pending the manager carries another revision-`p` content: saved too.
        // Round 1 (Fable L1): an unverified profile has no on-demand rules; becoming verified gives it its plan.
        let managerRelevant = p.policy != old.policy || (p.name != old.name && idle) || pendingRollbacks[id] != nil
            || p.engineVerified != old.engineVerified
        // Review 4 #8: while another start or session is under way the manager waits (behind until idle or its start).
        let saved = managerRelevant ? try await saveManagerUnlessBlocked(p) : false
        do throws(LPError) {
            try await repository.saveMetadata(p)
        } catch {
            if saved, !deleting.contains(old.id) {
                // Round 7 (Fable L2): conditional too; skipped, the idle sync brings the manager back to the metadata.
                let rolledBack = (try? await managers.save(ManagerConfiguration(profile: old, onDemand: onDemandPlan(for: old)), onlyIf: liveSafe(old))) ?? false
                if !rolledBack {
                    // Round 7/8: remembered in memory, so the next `load()` doesn't read the manager (ahead at the
                    // failed edit's revision, 2.0.2) as a replay; it re-saves it from the metadata at idle.
                    pendingRollbacks[old.id] = PendingRollback(metaRevision: old.metaRevision, managerRevision: p.metaRevision)
                    hasDeferredSync = true
                }
            }
            throw error
        }
        pendingRollbacks[id] = nil                               // round 8: a later commit supersedes it
        replace(p)
    }

    /// The manager doesn't carry this profile's current policy/revision (an interrupted write, a lost save): it must
    /// be re-saved before a start (review H1). A replay (older metadata) is handled by `load` instead.
    func managerIsBehind(_ p: Profile) -> Bool {
        guard let m = managers.managers.first(where: { $0.profileID == p.id }) else { return true }
        guard let s = m.stored else { return true }
        if rollbackPending(p, m) { return true }                 // round 7: the skipped rollback, still to be saved
        if s.metaRev < p.metaRevision || s.revision < p.payloadRevision { return true }
        return m.flags.map { $0 != ProtocolFlags(policy: p.policy, isFullTunnel: p.summary.isFullTunnel) } ?? true
    }

    /// Review 5c3a899/f18c0d6 M-1: a profile being deleted, or already gone, never gets a configuration back.
    private func refuseIfDeleted(_ p: Profile) throws(LPError) {
        try refuseIfDeleting(p)
        if profile(p.id) == nil { throw LPError(.profileNotProvisioned, detail: "profile deleted or unavailable") }
    }

    /// Only the in-flight Delete (a profile being created isn't in the list yet): every `managers.save` site checks it.
    private func refuseIfDeleting(_ p: Profile) throws(LPError) {
        if deleting.contains(p.id) { throw LPError(.profileNotProvisioned, detail: "profile deleted or unavailable") }
    }

    /// Re-saves a manager that is behind its profile (`load`; `prepareForStart` has its own). Round 6 (Codex M1): only
    /// if `condition` holds inside the serialization. False: skipped.
    private func syncManager(_ p: Profile, onlyIf condition: @MainActor () -> Bool) async throws(LPError) -> Bool {
        try refuseIfDeleted(p)
        guard managerIsBehind(p) else { return true }
        return try await managers.save(ManagerConfiguration(profile: p, onDemand: onDemandPlan(for: p)), onlyIf: condition)
    }

    /// Round 6 (Codex M1): the idle path's deferral, re-checked inside the serialization: nothing else starts or runs
    /// (`mutationBlocked`) and `id`'s own session isn't live (its flags and revision wait for its end, L-KS-2).
    private func idleAllowed(_ id: UUID) -> @MainActor () -> Bool {
        let managers = managers, blocked = mutationBlocked
        return { !blocked(id) && !managers.status(id).isLive }
    }

    /// The NE manager's protocol flags differ from the metadata right now (a drift being repaired, or a save that
    /// hasn't landed). The UI never claims the kill switch for such a profile (E2E-1). No manager: false (that is
    /// "not installed", a separate state).
    func protectionMismatch(_ id: UUID) -> Bool {
        guard let p = profile(id), let m = managers.managers.first(where: { $0.profileID == id }), let f = m.flags else { return false }
        return f != ProtocolFlags(policy: p.policy, isFullTunnel: p.summary.isFullTunnel)
    }

    /// Before every start (E2E-1, fail closed): bring the manager up to date, then, for a kill-switch profile, read
    /// the configuration back from NE preferences and verify the flags. macOS can rewrite a just-saved configuration
    /// asynchronously (nehelper re-derives the first one from its SCNetworkService ~50 ms later and drops
    /// includeAllNetworks), so a save is followed by a short settle before the verifying reload. One repair attempt;
    /// if the flags still disagree the start is refused: LockPlus never connects with a weaker configuration.
    /// 2.0.2 (Codex r9 MEDIUM): `admissible` is the caller's own condition, re-checked inside the serialization with
    /// `otherStartPending` before each save (the GUI's: its attempt is still current and an automatic retry finds nothing
    /// else busy). Refused: `.anotherTunnelActive`, nothing saved.
    func prepareForStart(_ p: Profile, admissible: @escaping @MainActor () -> Bool = { true }) async throws(LPError) {
        let wasBehind = managerIsBehind(p)
        // Round 7 (Fable L3): never inside another configuration's pending start (it would be refused beside it anyway).
        let otherPending = otherStartPending
        try refuseIfDeleted(p)
        if managerIsBehind(p) {
            guard try await managers.save(ManagerConfiguration(profile: p, onDemand: onDemandPlan(for: p)), onlyIf: { !otherPending(p.id) && admissible() }) else {
                throw LPError(.anotherTunnelActive, detail: "another configuration is starting")
            }
        }
        guard p.policy.killSwitch else { return }
        if wasBehind { try? await Task.sleep(for: settleAfterSave) }
        try await managers.loadAll()
        try refuseIfDeleted(p)                 // M-1: the Delete's removal may have landed inside the settle
        if managerIsBehind(p) {
            log.fault("protocol flags of \(p.id.uuidString.prefix(8), privacy: .public) differ from the metadata before start; re-saving")
            guard try await managers.save(ManagerConfiguration(profile: p, onDemand: onDemandPlan(for: p)), onlyIf: { !otherPending(p.id) && admissible() }) else {
                throw LPError(.anotherTunnelActive, detail: "another configuration is starting")
            }
            try? await Task.sleep(for: settleAfterSave)
            try await managers.loadAll()
        }
        try refuseIfDeleted(p)
        guard !managerIsBehind(p) else {
            log.fault("kill switch not applied for \(p.id.uuidString.prefix(8), privacy: .public); start refused")
            note("Couldn't apply the kill switch for \(p.name). LockPlus won't connect unprotected.")
            throw LPError(.killSwitchNotApplied, detail: "protocol flags differ from the profile after a repair")
        }
    }

    /// L-KS-2: policy changes only while disconnected (the UI disables the toggles; this is the backstop).
    func updatePolicy(_ id: UUID, _ change: (inout NetworkPolicy) -> Void) async throws(LPError) {
        let st = managers.status(id)
        guard st == .disconnected || st == .invalid else {
            throw LPError(.malformedRequest, detail: "mustBeDisconnected")
        }
        try await updateMetadata(id) { change(&$0.policy) }
    }

    func rename(_ id: UUID, to raw: String) async throws(LPError) {
        let others = profiles.filter { $0.id != id }.map(\.name)
        switch ProfileNameRules.validate(raw, existing: others) {
        case .success(let n): try await updateMetadata(id) { $0.name = n }
        case .failure(let e): throw LPError(.profileInvalid, detail: "name \(e)")
        }
    }

    /// Saves one manager with its current on-demand plan (restoring a suspension, re-enabling the auto profile).
    /// A manager that already carries the planned state (and isn't behind its profile) is left alone: the rules can't
    /// have changed since the last save of them (`resaveOnDemand` covers rule edits), and a save is a configuration
    /// change nesessionmanager has to digest (review simplification 3).
    ///
    /// Round 6 (Codex M1): `onlyIf` (the restore's "nothing is busy") is checked inside the serialization, after any
    /// wait for an earlier mutation. False: not saved (the caller keeps what it would have cleared, and tries again).
    @discardableResult
    func saveOnDemand(_ p: Profile, onlyIf condition: @MainActor () -> Bool = { true }) async throws(LPError) -> Bool {
        try refuseIfDeleting(p)
        let want = onDemandPlan(for: p)
        if let have = managers.managers.first(where: { $0.profileID == p.id }), have.onDemandEnabled == (want?.enabled ?? false),
           !managerIsBehind(p) { return true }
        let safe = behindSafe(p)              // the caller's `condition` is its busy predicate (a start's own restore, too)
        return try await managers.save(ManagerConfiguration(profile: p, onDemand: want), onlyIf: { [weak self] in
            condition() && safe() && self?.profile(p.id)?.metaRevision == p.metaRevision      // round 7 (Codex M2)
        })
    }

    /// Re-saves the managers whose on-demand plan depends on the auto-connect rules or the pause.
    /// Review R3: a save of another manager while a kill-switch start is pending is the PF 50 failure mode, so a rule
    /// edit during the start window waits for idle (`runDeferredSync`, which recomputes the plans).
    func resaveOnDemand() async {
        for p in profiles where !tampered.contains(p.id) && !deleting.contains(p.id) {
            let want = onDemandPlan(for: p)
            let have = managers.managers.first { $0.profileID == p.id }
            // Nothing to change: no plan, and the configuration carries neither enabled rules nor the consent flag.
            if want == nil, have?.onDemandEnabled == false, have?.stored?.onDemand != true { continue }
            // Review N3: a connected manager may get its on-demand and rules (`mutationBlocked`), never its flags.
            if mutationBlocked(p.id) || (isLive(p.id) && managerIsBehind(p)) { hasDeferredSync = true; continue }
            // Round 6 (Codex M1): the same deferral, re-checked inside the serialization.
            // Round 7 (Codex M2): "behind" recomputed inside, and the metadata this save carries must still be current.
            let safe = liveSafe(p)
            do throws(LPError) {
                let saved = try await managers.save(ManagerConfiguration(profile: p, onDemand: want), onlyIf: { [weak self] in
                    safe() && self?.profile(p.id)?.metaRevision == p.metaRevision
                })
                if !saved { hasDeferredSync = true }
            } catch {
                note("Auto-connect settings for \(p.name) weren't saved: \(error.code)")
            }
        }
        await revokeUnattended()
    }

    /// Round 1 (Codex 4): profiles without a plan have no unattended-start consent; the extension drops their recorded
    /// unattended admissions. After every on-demand re-save, every reconcile, and the end of a session (round 2, L2:
    /// `ConnectionStore` at a settled idle). Round 2 (L1, L3): the request names the profiles whose consent STANDS: those
    /// with a plan, plus `revocationHeld` (starting, running, or awaiting NE's restart: their record is still needed); the
    /// extension revokes every other unattended record of this user. An extension without start authorisation has none.
    /// A busy answer (a fresh extension process, L1) is retried once after `revokeRetryDelay`; other failures at the next
    /// trigger.
    ///
    /// Round 3 (Codex r3 #8): a keep set above one request's cap goes as the pages of one batch, which the extension applies
    /// only once complete.
    func revokeUnattended() async {
        guard extensionCapabilities?.contains(.startAuthorisation) == true else { return }
        // One at a time (the pages of two batches must not interleave: the extension keeps only the newest batch); a
        // call meanwhile runs once more after it, with what is current then.
        guard !revoking else { revokeAgain = true; return }
        revoking = true
        defer { revoking = false }
        repeat {
            revokeAgain = false
            await revokeOnce()
        } while revokeAgain
    }
    @ObservationIgnored private var revoking = false
    @ObservationIgnored private var revokeAgain = false

    private func revokeOnce() async {
        var keep = Set(profiles.filter { onDemandPlan(for: $0) != nil }.map(\.id))
        keep.formUnion(revocationHeld())
        for p in profiles where managers.status(p.id).isLive { keep.insert(p.id) }
        guard let pages = RevokeUnattendedRequest.pages(keeping: keep) else {
            log.error("revokeUnattended not sent: \(keep.count, privacy: .public) profiles keep consent (cap \(RevokeUnattendedRequest.maxProfiles * RevokeUnattendedRequest.maxPages, privacy: .public))")
            return
        }
        do throws(LPError) {
            for page in pages { try await service.callVoid(.revokeUnattended, page) }
        } catch {
            log.notice("revokeUnattended failed: \(error.code.rawValue, privacy: .public)")
            if error.code == .extensionBusy { scheduleRevokeRetry() }
        }
    }

    private func scheduleRevokeRetry() {
        guard revokeRetry == nil else { return }
        let sleep = revokeRetrySleep, delay = revokeRetryDelay
        revokeRetry = Task { @MainActor [weak self] in
            await sleep(delay)
            self?.revokeRetry = nil
            await self?.revokeUnattended()
        }
    }

    /// Round 4 (Fable N5): when this run first saw each orphaned kill-switch configuration, and how long it is kept.
    @ObservationIgnored private var orphanSeenAt: [UUID: Date] = [:]
    /// The user's Deletes of this run (their configurations' removal, if deferred, needs no grace: the user stopped them).
    @ObservationIgnored private var deletedByUser: Set<UUID> = []
    static let orphanKillSwitchGrace: TimeInterval = 120
    /// The clock of a user stop and of the orphan grace (tests).
    @ObservationIgnored var now: @MainActor () -> Date = { Date() }

    /// Round 2 (L1): profiles whose unattended record must stay although they have no plan (`ConnectionStore`: a
    /// pending entry of any kind, a network-restart hold). Live sessions are added here.
    @ObservationIgnored var revocationHeld: @MainActor () -> Set<UUID> = { [] }
    @ObservationIgnored private var revokeRetry: Task<Void, Never>?
    @ObservationIgnored var revokeRetryDelay: Duration = .seconds(25)
    @ObservationIgnored var revokeRetrySleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }

    /// §6.6 deletion: disconnect, remove the manager, extension removeProfile (queued on failure), DP keychain,
    /// sealed file and metadata. Every step runs even if an earlier one failed.
    func delete(_ id: UUID) async {
        // Review 5c3a899/f18c0d6 M-1: from here on nothing re-creates this profile's configuration (a start's prepare
        // still in flight), and the auto profile is no longer this one: on-demand can't come back on through a plan.
        deleting.insert(id)
        deletedByUser.insert(id)
        defer { deleting.remove(id) }
        settings.update { if $0.autoConnect.profileID == id { $0.autoConnect.profileID = nil; $0.autoConnect.enabled = false } }
        // M3: on-demand off first, or the system restarts it between stop and remove.
        var stillOnDemand = false
        func turnOnDemandOff() async {
            if managers.managers.first(where: { $0.profileID == id })?.onDemandEnabled == true {
                do throws(LPError) { try await managers.setOnDemandEnabled(false, for: id); stillOnDemand = false } catch {
                    stillOnDemand = true
                    note("Auto-connect of \(profile(id)?.name ?? String(id.uuidString.prefix(8))) couldn't be turned off before it was deleted (\(error.code)); its VPN configuration is removed now.")
                }
            }
        }
        await turnOnDemandOff()
        // Review e321e10 (HIGH): a user stop through the connection store, awaited (bounded) before the removal: a
        // removal inside the teardown loses NE's `.disconnected`, and a stop NE didn't attribute to the user was a
        // "stopped unexpectedly" with an error fetch and a crash wait.
        if let stopSessionBeforeRemoval { await stopSessionBeforeRemoval(id) } else if managers.status(id).isLive { managers.stop(id) }
        // Review b061b46-d4feb3a LOW-1: the start awaited above may have landed a save that created the manager (with
        // on-demand ON, from a plan read before this Delete began) after the first check: once more, then the stop.
        if managers.managers.contains(where: { $0.profileID == id && $0.onDemandEnabled }) {
            await turnOnDemandOff()
            if let stopSessionBeforeRemoval { await stopSessionBeforeRemoval(id) } else if managers.status(id).isLive { managers.stop(id) }
        }
        if onDemandHeldBack(id) && !stillOnDemand {
            // Review 4 #8: another profile is starting or running; a removal is a configuration change inside its
            // pending kill-switch start (E2E-3, 200003). The orphan sweep in `load()` removes it at idle.
            // Review 5 #4: not when its on-demand is still on (the disable failed): an enabled on-demand configuration
            // beside the session is the E2E-3 trigger itself, and as an orphan it would linger until idle.
            hasDeferredSync = true
        } else {
            do throws(LPError) {
                // Round 7 (Codex M4, Fable L2): the same deferral inside the serialization; skipped: the orphan sweep.
                let heldBack = onDemandHeldBack, still = stillOnDemand
                if try await !managers.remove(id, onlyIf: { !heldBack(id) || still }) { hasDeferredSync = true }
            } catch {
                // The orphan sweep in load() removes it later (its profile no longer exists).
                note("VPN configuration not removed yet: \(error.code)")
            }
        }
        do throws(LPError) { try await service.callVoid(.removeProfile, ProfileRequest(profileID: id)) } catch {
            settings.update { if !$0.pendingRemovals.contains(id) { $0.pendingRemovals.append(id) } }
        }
        do throws(KeychainError) { try await credentialStore.delete(id) } catch { note("Saved password not removed: \(error)") }
        await repository.delete(id)
        profiles.removeAll { $0.id == id }
        tampered.removeAll { $0 == id }
        pendingRollbacks[id] = nil
        setFacts(id, nil)
        settings.update {
            $0.profileOrder.removeAll { $0 == id }
            if $0.autoConnect.profileID == id { $0.autoConnect.profileID = nil; $0.autoConnect.enabled = false }
            if $0.lastUsedProfileID == id { $0.lastUsedProfileID = nil }
            $0.verifyTimeoutRuns[id.uuidString] = nil
        }
    }

    private func replace(_ p: Profile) {
        if let i = profiles.firstIndex(where: { $0.id == p.id }) { profiles[i] = p }
    }

    func payload(_ id: UUID) async throws(LPError) -> SecretBytes {
        guard let p = profile(id) else { throw LPError(.profileNotProvisioned, detail: "unknown profile") }
        return try await repository.payload(for: p)
    }

    // MARK: Credentials (§6.6)

    func saveCredentials(_ id: UUID, _ rec: CredentialRecord) async throws(LPError) {
        do throws(KeychainError) { try await credentialStore.save(id, rec) } catch { throw error.lpError }
        setFacts(id, rec)
        do throws(LPError) { try await service.callVoid(.updateCredentials, UpdateCredentialsRequest(profileID: id, credentials: rec)) } catch {
            note("The tunnel component didn't get the new password yet (\(error.code)); it will at the next sync.")
        }
    }

    /// "Forget password" deletes both copies (the username stays). A failed read aborts (review L10): saving an
    /// empty record would also lose the passphrase and the proxy credentials.
    func forgetPassword(_ id: UUID) async {
        do throws(LPError) {
            var rec = try await loadCredentials(id) ?? CredentialRecord()
            rec.password = nil
            rec.keyPassphrase = nil
            try await saveCredentials(id, rec)
        } catch { note("Password not forgotten: \(error.code)") }
    }

    /// nil only when nothing is saved; a keychain failure throws (L10).
    func loadCredentials(_ id: UUID) async throws(LPError) -> CredentialRecord? {
        do throws(KeychainError) { return try await credentialStore.load(id) } catch { throw error.lpError }
    }

    func credentialRecord(_ id: UUID) async -> CredentialRecord? { try? await credentialStore.load(id) }

    // MARK: Provisioning and reconcile (§6.4)

    /// Round 1 (Fable L1): the one gate for every caller (import, update, reconcile, the 221 retry): a profile the
    /// sandboxed check hasn't passed is never sent to root, where its start would run openvpn3's parser on it.
    func provision(_ p: Profile) async throws(LPError) {
        guard p.engineVerified else { throw LPError(.profileInvalid, detail: "not yet verified by LockPlus's file check") }
        let payload = try await repository.payload(for: p)
        let rec = try? await credentialStore.load(p.id)
        let req = ProvisionRequest(profileID: p.id, kind: p.kind, revision: p.payloadRevision,
                                   payload: payload.withUnsafeBytes { Data($0) }, credentials: rec)
        // Round 7 (Fable N6): a failed provision may have stored the payload and not the credentials (the extension
        // commits them one after the other); `reconcile` retries it even though revision and digest then match.
        do throws(LPError) { try await service.callVoid(.provisionProfile, req) } catch {
            provisionIncomplete.insert(p.id)
            throw error
        }
        provisionIncomplete.remove(p.id)
    }

    /// The sandboxed validator service's client (PLAN-2.0.2 §1.4), set by `AppEnvironment`; nil (headless, tests that
    /// don't care) skips `verifyPending`.
    var validator: (any OpenVPN3ProfileValidating)?
    @ObservationIgnored private var verifying = false

    /// The capabilities of the extension's last successful hello (`AppEnvironment.helloAndReconcile`); nil before one.
    @ObservationIgnored var extensionCapabilities: Set<Capability>?

    /// Profiles whose last provision failed (round 7, Fable N6), retried by the next `reconcile`.
    @ObservationIgnored private(set) var provisionIncomplete: Set<UUID> = []

    private func provisionQuietly(_ p: Profile) async {
        do throws(LPError) { try await provision(p) } catch {
            log.notice("provision deferred to reconcile: \(error.code.rawValue, privacy: .public)")
        }
    }

    /// After every successful hello: re-provision what differs or is missing, remove what has no local profile,
    /// retry queued removals, and re-run [7] for profiles saved as "Not yet verified".
    func reconcile() async {
        guard !reconciling, loaded else { return }
        reconciling = true
        defer { reconciling = false }
        await migrateNonFixedPointPayloads()
        let remote: [ProvisionedEntry]
        do throws(LPError) {
            remote = try await service.call(.listProvisioned, EmptyRequest(), as: ListProvisionedReply.self).entries
        } catch {
            note("Sync with the tunnel component failed: \(error.code)")
            return
        }
        // Round 2 (Codex r2 #1): only verified profiles are provisioned, but every profile that still exists locally
        // (unverified after a Save Only, or quarantined) keeps its extension copy: removing it would delete the approved
        // payload, the credentials and a connected kill-switch session's start authorisation (NE's restart → 225). Only
        // the user's Delete (`pendingRemovals`, or no local profile at all) removes one.
        let plan = Self.reconcilePlan(local: profiles.filter { !tampered.contains($0.id) && $0.engineVerified },
                                      existing: Set(profiles.map(\.id)).union(tampered),
                                      remote: remote, pendingRemovals: settings.value.pendingRemovals)
        let retry = provisionIncomplete.filter { id in !plan.provision.contains(id) && profile(id) != nil }
        for id in plan.provision + retry.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let p = profile(id) else { continue }
            do throws(LPError) { try await provision(p) } catch { note("\(p.name) couldn't be installed in the tunnel component: \(error.code)") }
        }
        var stillPending: [UUID] = []
        for id in plan.remove {
            // Round 3 (Fable L3): never the extension copy of a profile whose session is live, starting, or awaiting NE's
            // restart (its payload, credentials and start authorisation are what that session and its restart need): queued
            // until idle. Only `delete()` removes such a copy, after stopping the session.
            // Round 4 (Fable N5): nor while an NE configuration of it still exists: NE may restart its session in a gap
            // this app doesn't track (launched inside it, or its `.awaitingRestart` timed out). The user's Delete removes
            // the configuration first, so only an orphaned copy (its file vanished) waits here, until its configuration goes.
            if isLive(id) || revocationHeld().contains(id) || managers.managers.contains(where: { $0.profileID == id }) {
                stillPending.append(id); continue
            }
            do throws(LPError) { try await service.callVoid(.removeProfile, ProfileRequest(profileID: id)) } catch { stillPending.append(id) }
        }
        settings.update { $0.pendingRemovals = stillPending }
        await revokeUnattended()
        // Round 2 (Fable L8): last, after everything already verified is installed: a file that keeps the check busy
        // delays nothing else. What it verifies now is provisioned by `verifyPending` itself.
        await verifyPending(provisionVerified: true)
    }

    struct ReconcilePlan: Equatable {
        var provision: [UUID]
        var remove: [UUID]
    }

    /// Pure: what reconcile does (§6.4 steps 2–4). `local`: the profiles eligible to be provisioned; `existing`: every
    /// profile that still exists locally (round 2, Codex r2 #1: never removed from the extension). nil: `local`'s.
    static func reconcilePlan(local: [Profile], existing: Set<UUID>? = nil, remote: [ProvisionedEntry], pendingRemovals: [UUID]) -> ReconcilePlan {
        let r = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let provision = local.filter { p in
            guard let e = r[p.id] else { return true }
            return e.revision != p.payloadRevision || e.digest != p.payloadDigest
        }.map(\.id)
        let localIDs = existing ?? Set(local.map(\.id))
        var remove = remote.map(\.id).filter { !localIDs.contains($0) }
        for id in pendingRemovals where !remove.contains(id) && !localIDs.contains(id) { remove.append(id) }
        return ReconcilePlan(provision: provision.sorted { $0.uuidString < $1.uuidString },
                             remove: remove.sorted { $0.uuidString < $1.uuidString })
    }

    /// Round 1 (Codex 8): a stored OpenVPN payload that is not a fixed point of today's normaliser (2.0.1 dropped
    /// `link-mtu` without appending the mssfix floor) would be refused by the 2.0.2 extension's provision check. It is
    /// normalised once more (the same [1]–[5]; the new text must be a fixed point) and saved as a new revision that is
    /// "not yet verified", so `verifyPending` (next) runs [7] on exactly those bytes before anything is provisioned.
    /// Never for a live profile (its session keeps the stored revision; the next reconcile after it ends).
    func migrateNonFixedPointPayloads() async {
        for p in profiles where p.kind == .openVPN && !tampered.contains(p.id) && !deleting.contains(p.id) && !isLive(p.id)
                                && migrationChecked[p.id] != p.payloadRevision {
            // Round 2 (Fable N2): each stored revision is unsealed and checked once per run (not at every reconcile).
            migrationChecked[p.id] = p.payloadRevision
            guard let payload = try? await repository.payload(for: p) else { continue }
            let bytes = payload.withUnsafeBytes { Array($0) }
            guard !OVPNImporter.isCanonicalFixedPoint(bytes) else { continue }
            let r = OVPNImporter.importProfile(bytes)
            guard r.verdict != .rejected, let text = r.canonicalText, OVPNImporter.isCanonicalFixedPoint(Array(text.utf8)),
                  let cur = profile(p.id), cur.payloadRevision == p.payloadRevision else {
                log.error("stored payload of \(p.id.uuidString.prefix(8), privacy: .public) is not canonical and can't be migrated")
                continue
            }
            var report = p.importReport ?? ImportReport()
            for i in r.report.items(in: .note) where !report.items.contains(i) { report.items.append(i) }
            let draft = ProfileDraft(name: p.name, kind: .openVPN, payload: SecretBytes(copying: Array(text.utf8)), summary: r.summary,
                                     auth: p.auth ?? r.auth, report: report, policy: p.policy, credentials: nil,
                                     engineVerified: false, origin: p.origin, notes: p.notes)
            do throws(LPError) {
                _ = try await replacePayload(p.id, with: draft)
                log.notice("migrated the stored payload of \(p.id.uuidString.prefix(8), privacy: .public) to a canonical fixed point")
            } catch {
                log.error("payload migration of \(p.id.uuidString.prefix(8), privacy: .public) failed: \(error.code.rawValue, privacy: .public)")
            }
        }
    }

    /// §8.1: an OpenVPN profile saved while the validator was unavailable (2.0.1: the tunnel component) gets its [7]
    /// check now: at launch (after `load`) and after every hello. A profile the
    /// engine already rejected isn't re-checked on every hello (review L7: that bumped metaRevision each time).
    ///
    /// Round 1 (Fable M1, Sonnet M1): only a verdict on the file is persisted (`.rejected`, or `.checkCrashed` after
    /// the service died on it twice). A timeout or an unavailable service throws and leaves the profile "Not yet
    /// verified", retried later; a profile that timed out `maxTimeoutsPerRun` times is left alone until the next launch
    /// (each try can keep the service busy for its watchdog, twice).
    /// `provisionVerified` (reconcile, after a hello): a profile verified now is provisioned at once.
    func verifyPending(provisionVerified: Bool = false) async {
        if provisionVerified { provisionAfterVerify = true }
        guard validator != nil else { return }
        guard !verifying else { verifyAgain = true; return }
        verifying = true
        defer { verifying = false }
        repeat {
            verifyAgain = false
            await verifyPendingPass()
        } while verifyAgain
        // Round 3 (Fable N6): a profile the launch's pass verified before the first reconcile allowed provisioning (that
        // reconcile's plan was computed while it was still unverified) is installed now, not at the next reconcile.
        if provisionAfterVerify, !verifiedBeforeProvisioning.isEmpty {
            let ids = verifiedBeforeProvisioning.sorted { $0.uuidString < $1.uuidString }
            verifiedBeforeProvisioning = []
            for id in ids { if let p = profile(id), p.engineVerified { await provisionQuietly(p) } }
        }
    }
    /// Round 3 (Fable N6): verified while provisioning wasn't allowed yet (also in `provisionIncomplete`, for reconcile).
    @ObservationIgnored private var verifiedBeforeProvisioning: Set<UUID> = []
    @ObservationIgnored private var verifyAgain = false
    /// Set by the first reconcile's `verifyPending` (a hello succeeded): from then on, verified profiles are provisioned.
    @ObservationIgnored private var provisionAfterVerify = false

    private func verifyPendingPass() async {
        guard let validator else { return }
        func alreadyRejected(_ p: Profile) -> Bool {
            p.importReport?.items.contains { if case .engineValidationFailed = $0.reason { true } else { $0.reason == .checkCrashed } } ?? false
        }
        // Round 2 (Fable L8): at most `maxTimeoutsPerRunTotal` timeouts in one run, whatever the number of such files,
        // and a profile that timed out in `maxTimeoutRuns` runs is left to the user's "Check Again".
        for p in profiles where !p.engineVerified && !tampered.contains(p.id) && !alreadyRejected(p) && !verificationStalled(p.id)
                                && verifyTimeouts[p.id, default: 0] < Self.maxTimeoutsPerRun {
            guard verifyTimeoutsTotal < Self.maxTimeoutsPerRunTotal else {
                log.notice("file check: \(self.verifyTimeoutsTotal, privacy: .public) timeouts this run; the rest waits for the next launch")
                break
            }
            guard let payload = try? await repository.payload(for: p) else { continue }
            let text = payload.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
            let disableClientCert = !(text.contains("<cert>") && text.contains("<key>"))
            let ev: OVPNEngineEvaluation
            do { ev = try await validator.validate(canonical: text, disableClientCert: disableClientCert) } catch {
                if (error as? LPError)?.code == .timeout {
                    verifyTimeouts[p.id, default: 0] += 1
                    verifyTimeoutsTotal += 1
                    if timedOutThisRun.insert(p.id).inserted {
                        settings.update { $0.verifyTimeoutRuns[p.id.uuidString, default: 0] += 1 }
                        if verificationStalled(p.id) {
                            note(String(localized: "LockPlus's file check didn't finish for \(p.name) after several tries. It isn't retried automatically any more; choose Check Again on the profile to try once more.",
                                        comment: "Problems line (2.0.2 round 2): a profile's file check timed out in several launches"))
                        }
                    }
                }
                continue
            }
            settings.update { $0.verifyTimeoutRuns[p.id.uuidString] = nil }
            switch ev.verdict {
            case .accepted:
                verifyTimeouts[p.id] = nil
                // Round 1 (Codex 5): the verdict belongs to the bytes that were checked: committed only if the profile
                // still has that revision and digest (an editor save meanwhile is checked on its own).
                guard let cur = profile(p.id), cur.payloadRevision == p.payloadRevision, cur.payloadDigest == p.payloadDigest else { continue }
                try? await updateMetadata(p.id) {
                    if $0.payloadRevision == p.payloadRevision && $0.payloadDigest == p.payloadDigest { $0.engineVerified = true }
                }
                // Round 2 (L8): `reconcile` runs this after its own provisioning, so a profile verified now is installed
                // here (quietly: before the extension's first hello it waits for the next reconcile).
                if provisionAfterVerify, let verified = profile(p.id), verified.engineVerified {
                    await provisionQuietly(verified)
                } else if profile(p.id)?.engineVerified == true {
                    verifiedBeforeProvisioning.insert(p.id)
                    provisionIncomplete.insert(p.id)
                }
            case .rejected(category: let category):
                guard let cur = profile(p.id), cur.payloadRevision == p.payloadRevision, cur.payloadDigest == p.payloadDigest else { continue }
                try? await updateMetadata(p.id) {
                    var r = $0.importReport ?? ImportReport()
                    r.add(.notSupported, .engineValidationFailed(category: category))
                    $0.importReport = r
                }
                note(String(localized: "LockPlus's file check refused \(p.name): \(category)",
                            comment: "Problems line: the sandboxed OpenVPN check refused a saved profile; %1$@ profile name, %2$@ openvpn3's reason"))
            case .checkCrashed:
                guard let cur = profile(p.id), cur.payloadRevision == p.payloadRevision, cur.payloadDigest == p.payloadDigest else { continue }
                try? await updateMetadata(p.id) {
                    var r = $0.importReport ?? ImportReport()
                    r.add(.notSupported, .checkCrashed)
                    $0.importReport = r
                }
                note(String(localized: "LockPlus couldn't check \(p.name) safely.",
                            comment: "Problems line: the sandboxed OpenVPN check died on a saved profile twice; %@ profile name"))
            }
        }
    }
    /// Round 1 (Sonnet M1): timeouts per profile in this run (memory only: a new launch tries again).
    @ObservationIgnored private var verifyTimeouts: [UUID: Int] = [:]
    static let maxTimeoutsPerRun = 2
    /// Round 2 (Fable L8): every timeout of this run, all profiles together (each can cost two client timeouts).
    @ObservationIgnored private var verifyTimeoutsTotal = 0
    static let maxTimeoutsPerRunTotal = 3
    /// Round 2 (Fable L8): profiles that timed out in this run (each run counts once in `verifyTimeoutRuns`).
    @ObservationIgnored private var timedOutThisRun: Set<UUID> = []
    static let maxTimeoutRuns = 3
    /// Round 2 (Fable N2): the payload revision `migrateNonFixedPointPayloads` last checked, per profile.
    @ObservationIgnored private var migrationChecked: [UUID: UInt64] = [:]

    /// Round 2 (Fable L8): the file check timed out in `maxTimeoutRuns` launches; only "Check Again" retries it.
    func verificationStalled(_ id: UUID) -> Bool {
        settings.value.verifyTimeoutRuns[id.uuidString, default: 0] >= Self.maxTimeoutRuns
    }

    /// Round 2 (Fable L8): "Check Again": the profile's timeout history is forgotten and the check runs now (one more
    /// timeout budget for this run).
    func checkAgain(_ id: UUID) async {
        settings.update { $0.verifyTimeoutRuns[id.uuidString] = nil }
        verifyTimeouts[id] = nil
        timedOutThisRun.remove(id)
        verifyTimeoutsTotal = min(verifyTimeoutsTotal, Self.maxTimeoutsPerRunTotal - 1)
        await verifyPending()
    }
}
