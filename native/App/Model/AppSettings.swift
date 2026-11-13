import Foundation
import LPModel

// settings.json, history.json and migration.json (DESIGN §3.2, §3.3, §10.4, §13.1). Every field has a default and
// decoding is lenient PER FIELD (`try? decodeIfPresent`, E2E-4 review L6): an older or newer file, or one field of a
// type this build doesn't expect, never fails the whole file (and never resets the other settings).

struct AutoConnectRules: Codable, Sendable, Equatable {
    var enabled = false
    /// The one on-demand profile (§10.4).
    var profileID: UUID?
    /// ≤ 64 entries, each ≤ 32 bytes UTF-8.
    var trustedSSIDs: [String] = []
    var connectOnUntrustedWiFi = true
    var connectOnEthernet = false
    /// "Pause protection" (§10.4); nil = not paused.
    var pausedUntil: Date?
    /// Round 2 (Fable M1b): the tag of the choice (`enabled`, `profileID`) as LockPlus last made it
    /// (`ProfileRepository.sealRecord(.autoConnectChoice, …)`). An enabled choice whose tag doesn't verify at launch gives
    /// no plan (no on-demand rules, no unattended-start consent) and is turned off. The rest of the rules only shape when
    /// on-demand fires, never whether a profile has consent, so they aren't covered.
    /// Round 3 (Fable M1, Codex r3 #2): every state is sealed, "off" included, and each change replaces the one-time
    /// value, so a copy of an earlier enabled choice never verifies after the user turned it off. The first 2.0.2 launch
    /// seals whatever the choice is: from then on the one-time value exists (the "initialised" marker) and an untagged
    /// enabled choice is a forgery, not a choice from before 2.0.2.
    var choiceTag: String?

    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        profileID = try? c.decodeIfPresent(UUID.self, forKey: .profileID)
        trustedSSIDs = (try? c.decodeIfPresent([String].self, forKey: .trustedSSIDs)) ?? []
        connectOnUntrustedWiFi = (try? c.decodeIfPresent(Bool.self, forKey: .connectOnUntrustedWiFi)) ?? true
        connectOnEthernet = (try? c.decodeIfPresent(Bool.self, forKey: .connectOnEthernet)) ?? false
        pausedUntil = try? c.decodeIfPresent(Date.self, forKey: .pausedUntil)
        choiceTag = try? c.decodeIfPresent(String.self, forKey: .choiceTag)
    }

    /// Round 2 (Fable M1b), round 3 (M1): what the choice's tag covers: the toggle and the profile.
    static func choiceMessage(enabled: Bool, profileID: UUID?) -> Data {
        Data("lockplus.autoconnect-choice.v2\n\(enabled ? 1 : 0)\n\(profileID?.uuidString ?? "-")".utf8)
    }

    /// The profile the user just turned Auto-Connect on for: the toggle went on, or another profile was picked while
    /// it is on. That is fresh intent, so it ends a "suspended until the next network change" (§10.4, E2E-2).
    static func turnedOn(from old: AutoConnectRules, to new: AutoConnectRules) -> UUID? {
        guard new.enabled, let id = new.profileID, !old.enabled || old.profileID != id else { return nil }
        return id
    }

    /// §3.2 caps.
    static func sanitizedSSIDs(_ s: [String]) -> [String] {
        var out: [String] = []
        for x in s where !x.isEmpty && x.utf8.count <= 32 && !out.contains(x) && out.count < 64 { out.append(x) }
        return out
    }
}

/// §4.2 step 3 / §4.6 step 2: what to restore after the extension is replaced.
struct PendingResume: Codable, Sendable, Equatable {
    enum Reason: String, Codable, Sendable { case extensionUpdate, reinstall }
    var profileID: UUID?
    var onDemandEnabledIDs: [UUID]
    var reason: Reason
    /// Round 2 (Fable M1a): `ProfileRepository.sealRecord(.pendingResume, message(…))`, one shot. Without a valid one the
    /// end of the update restores on-demand but connects nothing.
    var intent: String? = nil

