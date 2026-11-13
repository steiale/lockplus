// LPWire/SigningRequirements.swift — identical in every configuration (DESIGN §5.3).
//
// Requirement strings are single-line constants with no comments, so the compiled requirement is the reviewed text.
// Annotated form of `releaseSigner`:
//   anchor apple generic
//     and certificate 1[field.1.2.840.113635.100.6.2.6]     Developer ID CA (G1 and G2; G2 verified, P1 skeleton)
//     and certificate leaf[field.1.2.840.113635.100.6.1.13] Developer ID Application leaf
//     and certificate leaf[subject.OU] = "M53GHX9FAY"       team
// The app's requirement (APP_REQ, applied by the extension and the validator service) also carries the build floor
// `info [CFBundleVersion] >= "<minimumAppBuild>"` before the team clause (2.0.2, PLAN-2.0.2 §2): numeric comparison,
// value quoted (unquoted is a syntax error), so every older signed LockPlus stops being a trusted peer.
//
// The dev clause (Apple Development, WWDR OID ...100.6.2.1) is NOT here. It lives in the targets'
// Shared/ActiveRequirements.swift under LP_DEV_SIGNING, because SwiftPM never sees Xcode configuration conditions.
// Package code receives APP_REQ/EXT_REQ only as init parameters (TunnelServiceListener, TunnelServiceClient; §2.2).

public enum SigningRequirements {
    public static let teamID = "M53GHX9FAY"
    public static let appIdentifier = "io.github.steiale.lockplus.mac"
    public static let extensionIdentifier = "io.github.steiale.lockplus.mac.tunnel"
    public static let validatorIdentifier = "io.github.steiale.lockplus.mac.validator"

    /// The oldest app build the extension and the validator accept as a peer. Always this release's LP_BUILD_NUMBER
    /// (Tools/release/version-check.sh enforces equality with Config/Version.xcconfig and with common.sh's MIN_APP_BUILD).
    /// Decimal digits only. Debug builds (`<build>.<stamp>`) compare numerically, so they pass their own floor.
    public static let minimumAppBuild = "200027"

    public static let releaseSigner = #"(certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13])"#

    public static func appReq(signer: String, minimumBuild: String = minimumAppBuild) -> String {
        #"anchor apple generic and identifier "io.github.steiale.lockplus.mac" and "# + signer
            + #" and info [CFBundleVersion] >= ""# + minimumBuild + #"" and certificate leaf[subject.OU] = "M53GHX9FAY""#
    }

    public static func extReq(signer: String) -> String {
        #"anchor apple generic and identifier "io.github.steiale.lockplus.mac.tunnel" and "# + signer + #" and certificate leaf[subject.OU] = "M53GHX9FAY""#
    }

    /// The validator service's requirement (2.0.2, PLAN-2.0.2 §1.4), applied by the app's `ValidatorClient`.
    public static func validatorReq(signer: String) -> String {
        #"anchor apple generic and identifier "io.github.steiale.lockplus.mac.validator" and "# + signer + #" and certificate leaf[subject.OU] = "M53GHX9FAY""#
    }
}
