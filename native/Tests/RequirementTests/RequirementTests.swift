import Foundation
import LPWire
import Security
import Testing

// DESIGN §5.3, §15.1: this bundle compiles Shared/ActiveRequirements.swift exactly as the app and extension do and
// holds the expected strings as literals. It runs under the Unit test plan (Debug: LP_DEV_SIGNING) AND the
// UnitRelease plan (Release: no dev clause), so both configurations' requirements are checked.

let releaseApp = #"anchor apple generic and identifier "io.github.steiale.lockplus.mac" and (certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13]) and info [CFBundleVersion] >= "200027" and certificate leaf[subject.OU] = "M53GHX9FAY""#
let releaseExt = #"anchor apple generic and identifier "io.github.steiale.lockplus.mac.tunnel" and (certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13]) and certificate leaf[subject.OU] = "M53GHX9FAY""#
let devApp = #"anchor apple generic and identifier "io.github.steiale.lockplus.mac" and ((certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13]) or (certificate 1[field.1.2.840.113635.100.6.2.1] and certificate leaf[field.1.2.840.113635.100.6.1.12])) and info [CFBundleVersion] >= "200027" and certificate leaf[subject.OU] = "M53GHX9FAY""#
let devExt = #"anchor apple generic and identifier "io.github.steiale.lockplus.mac.tunnel" and ((certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13]) or (certificate 1[field.1.2.840.113635.100.6.2.1] and certificate leaf[field.1.2.840.113635.100.6.1.12])) and certificate leaf[subject.OU] = "M53GHX9FAY""#
let releaseValidator = #"anchor apple generic and identifier "io.github.steiale.lockplus.mac.validator" and (certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13]) and certificate leaf[subject.OU] = "M53GHX9FAY""#
let devValidator = #"anchor apple generic and identifier "io.github.steiale.lockplus.mac.validator" and ((certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13]) or (certificate 1[field.1.2.840.113635.100.6.2.1] and certificate leaf[field.1.2.840.113635.100.6.1.12])) and certificate leaf[subject.OU] = "M53GHX9FAY""#

func compiles(_ text: String) -> Bool {
    var req: SecRequirement?
    return SecRequirementCreateWithString(text as CFString, [], &req) == errSecSuccess && req != nil
}

