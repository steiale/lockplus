// Shared/ActiveRequirements.swift — a member of the LockPlus, LockPlusTunnel, LockPlusValidator and RequirementTests targets (DESIGN §5.3).
// The Release strings come from LPWire.SigningRequirements; this file only chooses the signer clause per configuration.
import LPWire

#if LP_DEV_SIGNING
// DEV ONLY (O7, Fable security review: signed off): also admit Apple Development (WWDR intermediate OID
// ...100.6.2.1 AND the Mac Development leaf marker ...100.6.1.12, the review's optional tightening, adopted in
// draft 8), because Debug and FaultInjection builds are Apple Development-signed (§2.4).
// LP_DEV_SIGNING is set in Debug.xcconfig (inherited by FaultInjection.xcconfig) and never in Release.xcconfig;
// verify.sh fails if "113635.100.6.2.1" appears in a Release Mach-O or LP_DEV_SIGNING in Release build settings.
let activeSigner = #"((certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13]) or (certificate 1[field.1.2.840.113635.100.6.2.1] and certificate leaf[field.1.2.840.113635.100.6.1.12]))"#
#else
let activeSigner = SigningRequirements.releaseSigner
#endif

/// The app's requirement, applied by the extension's listener (injected into TunnelServiceListener) and, per connection,
/// by the validator service (injected into ValidatorListenerDelegate). Carries the build floor
/// (`SigningRequirements.minimumAppBuild`, 2.0.2).
let APP_REQ = SigningRequirements.appReq(signer: activeSigner)
/// The extension's requirement, applied by the app's client (injected into TunnelServiceClient).
let EXT_REQ = SigningRequirements.extReq(signer: activeSigner)
/// The validator service's requirement (2.0.2), applied by the app's validator client.
let VALIDATOR_REQ = SigningRequirements.validatorReq(signer: activeSigner)
