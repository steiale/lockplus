// Fallback driver for toolchains without libFuzzer (Xcode 27.1's swiftc rejects -sanitize=fuzzer). Built with
// -sanitize=address and SanitizerCoverage; replays the corpus, then runs seeded random mutations of it.
//   <target> [corpus dirs/files…]   env: FUZZ_ITERATIONS (default 20000), FUZZ_SEED (default 1), FUZZ_MAX_LEN (65536),
//   FUZZ_LAST (reproducer path)
import Foundation

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// FUZZ_LAST=<file>: every input is written there before it runs, so a crash leaves its reproducer behind.
let lastInputPath = ProcessInfo.processInfo.environment["FUZZ_LAST"]

func runOne(_ b: [UInt8]) {
    if let p = lastInputPath { try? Data(b).write(to: URL(fileURLWithPath: p)) }
    b.withUnsafeBufferPointer { p in
        let base = p.baseAddress ?? UnsafePointer(bitPattern: 1)!
        _ = fuzzOne(base, b.count)
    }
}

let env = ProcessInfo.processInfo.environment
let iterations = Int(env["FUZZ_ITERATIONS"] ?? "") ?? 20_000
let maxLen = Int(env["FUZZ_MAX_LEN"] ?? "") ?? 65_536
var rng = SplitMix64(state: UInt64(env["FUZZ_SEED"] ?? "") ?? 1)
var corpus: [[UInt8]] = []
for arg in CommandLine.arguments.dropFirst() {
    let url = URL(fileURLWithPath: arg)
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: arg, isDirectory: &isDir) else { continue }
    let files = isDir.boolValue ? ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []) : [url]
    for f in files.sorted(by: { $0.path < $1.path }) { if let d = try? Data(contentsOf: f) { corpus.append(Array(d)) } }
}
if corpus.isEmpty { corpus = [[]] }
for c in corpus { runOne(c) }
let dict: [[UInt8]] = ["\n", " ", "\"", "'", "\\", "#", ";", "<", ">", "</", "<connection>\n", "</connection>\n", "<ca>\n", "</ca>",
                       "setenv opt ", "--", "\r\n", "\u{FEFF}", "=", "[Peer]\n", "[Interface]\n", "/", ":", "0x", "b64:"].map { Array($0.utf8) }
for _ in 0..<iterations {
    var b = corpus.randomElement(using: &rng)!
    for _ in 0..<Int.random(in: 1...8, using: &rng) {
        switch Int.random(in: 0..<6, using: &rng) {
        case 0 where !b.isEmpty: b[Int.random(in: 0..<b.count, using: &rng)] ^= UInt8(1 << Int.random(in: 0..<8, using: &rng))
        case 1: b.insert(UInt8.random(in: 0...255, using: &rng), at: Int.random(in: 0...b.count, using: &rng))
        case 2 where !b.isEmpty: b.remove(at: Int.random(in: 0..<b.count, using: &rng))
        case 3: b.insert(contentsOf: dict.randomElement(using: &rng)!, at: Int.random(in: 0...b.count, using: &rng))
        case 4:
            let o = corpus.randomElement(using: &rng)!
            if !o.isEmpty { let s = Int.random(in: 0..<o.count, using: &rng); b.insert(contentsOf: o[s..<min(o.count, s + 64)], at: Int.random(in: 0...b.count, using: &rng)) }
        default:
            if b.count > 2 { let s = Int.random(in: 0..<b.count, using: &rng); b.insert(contentsOf: b[s..<min(b.count, s + 32)], at: s) }
        }
    }
    if b.count > maxLen { b = Array(b.prefix(maxLen)) }
    runOne(b)
}
print("ok: \(corpus.count) corpus inputs, \(iterations) mutations")
