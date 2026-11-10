import Foundation
import LPModel

/// `TunnelQuiescing` over the NE managers (DESIGN §4.2 step 3, §4.6 step 2, §12.3). `SystemExtensionManager` is
/// created before the stores, so the stores are attached afterwards (`attach`); until then it answers "nothing to do".
@MainActor final class ManagerQuiescer: TunnelQuiescing {
    private weak var connection: ConnectionStore?
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
            await settings.updateDurably {
                $0.pendingResume = PendingResume(profileID: active, onDemandEnabledIDs: onDemand,
                                                 reason: reason == .reinstall ? .reinstall : .extensionUpdate)
            }
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
            await connection.returnOnDemand(r.onDemandEnabledIDs, thenConnect: r.profileID, ending: clear)
        } else {
            await settings.updateDurably(clear)
        }
    }
}
