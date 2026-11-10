import Foundation
import LPModel
import LPWire
import Observation

/// The §11.3 baseline rule: bytes and time are committed together, or the rate desyncs (the Go tray bug).
struct RateMeter: Sendable {
    private var baseline: (rx: UInt64, tx: UInt64, t: Date)?

    /// nil for the first sample and for samples < 0.5 s apart (bytes AND time skip together).
    mutating func ingest(rx: UInt64, tx: UInt64, at t: Date) -> Rate? {
        guard let b = baseline else { baseline = (rx, tx, t); return nil }
        let dt = t.timeIntervalSince(b.t)
        guard dt >= 0.5 else { return nil }
        defer { baseline = (rx, tx, t) }                  // one assignment
        let down = rx >= b.rx ? Double(rx - b.rx) / dt : 0   // counter reset → 0
        let up = tx >= b.tx ? Double(tx - b.tx) / dt : 0
        return Rate(down: down, up: up)
    }

    /// After an XPC interruption or a new session (§5.4).
    mutating func reset() { baseline = nil }
}

/// `StatsStore` (§11.2, §7.7): `statistics` polling at 1 Hz while someone looks (menu open, main window visible) and a
/// tunnel is active. Writes `current` and `samples` separately so text and chart invalidate independently.
@MainActor final class StatsStore {
    enum Consumer: Hashable, Sendable { case menu, mainWindow }

    private let service: any TunnelServicing
    private let model: StatsUIModel
    private let profileID: @MainActor () -> UUID?
    private let isActive: @MainActor () -> Bool
    private var consumers: Set<Consumer> = []
    private var task: Task<Void, Never>?
    private var meter = RateMeter()
    private var session: UUID?
    private var nextSampleID = 0

    init(service: any TunnelServicing, model: StatsUIModel, profileID: @escaping @MainActor () -> UUID?,
         isActive: @escaping @MainActor () -> Bool) {
        self.service = service
        self.model = model
        self.profileID = profileID
        self.isActive = isActive
    }

    func addConsumer(_ c: Consumer) {
        consumers.insert(c)
        reevaluate()
    }

    func removeConsumer(_ c: Consumer) {
        consumers.remove(c)
        reevaluate()
    }

    /// Call on every status change: polling stops while no tunnel is active.
    func reevaluate() {
        let should = !consumers.isEmpty && isActive()
        if should, task == nil {
            task = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    await self?.tick()
                    try? await Task.sleep(for: .seconds(1), tolerance: .milliseconds(100))
                }
            }
        } else if !should, let t = task {
            t.cancel()
            task = nil
            meter.reset()
            if !isActive() {
                model.current = nil
                model.samples = []
            }
        }
    }

    func resetBaseline() { meter.reset() }

    private func tick() async {
        guard let id = profileID() else { return }
        guard let s = try? await service.call(.statistics, ProfileRequest(profileID: id), as: TunnelStatistics.self) else { return }
        if s.sessionID != session {
            session = s.sessionID
            meter.reset()
            model.samples = []
        }
        model.sessionReceived = s.rxBytes
        model.sessionSent = s.txBytes
        model.lastHandshake = s.lastHandshakeAt
        if let r = meter.ingest(rx: s.rxBytes, tx: s.txBytes, at: s.sampledAt) {
            model.current = r
            nextSampleID += 1
            var samples = model.samples
            samples.append(RateSample(id: nextSampleID, t: s.sampledAt, rx: r.down, tx: r.up))
            if samples.count > 300 { samples.removeFirst(samples.count - 300) }
            model.samples = samples
        }
    }
}
