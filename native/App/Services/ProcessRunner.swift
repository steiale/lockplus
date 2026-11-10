import Foundation
import Synchronization

// Deadlines: LPModel.withDeadline (a OneShot gate; never a TaskGroup race, which would wait for a blocked child).

/// Blocking work on a GCD thread, never on the cooperative pool (review M10).
enum Blocking {
    private static let queue = DispatchQueue(label: "lockplus.blocking", attributes: .concurrent)
    static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (k: CheckedContinuation<T, Never>) in
            queue.async { @Sendable in k.resume(returning: work()) }
        }
    }
}

/// Runs a system tool read-only, as the user, with an absolute path and a timeout (no shell, no PATH lookup).
/// Reviews M10, FA-L4: the pipe is drained to EOF continuously (keeping the first `maxBytes`), so a chatty tool
/// never stalls on a full pipe; completion comes from `terminationHandler`, nothing blocks the cooperative pool;
/// the timeout keeps its sub-second part.
enum ProcessRunner {
    /// The output buffer, filled from the pipe's readability handler.
    private final class Collector: Sendable {
        let data = Mutex(Data())
        let limit: Int
        init(limit: Int) { self.limit = limit }
        func append(_ d: Data) {
            data.withLock { buf in
                let room = limit - buf.count
                if room > 0 { buf.append(d.prefix(room)) }
            }
        }
    }

    /// SAFETY: Process is used from the termination handler and the timer only for `isRunning`/`terminate`, which
    /// Foundation documents as thread-safe.
    private final class ProcessBox: @unchecked Sendable {
        let process = Process()
    }

    static func run(_ path: String, _ args: [String], timeout: Duration, maxBytes: Int = 4 << 20) async -> String? {
        let box = ProcessBox()
        let p = box.process
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        let collector = Collector(limit: maxBytes)
        let reader = out.fileHandleForReading
        reader.readabilityHandler = { @Sendable h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { collector.append(d) }
        }
        return await withCheckedContinuation { (k: CheckedContinuation<String?, Never>) in
            p.terminationHandler = { @Sendable proc in
                reader.readabilityHandler = nil
                if let rest = try? reader.readToEnd() { collector.append(rest) }
                let ok = proc.terminationStatus == 0 && proc.terminationReason == .exit
                let text = collector.data.withLock { String(decoding: $0, as: UTF8.self) }
                k.resume(returning: ok ? text : nil)
            }
            do { try p.run() } catch {
                reader.readabilityHandler = nil
                k.resume(returning: nil)
                return
            }
            let c = timeout.components
            let ns = Int(c.seconds) * 1_000_000_000 + Int(c.attoseconds / 1_000_000_000)
            DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(ns)) { @Sendable in
                if box.process.isRunning { box.process.terminate() }
            }
        }
    }
}
