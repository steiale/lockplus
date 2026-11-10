import Foundation
import LPModel
import LPWire
import Synchronization
import Testing
@testable import TunnelEngine
import TunnelEngineTestSupport

struct FakeUtun: UtunSystem {
    var fds: [Int32: String]                 // fd → interface
    var addrs: [String: String]              // interface → address
    func utunControlFDs() -> [Int32] { fds.keys.sorted() }
    func interfaceName(of fd: Int32) -> String? { fds[fd] }
    func interface(_ name: String, hasAddress address: String) -> Bool { addrs[name] == address }
}

@Suite struct UtunSelectorTests {
    @Test func singleCandidate() throws {
        let s = try UtunSelector.select(matching: nil, system: FakeUtun(fds: [8: "utun4"], addrs: [:]))
        #expect(s.fd == 8)
    }

    @Test func twoCandidatesPicksTheApplied() throws {
        let sys = FakeUtun(fds: [8: "utun4", 9: "utun5"], addrs: ["utun5": "10.8.0.2"])
        #expect(try UtunSelector.select(matching: "10.8.0.2", system: sys).fd == 9)
    }

    /// The S7 `s7fdrule` layout: a lingering dup on utun11 plus NE's fd and a live dup on utun12.
    @Test func lingeringDupOnOldInterface() throws {
        let sys = FakeUtun(fds: [7: "utun11", 8: "utun12", 10: "utun12"], addrs: ["utun12": "10.87.0.2", "utun11": "10.86.0.2"])
        let s = try UtunSelector.select(matching: "10.87.0.2", system: sys)
        #expect(s.fd == 8 && s.interface == "utun12" && s.candidates == 3)
    }

    /// T17: an IPv6-only plan selects by its IPv6 address.
    @Test func ipv6OnlyPlanSelects() throws {
        let sys = FakeUtun(fds: [8: "utun4", 9: "utun5"], addrs: ["utun5": "fd00::2"])
        let plan = NetworkPlan(ipv6: [.init("fd00::2", 64)], remoteAddress: "2001:db8::1")
        #expect(try UtunSelector.select(matching: plan.primaryAddress, system: sys).fd == 9)
    }

    @Test func ambiguityIsAnError() {
        let sys = FakeUtun(fds: [7: "utun1", 8: "utun2"], addrs: ["utun1": "10.0.0.2", "utun2": "10.0.0.2"])
        #expect(throws: LPTunnelError.self) { try UtunSelector.select(matching: "10.0.0.2", system: sys) }
        #expect(throws: LPTunnelError.self) { try UtunSelector.select(matching: nil, system: sys) }
        #expect(throws: LPTunnelError.self) { try UtunSelector.select(matching: "1.1.1.1", system: FakeUtun(fds: [:], addrs: [:])) }
    }

    @Test func darwinSystemFindsNoUtunInTheTestProcess() {
        #expect(DarwinUtunSystem().utunControlFDs().isEmpty)
    }
}

