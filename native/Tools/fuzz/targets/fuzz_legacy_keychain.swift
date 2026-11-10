// libFuzzer target: the Go-app legacy keychain value decoder (§6.7) and the RFC 3339 reader of the migration.
@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzOne(_ data: UnsafePointer<UInt8>, _ size: Int) -> Int32 {
    let bytes = Array(UnsafeBufferPointer(start: data, count: size))
    _ = LegacyKeychainDecoder.decode(bytes)
    _ = RFC3339.parse(String(decoding: bytes.prefix(64), as: UTF8.self))
    _ = ProfileNameSanitizer.sanitize(String(decoding: bytes.prefix(512), as: UTF8.self))
    return 0
}
