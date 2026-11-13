import Foundation
import LPValidatorService
import LPWire
import OpenVPN3Shim

/// The validator service process (PLAN-2.0.2 §1.1, §1.6): sandboxed (`com.apple.security.app-sandbox` is its only
/// entitlement), network-less, running as the user. Bytes in, fixed-shape data out.
enum ValidatorProcess {
    /// Never returns: `resume()` on a service listener runs the XPC main loop.
    static func run() -> Never {
        // First, before any parsing: openvpn3's OpenSSL, with no config file loaded (the sandbox has none anyway).
        LPOpenVPN3Core.initializeCrypto()
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let handler = ValidatorServiceHandler(build: build)
        // The peer requirement (APP_REQ) is applied per connection by the delegate, never on the listener: a service
        // listener has no listener connection, and `setConnectionCodeSigningRequirement` on it crashes the service at
        // every launch (200026 E2E; the SDK header allows it only on anonymous and Mach-service listeners; lint
        // `lp_listener_requirement`). A malformed requirement would raise there; RequirementTests make that unreachable.
        let delegate = ValidatorListenerDelegate(handler: handler, peerRequirement: APP_REQ)
        let listener = NSXPCListener.service()
        listener.delegate = delegate
        listener.resume()
        fatalError("NSXPCListener.service().resume() returned")
    }
}
