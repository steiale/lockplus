// Shared/FaultInjectionSwitches.swift — a member of the LockPlus, LockPlusTunnel and RequirementTests targets (DESIGN §7.3, §15.3).
// Switches the leak harness needs that must never exist in a shipped build. The key strings are compiled only under
// LP_FAULT_INJECTION (FaultInjection.xcconfig); in Debug and Release every switch reads as "off" and the strings are
// absent, which verify.sh static (Release Mach-Os) and RequirementTests (Unit + UnitRelease) both assert.
import Foundation

enum FaultInjectionSwitches {
    #if LP_FAULT_INJECTION
    /// `"packetFlow"` under this key, in `providerConfiguration` or the start options, forces `dataPlane = .packetFlow`
    /// for that session, so the §15.3 leak harness can run once per data-plane mode (R13).
    static let dataPlaneKey = "lp.fi.dataPlane"
    #endif

    /// True only in FaultInjection builds, and only when the configuration or the start options ask for `packetFlow`.
    static func forcesPacketFlow(providerConfiguration: [String: Any]?, startOptions: [String: NSObject]?) -> Bool {
        #if LP_FAULT_INJECTION
        (startOptions?[dataPlaneKey] as? String) == "packetFlow" || (providerConfiguration?[dataPlaneKey] as? String) == "packetFlow"
        #else
        false
        #endif
    }
}