    static func message(profileID: UUID, reason: Reason) -> Data {
        Data("lockplus.pending-resume.v1\n\(profileID.uuidString)\n\(reason.rawValue)".utf8)
    }
}

/// §12.3 step 2 (variant B): Sparkle's postpone hook records the install it is about to perform. The §4.2 preflight
/// treats it as a resume marker; `resumeAfterUpdate()` (or a failed install) clears it.
struct ExpectedUpdate: Codable, Sendable, Equatable {
    var from: String
    var to: String
}

/// §10.4 pause record: what to restore at expiry.
struct PausedState: Codable, Sendable, Equatable {
    var profileID: UUID?
    var onDemandEnabledIDs: [UUID]
    var agentBuild: String
    /// Round 1 (Codex 3), round 2 (L5): `ProfileRepository.sealRecord(.pause, ResumeIntent.message(…))` for `profileID`
    /// and the pause's end, one shot (consumed at the resume). A record without a valid one restores on-demand but arms
    /// and starts nothing.
    var intent: String? = nil
}

/// The settings.json records that can lead to a start or to unattended-start consent (round 2, Fable M1). Each has its
/// own HKDF key and its own one-time value in the keychain (`ProfileRepository.sealRecord`).
enum SettingsRecord: String, CaseIterable, Sendable {
    case pause = "pause"
    case pendingResume = "pending-resume"
    case autoConnectChoice = "autoconnect-choice"
    /// Round 3 (Codex r3 #4): `networkRestartHold`.
    case networkRestartHold = "network-restart-hold"
}

/// `ProfileRepository.checkRecord`.
enum RecordCheck: Sendable, Equatable {
    case valid
    /// The tag doesn't verify (forged, replayed, or a copy of a record already acted on).
    case invalid
    /// No record of this kind was ever sealed on this Mac (one written before 2.0.2).
    case neverSealed
    /// The keychain couldn't be read now: retry, never "changed outside LockPlus".
    case unavailable
}

/// Round 1 (Codex 3): the authenticated part of a pause record.
enum ResumeIntent {
    /// A pause end older than this is not resumed by its record (bounds the replay of an old, genuine record).
    static let maxAge: TimeInterval = 7 * 24 * 3600
    /// Whole seconds: settings.json stores dates in ISO 8601 without fractions, and the pause end is written rounded.
    static func message(profileID: UUID, until: Date) -> Data {
        Data("lockplus.resume-intent.v2\n\(profileID.uuidString)\n\(Int64(until.timeIntervalSince1970.rounded(.down)))".utf8)
    }

    /// What a resume may do with the record's profile.
    enum Check: Sendable, Equatable {
        case holds
        case changedOutside
        case tooOld
        /// Written before 2.0.2 (no intent, and no pause was ever sealed here).
        case olderRecord
        /// The keychain couldn't be read: retried, the pause stays.
        case unavailable
    }
    static func wholeSeconds(_ d: Date) -> Date { Date(timeIntervalSince1970: d.timeIntervalSince1970.rounded(.down)) }
    static func isFresh(until: Date, now: Date) -> Bool { now.timeIntervalSince(until) <= maxAge }
}

struct AppSettings: Codable, Sendable, Equatable {
    /// v2.0 ships English and German (lead decision); an older file's "ko"/"ja" decodes as `.system`.
    enum Language: String, Codable, Sendable { case system, en, de }
    /// §6.14: the window appearance; `.system` follows macOS. Applied through `AppAppearanceApplier`.
    enum Appearance: String, Codable, Sendable { case system, light, dark }
    enum RateLabel: String, Codable, Sendable { case off, download, both }
    enum IconStyle: String, Codable, Sendable { case monochrome, color }
    enum Notifications: String, Codable, Sendable { case problemsOnly, connectDisconnect, off }
    enum Level: String, Codable, Sendable { case error, warning, info, debug }

