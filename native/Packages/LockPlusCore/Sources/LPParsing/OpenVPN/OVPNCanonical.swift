import LPModel
// Canonical OpenVPN text (DESIGN §8.1 [5]) and the directive stream both parsers must agree on ([6]).
//
// Canonical text: one directive per line; the name bare, every argument double-quoted with only `\\` and `\"`
// escapes; inline blocks as "<name>\n…\n</name>"; no comments; "\n" line ends; a final "\n".
//
// The stream is what openvpn3's `OptionList` must produce for the canonical text: one `[String]` per directive,
// `[name] + args` for a plain directive and `[name, body]` for an inline block, where `body` is every body line
// followed by "\n" (empty for an empty block). A `<connection>` block is an inline block whose body is its canonical
// child lines.

public enum OVPNCanonical {
    /// Quotes one argument: `"` + (`\` → `\\`, `"` → `\"`) + `"`.
    public static func quote(_ s: String) -> String {
        var out = "\""
        out.reserveCapacity(s.utf8.count + 2)
        for c in s.unicodeScalars {
            if c == "\\" { out += "\\\\" } else if c == "\"" { out += "\\\"" } else { out.unicodeScalars.append(c) }
        }
        return out + "\""
    }

    /// One plain directive line.
    public static func line(_ name: String, _ args: [String]) -> String {
        ([name] + args.map(quote)).joined(separator: " ")
    }

    /// The canonical body lines of an inline block: split on "\n", a trailing "\r" removed from every line, the empty
    /// tail after the final newline dropped.
    public static func bodyLines(_ body: String) -> [String] {
        // Split on bytes: in Swift "\r\n" is one Character, so a Character split would miss CRLF lines.
        var lines = body.utf8.split(separator: 0x0A, omittingEmptySubsequences: false).map { l -> String in
            var b = Array(l)
            if b.last == 0x0D { b.removeLast() }
            return String(decoding: b, as: UTF8.self)
        }
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// A body as openvpn3 holds it: every line + "\n".
    public static func streamBody(_ lines: [String]) -> String {
        lines.map { $0 + "\n" }.joined()
    }

    public static func inlineBlock(_ name: String, _ lines: [String]) -> String {
        (["<\(name)>"] + lines + ["</\(name)>"]).joined(separator: "\n")
    }

    /// The stream of a tokenized profile (our tokenizer's view). Used to check that canonical text re-tokenizes to
    /// the stream it was emitted from (§15.4 `fuzz_ovpn_import`) and by the [6] comparison.
    public static func stream(of ds: [OVPNDirective]) -> [[String]] {
        ds.map { d in d.isInline ? [d.name, d.body] : [d.name] + d.args }
    }

    /// openvpn3's size accounting (MAX_PROFILE_SIZE): raw bytes + 64 per directive + 16 per argument. The name is
    /// counted as a term too (conservative: whether openvpn3's `add_term` covers the name is unverified).
    public static func accounting(text: String, stream: [[String]]) -> Int {
        var n = text.utf8.count
        for d in stream {
            n += OVPNImportLimits.perDirectiveOverhead + OVPNImportLimits.perArgumentOverhead * d.count
        }
        return n
    }
}
