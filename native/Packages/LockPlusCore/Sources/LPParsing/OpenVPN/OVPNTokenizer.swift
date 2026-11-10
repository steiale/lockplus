import LPModel
// OVPNTokenizer: a line-for-line port of internal/ovpn/parse.go, which itself ports how OpenVPN 2.7.8 reads a
// --config file (options_parse.c: read_config_file, parse_line, check_inline_file, read_inline_file,
// read_config_string, buf_parse). DESIGN §8.1 step [2].
//
// Behaviour MUST stay identical to the Go tokenizer: the shared vectors (Tests/LPParsingTests/GoVectors.generated.swift,
// exported by native/Tools/fuzz/govectors/export.sh) compare the directive tree and the exact error text.
// Where an exact port isn't worth it, the Go parser is STRICTER than openvpn (it errors), never laxer; this port
// inherits that.
//
// Input is raw bytes (UTF-8 is not required at this step). Tokens are decoded with String(decoding:as:), which
// replaces invalid sequences; every directive records whether any of its bytes were invalid UTF-8 so the normalizer
// can reject it instead of silently changing an argument.

/// OpenVPN constants (options.h).
public enum OVPNTokenizerLimits {
    public static let optionLineSize = 256   // OPTION_LINE_SIZE
    public static let optionParmSize = 256   // OPTION_PARM_SIZE
    public static let maxParms = 16          // MAX_PARMS
}

/// One option as openvpn's add_option receives it.
public struct OVPNDirective: Sendable, Equatable {
    /// p[0], after bypass_doubledash and inline-tag stripping.
    public var name: String
    /// p[1:] (empty for inline directives; the content is in `body`).
    public var args: [String]
    /// 1-based physical line in the original file.
    public var line: Int
    /// Came from a `<name>…</name>` block.
    public var isInline: Bool
    /// Inline block content, every line with its newline, exactly as read.
    public var body: String
    /// Directives of a `<connection>` block, re-parsed the way read_config_string does.
    public var children: [OVPNDirective]
    /// Some byte of the name, an argument or the body was not valid UTF-8 (decoded with U+FFFD).
    public var hasInvalidUTF8: Bool

    public init(name: String, args: [String] = [], line: Int, isInline: Bool = false, body: String = "",
                children: [OVPNDirective] = [], hasInvalidUTF8: Bool = false) {
        self.name = name
        self.args = args
        self.line = line
        self.isInline = isInline
        self.body = body
        self.children = children
        self.hasInvalidUTF8 = hasInvalidUTF8
    }
}

/// A tokenizer error. `message` is byte-identical to the Go error text (`err.Error()`), and never contains an argument.
public struct OVPNTokenizerError: Error, Sendable, Equatable, CustomStringConvertible {
    public var message: String
    /// The 1-based line the error refers to, when there is one.
    public var line: Int?
    public var description: String { message }
}

public enum OVPNTokenizer {
    // MARK: parse_line

