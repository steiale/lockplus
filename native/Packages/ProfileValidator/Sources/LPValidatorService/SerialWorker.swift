import Foundation

/// One dedicated thread with an 8 MiB stack that runs submitted closures one at a time, in order. The validator's
/// work (openvpn3 C++ parsing, OpenSSL PEM/ASN.1, zlib) is blocking and can recurse deeply: it must neither run on a
/// cooperative-pool thread nor on a GCD worker (512 KiB stacks). Same stack size as the engine's connect thread.
// SAFETY: `@unchecked Sendable` — all mutable state (`jobs`, `stopped`) is touched only while holding `cond`.
final class SerialWorker: @unchecked Sendable {
    private let cond = NSCondition()
    private var jobs: [@Sendable () -> Void] = []
    private var stopped = false
    private var thread: Thread?

    init(name: String, stackSize: Int = 8 << 20) {
        let t = Thread { [self] in loop() }
        t.name = name
        t.stackSize = stackSize
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
    }

    func submit(_ job: @escaping @Sendable () -> Void) {
        cond.lock()
        jobs.append(job)
        cond.signal()
        cond.unlock()
    }

    func stop() {
        cond.lock()
        stopped = true
        cond.signal()
        cond.unlock()
    }

    private func loop() {
        while true {
            cond.lock()
            while jobs.isEmpty && !stopped { cond.wait() }
            if jobs.isEmpty && stopped { cond.unlock(); return }
            let job = jobs.removeFirst()
            cond.unlock()
            job()
        }
    }
}