@Suite struct RequirementTests {
    #if LP_DEV_SIGNING
    @Test func debugAndFaultInjectionAdmitAppleDevelopment() {
        #expect(APP_REQ == devApp)
        #expect(EXT_REQ == devExt)
        #expect(VALIDATOR_REQ == devValidator)
        // Fable optional tightening: the WWDR intermediate alone isn't enough; the leaf must be a Mac Development cert.
        let devBranch = "certificate 1[field.1.2.840.113635.100.6.2.1] and certificate leaf[field.1.2.840.113635.100.6.1.12]"
        #expect(APP_REQ.contains(devBranch) && EXT_REQ.contains(devBranch) && VALIDATOR_REQ.contains(devBranch))
    }
    #else
    @Test func releasePinsDeveloperIDOnly() {
        #expect(APP_REQ == releaseApp)
        #expect(EXT_REQ == releaseExt)
        #expect(VALIDATOR_REQ == releaseValidator)
        #expect(![APP_REQ, EXT_REQ, VALIDATOR_REQ].contains { $0.contains("113635.100.6.2.1]") })
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
    @Test(arguments: [APP_REQ, EXT_REQ, VALIDATOR_REQ, releaseApp, releaseExt, devApp, devExt, releaseValidator, devValidator])
    func compilesAsARequirement(_ text: String) { #expect(compiles(text)) }

    @Test func packageReleaseStringsMatchTheLiterals() {
        #expect(SigningRequirements.appReq(signer: SigningRequirements.releaseSigner) == releaseApp)
        #expect(SigningRequirements.extReq(signer: SigningRequirements.releaseSigner) == releaseExt)
        #expect(SigningRequirements.validatorReq(signer: SigningRequirements.releaseSigner) == releaseValidator)
    }

    @Test func requirementsPinTeamAndIdentifiers() {
        for r in [APP_REQ, EXT_REQ, VALIDATOR_REQ] {
            #expect(r.hasPrefix("anchor apple generic and identifier "))
            #expect(r.hasSuffix(#"certificate leaf[subject.OU] = "M53GHX9FAY""#))
        }
        #expect(APP_REQ.contains(#"identifier "io.github.steiale.lockplus.mac" "#))
        #expect(EXT_REQ.contains(#"identifier "io.github.steiale.lockplus.mac.tunnel" "#))
        #expect(VALIDATOR_REQ.contains(#"identifier "io.github.steiale.lockplus.mac.validator" "#))
    }

    // MARK: 2.0.2 build floor (PLAN-2.0.2 §2, W8)

    /// The floor clause is in the app requirement of both configurations, before the team clause; never in the others.
    @Test func releaseAppRequirementCarriesTheBuildFloor() {
        let clause = #" and info [CFBundleVersion] >= "\#(SigningRequirements.minimumAppBuild)" and certificate leaf[subject.OU] = "M53GHX9FAY""#
        #expect(releaseApp.hasSuffix(clause))
        #expect(!releaseExt.contains("CFBundleVersion") && !releaseValidator.contains("CFBundleVersion"))
    }

    @Test func debugAppRequirementCarriesTheBuildFloor() {
        let clause = #" and info [CFBundleVersion] >= "\#(SigningRequirements.minimumAppBuild)" and certificate leaf[subject.OU] = "M53GHX9FAY""#
        #expect(devApp.hasSuffix(clause) && APP_REQ.hasSuffix(clause))
        #expect(!devExt.contains("CFBundleVersion") && !devValidator.contains("CFBundleVersion"))
        #expect(!EXT_REQ.contains("CFBundleVersion") && !VALIDATOR_REQ.contains("CFBundleVersion"))
    }

    /// The floor is this build: the integer part of this test bundle's CFBundleVersion (Tests.xcconfig generates the
    /// Info.plist from CURRENT_PROJECT_VERSION, `<LP_BUILD_NUMBER>` in Release, `<LP_BUILD_NUMBER>.<stamp>` in Debug).
    @Test func floorEqualsThisBuild() throws {
        let floor = SigningRequirements.minimumAppBuild
        #expect(!floor.isEmpty && floor.allSatisfy { $0.isASCII && $0.isNumber })
        let v = try #require(Bundle(for: BundleMarker.self).object(forInfoDictionaryKey: "CFBundleVersion") as? String)
        #expect(v.split(separator: ".", omittingEmptySubsequences: false).first.map(String.init) == floor)
    }

    /// An unquoted floor is a syntax error (F1), so the quotes are not an optional nicety.
    @Test func unquotedFloorDoesNotCompile() {
        #expect(!compiles("info [CFBundleVersion] >= 200025"))
        #expect(compiles(#"info [CFBundleVersion] >= "200025""#))
    }

    /// F1 on real signatures: ad-hoc-signed fixture bundles (a copy of /usr/bin/true) with these CFBundleVersions,
    /// checked statically against `info [CFBundleVersion] >= "200024"`. Numeric order: string order would accept
    /// `99999` and reject `1000000`.
    @Test(arguments: [("200023", false), ("200024", true), ("200024.31415", true), ("200100", true), ("1000000", true), ("99999", false)])
    func floorComparesNumerically(_ c: (version: String, accepted: Bool)) throws {
        let fixture = try FloorFixture(version: c.version)
        defer { fixture.remove() }
        #expect(try fixture.satisfies(#"info [CFBundleVersion] >= "200024""#) == c.accepted, "\(c.version)")
    }
}

/// `Bundle(for:)` anchor for this test bundle.
private final class BundleMarker {}

/// A throwaway ad-hoc-signed app bundle under the per-user temporary directory (`/var/folders/…`, never /tmp).
private struct FloorFixture {
    let root: URL
    let app: URL

    init(version: String) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "lp-floor-\(UUID().uuidString)", directoryHint: .isDirectory)
        app = root.appending(path: "Floor.app", directoryHint: .isDirectory)
        let macOS = app.appending(path: "Contents/MacOS", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(filePath: "/usr/bin/true"), to: macOS.appending(path: "Floor"))
        let info: [String: Any] = ["CFBundleIdentifier": "io.github.steiale.lockplus.tests.floor", "CFBundleExecutable": "Floor",
                                   "CFBundlePackageType": "APPL", "CFBundleVersion": version]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appending(path: "Contents/Info.plist"))
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/codesign")
        p.arguments = ["-s", "-", "-f", app.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
    }

    func satisfies(_ requirement: String) throws -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { throw CocoaError(.fileReadUnknown) }
        var req: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess, let req else { throw CocoaError(.fileReadCorruptFile) }
        let rc = SecStaticCodeCheckValidity(code, [], req)
        guard rc == errSecSuccess || rc == errSecCSReqFailed else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(rc)) }
        return rc == errSecSuccess
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
