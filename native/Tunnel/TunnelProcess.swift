import Foundation
import NetworkExtension
import LPWire
import OpenVPN3Shim
import os
import TunnelEngine
import WireGuardKitGo

/// Process-scope state of the extension (DESIGN §5.1): the XPC listener belongs to the process, not to a provider
/// instance. Everything here is nonisolated; `main.swift` only calls these functions.
enum TunnelProcess {
    static let log = Logger(subsystem: "io.github.steiale.lockplus.mac.tunnel", category: "process")

    /// Process-lifetime listener (its delegate is weak; this global is the strong owner).
    // SAFETY: nonisolated(unsafe) — written exactly once from main.swift's startup code before dispatchMain(), never
    // read afterwards; it exists only to keep the listener alive.
    nonisolated(unsafe) private static var listener: TunnelServiceListener?

    static func logFirstLight() {
        // OPENSSL_init_crypto(OPENSSL_INIT_NO_LOAD_CONFIG) before anything else touches OpenSSL (S13 A3, §8.1).
        LPOpenVPN3Core.initializeCrypto()
        log.notice("first light pid=\(getpid(), privacy: .public) uid=\(getuid(), privacy: .public) mach=\(Bundle.main.lpMachServiceName ?? "<missing>", privacy: .public) \(engineVersions(), privacy: .public)")
    }

    /// `autoreleasepool { NEProvider.startSystemExtensionMode(); <listener>.start() }` (ref/toolchain §3.4).
    static func startSystemExtensionMode() {
        autoreleasepool {
            NEProvider.startSystemExtensionMode()
            startListener()
        }
    }

    private static func startListener() {
        guard let name = Bundle.main.lpMachServiceName else {
            log.fault("NEMachServiceName missing from Info.plist; no XPC listener")
            return
        }
        let engine = TunnelEngineAssembly.shared
        let l = TunnelServiceListener(machServiceName: name, peerRequirement: APP_REQ, backend: engine.backend,
                                      registry: engine.registry)
        l.start()
        listener = l
    }

    /// Both engines are linked into this one binary (S7: GO, one extension). Also proves the link at build time.
    static func engineVersions() -> String {
        // Go returns a C-heap string the caller frees (§9.2 Go entry rules).
        let wg = wgVersion().map { p -> String in defer { free(UnsafeMutablePointer(mutating: p)) }; return String(cString: p) } ?? "?"
        return "wireguard-go=\(wg) openvpn3=\(LPOpenVPN3Core.corePlatform) \(LPOpenVPN3Core.opensslVersion)"
    }
}
