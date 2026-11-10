// OCRs every rendered review PNG (Vision, accurate, EN + DE) and flags text lines that contain "…" or "..." and are not
// intentional wording (allow-ellipsis.txt), plus German renders written in Sie-form.
//
//   scan-truncation.swift [Screenshots-dir] [allowlist] [screens.json]      (defaults: ../Screenshots, allow-ellipsis.txt, screens.json)
//   run:  swiftc -O -o "$LP_BUILD_ROOT/scan-truncation" scan-truncation.swift && "$LP_BUILD_ROOT/scan-truncation"
//
// Also allowed: every string of App/UI/Localizable.xcstrings (key or EN/DE value) that itself contains "…"; its %@ / %lld
// placeholders match any text. So new intentional wording needs no allowlist edit, only a truncated line stays a hit.
//
// Allowlist: one entry per line, `#` comments. An entry is matched as a case-insensitive substring of the OCR line
// (after "..." is folded to "…"). Exit status 1 when any hit remains.
import AppKit
import Foundation
import Vision

struct Manifest: Decodable { struct Screen: Decodable { let id: String; let base: String }; let screens: [Screen] }

let args = CommandLine.arguments
let here = URL(fileURLWithPath: args[0]).deletingLastPathComponent()
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
func path(_ i: Int, _ dflt: String) -> URL { args.count > i ? URL(fileURLWithPath: args[i]) : root.appending(path: dflt) }
let catalogFile = path(4, "../../../App/UI/Localizable.xcstrings")
let dir = path(1, "../Screenshots"), allowFile = path(2, "allow-ellipsis.txt"), manifestFile = path(3, "screens.json")

func fold(_ s: String) -> String { s.replacingOccurrences(of: "...", with: "…").lowercased() }
let allow = ((try? String(contentsOf: allowFile, encoding: .utf8)) ?? "").split(separator: "\n")
    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }.map(fold)
/// Regexes for the catalog's intentional ellipsis strings: literal text, placeholders as `.*`, `…` tolerant of a space and "...".
func catalogPatterns() -> [NSRegularExpression] {
    guard let data = try? Data(contentsOf: catalogFile), let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
    var found = Set<String>()
    func walk(_ n: Any) {
        if let s = n as? String, s.contains("…") { found.insert(s) }
        else if let d = n as? [String: Any] { for (k, v) in d { walk(k); walk(v) } }
        else if let a = n as? [Any] { a.forEach(walk) }
    }
    walk(root)
    let spec = try! NSRegularExpression(pattern: #"%(\d+\$)?(ll|l)?[@dDsfuUxX]"#)
    // A string that wraps shows only its tail on the last line ("…to disconnect…"), so every word-boundary tail
    // that still holds a literal letter counts as well.
    var out: [NSRegularExpression] = []
    for s in found {
        var pieces: [String] = [], last = s.startIndex
        for m in spec.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            let r = Range(m.range, in: s)!
            pieces.append(String(s[last..<r.lowerBound])); pieces.append("\u{1}")
            last = r.upperBound
        }
        pieces.append(String(s[last...]))
        let whole = pieces.joined()
        var starts = [whole.startIndex]
        for i in whole.indices where whole[i] == " " { starts.append(whole.index(after: i)) }
        for st in starts {
            let tail = String(whole[st...])
            guard tail.contains(where: { $0.isLetter }) else { continue }
            var pat = tail.split(separator: "\u{1}", omittingEmptySubsequences: false)
                .map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: ".*")
            pat = pat.replacingOccurrences(of: "…", with: "\\s?(…|\\.\\.\\.)")
            if let re = try? NSRegularExpression(pattern: st == whole.startIndex ? pat : "^" + pat + #"[.\s]*$"#, options: [.caseInsensitive]) { out.append(re) }
        }
    }
    return out
}
let catalog = catalogPatterns()
func allowed(_ line: String) -> Bool {
    let f = fold(line)
    if allow.contains(where: { f.contains($0) }) { return true }
    let r = NSRange(line.startIndex..., in: line)
    return catalog.contains { $0.firstMatch(in: line, range: r) != nil }
}

let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestFile))
var idsByBase: [String: [String]] = [:]
for s in manifest.screens { idsByBase[s.base, default: []].append(s.id) }

let sie = try NSRegularExpression(pattern: #"\b(Sie|Ihr|Ihre|Ihren|Ihrem|Ihrer|Ihnen)\b"#)

func lines(_ url: URL, de: Bool) -> [String] {
    guard let img = NSImage(contentsOf: url), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = false
    req.recognitionLanguages = de ? ["de-DE", "en-US"] : ["en-US", "de-DE"]
    try? VNImageRequestHandler(cgImage: cg).perform([req])
    return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
}

let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "png" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
var hits = 0, sieHits = 0, scanned = 0
for f in files {
    var stem = f.deletingPathExtension().lastPathComponent
    let de = stem.hasSuffix("-de"); if de { stem.removeLast(3) }
    for suffix in ["-light", "-dark"] where stem.hasSuffix(suffix) { stem.removeLast(suffix.count) }
    let ids = idsByBase[stem]?.joined(separator: ",") ?? "unlisted"
    scanned += 1
    for line in lines(f, de: de) {
        let folded = fold(line)
        if folded.contains("…"), line.contains(where: { $0.isLetter }), !allowed(line) {   // dot-only lines are masked password fields
            hits += 1; print("ELLIPSIS\t\(ids)\t\(f.lastPathComponent)\t\(line)")
        }
        if de, sie.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
            sieHits += 1; print("SIE-FORM\t\(ids)\t\(f.lastPathComponent)\t\(line)")
        }
    }
}
print("scanned \(scanned) PNGs: \(hits) ellipsis hit(s), \(sieHits) Sie-form hit(s)")
exit(hits + sieHits == 0 ? 0 : 1)
