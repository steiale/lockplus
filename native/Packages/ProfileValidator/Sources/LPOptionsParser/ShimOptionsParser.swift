import Foundation
import LPParsing
import OpenVPN3Shim

/// LPParsing's [6] seam (`OpenVPN3OptionsParsing`) over the shim's OptionList parser (DESIGN §8.1). The shim applies
/// openvpn3's client profile limits (size, line length, directive size). Used by the validator service (every
/// evaluation) and by the extension (the differential on the session's own payload at start).
public struct ShimOptionsParser: OpenVPN3OptionsParsing {
    public struct Refused: Error, Sendable {
        public let reason: String
    }

    public init() {}

    public func parse(canonical: String) throws -> [[String]] {
        try Self.parse(bytes: Array(canonical.utf8))
    }

    public static func parse(bytes: some ContiguousBytes) throws -> [[String]] {
        var err: NSString?
        let r = bytes.withUnsafeBytes { b -> [[String]]? in
            guard let base = b.baseAddress else { return [] }
            return LPOpenVPN3Profile.parseOptionsBytes(base, length: b.count, error: &err)
        }
        guard let r else { throw Refused(reason: (err as String?) ?? "refused") }
        return r
    }
}
