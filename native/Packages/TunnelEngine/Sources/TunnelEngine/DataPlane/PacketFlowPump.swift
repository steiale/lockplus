import Foundation
import LPModel
import NetworkExtension
import Synchronization

/// What the pump needs from `NEPacketTunnelFlow` (injectable for tests).
public protocol PacketFlowSource: AnyObject, Sendable {
    func readPackets(_ handler: @escaping @Sendable ([Data], [NSNumber]) -> Void)
    @discardableResult func writePackets(_ packets: [Data], protocols: [NSNumber]) -> Bool
}

/// `NEPacketTunnelFlow` is documented thread safe [NEPacketTunnelFlow.h:25] but not `Sendable` in Swift.
// SAFETY: NEPacketTunnelFlow "is thread safe" per its header; we only call its two methods.
public final class NEPacketFlowSource: PacketFlowSource, @unchecked Sendable {
    private let flow: NEPacketTunnelFlow
    public init(_ flow: NEPacketTunnelFlow) { self.flow = flow }
    public func readPackets(_ handler: @escaping @Sendable ([Data], [NSNumber]) -> Void) {
        flow.readPackets { @Sendable p, n in handler(p, n) }
    }
    public func writePackets(_ packets: [Data], protocols: [NSNumber]) -> Bool { flow.writePackets(packets, withProtocols: protocols) }
}

public enum SocketPair {
    public static let minBuffer: Int32 = 1 << 20   // §7.3 MUST: ≥ 1 MB (the AF_UNIX datagram default of 2 KiB is < 1 packet)

    /// `socketpair(AF_UNIX, SOCK_DGRAM)` with ≥ 1 MB buffers on both ends and CLOEXEC.
    public static func make() throws(LPTunnelError) -> (engineEnd: Int32, pumpEnd: Int32) {
        var sv: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &sv) == 0 else { throw .of(.tunDeviceFailed, "socketpair \(errno)") }
        for fd in sv {
            var snd: Int32 = minBuffer, rcv: Int32 = minBuffer * 4
            let size = socklen_t(MemoryLayout<Int32>.size)
            if setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &snd, size) != 0 || setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcv, size) != 0 {
                close(sv[0]); close(sv[1]); throw .of(.tunDeviceFailed, "sockbuf \(errno)")
            }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }
        return (sv[0], sv[1])
    }

    static func bufferSizes(_ fd: Int32) -> (snd: Int32, rcv: Int32) {
        var a: Int32 = 0, b: Int32 = 0
        var l = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_SNDBUF, &a, &l)
        l = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_RCVBUF, &b, &l)
        return (a, b)
    }
}

/// `NEPacketTunnelFlow` ↔ the pump end of a socketpair, with utun framing (4-byte AF header). DESIGN §7.3 MUST rules:
/// - ONE pump per NE session, shared by every adapter start in it (NE serves one outstanding `readPackets`);
///   engines attach and detach; packets read while nothing is attached are dropped and the read re-armed.
/// - Engine → flow: one `DispatchSource` read source (kqueue) per attached fd on the pump's serial queue, instead of a
///   reader thread polling every 200 ms (tunnel review simplification; fold-in: this replaces the "readers poll" MUST).
///   Retiring an fd cancels its source at once; no thread per attach.
/// - Fds are closed only in the source's cancel handler, under the send lock, so a send never hits a closed or reused
///   descriptor. Both socketpair ends have ≥ 1 MB buffers (`SocketPair`).
// SAFETY: all mutable state is in `st`; sends and closes happen under it. Dispatch sources are used only through
// their thread-safe API (resume/cancel) and handlers run on `queue`.
public final class PacketFlowPump: @unchecked Sendable {
    public struct Stats: Sendable, Equatable { public var toEngine = 0, toFlow = 0, dropped = 0, readers = 0, outstandingReads = 0 }
    private struct St {
        var cur: Int32 = -1
        var sources: [Int32: any DispatchSourceRead] = [:]
        var running = true
        var reading = false
        var stats = Stats()
    }
    private let flow: any PacketFlowSource
    private let st = Mutex(St())
    private let queue = DispatchQueue(label: "lockplus.pf.reader", qos: .userInitiated)
    static let batch = 64

    public init(flow: any PacketFlowSource) {
        self.flow = flow
    }

    public var stats: Stats { st.withLock { $0.stats } }

