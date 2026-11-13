import Foundation
import LPModel
import LPWire

// The app's profile model (DESIGN §3.1). LPModel carries the parts shared with the extension (policy, summary,
// auth, import report); the whole record is app-only, integrity-protected on disk (§3.3, §3.4).

enum ProfileOrigin: Codable, Sendable, Equatable {
    case file(String)
    case zip(String)
    /// No longer created (2.0.2 removed QR import); kept so stores written by 2.0.0/2.0.1 still decode. Don't delete.
    case qr
    case editor
    case migratedGo(String)
}

/// `Profile` (§3.1). `name` is display only; every store is keyed by `id`.
struct Profile: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    var name: String
    let kind: VPNProtocolKind
    var policy: NetworkPolicy
    /// OpenVPN only.
    var auth: AuthPolicy?
    /// ≤ 4 KiB
    var notes: String
    var summary: ProfileSummary
    var payloadRevision: UInt64
    var payloadDigest: String
    var metaRevision: UInt64
    var ownerUID: uid_t
    var createdAt: Date
    var updatedAt: Date
    var origin: ProfileOrigin
    var importReport: ImportReport?
    /// §8.1 [7]: false = "Not yet verified" (the extension was unavailable at import). Connect stays disabled until a
    /// later `validateProfile` passes. Always true for WireGuard.
    var engineVerified: Bool
    /// The server issued a CRV1 challenge for this profile before (OTP-class, §8.4).
    var dynamicChallengeSeen: Bool = false

    static let maxNotesBytes = 4096

    /// Known-interactive (draft 6, §8.4): the app prompts BEFORE the first start. `hasSavedPassword` and
    /// `hasSavedPassphrase` come from the app's credential store.
    func preStartAuthKind(hasSavedPassword: Bool, hasSavedPassphrase: Bool) -> AuthKind? {
        guard kind == .openVPN, let a = auth else { return nil }
        if a.staticChallenge != nil { return .staticChallenge }
        if a.needsKeyPassphrase && !hasSavedPassphrase { return .keyPassphrase }
        if a.needsUserPass && (a.appendOTP || !hasSavedPassword) { return .userPass }
        return nil
    }

    /// OTP-class profiles can't be the auto-connect profile (§8.4, §10.4).
    var needsOneTimeCode: Bool {
        guard let a = auth else { return false }
        return a.appendOTP || a.staticChallenge != nil || dynamicChallengeSeen
    }

    /// The NE manager's `localizedDescription` and System Settings name.
    var serverAddress: String { summary.endpoints.first ?? "" }
}

/// §3.1 name rules: 1…64 grapheme clusters, no C0/C1 controls, no leading/trailing whitespace, NFC; unique among the
/// owner's profiles, case- and diacritic-insensitively.
enum ProfileNameRules {
    enum Problem: Error, Sendable, Equatable { case empty, tooLong, controlCharacter, duplicate }

    static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
    }

    static func validate(_ raw: String, existing: [String]) -> Result<String, Problem> {
        let n = normalized(raw)
        if n.isEmpty { return .failure(.empty) }
        if n.count > 64 { return .failure(.tooLong) }
        if n.unicodeScalars.contains(where: { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) }) {
            return .failure(.controlCharacter)
        }
        let key = foldKey(n)
        if existing.contains(where: { foldKey($0) == key }) { return .failure(.duplicate) }
        return .success(n)
    }

    /// A free name: "Work", "Work 2", "Work 3", …
    static func unique(_ raw: String, existing: [String]) -> String {
        let base = String(normalized(raw).prefix(58))
        let start = base.isEmpty ? "Profile" : base
        if case .success(let n) = validate(start, existing: existing) { return n }
        for i in 2...999 {
            if case .success(let n) = validate("\(start) \(i)", existing: existing) { return n }
        }
        return "\(start) \(UUID().uuidString.prefix(4))"
    }

    static func foldKey(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