    /// 2: the menu bar icon default became the colour tile (UI review 2026-11-09); see `init(from:)`.
    static let currentSchema = 2
    var schema = AppSettings.currentSchema
    var language: Language = .system
    var appearance: Appearance = .system
    var menuBarRateLabel: RateLabel = .both
    var menuBarIconStyle: IconStyle = .color
    var openWindowAtLogin = false
    var notifications: Notifications = .problemsOnly
    var receiveReleaseCandidates = false
    var logLevel: Level = .info
    var onboardingComplete = false
    var supportNoteShown = false
    /// E2E-5 F5: LockPlus 1.0.x's LaunchAgent was retired; the "Open LockPlus at login?" offer stays until answered
    /// (pre-release review LOW: it lived only in memory, so a quit before answering lost both).
    var launchAtLoginOffer = false
    /// Last launches in which the menu was opened (§11.3 visibility policy); ≤ 5 entries.
    var menuOpenedLaunches: [Date] = []
    /// Launch timestamps, newest last (≤ 5), for the "menu not opened in the last 5 launches" rule.
    var launches: [Date] = []
    /// 2.0.1 E2E: the build (`CFBundleVersion`) of the last launch; a different one is a first launch or an update, and
    /// the main window opens (UI-CONCEPT §11.3 visibility: "opens once on first launch and after every update").
    var lastLaunchedBuild: String?
    var autoConnect = AutoConnectRules()
    var newProfileDefaults = NetworkPolicy(killSwitch: true)
    /// §5.5 / §11.2: a launch-time snapshot error is shown only if it is newer than this.
    var lastQuitAt: Date?
    var lastUsedProfileID: UUID?
    var pausedState: PausedState?
    var pendingResume: PendingResume?
    var expectedUpdate: ExpectedUpdate?
    /// §10.4: on-demand turned off by a user Disconnect, "until the next network change" (review H2).
    var onDemandSuspended: [UUID] = []
    /// The network signature when it was suspended; a different one restores on-demand.
    var onDemandSuspendedNetwork: String?
    /// E2E-3 / review 2026-10-30: the configurations whose on-demand a start turned off (or a restore still owes),
    /// recorded BEFORE the pause. Restored exactly, then cleared, when nothing else is active or starting; kept until
    /// a restore succeeds (and across a quit or crash).
    var onDemandPausedByStart: [UUID] = []
    /// E2E-4 200011: the kill-switch profile whose session NE refused or ended with "No network available"
    /// (`NEVPNConnectionErrorDomain` 2) and restarts by itself once an interface returns. While set (and still
    /// applicable), nothing paused is restored, at launch and by the headless resume too. Written durably when the hold
    /// begins; cleared when NE's restart is active, the user stops it, or the fallback after the network's return ends it.
    var networkRestartHold: UUID?
    /// Round 3 (Codex r3 #4): `ProfileRepository.sealRecord(.networkRestartHold, networkRestartHoldMessage(id))`, written
    /// with the hold and consumed when it ends. A hold read at launch without a valid one is dropped: it never becomes a
    /// recovery hold, so it can't be a pause's target (a pause signs its target for an armed start at its end).
    var networkRestartHoldTag: String?
    /// Round 6 (Codex r6 #3, Fable r6 N4b): a delete of the pause's one-time value failed and is still owed. Retried
    /// (GUI: timer, `load()`, wake; agent: each run) until it succeeds; spent first at the end of any pause; the agent
    /// stays registered while it is set. Not authenticated (defence in depth for a crash or quit while owed).
    var pauseValueOwed = false

    static func networkRestartHoldMessage(_ id: UUID) -> Data { Data("lockplus.network-restart-hold.v1\n\(id.uuidString)".utf8) }

    /// §12.3, review N2: between `quiesce` (or Sparkle's `prepareForInstall`) and `resumeAfterUpdate` no configuration's
    /// on-demand is turned on (`ProfilesStore.onDemandPlan` holds it) and nothing is restored or dropped from the pause
    /// record; `resumeAfterUpdate` hands everything back through the record.
    var extensionHandOver: Bool { pendingResume != nil || expectedUpdate != nil }

