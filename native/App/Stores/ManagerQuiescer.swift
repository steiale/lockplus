import Foundation
import LPModel
import os

/// `TunnelQuiescing` over the NE managers (DESIGN §4.2 step 3, §4.6 step 2, §12.3). `SystemExtensionManager` is
/// created before the stores, so the stores are attached afterwards (`attach`); until then it answers "nothing to do".
@MainActor final class ManagerQuiescer: TunnelQuiescing {
    private weak var connection: ConnectionStore?
    private let log = Logger(subsystem: "io.github.steiale.lockplus.mac", category: "lifecycle")
    /// Between the checks of an unreadable keychain (tests: no wait).
    var retrySleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    private var managers: (any VPNManaging)?
    private var settings: SettingsStore?

    func attach(managers: any VPNManaging, settings: SettingsStore, connection: ConnectionStore) {
        self.managers = managers
        self.settings = settings
        self.connection = connection
    }

    func hasOnDemandOrResumeMarker() async -> Bool {
        guard let managers, let settings else { return false }
        return managers.managers.contains(where: \.onDemandEnabled) || settings.value.pendingResume != nil
            || settings.value.expectedUpdate != nil
    }

    /// Write pendingResume, turn on-demand off, stop and await `.disconnected` (15 s, then continue, logged).
    func quiesce(reason: QuiesceReason) async {
        guard let managers, let settings else { return }
        let snapshot = managers.managers
        let active = snapshot.first { $0.status.isActive }?.profileID
        let onDemand = snapshot.filter(\.onDemandEnabled).map(\.profileID)
        if settings.value.pendingResume == nil {
            let why: PendingResume.Reason = reason == .reinstall ? .reinstall : .extensionUpdate
            var record = PendingResume(profileID: active, onDemandEnabledIDs: onDemand, reason: why)
            // Round 2 (Fable M1a): the profile is reconnected after the update only with this one-shot intent.
            if let active, let repository = connection?.profileRepository {
                do throws(LPError) { record.intent = try await repository.sealRecord(.pendingResume, PendingResume.message(profileID: active, reason: why)) } catch {
                    log.error("update resume record not sealed (\(error.code.rawValue, privacy: .public)); the profile won't reconnect by itself")
                }
            }
            await settings.updateDurably { $0.pendingResume = record }
        }
        for id in onDemand { try? await managers.setOnDemandEnabled(false, for: id) }
        // Review e321e10 LOW 1: user stops (no teardown entry, no error fetch, no crash wait).
        for m in snapshot where m.status.isLive {
            if let connection { connection.stopAsUser(m.profileID) } else { managers.stop(m.profileID) }
        }
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, snapshot.contains(where: { let s = managers.status($0.profileID); return s != .disconnected && s != .invalid }) {
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    /// After `.completed` (§12.3 step 5), or an activation that failed with the old extension still installed (review 4
    /// #3): restore on-demand and restart the profile that was connected, then clear `pendingResume` and
    /// `expectedUpdate`. The expected-update marker is cleared even when nothing was quiesced, through the same restore
    /// (`endExtensionHandOver`, review 4 #2: a plan held off meanwhile comes back).
    func resumeAfterUpdate() async {
        guard let settings else { return }
        guard let r = settings.value.pendingResume else {
            guard settings.value.expectedUpdate != nil else { return }
            if let connection { await connection.endExtensionHandOver { $0.expectedUpdate = nil } } else {
                await settings.updateDurably { $0.expectedUpdate = nil }
            }
            return
        }
        // Review R5: through the pause record (durable, restored when nothing else is active or starting); the profile
        // that was connected restarts first and takes its own on-demand with it. Review N2: the record and the cleared
        // markers are one durable write (the plans are held while a marker is set), so a crash at any point still knows.
        let clear: (inout AppSettings) -> Void = {
            $0.pendingResume = nil
            $0.expectedUpdate = nil
        }
        if let connection {
            // Round 2 (Fable M1a): settings.json isn't authenticated; the profile is reconnected only with the record's
            // one-shot intent (consumed here). Without it, on-demand comes back and nothing is connected.
            var target = r.profileID
            if let id = target {
                let check = await Self.checkIntent(r, profileID: id, repository: connection.profileRepository, sleep: retrySleep)
                // Round 3 (Fable L2): the update's resume ends here whatever the check says; its one-time value goes (an
                // unreadable keychain excepted), so a genuine record altered at this moment can't be written back later.
                if check != .unavailable { await connection.profileRepository.consumeRecord(.pendingResume) }
                if check != .valid {
                    log.fault("update resume record of \(id.uuidString.prefix(8), privacy: .public): \(String(describing: check), privacy: .public); not reconnected")
                    connection.noteProblem(check == .unavailable
                        ? String(localized: "A profile wasn't reconnected after the update: LockPlus couldn't read its keychain. Connect it yourself.",
                                 comment: "Problems line (2.0.2 round 2): the extension update's resume record couldn't be checked")
                        : String(localized: "A profile wasn't reconnected after the update: its resume record was changed outside LockPlus. Connect it yourself.",
                                 comment: "Problems line (2.0.2 round 2): the extension update's resume record failed its authentication check"))
                    target = nil
                }
            } else {
                // Round 3 (Fable L2): a record whose profile was removed at this moment ends too (its value is spent).
                await connection.profileRepository.consumeRecord(.pendingResume)
            }
            await connection.returnOnDemand(r.onDemandEnabledIDs, thenConnect: target, ending: clear)
        } else {
            await settings.updateDurably(clear)
        }
    }

    /// Round 2 (Fable M1a): a keychain that can't be read is asked again twice, a second apart (the record stays valid).
    static func checkIntent(_ r: PendingResume, profileID: UUID, repository: ProfileRepository,
                            sleep: @Sendable (Duration) async -> Void) async -> RecordCheck {
        let message = PendingResume.message(profileID: profileID, reason: r.reason)
        var check = await repository.checkRecord(.pendingResume, tag: r.intent, message)
        for _ in 0..<2 where check == .unavailable {
            await sleep(.seconds(1))
            check = await repository.checkRecord(.pendingResume, tag: r.intent, message)
        }
        return check
    }
}
