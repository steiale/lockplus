import Foundation
import LPModel
import LPWire
import os
import TunnelEngine
import WireGuardKitGo

/// `WireGuardBackend` over libwg-go's C exports (DESIGN §9.2: W3–W6, W10 of the fork). TunnelEngine's
/// WireGuardAdapter makes every call from its serial `workQueue`; the bridge's handle map is mutex-guarded (W7) too.
struct WireGuardGoBackend: WireGuardBackend {
    init() { WireGuardGoLog.installOnce() }

    func turnOn(uapi: SecretBytes, tunFD: Int32) -> Int32 {
        Self.withCString(uapi) { wgTurnOn($0, tunFD) }
    }

    func turnOnPacketFlow(uapi: SecretBytes, socketFD: Int32, mtu: Int32) -> Int32 {
        Self.withCString(uapi) { wgTurnOnPF($0, socketFD, mtu) }
    }

    func turnOff(_ handle: Int32) { wgTurnOff(handle) }

    func setEndpoint(_ handle: Int32, publicKeyHex: String, endpoint: String) -> Int32 {
        let r = wgSetEndpoint(handle, publicKeyHex, endpoint)
        return r == 0 ? 0 : Int32(clamping: min(r, -1))
    }

    func sendHandshake(_ handle: Int32) -> (result: Int32, sentNs: Int64) {
        var ns: Int64 = 0
        let r = wgSendHandshake(handle, &ns)
        return (r, ns)
    }

    func stats(_ handle: Int32) -> String? {
        guard let p = wgGetStats(handle) else { return nil }
        defer { free(p) }                       // Go C-heap string (§9.2 Go entry rules); W5 text carries no keys
        return String(cString: p)
    }

    func isClosed(_ handle: Int32) -> Bool { wgIsClosed(handle) != 0 }

    func bumpSockets(_ handle: Int32) { wgBumpSockets(handle) }

    /// The UAPI text holds the private and preshared keys in hex: hand Go a NUL-terminated copy that is zeroed
    /// right after the call (Go copies it into its own memory, out of our control, §6.5).
    static func withCString<R>(_ s: SecretBytes, _ body: (UnsafePointer<CChar>) -> R) -> R {
        let n = s.count
        let buf = UnsafeMutablePointer<CChar>.allocate(capacity: n + 1)
        defer { memset_s(buf, n + 1, 0, n + 1); buf.deallocate() }
        s.withUnsafeBytes { b in
            if let base = b.baseAddress { memcpy(buf, base, n) }
        }
        buf[n] = 0
        return body(buf)
    }
}

/// W8: Go `Verbosef` (level 0) → `.debug`, `Errorf` (level 1) → `.error`; the message is `.private` (it can name
/// endpoint IPs; wireguard-go logs peers only as public-key prefixes and never logs keys). Errors also reach the
/// LogRing (the app's recent logs); verbose lines only at `.debug` (§14.1).
enum WireGuardGoLog {
    static let log = Logger(subsystem: "io.github.steiale.lockplus.mac.tunnel", category: "wireguard-go")
    private static let installed: Void = { wgSetLogger(nil, wireGuardGoLogCallback) }()
    static func installOnce() { _ = installed }
}

/// The C logger (`logger_fn_t`): a global function, so it captures nothing; it runs synchronously on whatever Go
/// thread logs, touches only `Logger` and the `Mutex` LogRing, and never calls back into Go (§9.2).
func wireGuardGoLogCallback(_ context: UnsafeMutableRawPointer?, _ level: Int32, _ message: UnsafePointer<CChar>?) {
    guard let message else { return }
    let text = String(cString: message).trimmingCharacters(in: .newlines)
    if level == 1 {
        WireGuardGoLog.log.error("\(text, privacy: .private)")
        LogRing.shared.append("wg error: " + text)
    } else {
        WireGuardGoLog.log.debug("\(text, privacy: .private)")
        if EngineLogLevel.current == .debug { LogRing.shared.append("wg: " + text) }
    }
}
