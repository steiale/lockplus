// libFuzzer target (DESIGN §15.4): tokenizer → allowlist → normalizer. Asserts the normalizer output re-tokenizes to
// the same stream and that the canonical text is a fixpoint (the extension re-runs the pipeline on it, §8.1).
@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzOne(_ data: UnsafePointer<UInt8>, _ size: Int) -> Int32 {
    let bytes = Array(UnsafeBufferPointer(start: data, count: size))
    let r = OVPNImporter.importProfile(bytes)
    guard let text = r.canonicalText, let stream = r.stream else { return 0 }
    guard case .success(let ds) = OVPNTokenizer.parse(Array(text.utf8)), OVPNCanonical.stream(of: ds) == stream else {
        fatalError("canonical text does not re-tokenize to its stream")
    }
    let again = OVPNImporter.importProfile(Array(text.utf8), options: OVPNNormalizerOptions(dynamicChallengeSeen: r.otpClass))
    if again.canonicalText != text { fatalError("canonical text is not a fixpoint") }
    for d in stream where OVPNEngineSupport.table[d[0]] != .mapped { fatalError("unmapped directive reached canonical text") }
    return 0
}
