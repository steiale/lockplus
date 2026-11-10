/// Import caps for OpenVPN profiles (DESIGN §3.5, §8.1 [1] and [5]).
public enum OVPNImportLimits {
    /// [1] raw file cap (Go `maxOVPNSize`).
    public static let maxRawBytes = 1 << 20
    /// openvpn3 `MAX_PROFILE_SIZE`: raw canonical bytes + 64 per directive + 16 per argument must stay below this.
    public static let maxProfileAccounting = 262_144
    public static let perDirectiveOverhead = 64
    public static let perArgumentOverhead = 16
    /// openvpn3 `MAX_LINE_SIZE`, applied to every physical line including inline-block bodies.
    public static let maxPhysicalLineBytes = 512
    /// Native cap for a canonical directive line (not inline bodies): the 2.x tokenizer this module ports reads
    /// lines through fgets(257) and rejects 256 bytes, so canonical text re-parses only if every directive line is
    /// ≤ 254 bytes. The extension re-runs [1]–[6] on the canonical text before every start (§8.1), so this is a hard cap.
    public static let maxCanonicalDirectiveLineBytes = 254
    /// openvpn3 `MAX_DIRECTIVE_SIZE`.
    public static let maxDirectiveNameBytes = 64
    /// openvpn3 per-`<connection>` block cap.
    public static let maxConnectionBlockBytes = 4096
}
