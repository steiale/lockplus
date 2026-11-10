import Darwin
import Foundation
import Testing
@testable import LockPlus

/// Go 1.1.0's state file as left on the VM (`internal/tunnel/recovery.go`: name and utun, no pid).
let e2e7WGSplit = #"{"tunnel_name":"wg-split","interface_name":"utun6"}"#

/// E2E-7 (VM 26, 200016): the native helper removal after a hard-killed Go helper. `tunnelstale` runs unprivileged
/// against fixtures (fake `launchctl`, `pgrep` and `ifconfig` first on PATH, the real `stat`, `find` and `plutil`);
/// nothing privileged runs. Root ownership can't be faked, so the fixture's owner stands in for uid 0. Not on the main
/// actor: ~40 blocking shell runs there would starve the other suites' `eventually` deadlines.
@Suite("E2E-7 helper removal fixes", .serialized, .timeLimit(.minutes(1)))
struct E2E7FixTests {
    /// Runs the functions and one call under `/bin/sh` with a clean environment (as `E2E6FixTests.sh`, off the main actor).
    /// `set -f` first, as in the body (review N1); `cwd` stands in for a caller-chosen directory (review L1).
    static func sh(_ functions: String, _ call: String, path: String, cwd: URL? = nil) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "set -f\n" + functions + "\n" + call]
        p.currentDirectoryURL = cwd
        p.environment = ["PATH": path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// `sh -n`: parses, runs nothing.
    static func parses(_ text: String) throws -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-n", "-c", text]
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    @Test("Review M1: a broken body inside the wrapper still parses as the wrapper; only the body check catches it")
    func theBodyItselfIsParsed() throws {
        let broken = "if then fi (((\n"
        #expect(try Self.parses(LegacyHelperRemoval.wrapped(broken)))
        #expect(try !Self.parses(broken))
        #expect(try Self.parses(LegacyHelperRemoval.body))
    }

    enum Entry { case file(String), symlink, dir, fifo }
    static let helper = "/Library/PrivilegedHelperTools/io.github.steiale.lockplus.helper"
    static let label = "io.github.steiale.lockplus.helper"
    static let helperLine = helper + " --helper --socket=/var/run/lockplus/lockplus.sock"
    static let systemUtuns = "lo0 gif0 stf0 en0 en1 awdl0 llw0 utun0 utun1 utun2 utun3 bridge0"

    /// The fakes: `launchctl print system/<label>` knows only `loaded` (`"!error"`: exit 5, else 113 "Could not find service"); `pgrep -f <re>` matches `processes` (nil: exit 3);
    /// `ifconfig -l` prints `interfaces` (nil: exit 1).
    static func fakes(_ dir: TestDir, loaded: String?, processes: [String]?, interfaces: String?) throws -> String {
        let bin = dir.url.appending(path: "bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        func q(_ t: String) -> String { "'" + t.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let table = dir.url.appending(path: "processes")
        try (processes ?? []).map { $0 + "\n" }.joined().write(to: table, atomically: true, encoding: .utf8)
        let scripts = [
            "launchctl": "[ \"$1\" = print ] || exit 9\n" + (loaded == "!error" ? "exit 5\n" : "")
                + (loaded.map { "[ \"$2\" = \(q("system/" + $0)) ] && exit 0\n" } ?? "") + "exit 113\n",
            "pgrep": "[ \"$1\" = -f ] || exit 9\n" + (processes == nil ? "exit 3\n" : "grep -q -E -e \"$2\" \(q(table.path)) && exit 0\nexit 1\n"),
            "ifconfig": "[ \"$1\" = -l ] || exit 9\n" + (interfaces.map { "printf '%s\\n' \(q($0))\n" } ?? "exit 1\n"),
        ]
        for (name, body) in scripts {
            let url = bin.appending(path: name)
            try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return bin.path + ":/usr/bin:/bin:/usr/sbin:/sbin"
    }

    /// The script's own `rootfile` and `tunnelstale`, with this user's uid for root's.
    static func functions() throws -> String {
        let lines = LegacyHelperRemoval.body.split(separator: "\n").map(String.init)
        let rootfile = try #require(lines.first { $0.hasPrefix("rootfile() ") })
        let text = rootfile + "\n" + LegacyHelperRemoval.tunnelStaleFunction
        #expect(text.components(separatedBy: "= 0 ]").count == 3)       // both owner checks, nothing else
        return text.replacingOccurrences(of: "= 0 ]", with: "= \(getuid()) ]")
    }

    static func run(_ entries: [String: Entry], loaded: String? = nil, processes: [String]? = [], interfaces: String? = systemUtuns,
                    appPattern: String? = nil, linkedStateDir: Bool = false, cwdInStates: Bool = false) throws -> Int32 {
        let dir = TestDir()
        defer { dir.cleanup() }
        let path = try fakes(dir, loaded: loaded, processes: processes, interfaces: interfaces)
        let data = dir.url.appending(path: "data", directoryHint: .isDirectory)
        let real = dir.url.appending(path: linkedStateDir ? "elsewhere" : "data/tunnel-states", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        if linkedStateDir { try FileManager.default.createSymbolicLink(at: data.appending(path: "tunnel-states"), withDestinationURL: real) }
        let target = dir.url.appending(path: "target.json")
        try e2e7WGSplit.write(to: target, atomically: true, encoding: .utf8)
        for (name, entry) in entries {
            let url = real.appending(path: name)
            switch entry {
            case .file(let json): try json.write(to: url, atomically: true, encoding: .utf8)
            case .symlink: try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
            case .dir: try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            case .fifo: #expect(mkfifo(url.path, 0o600) == 0)
            }
        }
        func q(_ t: String) -> String { "'" + t.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let call = "tunnelstale \(q(data.path)) \(q(label)) \(q(helper))" + (appPattern.map { " " + q($0) } ?? "")
        return try sh(try functions(), call, path: path, cwd: cwdInStates ? real : nil)
    }

    // MARK: F3 a state file a hard-killed helper left isn't "busy"

    @Test("F3: state file, no job, no process, no utun = stale (also 1.0.x's extra fields, a name with a space)",
          arguments: [
            ["wg-split.json": Entry.file(e2e7WGSplit)],
            ["old.json": .file(#"{"tunnel_name":"old","interface_name":"utun4","dns_servers_original":["1.1.1.1"],"full_tunnel":true,"table":"auto"}"#)],
            ["my vpn.json": .file(#"{"tunnel_name":"my vpn","interface_name":"utun12"}"#), "notes.txt": .file("x")],
            ["a.json": .file(e2e7WGSplit), "b.json": .file(#"{"tunnel_name":"b","interface_name":"utun7"}"#)],
            ["a*.json": .file(e2e7WGSplit), "a1.json": .file(#"{"tunnel_name":"a1","interface_name":"utun7"}"#)],   // review N4d: never globbed
          ])
    func staleStateIsNotBusy(_ entries: [String: Entry]) throws {
        #expect(try Self.run(entries) == 0)
        // Native 2.0 (`MacOS/LockPlus`) and an unrelated process never count.
        #expect(try Self.run(entries, processes: ["/Applications/LockPlus.app/Contents/MacOS/LockPlus", "/usr/sbin/mDNSResponder"]) == 0)
    }

    @Test("F3: a utun the state file names is still there = busy (also when only one of two files matches)")
    func matchingUtunIsBusy() throws {
        #expect(try Self.run(["wg-split.json": .file(e2e7WGSplit)], interfaces: Self.systemUtuns + " utun6") == 1)
        #expect(try Self.run(["a.json": .file(#"{"tunnel_name":"a","interface_name":"utun5"}"#), "wg-split.json": .file(e2e7WGSplit)],
                             interfaces: Self.systemUtuns + " utun6") == 1)
        #expect(try Self.run(["wg-split.json": .file(e2e7WGSplit)], interfaces: nil) == 1)                       // ifconfig failed
        #expect(try Self.run(["wg-split.json": .file(e2e7WGSplit)], interfaces: "") == 1)                        // review L2: no lo0
        #expect(try Self.run(["wg-split.json": .file(e2e7WGSplit)], interfaces: "en0 utun0") == 1)
    }

    @Test("F3: the helper, the old app or a loaded job = busy; a pgrep or launchctl error is never 'not there'")
    func activityIsBusy() throws {
        let state: [String: Entry] = ["wg-split.json": .file(e2e7WGSplit)]
        #expect(try Self.run(state, processes: [Self.helperLine]) == 1)
        #expect(try Self.run(state, processes: [Self.helper]) == 1)
        #expect(try Self.run(state, processes: ["/Applications/LockPlus.app/Contents/MacOS/lockplus"]) == 1)
        #expect(try Self.run(state, processes: ["/Applications/WireGuide+.app/Contents/MacOS/wireguide-plus --flag"]) == 1)
        #expect(try Self.run(state, loaded: Self.label) == 1)
        #expect(try Self.run(state, processes: nil) == 1)
        #expect(try Self.run(state, loaded: "!error") == 1)
        // WireGuide+ 1.0.0's GUI counts only through the extra pattern (passed for com.wireguide.helper).
        let wg100 = ["/Applications/WireGuide.app/Contents/MacOS/wireguide"]
        #expect(try Self.run(state, processes: wg100) == 0)
        #expect(try Self.run(state, processes: wg100, appPattern: LegacyHelperRemoval.wireGuide100Pattern) == 1)
    }

    @Test("F3: malformed, unexpected or symlinked state = busy (fail safe)",
          arguments: [
            ["wg-split.json": Entry.file("not json")],
            ["wg-split.json": .file(#"{"tunnel_name":"wg-split"}"#)],
            ["wg-split.json": .file(#"{"tunnel_name":"wg-split","interface_name":""}"#)],
            ["wg-split.json": .file(#"{"tunnel_name":"wg-split","interface_name":"en0"}"#)],
            ["wg-split.json": .file(#"{"tunnel_name":"wg-split","interface_name":"utun1234"}"#)],
            ["wg-split.json": .file(#"{"tunnel_name":"wg-split","interface_name":"utun6 utun7"}"#)],
            ["wg-split.json": .file(#"{"tunnel_name":"wg-split","interface_name":"utun*"}"#)],
            ["wg-split.json": .file(#"{"tunnel_name":"wg-split","interface_name":6}"#)],
            ["wg-split.json": .file(#"["utun6"]"#)],
            ["wg-split.json": .symlink],
            ["wg-split.json": .dir],
            ["a.json": .file(e2e7WGSplit), "b.json": .symlink],
            ["wg-split.json": .fifo],                                                                            // review N4c
            ["wg-split.json": .file(#"{"tunnel_name":"wg-split","interface_name":"utun6\n"}"#)],                 // review N2
            ["wg-split.json": .file(#"{"tunnel_name":"wg-split","interface_name":"utun6\n\n"}"#)],
            ["wg-split.json": .file(#"{"tunnel_name":"wg-split","interface_name":"\nutun6"}"#)],
          ])
    func malformedStateIsBusy(_ entries: [String: Entry]) throws {
        #expect(try Self.run(entries) == 1)
    }

    @Test("F3: a symlinked tunnel-states directory = busy")
    func linkedStateDirectoryIsBusy() throws {
        #expect(try Self.run(["wg-split.json": .file(e2e7WGSplit)], linkedStateDir: true) == 1)
    }

    /// Review L1/N4a: a live tunnel named "a.json⏎a.json" splits into `…/a.json` and a relative `a.json`; from a cwd
    /// inside `tunnel-states` both would resolve to the stale `a.json` and the live file's utun6 would never be read.
    @Test("F3: a newline in a state file's name = busy, whatever the working directory")
    func newlineNamedStateIsBusy() throws {
        let entries: [String: Entry] = ["a.json": .file(#"{"tunnel_name":"a","interface_name":"utun7"}"#), "a.json\na.json": .file(e2e7WGSplit)]
        #expect(try Self.run(entries, interfaces: Self.systemUtuns + " utun6", cwdInStates: true) == 1)
        #expect(try Self.run(entries, cwdInStates: true) == 1)
        #expect(try Self.run(["x\nwg-split.json": .file(e2e7WGSplit)]) == 1)
    }

    @Test("F3: stale state falls through to the pf, journal and old-app checks; cleandata removes tunnel-states")
    func staleStateKeepsTheOrder() throws {
        let s = LegacyHelperRemoval.body          // unwrapped: the script escapes each `'`
        #expect(s.contains(#"tunnelcheck() { tunnelup "$1" || return 0; tunnelstale "$@" || { echo "LP_BUSY=tunnel"; result busy; }; ST=yes; }"#))
        // Review L5: every busy has a constant reason line right before it.
        #expect(s.components(separatedBy: "result busy").count == 3)
        #expect(s.contains("echo \"LP_BUSY=tunnel\"; result busy") && s.contains("echo \"LP_BUSY=pf\"\n  result busy"))
        let first = try #require(s.range(of: #"tunnelcheck "$D" "$L" "$B""#)).lowerBound
        #expect(s.contains(#"tunnelcheck "$D2" "$L2" "$B2""#))
        #expect(s.contains(#"if [ "$U3" = yes ]; then tunnelcheck "$D3" "$L3" "$B3" '"# + LegacyHelperRemoval.wireGuide100Pattern + "'; fi"))
        let pf = try #require(s.range(of: "PF=$(pfctl")).lowerBound
        let journal = try #require(s.range(of: #"journalcheck "$D"; fi"#)).lowerBound
        let bootout = try #require(s.range(of: "launchctl bootout")).lowerBound
        #expect(first < pf && pf < journal && journal < bootout)
        #expect(try #require(s.range(of: "tunnelstale() {")).lowerBound < first)
        #expect(s.contains(#"if [ -d "$C/$x" ] && [ ! -L "$C/$x" ]; then rm -rf "$C/$x"; fi"#))
        // Review L3: reported after the cleanup, before the final result; review N1/L1: `cd /` and `set -f` come first.
        let stale = try #require(s.range(of: #"if [ "$ST" = yes ]; then echo "LP_STALE=tunnel-states"; fi"#)).lowerBound
        #expect(try #require(s.range(of: #"cleandata "$D""#)).lowerBound < stale)
        #expect(stale < (try #require(s.range(of: "result removed-left-state"))).lowerBound)
        #expect(try #require(s.range(of: "result incomplete")).lowerBound < stale)          // review N5: never on a failure
        #expect(s.hasPrefix("export PATH=/usr/bin:/bin:/usr/sbin:/sbin\numask 077\ncd /\nset -f\n"))
        #expect(s.components(separatedBy: "set -f").count == 2 && !s.contains("set +f"))
    }
}

/// E2E-7 F3 review L3/L4: what the app makes of the script's answer.
@MainActor @Suite("E2E-7 helper removal: app side", .serialized, .timeLimit(.minutes(1)))
struct E2E7AppTests {
    @Test("L3: LP_STALE is read from its own line; the removal then suggests a restart, the DNS copy wins over it")
    func staleTunnelSuggestsARestart() async throws {
        #expect(LegacyHelperRemoval.staleTunnel(in: "LP_STALE=tunnel-states\nLP_RESULT=removed\n"))
        #expect(LegacyHelperRemoval.staleTunnel(in: "LP_STALE=tunnel-states\rLP_RESULT=removed"))
        #expect(!LegacyHelperRemoval.staleTunnel(in: "LP_RESULT=removed\n"))
        #expect(!LegacyHelperRemoval.staleTunnel(in: "xLP_STALE=tunnel-states\nLP_STALE=tunnel-states2\nLP_RESULT=removed\n"))
        let (h, _, _) = E2E5FixTests().removalHarness(answer: .finished(output: "LP_STALE=tunnel-states\nLP_RESULT=removed\n"))
        defer { h.dir.cleanup() }
        await h.env.legacy.refresh()
        await h.env.legacy.removeHelper()
        #expect(h.env.legacy.removal == .removed(leftNetworkState: false, staleTunnel: true))
        let stale = LegacyHelperCopy.removed(leftNetworkState: false, staleTunnel: true)
        #expect(stale.contains("restart your Mac") && stale.contains("routes") && !stale.contains("DNS"))
        #expect(LegacyHelperCopy.removed(leftNetworkState: true, staleTunnel: true) == LegacyHelperCopy.removed(leftNetworkState: true))
        #expect(LegacyHelperCopy.removed(leftNetworkState: false) == "The old LockPlus helper was removed.")
        // Review N5: a stale flag never leaks into a failure.
        let (h2, _, _) = E2E5FixTests().removalHarness(answer: .finished(output: "LP_STALE=tunnel-states\nLP_RESULT=incomplete\n"),
                                                        leaves: [LegacyAppDetector.helperPlist, LegacyAppDetector.helperBinary])
        defer { h2.dir.cleanup() }
        await h2.env.legacy.refresh()
        await h2.env.legacy.removeHelper()
        #expect(h2.env.legacy.removal == .failed(.incomplete))
    }

    @Test("L4/L5: only a tunnel-state 'busy' while LockPlus itself is connected says to disconnect LockPlus first",
          arguments: [
            ("LP_BUSY=tunnel\nLP_RESULT=busy\n", true, LegacyHelperRemovalState.Failure.busyWhileConnected),
            ("LP_BUSY=tunnel\nLP_RESULT=busy\n", false, .busy),
            ("LP_BUSY=pf\nLP_RESULT=busy\n", true, .busy),                        // a kill switch: the plain copy names it
            ("LP_RESULT=busy\n", true, .busy),                                    // no reason: the conservative default
            ("xLP_BUSY=tunnel\nLP_BUSY=tunnel2\nLP_RESULT=busy\n", true, .busy),  // exact lines only
          ])
    func busyWhileConnectedNamesLockPlus(_ output: String, _ connected: Bool, _ expected: LegacyHelperRemovalState.Failure) async throws {
        let (h, _, runner) = E2E5FixTests().removalHarness(answer: .finished(output: output),
                                                           leaves: [LegacyAppDetector.helperPlist, LegacyAppDetector.helperBinary])
        defer { h.dir.cleanup() }
        #expect(h.env.legacy.nativeTunnelUp() == false)                       // AppEnvironment's wiring: nothing connected
        h.env.legacy.nativeTunnelUp = { connected }
        await h.env.legacy.refresh()
        await h.env.legacy.removeHelper()
        #expect(runner.runs == 1 && h.env.legacy.removal == .failed(expected))
    }

    @Test("L4: the copies")
    func busyCopies() {
        let copy = LegacyHelperCopy.removalProblem(.failed(.busyWhileConnected))
        #expect(copy.contains("Disconnect LockPlus") && copy.contains("old LockPlus") && copy.contains("restart your Mac"))
        #expect(LegacyHelperCopy.removalProblem(.failed(.busy)).contains("Disconnect in the old LockPlus first"))
    }
}