    /// Ends "suspended until the next network change" for `ids` (the network is forgotten with the last one).
    mutating func endOnDemandSuspension(_ ids: [UUID]) {
        onDemandSuspended.removeAll { ids.contains($0) }
        if onDemandSuspended.isEmpty { onDemandSuspendedNetwork = nil }
    }
    /// §6.4 step 4: extension removals that failed, retried on the next reconcile.
    var pendingRemovals: [UUID] = []
    /// Round 2 (Fable L8): per profile (UUID string), the runs in which its file check timed out. At
    /// `ProfilesStore.maxTimeoutRuns` the check isn't retried automatically any more ("Check Again" resets it). Not
    /// authenticated: a forged value can only stop retries the user can restart.
    var verifyTimeoutRuns: [String: Int] = [:]
    /// User-defined sidebar order (default alphabetical).
    var profileOrder: [UUID] = []

    init() {}

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let def = AppSettings()
        schema = (try? c.decodeIfPresent(Int.self, forKey: .schema)) ?? 1
        language = (try? c.decodeIfPresent(Language.self, forKey: .language)) ?? def.language
        appearance = (try? c.decodeIfPresent(Appearance.self, forKey: .appearance)) ?? def.appearance
        menuBarRateLabel = (try? c.decodeIfPresent(RateLabel.self, forKey: .menuBarRateLabel)) ?? def.menuBarRateLabel
        menuBarIconStyle = (try? c.decodeIfPresent(IconStyle.self, forKey: .menuBarIconStyle)) ?? def.menuBarIconStyle
        openWindowAtLogin = (try? c.decodeIfPresent(Bool.self, forKey: .openWindowAtLogin)) ?? false
        notifications = (try? c.decodeIfPresent(Notifications.self, forKey: .notifications)) ?? def.notifications
        receiveReleaseCandidates = (try? c.decodeIfPresent(Bool.self, forKey: .receiveReleaseCandidates)) ?? false
        logLevel = (try? c.decodeIfPresent(Level.self, forKey: .logLevel)) ?? def.logLevel
        onboardingComplete = (try? c.decodeIfPresent(Bool.self, forKey: .onboardingComplete)) ?? false
        supportNoteShown = (try? c.decodeIfPresent(Bool.self, forKey: .supportNoteShown)) ?? false
        launchAtLoginOffer = (try? c.decodeIfPresent(Bool.self, forKey: .launchAtLoginOffer)) ?? false
        menuOpenedLaunches = (try? c.decodeIfPresent([Date].self, forKey: .menuOpenedLaunches)) ?? []
        launches = (try? c.decodeIfPresent([Date].self, forKey: .launches)) ?? []
        lastLaunchedBuild = try? c.decodeIfPresent(String.self, forKey: .lastLaunchedBuild)
        autoConnect = (try? c.decodeIfPresent(AutoConnectRules.self, forKey: .autoConnect)) ?? AutoConnectRules()
        newProfileDefaults = (try? c.decodeIfPresent(NetworkPolicy.self, forKey: .newProfileDefaults)) ?? def.newProfileDefaults
        lastQuitAt = try? c.decodeIfPresent(Date.self, forKey: .lastQuitAt)
        lastUsedProfileID = try? c.decodeIfPresent(UUID.self, forKey: .lastUsedProfileID)
        pausedState = try? c.decodeIfPresent(PausedState.self, forKey: .pausedState)
        pendingResume = try? c.decodeIfPresent(PendingResume.self, forKey: .pendingResume)
        expectedUpdate = try? c.decodeIfPresent(ExpectedUpdate.self, forKey: .expectedUpdate)
        onDemandSuspended = (try? c.decodeIfPresent([UUID].self, forKey: .onDemandSuspended)) ?? []
        onDemandSuspendedNetwork = try? c.decodeIfPresent(String.self, forKey: .onDemandSuspendedNetwork)
        onDemandPausedByStart = (try? c.decodeIfPresent([UUID].self, forKey: .onDemandPausedByStart)) ?? []
        networkRestartHold = try? c.decodeIfPresent(UUID.self, forKey: .networkRestartHold)
        networkRestartHoldTag = try? c.decodeIfPresent(String.self, forKey: .networkRestartHoldTag)
        pauseValueOwed = (try? c.decodeIfPresent(Bool.self, forKey: .pauseValueOwed)) ?? false
        pendingRemovals = (try? c.decodeIfPresent([UUID].self, forKey: .pendingRemovals)) ?? []
        verifyTimeoutRuns = (try? c.decodeIfPresent([String: Int].self, forKey: .verifyTimeoutRuns)) ?? [:]
        profileOrder = (try? c.decodeIfPresent([UUID].self, forKey: .profileOrder)) ?? []
        // Schema 1 wrote the default (monochrome) into every file, so a stored "monochrome" can't be told from "never
        // changed": it moves to the new default. Any choice made from schema 2 on is kept as stored.
        if schema < 2 {
            if menuBarIconStyle == .monochrome { menuBarIconStyle = .color }
            schema = Self.currentSchema
        }
    }

    /// Round 2 (M1b): the settings without the Auto-Connect choice's tag, which lands asynchronously after the choice
    /// (`ProfilesStore`): its arrival is not a change the editable UI models must be refreshed from (E2E-2 bug 1: a push
    /// between a click and its persistence reverts the click).
    var uiComparable: AppSettings {
        var s = self
        s.autoConnect.choiceTag = nil
        s.pauseValueOwed = false
        return s
    }

    /// §11.3 visibility (2.0.1 E2E): the first launch of a build (a first launch or an update) opens the main window.
    static func isNewBuildLaunch(previous: String?, current: String) -> Bool { previous != current }

    /// §11.3 item 2: the menu wasn't opened in any of the last 5 launches.
    var iconMayBeHidden: Bool {
        guard launches.count >= 5, let oldest = launches.suffix(5).first else { return false }
        return !menuOpenedLaunches.contains { $0 >= oldest }
    }
}