@Suite(.serialized) struct PacketFlowPumpTests {
    /// Open AF_UNIX sockets (other suites run in parallel and open files, so only these are counted).
    static func openFDs() -> Int {
        (0..<4096).reduce(0) { n, fd in
            var ss = sockaddr_storage(); var l = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let ok = withUnsafeMutablePointer(to: &ss) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(Int32(fd), $0, &l) == 0 } }
            return ok && ss.ss_family == UInt8(AF_UNIX) ? n + 1 : n
        }
    }

    @Test func socketBuffersAreAtLeast1MB() throws {
        let p = try SocketPair.make()
        defer { close(p.engineEnd); close(p.pumpEnd) }
        for fd in [p.engineEnd, p.pumpEnd] {
            let b = SocketPair.bufferSizes(fd)
            #expect(b.snd >= SocketPair.minBuffer && b.rcv >= SocketPair.minBuffer)
        }
    }

    @Test func framingBothDirectionsV4AndV6() async throws {
        let flow = FakeFlow()
        let pump = PacketFlowPump(flow: flow)
        let p = try SocketPair.make()
        pump.attach(p.pumpEnd)
        #expect(await waitUntil { flow.outstanding == 1 })
        // flow → engine: AF header added
        flow.deliver([Data([0x45, 1, 2, 3])], AF_INET)
        var buf = [UInt8](repeating: 0, count: 64)
        #expect(await waitUntil { flow.outstanding == 1 })
        let n = recv(p.engineEnd, &buf, buf.count, 0)
        #expect(n == 8 && Array(buf[0..<4]) == [0, 0, 0, UInt8(AF_INET)] && Array(buf[4..<8]) == [0x45, 1, 2, 3])
        // engine → flow: AF header stripped, protocol kept
        let frame: [UInt8] = [0, 0, 0, UInt8(AF_INET6), 0x60, 9, 9]
        _ = send(p.engineEnd, frame, frame.count, 0)
        #expect(await waitUntil { flow.written.count == 1 })
        #expect(flow.written[0].0 == Data([0x60, 9, 9]) && flow.written[0].1 == AF_INET6)
        pump.detach()
        #expect(await waitUntil { pump.stats.readers == 0 })
        close(p.engineEnd)
        pump.endSession()
    }

    /// L3: an empty packet from the flow is dropped (it used to trap indexing past the AF header); the next one passes.
    @Test func emptyPacketIsDroppedNotATrap() async throws {
        let flow = FakeFlow()
        let pump = PacketFlowPump(flow: flow)
        let p = try SocketPair.make()
        pump.attach(p.pumpEnd)
        #expect(await waitUntil { flow.outstanding == 1 })
        flow.deliver([Data(), Data([0x45, 7])], AF_INET)
        #expect(await waitUntil { flow.outstanding == 1 })
        var buf = [UInt8](repeating: 0, count: 64)
        let n = recv(p.engineEnd, &buf, buf.count, 0)
        #expect(n == 6 && Array(buf[4..<6]) == [0x45, 7])
        #expect(pump.stats.dropped == 1)
        pump.detach()
        #expect(await waitUntil { pump.stats.readers == 0 })
        close(p.engineEnd)
        pump.endSession()
    }

    /// One outstanding read per session across 20 attach/detach cycles; detached readers exit within a poll period
    /// and close their fd; packets read while nothing is attached are dropped and the read re-armed.
    @Test func oneReadPerSessionAndNoFDLeak() async throws {
        let base = Self.openFDs()
        let flow = FakeFlow()
        let pump = PacketFlowPump(flow: flow)
        for _ in 0..<20 {
            let p = try SocketPair.make()
            pump.attach(p.pumpEnd)
            #expect(flow.outstanding == 1)
            pump.detach()
            close(p.engineEnd)
            #expect(await waitUntil { pump.stats.readers == 0 })
        }
        #expect(flow.s.withLock { $0.reads } == 1)
        flow.deliver([Data([1])], AF_INET)               // nothing attached: dropped, read re-armed
        #expect(pump.stats.dropped == 1 && flow.outstanding == 1)
        #expect(await waitUntil { Self.openFDs() == base })
        pump.endSession()
        flow.deliver([Data([1])], AF_INET)
        #expect(flow.outstanding == 0)                    // the session ended: no re-arm
    }

    /// NEW-3: an attach after `endSession()` creates no source, arms no read and closes the pump end at once (the
    /// pump owns it): the engine end sees its peer gone.
    @Test func attachAfterEndSessionClosesTheFD() async throws {
        let flow = FakeFlow()
        let pump = PacketFlowPump(flow: flow)
        pump.endSession()
        let p = try SocketPair.make()
        defer { close(p.engineEnd) }
        pump.attach(p.pumpEnd)
        #expect(pump.stats.readers == 0)
        #expect(flow.s.withLock { $0.reads } == 0 && flow.outstanding == 0)
        let byte: [UInt8] = [0, 0, 0, UInt8(AF_INET), 0x45]
        #expect(send(p.engineEnd, byte, byte.count, 0) < 0)          // peer closed
        pump.endSession()                                            // still idempotent
        #expect(pump.stats.readers == 0)
    }

    @Test func attachRetiresThePreviousFD() async throws {
        let flow = FakeFlow()
        let pump = PacketFlowPump(flow: flow)
        let a = try SocketPair.make(), b = try SocketPair.make()
        pump.attach(a.pumpEnd)
        pump.attach(b.pumpEnd)
        #expect(await waitUntil { pump.stats.readers == 1 })
        pump.endSession()
        #expect(await waitUntil { pump.stats.readers == 0 })
        close(a.engineEnd); close(b.engineEnd)
    }

    /// Review nit: an old attempt's stop (detach of ITS fd) after a newer attempt attached leaves the newer one live.
    @Test func detachOfASupersededFDKeepsTheLiveOne() async throws {
        let flow = FakeFlow()
        let pump = PacketFlowPump(flow: flow)
        let a = try SocketPair.make(), b = try SocketPair.make()
        pump.attach(a.pumpEnd)
        pump.attach(b.pumpEnd)
        #expect(await waitUntil { pump.stats.readers == 1 })
        pump.detach(a.pumpEnd)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(pump.stats.readers == 1)
        pump.detach(b.pumpEnd)
        #expect(await waitUntil { pump.stats.readers == 0 })
        pump.endSession()
        close(a.engineEnd); close(b.engineEnd)
    }
}
