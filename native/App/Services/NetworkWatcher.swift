import Foundation
import Network

/// The network the Mac is on, reduced to a comparable signature (§10.4 "until the next network change").
protocol NetworkWatching: AnyObject {
    /// Called on the main actor with the current signature; the first call comes right after `start()`.
    @MainActor var onChange: ((String) -> Void)? { get set }
    @MainActor func start()
}

/// `NWPathMonitor` on its own queue; only a Sendable signature crosses to the main actor.
@MainActor final class LiveNetworkWatcher: NetworkWatching {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "lockplus.network-watcher")
    var onChange: ((String) -> Void)?

    func start() {
        monitor.pathUpdateHandler = { @Sendable [weak self] path in
            let sig = Self.signature(path)
            Task { @MainActor in self?.onChange?(sig) }
        }
        monitor.start(queue: queue)
    }

    /// Status plus the physical interfaces in use (tunnels excluded, so our own connect isn't a "change").
    nonisolated static func signature(_ path: NWPath) -> String {
        let ifs = path.availableInterfaces.filter { $0.type != .other }.map { "\($0.type):\($0.name)" }.sorted()
        return "\(path.status)|" + ifs.joined(separator: ",")
    }

    isolated deinit { monitor.cancel() }
}

/// Preview mode and tests: emits what the test tells it.
@MainActor final class FixtureNetworkWatcher: NetworkWatching {
    var onChange: ((String) -> Void)?
    var current = "satisfied|wifi:en0"
    func start() { onChange?(current) }
    func change(to sig: String) {
        current = sig
        onChange?(sig)
    }
}
