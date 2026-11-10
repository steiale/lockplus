import LPModel
// Cipher and digest classification for `cipher` / `auth` (DESIGN §8.2 TLS/crypto rows, §8.6).
//
// openvpn3's data-channel algorithms (cryptoalgs.hpp): AES-128/192/256-CBC, AES-128/192/256-GCM, CHACHA20-POLY1305,
// plus the 64-bit-block DES-CBC, DES-EDE3-CBC and BF-CBC, which need `enableLegacyAlgorithms`. That flag is NEVER
// set (owner decision, draft 7, Conflicts aj), so every 64-bit-block cipher, `cipher none` and every digest under
// 160 bits are rejected at import.

public enum OVPNCipherClass: Sendable, Equatable {
    /// AES-GCM or CHACHA20-POLY1305: the preferred set.
    case aead
    /// A 128-bit-block CBC cipher openvpn3 supports with `enableNonPreferredDCAlgorithms` (the Acme case).
    case cbc
    /// A 64-bit-block cipher (BF, DES, 3DES, DESX, RC2, RC5, CAST5, IDEA): needs legacy algorithms → rejected.
    case legacy64BitBlock
    /// `cipher none` → rejected.
    case none
    /// Not a cipher openvpn3 knows (it would fail the profile at [7]) → rejected.
    case unknown
}

public enum OVPNDigestClass: Sendable, Equatable {
    /// SHA1 and stronger digests openvpn3 supports.
    case ok
    /// `none` (no HMAC; only meaningful with AEAD).
    case none
    /// Under 160 bits (MD5, MD4, …): needs legacy algorithms → rejected.
    case weak
    /// Not a digest openvpn3 knows → rejected.
    case unknown
}

public enum OVPNCrypto {
    static let aeadCiphers: Set<String> = ["AES-128-GCM", "AES-192-GCM", "AES-256-GCM", "CHACHA20-POLY1305"]
    static let cbcCiphers: Set<String> = ["AES-128-CBC", "AES-192-CBC", "AES-256-CBC"]
    /// Prefixes of 64-bit-block cipher families (OpenSSL names; "3DES" is a common alias).
    static let legacyPrefixes = ["BF-", "DES-", "DES3", "DESX", "RC2-", "RC5-", "CAST5-", "CAST-", "IDEA-", "3DES"]
    static let legacyExact: Set<String> = ["BF", "DES", "DESX", "RC2", "RC5", "CAST5", "CAST", "IDEA", "DES-EDE", "DES-EDE3"]

    public static func classifyCipher(_ name: String) -> OVPNCipherClass {
        let u = name.uppercased()
        if u == "NONE" { return .none }
        if aeadCiphers.contains(u) { return .aead }
        if cbcCiphers.contains(u) { return .cbc }
        if legacyExact.contains(u) || legacyPrefixes.contains(where: { u.hasPrefix($0) }) { return .legacy64BitBlock }
        return .unknown
    }

    static let strongDigests: Set<String> = ["SHA1", "SHA224", "SHA256", "SHA384", "SHA512", "SHA-1", "SHA-224",
                                             "SHA-256", "SHA-384", "SHA-512", "SHA512-224", "SHA512-256"]
    static let weakDigests: Set<String> = ["MD5", "MD4", "MD2", "MDC2", "RIPEMD128", "RMD128"]

    public static func classifyDigest(_ name: String) -> OVPNDigestClass {
        let u = name.uppercased()
        if u == "NONE" { return .none }
        if strongDigests.contains(u) { return .ok }
        if weakDigests.contains(u) { return .weak }
        return .unknown
    }

    /// Go `isCipherName`: a name safe to show in the UI (cipher names are not secrets; everything else is withheld).
    public static func isDisplayableAlgorithmName(_ s: String) -> Bool {
        let b = Array(s.utf8)
        return !b.isEmpty && b.count <= 64 && b.allSatisfy {
            $0 == 0x2D || ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A)
        }
    }
}