    /// C isspace() in the "C" locale.
    @inline(__always)
    static func cIsSpace(_ c: UInt8) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0B || c == 0x0C || c == 0x0D
    }

    enum LineError: Error, Equatable {
        case badBackslash, parameterTooLong, noClosingQuote, noClosingSingleQuote, residual

        var text: String {
            switch self {
            case .badBackslash: "bad backslash usage"
            case .parameterTooLong: "parameter too long (\(OVPNTokenizerLimits.optionParmSize) chars max)"
            case .noClosingQuote: "no closing quotation (\")"
            case .noClosingSingleQuote: "no closing single quotation (')"
            case .residual: "residual parse state"
            }
        }
    }

    /// Port of options_parse.c parse_line (via parse.go parseLine). Returns raw byte tokens.
    static func parseLineBytes(_ line: ArraySlice<UInt8>) -> Result<[[UInt8]], LineError> {
        enum State { case initial, quoted, unquoted, done, squoted }
        var ret: [[UInt8]] = []
        var state = State.initial
        var backslash = false
        var parm: [UInt8] = []
        parm.reserveCapacity(64)
        let start = line.startIndex
        let count = line.count
        var i = 0
        scan: while true {
            let input: UInt8 = i < count ? line[start + i] : 0   // C string terminator at i == len(line)
            var out: UInt8 = 0
            if !backslash && input == UInt8(ascii: "\\") && state != .squoted {
                backslash = true
            } else {
                switch state {
                case .initial:
                    if !(input == 0 || cIsSpace(input)) {
                        if input == UInt8(ascii: ";") || input == UInt8(ascii: "#") {   // comment
                            break scan
                        }
                        if !backslash && input == UInt8(ascii: "\"") {
                            state = .quoted
                        } else if !backslash && input == UInt8(ascii: "'") {
                            state = .squoted
                        } else {
                            out = input
                            state = .unquoted
                        }
                    }
                case .unquoted:
                    if !backslash && (input == 0 || cIsSpace(input)) {
                        state = .done
                    } else {
                        out = input
                    }
                case .quoted:
                    if !backslash && input == UInt8(ascii: "\"") {
                        state = .done
                    } else {
                        out = input
                    }
                case .squoted:
                    if input == UInt8(ascii: "'") {
                        state = .done
                    } else {
                        out = input
                    }
                case .done:
                    break
                }
                if state == .done {
                    ret.append(parm)
                    parm.removeAll(keepingCapacity: true)
                    state = .initial
                }
                if backslash && out != 0 {
                    if !(out == UInt8(ascii: "\\") || out == UInt8(ascii: "\"") || cIsSpace(out)) {
                        return .failure(.badBackslash)
                    }
                }
                backslash = false
            }
            if out != 0 {
                if parm.count >= OVPNTokenizerLimits.optionParmSize {
                    return .failure(.parameterTooLong)
                }
                parm.append(out)
            }
            if ret.count >= OVPNTokenizerLimits.maxParms {
                break   // openvpn silently drops further tokens
            }
            if i >= count {   // do { ... } while (*c++ != '\0')
                break
            }
            i += 1
        }
        switch state {
        case .quoted: return .failure(.noClosingQuote)
        case .squoted: return .failure(.noClosingSingleQuote)
        case .initial: return .success(ret)
        default: return .failure(.residual)
        }
    }

    /// `parseLine` on a String, for tests and the push-option filter. Error text equals the Go error.
    public static func parseLine(_ line: String) -> Result<[String], OVPNTokenizerError> {
        let bytes = Array(line.utf8)
        switch parseLineBytes(bytes[...]) {
        case .success(let toks): return .success(toks.map { String(decoding: $0, as: UTF8.self) })
        case .failure(let e): return .failure(OVPNTokenizerError(message: e.text, line: nil))
        }
    }

    /// bypass_doubledash.
    static func bypassDoubleDash(_ s: [UInt8]) -> [UInt8] {
        if s.count >= 3 && s[0] == UInt8(ascii: "-") && s[1] == UInt8(ascii: "-") {
            return Array(s[2...])
        }
        return s
    }

    /// check_inline_file: exactly one token of the form "<name>".
    static func inlineTag(_ p: [[UInt8]]) -> [UInt8]? {
        guard p.count == 1 else { return nil }
        let a = p[0]
        if a.count >= 2 && a[0] == UInt8(ascii: "<") && a[a.count - 1] == UInt8(ascii: ">") {
            return Array(a[1..<(a.count - 1)])
        }
        return nil
    }

    // MARK: line sources (in_src: fgets on the file, buf_parse on a <connection> body)

    struct LineSource {
        let data: [UInt8]
        var pos: Int
        let end: Int
        let buf: Bool   // true: buf_parse semantics; false: fgets semantics

        /// fgets(line, size, fp): up to size-1 bytes, stopping after (and including) a newline.
        mutating func fgets(_ size: Int) -> (line: ArraySlice<UInt8>, start: Int)? {
            let start = pos
            if pos >= end { return nil }
            let limit = min(pos + size - 1, end)
            var i = pos
            while i < limit {
                let c = data[i]
                i += 1
                if c == 0x0A { break }
            }
            let line = data[pos..<i]
            pos = i
            return (line, start)
        }

        /// buf_parse(buf, '\n', line, size): up to size-1 bytes, consuming (not returning) the delimiter.
        mutating func bufParse(_ size: Int) -> (line: ArraySlice<UInt8>, start: Int, ok: Bool, truncated: Bool) {
            let start = pos
            var i = pos
            var eol = false
            var truncated = false
            while true {
                if i >= end {
                    eol = true
                    break
                }
                if data[i] == 0x0A {
                    let line = data[pos..<i]
                    i += 1
                    pos = i
                    return (line, start, true, false)
                }
                if i - pos >= size - 1 {
                    truncated = true
                    break
                }
                i += 1
            }
            let line = data[pos..<i]
            pos = i
            return (line, start, !(eol && line.isEmpty), truncated)
        }

        /// in_src_get, used by read_inline_file.
        mutating func get() -> (line: [UInt8], start: Int, ok: Bool, truncated: Bool) {
            if !buf {
                guard let r = fgets(OVPNTokenizerLimits.optionLineSize) else { return ([], pos, false, false) }
                return (Array(r.line), r.start, true, false)
            }
            let r = bufParse(OVPNTokenizerLimits.optionLineSize)
            var line = Array(r.line)
            if line.count + 1 < OVPNTokenizerLimits.optionLineSize {
                line.append(0x0A)
            }
            return (line, r.start, r.ok, r.truncated)
        }
    }

    static func lineNo(_ data: [UInt8], _ off: Int) -> Int {
        var n = 1
        var i = 0
        while i < off {
            if data[i] == 0x0A { n += 1 }
            i += 1
        }
        return n
    }

    /// Monotonic offset → line number in O(total).
    struct LineCounter {
        let data: [UInt8]
        var off: Int
        var line: Int
        init(_ data: [UInt8], _ off: Int) {
            self.data = data
            self.off = off
            self.line = OVPNTokenizer.lineNo(data, off)
        }
        mutating func at(_ o: Int) -> Int {
            if o < off {
                off = o
                line = OVPNTokenizer.lineNo(data, o)
                return line
            }
            var i = off
            while i < o {
                if data[i] == 0x0A { line += 1 }
                i += 1
            }
            off = o
            return line
        }
    }

    /// read_inline_file: lines accumulate until one whose leading-whitespace-stripped text STARTS WITH the close tag
    /// (strncmp prefix match, so "</ca>trailing" closes and the trailing text is discarded).
    static func readInline(_ src: inout LineSource, closeTag: [UInt8]) -> Result<(body: [UInt8], start: Int, end: Int), OVPNTokenizerError> {
        var body: [UInt8] = []
        let bodyStart = src.pos
        while true {
            let r = src.get()
            if !r.ok {
                return .failure(OVPNTokenizerError(message: "end tag \(String(decoding: closeTag, as: UTF8.self)) missing", line: nil))
            }
            if r.truncated {
                let ln = lineNo(src.data, r.start)
                return .failure(OVPNTokenizerError(message: "line \(ln) too long", line: ln))
            }
            var j = 0
            while j < r.line.count && cIsSpace(r.line[j]) { j += 1 }
            if r.line.count - j >= closeTag.count && r.line[j..<(j + closeTag.count)].elementsEqual(closeTag) {
                return .success((body, bodyStart, r.start))
            }
            body.append(contentsOf: r.line)
        }
    }

    // MARK: parse_config

    /// Parses a whole .ovpn file the way `openvpn --config FILE` does.
    public static func parse(_ input: some Collection<UInt8>) -> Result<[OVPNDirective], OVPNTokenizerError> {
        let data = Array(input)
        // fgets/strlen/buf_parse treat NUL differently; no legitimate profile contains one.
        if let i = data.firstIndex(of: 0) {
            let ln = lineNo(data, i)
            return .failure(OVPNTokenizerError(message: "line \(ln): NUL byte in config", line: ln))
        }
        var src = LineSource(data: data, pos: 0, end: data.count, buf: false)
        var lc = LineCounter(data, 0)
        var out: [OVPNDirective] = []
        var first = true
        while let r = src.fgets(OVPNTokenizerLimits.optionLineSize + 1) {
            let ln = lc.at(r.start)
            var line = r.line
            if line.count == OVPNTokenizerLimits.optionLineSize {
                return .failure(OVPNTokenizerError(message: "line \(ln): too long (max \(OVPNTokenizerLimits.optionLineSize - 2) characters)", line: ln))
            }
            if first && line.count >= 3 && line[line.startIndex] == 0xEF && line[line.startIndex + 1] == 0xBB && line[line.startIndex + 2] == 0xBF {
                line = line.dropFirst(3)
            }
            first = false
            let p: [[UInt8]]
            switch parseLineBytes(line) {
            case .success(let toks): p = toks
            case .failure(let e): return .failure(OVPNTokenizerError(message: "line \(ln): \(e.text)", line: ln))
            }
            if p.isEmpty { continue }
            var toks = p
            toks[0] = bypassDoubleDash(toks[0])
            if let tag = inlineTag(toks) {
                let tagS = String(decoding: tag, as: UTF8.self)
                let closeTag = Array("</".utf8) + tag + [UInt8(ascii: ">")]
                switch readInline(&src, closeTag: closeTag) {
                case .failure(let e):
                    return .failure(OVPNTokenizerError(message: "line \(ln): <\(tagS)>: \(e.message)", line: ln))
                case .success(let r):
                    var d = makeInline(tag: tag, body: r.body, line: ln)
                    if tagS == "connection" {
                        switch parseConnection(data, start: r.start, end: r.end) {
                        case .failure(let e): return .failure(e)
                        case .success(let children):
                            d.children = children
                        }
                    }
                    out.append(d)
                }
            } else {
                out.append(makePlain(toks, line: ln))
            }
        }
        return .success(out)
    }

    /// read_config_string on a <connection> body: buf_parse lines, no BOM handling, inline blocks through the buffer
    /// variant of in_src_get.
    static func parseConnection(_ data: [UInt8], start: Int, end: Int) -> Result<[OVPNDirective], OVPNTokenizerError> {
        var src = LineSource(data: data, pos: start, end: end, buf: true)
        var lc = LineCounter(data, start)
        var out: [OVPNDirective] = []
        while true {
            let r = src.bufParse(OVPNTokenizerLimits.optionLineSize)
            if !r.ok { break }
            let ln = lc.at(r.start)
            if r.truncated {
                return .failure(OVPNTokenizerError(message: "line \(ln): too long inside <connection> (max \(OVPNTokenizerLimits.optionLineSize - 2) characters)", line: ln))
            }
            let p: [[UInt8]]
            switch parseLineBytes(r.line) {
            case .success(let toks): p = toks
            case .failure(let e): return .failure(OVPNTokenizerError(message: "line \(ln): \(e.text)", line: ln))
            }
            if p.isEmpty { continue }
            var toks = p
            toks[0] = bypassDoubleDash(toks[0])
            if let tag = inlineTag(toks) {
                let tagS = String(decoding: tag, as: UTF8.self)
                let closeTag = Array("</".utf8) + tag + [UInt8(ascii: ">")]
                switch readInline(&src, closeTag: closeTag) {
                case .failure(let e):
                    return .failure(OVPNTokenizerError(message: "line \(ln): <\(tagS)>: \(e.message)", line: ln))
                case .success(let r2):
                    if tagS == "connection" {
                        // openvpn rejects this too (connection is not a connection-block option); don't recurse.
                        return .failure(OVPNTokenizerError(message: "line \(ln): nested <connection> blocks are not allowed", line: ln))
                    }
                    out.append(makeInline(tag: tag, body: r2.body, line: ln))
                }
            } else {
                out.append(makePlain(toks, line: ln))
            }
        }
        return .success(out)
    }

    static func makePlain(_ toks: [[UInt8]], line: Int) -> OVPNDirective {
        var invalid = false
        let strs = toks.map { t -> String in
            if String(validating: t, as: UTF8.self) == nil { invalid = true }
            return String(decoding: t, as: UTF8.self)
        }
        return OVPNDirective(name: strs[0], args: Array(strs.dropFirst()), line: line, hasInvalidUTF8: invalid)
    }

    static func makeInline(tag: [UInt8], body: [UInt8], line: Int) -> OVPNDirective {
        let invalid = String(validating: tag, as: UTF8.self) == nil || String(validating: body, as: UTF8.self) == nil
        return OVPNDirective(name: String(decoding: tag, as: UTF8.self), line: line, isInline: true,
                             body: String(decoding: body, as: UTF8.self), hasInvalidUTF8: invalid)
    }

    /// Visits every directive openvpn will apply, descending into <connection> blocks after the block itself.
    public static func walk(_ ds: [OVPNDirective], _ fn: (OVPNDirective) -> Bool) -> Bool {
        for d in ds {
            if !fn(d) { return false }
            if !d.children.isEmpty && !walk(d.children, fn) { return false }
        }
        return true
    }
}
