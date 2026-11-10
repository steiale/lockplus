import Foundation

/// Secret bytes in memory (DESIGN §6.5). Locked (best effort), zeroed with `memset_s` on deinit,
/// no reflection, not Codable, not Equatable, no mutating API.
// SAFETY: the buffer is written only inside init and is immutable afterwards; deinit may run on any thread.
public final class SecretBytes: @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let buf: UnsafeMutableRawBufferPointer
    public let count: Int

    public init(copying bytes: some ContiguousBytes) {
        let n = bytes.withUnsafeBytes { $0.count }
        count = n
        buf = .allocate(byteCount: max(n, 1), alignment: 16)
        bytes.withUnsafeBytes { src in
            if let s = src.baseAddress, n > 0 { buf.baseAddress!.copyMemory(from: s, byteCount: n) }
        }
        mlock(buf.baseAddress, buf.count)
    }

    public init(count n: Int, initializingWith body: (UnsafeMutableRawBufferPointer) throws -> Void) rethrows {
        count = n
        buf = .allocate(byteCount: max(n, 1), alignment: 16)
        mlock(buf.baseAddress, buf.count)
        // All stored properties are set, so a throw here still runs `deinit` (zero, munlock, deallocate) exactly once.
        try body(UnsafeMutableRawBufferPointer(rebasing: buf[0..<n]))
    }

    /// Concatenates secrets without an intermediate `Data`/`String` copy.
    public convenience init(concatenating parts: [SecretBytes]) {
        let total = parts.reduce(0) { $0 + $1.count }
        self.init(count: total) { dst in
            var off = 0
            for p in parts {
                p.withUnsafeBytes { src in
                    if let s = src.baseAddress, src.count > 0 { (dst.baseAddress! + off).copyMemory(from: s, byteCount: src.count) }
                }
                off += p.count
            }
        }
    }

    public var isEmpty: Bool { count == 0 }

    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try body(UnsafeRawBufferPointer(rebasing: buf[0..<count]))
    }

    deinit {
        memset_s(buf.baseAddress, buf.count, 0, buf.count)
        munlock(buf.baseAddress, buf.count)
        buf.deallocate()
    }

    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .class) }
}

extension SecretBytes {
    /// Copy for the engine boundary (e.g. a C string). The caller zeroes or drops the result immediately.
    public func copyBytes() -> [UInt8] { withUnsafeBytes { Array($0) } }

    public static func fromData(_ d: Data?) -> SecretBytes? { d.map { SecretBytes(copying: $0) } }

    /// Constant-time comparison (tests and the CRV1 retry check only).
    public func constantTimeEquals(_ other: SecretBytes) -> Bool {
        guard count == other.count else { return false }
        return withUnsafeBytes { a in other.withUnsafeBytes { b in
            var d: UInt8 = 0
            for i in 0..<a.count { d |= a[i] ^ b[i] }
            return d == 0
        } }
    }
}
