import Foundation
import Observation

/// The in-memory `AppSettings` (§3.2) with write-through to settings.json (atomic, off the main actor).
///
/// Review N4: every write goes through ONE ordered queue into `SettingsFileStore`, and each write saves the value as
/// of the write (latest wins). A durable change (`updateDurably`) returns once its write (or a later one) is on disk.
/// The only write on the calling thread is the quit path (`writeSynchronously`); every write carries a sequence number
/// and the file store never puts an older one over a newer one.
///
/// E2E-4 (settings reset on 26 under 200005): before `replaceAll` has put the file's value in place, `value` is
/// `AppSettings()`. A quit in that window (a scripted quit right after launch, the second-instance alert's terminate,
/// Sparkle) ran the quit path's synchronous write and replaced settings.json with defaults (`onboardingComplete`,
/// `lastUsedProfileID` gone). A store created with `loadedFromDisk: false` writes NOTHING until `replaceAll`.
@MainActor @Observable
final class SettingsStore {
    private(set) var value: AppSettings
    @ObservationIgnored private let files: SettingsFileStore?
    @ObservationIgnored private var writeTask: Task<Void, Never>?
    @ObservationIgnored private var seq: UInt64 = 0
    /// False until the value on disk has been read (`replaceAll`): no write may put a value over the file before then.
    @ObservationIgnored private(set) var loadedFromDisk: Bool
    /// Round 2 (Fable M1b): called after every in-process change of the Auto-Connect choice (`enabled`, `profileID`). A
    /// value changed in this process is the user's (or LockPlus's own) choice; only what `replaceAll` read from disk
    /// needs its tag checked. `ProfilesStore` seals the new choice.
    @ObservationIgnored var onAutoConnectChoiceChange: (@MainActor () -> Void)?

    init(value: AppSettings = AppSettings(), files: SettingsFileStore?, loadedFromDisk: Bool = true) {
        self.value = value
        self.files = files
        self.loadedFromDisk = loadedFromDisk
    }

    /// The value read from disk at launch (no write-back). From now on writes go through.
    func replaceAll(_ v: AppSettings) {
        value = v
        loadedFromDisk = true
    }

    /// Changes the value; the write is queued.
    func update(_ change: (inout AppSettings) -> Void) {
        var v = value
        change(&v)
        guard v != value else { return }
        let choiceChanged = v.autoConnect.enabled != value.autoConnect.enabled || v.autoConnect.profileID != value.autoConnect.profileID
        value = v
        persist()
        if choiceChanged { onAutoConnectChoiceChange?() }
    }

    /// Changes the value and returns once it is on disk (the pause record: a crash right after must still know).
    func updateDurably(_ change: (inout AppSettings) -> Void) async {
        update(change)
        await flush()
    }

    /// Writes in order: each write waits for the previous one and saves the value AS OF THE WRITE.
    private func persist() {
        guard let files, loadedFromDisk else { return }
        let previous = writeTask
        writeTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            self.seq &+= 1
            await files.save(self.value, seq: self.seq)
        }
    }

    /// Quit path only (the process exits right after; the queue may not get to run): on the main thread.
    func writeSynchronously() {
        guard let files, loadedFromDisk else { return }
        seq &+= 1
        files.saveNow(value, seq: seq)
    }

    /// Waits for pending writes.
    func flush() async { await writeTask?.value }
}