    /// Engine started: `pumpEnd` becomes the live fd (the previous one, if any, is retired). Starts the flow read once.
    /// Takes ownership of `pumpEnd`: after `endSession()` (NEW-3) it is closed under the lock and no source is made.
    public func attach(_ pumpEnd: Int32) {
        let attached = st.withLock { s -> (src: any DispatchSourceRead, old: (any DispatchSourceRead)?, startRead: Bool)? in
            guard s.running else { close(pumpEnd); return nil }
            _ = fcntl(pumpEnd, F_SETFL, fcntl(pumpEnd, F_GETFL) | O_NONBLOCK)
            let src = makeSource(pumpEnd)
            let old = s.cur >= 0 ? s.sources[s.cur] : nil
            s.cur = pumpEnd
            s.sources[pumpEnd] = src
            s.stats.readers += 1
            guard !s.reading else { return (src, old, false) }
            s.reading = true
            return (src, old, true)
        }
        guard let attached else { return }
        attached.old?.cancel()
        attached.src.resume()
        if attached.startRead { armRead() }
    }

    private func makeSource(_ pumpEnd: Int32) -> any DispatchSourceRead {
        let src = DispatchSource.makeReadSource(fileDescriptor: pumpEnd, queue: queue)
        src.setEventHandler { @Sendable [self] in drain(pumpEnd) }
        src.setCancelHandler { @Sendable [self] in
            // Close under the send lock (§7.3 MUST).
            st.withLock { s in
                s.sources[pumpEnd] = nil
                if s.cur == pumpEnd { s.cur = -1 }
                s.stats.readers -= 1
                close(pumpEnd)
            }
        }
        return src
    }

    /// Engine stopped: retire the live fd. The flow keeps being read (packets dropped until the next attach).
    public func detach() { retireCurrent(endingSession: false) }

    /// An adapter's stop: retires `pumpEnd` only while it is still the live fd. A previous attempt's capped stop that
    /// finishes after a newer attempt attached (hold retry) must not detach the newer attempt (review nit).
    public func detach(_ pumpEnd: Int32) {
        let src = st.withLock { s -> (any DispatchSourceRead)? in
            guard s.cur == pumpEnd, s.cur >= 0 else { return nil }
            defer { s.cur = -1 }
            return s.sources[pumpEnd]
        }
        src?.cancel()
    }

    /// End of the NE session: stop re-arming the read and retire the live fd.
    public func endSession() { retireCurrent(endingSession: true) }

    private func retireCurrent(endingSession: Bool) {
        let src = st.withLock { s -> (any DispatchSourceRead)? in
            if endingSession { s.running = false }
            guard s.cur >= 0 else { return nil }
            defer { s.cur = -1 }
            return s.sources[s.cur]
        }
        src?.cancel()
    }

    private func armRead() {
        st.withLock { $0.stats.outstandingReads += 1 }
        flow.readPackets { @Sendable [self] packets, protocols in
            let again = st.withLock { s -> Bool in
                s.stats.outstandingReads -= 1
                guard s.running else { s.reading = false; return false }
                guard s.cur >= 0 else { s.stats.dropped += packets.count; return true }
                for (p, proto) in zip(packets, protocols) {
                    // L3: an empty packet would index past the 4-byte header below (trap in the root extension).
                    guard !p.isEmpty else { s.stats.dropped += 1; continue }
                    var frame = [UInt8](repeating: 0, count: 4 + p.count)
                    let af = UInt32(proto.int32Value).bigEndian
                    withUnsafeBytes(of: af) { frame.replaceSubrange(0..<4, with: $0) }
                    p.copyBytes(to: &frame[4], count: p.count)
                    let n = frame.withUnsafeBytes { send(s.cur, $0.baseAddress, $0.count, MSG_DONTWAIT) }
                    if n < 0 { s.stats.dropped += 1 } else { s.stats.toEngine += 1 }
                }
                return true
            }
            if again { armRead() }
        }
    }

    /// Read-source event (on `queue`): drain up to `batch` datagrams without blocking, then hand them to the flow.
    /// EOF or a hard error cancels the source (which closes the fd).
    private func drain(_ fd: Int32) {
        var datas: [Data] = [], protos: [NSNumber] = []
        var dead = false
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 65536 + 4) { buf in
            while datas.count < Self.batch {
                let n = recv(fd, buf.baseAddress, buf.count, MSG_DONTWAIT)
                if n < 0 { if errno != EAGAIN && errno != EINTR { dead = true }; break }
                if n == 0 { dead = true; break }
                if n > 4 {
                    let af = UInt32(buf[0]) << 24 | UInt32(buf[1]) << 16 | UInt32(buf[2]) << 8 | UInt32(buf[3])
                    datas.append(Data(buf[4..<n])); protos.append(NSNumber(value: Int32(bitPattern: af)))
                }
            }
        }
        if !datas.isEmpty {
            flow.writePackets(datas, protocols: protos)
            st.withLock { $0.stats.toFlow += datas.count }
        }
        if dead, let src = st.withLock({ $0.sources[fd] }) { src.cancel() }
    }
}
