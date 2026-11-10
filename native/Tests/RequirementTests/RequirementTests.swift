import Foundation
import LPWire
import Security
import Testing

// DESIGN §5.3, §15.1: this bundle compiles Shared/ActiveRequirements.swift exactly as the app and extension do and
// holds the expected strings as literals. It runs under the Unit test plan (Debug: LP_DEV_SIGNING) AND the
// UnitRelease plan (Release: no dev clause), so both configurations' requirements are checked.

let releaseApp = #"anchor apple generic and identifier "io.github.steiale.lockplus.mac" and (certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13]) and certificate leaf[subject.OU] = "M53GHX9FAY""#
let releaseExt = #"anchor apple generic and identifier "io.github.steiale.lockplus.mac.tunnel" and (certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13]) and certificate leaf[subject.OU] = "M53GHX9FAY""#
let devApp = #"anchor apple generic and identifier "io.github.steiale.lockplus.mac" and ((certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13]) or (certificate 1[field.1.2.840.113635.100.6.2.1] and certificate leaf[field.1.2.840.113635.100.6.1.12])) and certificate leaf[subject.OU] = "M53GHX9FAY""#
let devExt = #"anchor apple generic and identifier "io.github.steiale.lockplus.mac.tunnel" and ((certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13]) or (certificate 1[field.1.2.840.113635.100.6.2.1] and certificate leaf[field.1.2.840.113635.100.6.1.12])) and certificate leaf[subject.OU] = "M53GHX9FAY""#

func compiles(_ text: String) -> Bool {
    var req: SecRequirement?
    return SecRequirementCreateWithString(text as CFString, [], &req) == errSecSuccess && req != nil
}

@Suite struct RequirementTests {
    #if LP_DEV_SIGNING
    @Test func debugAndFaultInjectionAdmitAppleDevelopment() {
        #expect(APP_REQ == devApp)
        #expect(EXT_REQ == devExt)
        // Fable optional tightening: the WWDR intermediate alone isn't enough; the leaf must be a Mac Development cert.
        let devBranch = "certificate 1[field.1.2.840.113635.100.6.2.1] and certificate leaf[field.1.2.840.113635.100.6.1.12]"
        #expect(APP_REQ.contains(devBranch) && EXT_REQ.contains(devBranch))
    }
    #else
    @Test func releasePinsDeveloperIDOnly() {
        #expect(APP_REQ == releaseApp)
        #expect(EXT_REQ == releaseExt)
        #expect(!APP_REQ.contains("113635.100.6.2.1]") && !EXT_REQ.contains("113635.100.6.2.1]"))
    }
    #endif

    /// The FaultInjection packetFlow switch (Shared/FaultInjectionSwitches.swift) is honoured only under
    /// LP_FAULT_INJECTION. Debug (Unit) and Release (UnitRelease) ignore the key; verify.sh static also asserts that the
    /// key string is absent from every Release Mach-O.
    @Test func faultInjectionPacketFlowSwitchOnlyInFaultInjectionBuilds() {
        let pc: [String: Any] = ["lp.fi.dataPlane": "packetFlow"]
        let opts: [String: NSObject] = ["lp.fi.dataPlane": "packetFlow" as NSString]
        #if LP_FAULT_INJECTION
        #expect(FaultInjectionSwitches.forcesPacketFlow(providerConfiguration: pc, startOptions: nil))
        #expect(FaultInjectionSwitches.forcesPacketFlow(providerConfiguration: nil, startOptions: opts))
        #expect(!FaultInjectionSwitches.forcesPacketFlow(providerConfiguration: ["lp.fi.dataPlane": "utunFD"], startOptions: nil))
        #else
        #expect(!FaultInjectionSwitches.forcesPacketFlow(providerConfiguration: pc, startOptions: opts))
        #endif
        #expect(!FaultInjectionSwitches.forcesPacketFlow(providerConfiguration: nil, startOptions: nil))
    }

    /// A malformed string is a fatal error inside setCodeSigningRequirement, so every literal must compile.
    @Test(arguments: [APP_REQ, EXT_REQ, releaseApp, releaseExt, devApp, devExt])
    func compilesAsARequirement(_ text: String) { #expect(compiles(text)) }

    @Test func packageReleaseStringsMatchTheLiterals() {
        #expect(SigningRequirements.appReq(signer: SigningRequirements.releaseSigner) == releaseApp)
        #expect(SigningRequirements.extReq(signer: SigningRequirements.releaseSigner) == releaseExt)
    }

    @Test func requirementsPinTeamAndIdentifiers() {
        for r in [APP_REQ, EXT_REQ] {
            #expect(r.hasPrefix("anchor apple generic and identifier "))
            #expect(r.hasSuffix(#"certificate leaf[subject.OU] = "M53GHX9FAY""#))
        }
        #expect(APP_REQ.contains(#"identifier "io.github.steiale.lockplus.mac" "#))
        #expect(EXT_REQ.contains(#"identifier "io.github.steiale.lockplus.mac.tunnel" "#))
    }
}
