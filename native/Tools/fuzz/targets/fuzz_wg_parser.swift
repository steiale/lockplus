// libFuzzer target (DESIGN §15.4): WireGuard parse → validate → canonical; the canonical text must be a fixpoint.
@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzOne(_ data: UnsafePointer<UInt8>, _ size: Int) -> Int32 {
    let bytes = Array(UnsafeBufferPointer(start: data, count: size))
    let r = WGImporter.importProfile(bytes)
    guard let text = r.canonicalText else { return 0 }
    let again = WGImporter.importProfile(Array(text.utf8))
    if again.canonicalText != text { fatalError("WG canonical text is not a fixpoint") }
    return 0
}
