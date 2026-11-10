import Foundation
import LPModel

/// Decodes a Go-app OpenVPN keychain value (DESIGN §6.7; port of `decodeSecret` + `LoadCredentials` in
/// internal/ovpn/keychain_darwin.go). Pure: the keychain read itself is the app's Objective-C reader.
///
/// Formats, tried in order:
/// 1. `"b64:" + base64(username + "\n" + basePassword)` (current);
/// 2. hex of the raw `username\npassword` bytes (pre-1.0.50 `security -w`), any case, as Go `hex.DecodeString`;
/// 3. plain text.
/// The value is split on the FIRST "\n": the username before it, the base password after.
public enum LegacyKeychainDecoder {
    public struct Decoded: Sendable {
        public var username: SecretBytes
        /// nil when the value had no "\n" (username only).
        public var basePassword: SecretBytes?
    }

    public enum DecodeError: Error, Sendable, Equatable {
        /// "b64:" prefix with invalid base64 (Go returns an error rather than falling back).
        case invalidBase64
    }

    public static func decode(_ raw: some Collection<UInt8>) -> Result<Decoded, DecodeError> {
        // Every secret-bearing buffer below is a uniquely owned array/Data that is zeroed in place (never a COW copy
        // of another buffer), so no un-zeroed duplicate is left behind.
        var bytes: [UInt8] = []
        bytes.reserveCapacity(raw.count)
        bytes.append(contentsOf: raw)
        defer { wipe(&bytes) }
        var payload: [UInt8]
        switch decodePayload(of: bytes) {
        case .success(let p): payload = p
        case .failure(let e): return .failure(e)
        }
        defer { wipe(&payload) }
        if let nl = payload.firstIndex(of: 0x0A) {
            return .success(Decoded(username: SecretBytes(copying: payload[..<nl]),
                                    basePassword: SecretBytes(copying: payload[(nl + 1)...])))
        }
        return .success(Decoded(username: SecretBytes(copying: payload), basePassword: nil))
    }

    /// The decoded `username\npassword` bytes, in a fresh array that never aliases `bytes`.
    private static func decodePayload(of bytes: [UInt8]) -> Result<[UInt8], DecodeError> {
        if bytes.starts(with: Array("b64:".utf8)) {
            // Go's base64 decoder skips "\r" and "\n"; nothing else is tolerated.
            var b64 = bytes.dropFirst(4).filter { $0 != 0x0A && $0 != 0x0D }
            defer { wipe(&b64) }
            var encoded = Data(b64)
            defer { wipe(&encoded) }
            guard var decoded = Data(base64Encoded: encoded) else { return .failure(.invalidBase64) }
            defer { wipe(&decoded) }
            return .success(Array(decoded))
        }
        if let h = hexDecode(bytes), !h.isEmpty { return .success(h) }
        return .success(bytes.withUnsafeBufferPointer { Array($0) })      // a copy, so each side is zeroed on its own
    }

    private static func wipe(_ a: inout [UInt8]) {
        a.withUnsafeMutableBytes { if let p = $0.baseAddress { _ = memset_s(p, $0.count, 0, $0.count) } }
    }

    private static func wipe(_ d: inout Data) {
        d.withUnsafeMutableBytes { if let p = $0.baseAddress { _ = memset_s(p, $0.count, 0, $0.count) } }
    }

    /// Go `hex.DecodeString`: even length, [0-9a-fA-F] only.
    static func hexDecode(_ b: [UInt8]) -> [UInt8]? {
        guard b.count % 2 == 0 else { return nil }
        func v(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30...0x39: c - 0x30
            case 0x61...0x66: c - 0x61 + 10
            case 0x41...0x46: c - 0x41 + 10
            default: nil
            }
        }
        var out: [UInt8] = []
        out.reserveCapacity(b.count / 2)
        var i = 0
        while i < b.count {
            guard let hi = v(b[i]), let lo = v(b[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }
}

/// Display names from file or zip-entry names (DESIGN §3.5 `sanitizeProfileName`, the native successor of Go
/// `sanitizeTunnelName`). Names are display-only (§3.1 `ProfileName`): Unicode is kept (old names like `work.vpn`
/// that the Go rules rejected are valid now, §13.1); C0/C1 controls and line/paragraph separators are removed,
/// whitespace runs collapse, the result is NFC, trimmed and capped at 64 grapheme clusters. Empty → "Profile".
public enum ProfileNameSanitizer {
    public static func sanitize(_ raw: String, fallback: String = "Profile") -> String {
        var out = ""
        var lastSpace = false
        for s in raw.precomposedStringWithCanonicalMapping.unicodeScalars {
            let cat = s.properties.generalCategory
            if cat == .control || cat == .lineSeparator || cat == .paragraphSeparator || cat == .format || s.properties.isWhitespace {
                if !lastSpace && !out.isEmpty { out.unicodeScalars.append(" ") }
                lastSpace = true
                continue
            }
            out.unicodeScalars.append(s)
            lastSpace = false
        }
        while out.last == " " { out.removeLast() }
        if out.count > 64 {
            out = String(out.prefix(64))
            while out.last == " " { out.removeLast() }
        }
        return out.isEmpty ? fallback : out
    }

    /// The display name for an imported file: the file name without its `.ovpn`/`.conf` extension.
    public static func displayName(forFileName name: String) -> String {
        var base = (name as NSString).lastPathComponent
        for ext in [".ovpn", ".conf"] where base.lowercased().hasSuffix(ext) && base.count > ext.count {
            base.removeLast(ext.count)
        }
        return sanitize(base)
    }
}