/// §3.2 history entry (capped at 500).
struct HistoryEntry: Codable, Sendable, Identifiable, Equatable {
    enum EndReason: Codable, Sendable, Equatable {
        case user, error(Int), sleep, onDemand, replaced, other
        init(summary s: String) {
            switch s {
            case "user": self = .user
            case "sleep": self = .sleep
            case "onDemand": self = .onDemand
            case "replaced": self = .replaced
            default:
                if s.hasPrefix("error:"), let n = Int(s.dropFirst(6)) { self = .error(n) } else { self = .other }
            }
        }
    }
    let id: UUID
    var profileID: UUID?
    var profileName: String
    var start: Date
    var end: Date?
    var rxBytes: UInt64
    var txBytes: UInt64
    var endReason: EndReason

    static let cap = 500
}

/// migration.json (§13.1 step 9). Automatic migration runs only while no COMPLETE marker exists. E2E-5 F4: the file is
/// written after every step with `complete == false`, so an interrupted migration (the app killed during the saved-
/// password prompt) is resumed instead of lost; files from before carry no `complete` and were complete.
struct MigrationMarker: Codable, Sendable, Equatable {
    struct Item: Codable, Sendable, Equatable {
        var oldName: String
        var newID: UUID?
        var digest: String?
        var result: String
    }
    /// When the migration finished; while `complete` is false, the time of the last step.
    var completedAt: Date
    var source: String
    var items: [Item]
    var complete = true
    /// The finished steps of an incomplete migration (`Step.rawValue`).
    var steps: [String] = []

    enum Step: String, Sendable { case credentials, settings, history }

    init(completedAt: Date, source: String, items: [Item], complete: Bool = true, steps: [String] = []) {
        self.completedAt = completedAt
        self.source = source
        self.items = items
        self.complete = complete
        self.steps = steps
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        completedAt = try c.decode(Date.self, forKey: .completedAt)
        source = try c.decode(String.self, forKey: .source)
        items = try c.decode([Item].self, forKey: .items)
        complete = try c.decodeIfPresent(Bool.self, forKey: .complete) ?? true
        steps = try c.decodeIfPresent([String].self, forKey: .steps) ?? []
    }

    func did(_ step: Step) -> Bool { steps.contains(step.rawValue) }

    /// One item per old tunnel: a retried tunnel's result replaces its earlier one (pre-release review LOW).
    mutating func record(_ item: Item) {
        items.removeAll { $0.oldName == item.oldName }
        items.append(item)
    }
}
