// libFuzzer target (DESIGN §15.4): the OpenVPN tokenizer on arbitrary bytes. Must never crash or hang.
@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzOne(_ data: UnsafePointer<UInt8>, _ size: Int) -> Int32 {
    let bytes = Array(UnsafeBufferPointer(start: data, count: size))
    if case .success(let ds) = OVPNTokenizer.parse(bytes) {
        _ = OVPNTokenizer.walk(ds) { !$0.name.isEmpty || true }
        _ = OVPNAllowlist.inspect(ds)
    }
    // parse_line on every physical line (also used for pushed options)
    for line in bytes.split(separator: 0x0A, omittingEmptySubsequences: false).prefix(64) {
        _ = OVPNTokenizer.parseLine(String(decoding: line, as: UTF8.self))
    }
    return 0
}
