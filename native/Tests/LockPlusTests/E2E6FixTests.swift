import Darwin
import Foundation
import Testing
@testable import LockPlus

/// networksetup's answer for a service with Automatic DNS.
let e2e6NoDNS = "There aren't any DNS Servers set on USB LAN."

/// Go 1.1.0's journal as written on a VM: `null` for an Automatic baseline, the user's own servers otherwise.
let journal110 = #"{"dns":{"Wi-Fi":null,"Thunderbolt Bridge":null,"USB 10/100/1000 LAN":["192.168.1.53"]},"search":{"Wi-Fi":null,"Thunderbolt Bridge":null,"USB 10/100/1000 LAN":["fritz.box"]}}"#

/// A journal with 65 recorded servers (over the cap of 64).
let e2e6Over64 = "{\"dns\":{\"Wi-Fi\":[" + (1...65).map { "\"10.0.0.\($0)\"" }.joined(separator: ",") + "]}}"

/// E2E-6 (VMs, 200013, live Go helpers): the native helper removal's dead ends. The shell functions run unprivileged
/// against fixtures (a fake `networksetup` first on PATH, the real `plutil` and `grep`); nothing privileged runs.
@MainActor @Suite("E2E-6 helper removal fixes", .serialized, .timeLimit(.minutes(1)))
struct E2E6FixTests {
    /// Runs one of the script's functions under `/bin/sh` with a clean environment.
    static func sh(_ function: String, _ call: String, path: String = "/usr/bin:/bin:/usr/sbin:/sbin") throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "set -f\n" + function + "\n" + call]        // the body's `set -f` (E2E-7 F3 review N1)
        p.environment = ["PATH": path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// A fake `networksetup -getdnsservers <service>` answering from `answers` (service → stdout, exit status, stderr).
    static func fakeNetworksetup(_ dir: TestDir, _ answers: [String: (String, Int, String)]) throws -> String {
        let bin = dir.url.appending(path: "bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        func q(_ t: String) -> String { "'" + t.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        var cases = ""
        for (svc, (out, rc, err)) in answers {
            cases += "  \(q(svc))) printf '%s\\n' \(q(out)); \(err.isEmpty ? "" : "printf '%s\\n' \(q(err)) >&2;") exit \(rc) ;;\n"
        }
        let script = "#!/bin/sh\n[ \"$1\" = -getdnsservers ] || exit 9\ncase \"$2\" in\n\(cases)  *) echo \"$2 is not a recognized network service.\"; exit 4 ;;\nesac\n"
        let url = bin.appending(path: "networksetup")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return bin.path + ":/usr/bin:/bin"
    }

    // MARK: N1 a stale journal doesn't block the removal (review 650b251: null, manual servers, localized output)


    /// 0 = stale (goes), 1 = refuse ("set DNS to Automatic and try again"; also every fail-closed case), 2 = refuse,
    /// the user's own servers ("Restart your Mac — the old helper then restores …").
    @Test("N1: journalstale per recorded service: nothing recorded + Automatic, or the same own servers = stale",
          arguments: [
            (journal110, ["Wi-Fi": (e2e6NoDNS, 0, ""), "Thunderbolt Bridge": (e2e6NoDNS, 0, ""), "USB 10/100/1000 LAN": ("192.168.1.53", 0, "")], 0),
            (journal110, ["Wi-Fi": ("10.8.0.1", 0, ""), "Thunderbolt Bridge": (e2e6NoDNS, 0, ""), "USB 10/100/1000 LAN": ("192.168.1.53", 0, "")], 1),   // the VPN's resolver
            (journal110, ["Wi-Fi": (e2e6NoDNS, 0, ""), "Thunderbolt Bridge": (e2e6NoDNS, 0, ""), "USB 10/100/1000 LAN": (e2e6NoDNS, 0, "")], 2),     // own server gone
            (#"{"dns":{"Wi-Fi":null}}"#, ["Wi-Fi": ("Es gibt keine DNS-Server für Wi-Fi.", 0, "")], 0),                                 // German: no IP lines
            (#"{"dns":{"Wi-Fi":null}}"#, ["Wi-Fi": (e2e6NoDNS, 0, "2026-11-09 CFPreferences: warning 10.0.0.1")], 0),               // stderr never counts
            (#"{"dns":{"Wi-Fi":["192.168.1.1"]}}"#, ["Wi-Fi": ("192.168.1.1", 0, "CFPreferences: warning")], 0),
            (#"{"dns":{"Wi-Fi":["fd00::53"]}}"#, ["Wi-Fi": ("fd00::53", 0, "")], 0),
            (#"{"dns":{"Wi-Fi":[]},"search":{}}"#, ["Wi-Fi": (e2e6NoDNS, 0, "")], 0),
            (#"{"dns":{},"search":{}}"#, [:], 0),
            (#"{"dns":{"Wi-Fi":["192.168.1.1","8.8.8.8"]}}"#, ["Wi-Fi": ("8.8.8.8\n192.168.1.1", 0, "")], 2),                       // order differs
            (#"{"dns":{"Wi-Fi":["192.168.1.1"]}}"#, ["Wi-Fi": ("192.168.1.1\n10.8.0.1", 0, "")], 2),
            (#"{"dns":{"Wi-Fi":[]}}"#, ["Wi-Fi": ("10.8.0.1", 0, "")], 1),
            (#"{"dns":{"Thunderbolt.Bridge":null}}"#, ["Thunderbolt.Bridge": (e2e6NoDNS, 0, "")], 1),                              // unaddressable name
            (#"{"dns":{"@count":["1.1.1.1"]}}"#, [:], 1),
            (#"{"dns":{"Gone":["1.1.1.1"]}}"#, [:], 1),                                                                          // networksetup exit 4
            (#"{"dns":{"Wi-Fi":null}}"#, ["Wi-Fi": ("** Error: The parameters were not valid.", 0, "")], 1),
            (#"{"dns":{"Wi-Fi":"192.168.1.1"}}"#, ["Wi-Fi": (e2e6NoDNS, 0, "")], 1),                                            // not an array
            (#"{"dns":{"Wi-Fi":[1]}}"#, ["Wi-Fi": (e2e6NoDNS, 0, "")], 1),                                                     // not strings
            (e2e6Over64, ["Wi-Fi": (e2e6NoDNS, 0, "")], 1),                                                                     // > 64 servers
            (#"{"dns":["Wi-Fi"]}"#, [:], 1),
            (#"not json"#, [:], 1),
          ] as [(String, [String: (String, Int, String)], Int32)])
    func journalStaleness(_ journal: String, _ answers: [String: (String, Int, String)], _ expected: Int32) throws {
        let dir = TestDir()
        defer { dir.cleanup() }
        let path = try Self.fakeNetworksetup(dir, answers)
        let j = dir.url.appending(path: "dns-journal.json")
        try journal.write(to: j, atomically: true, encoding: .utf8)
        let rc = try Self.sh(LegacyHelperRemoval.journalStaleFunction, "journalstale '\(j.path)'", path: path)
        #expect(rc == expected, "rc \(rc) for \(journal)")
    }

    @Test("Review 650b251: the user's own servers refuse with the restart copy; plutil reads Go's null as (any)")
    func manualServersNeedARestart() async throws {
        #expect(LegacyHelperRemoval.outcome(of: "LP_RESULT=dns-unrestored-manual") == .dnsUnrestoredManual)
        let (h, _, runner) = E2E5FixTests().removalHarness(answer: .finished(output: "LP_RESULT=dns-unrestored-manual\n"),
                                                           leaves: [LegacyAppDetector.helperPlist, LegacyAppDetector.helperBinary])
        defer { h.dir.cleanup() }
        await h.env.legacy.refresh()
        await h.env.legacy.removeHelper()
        #expect(runner.runs == 1 && h.env.legacy.removal == .failed(.dnsRestartRestores))
        #expect(LegacyHelperCopy.removalProblem(.failed(.dnsRestartRestores)) == "Restart your Mac — the old helper then restores your DNS settings — then remove it.")
        // The plutil behaviour the function relies on (checked here on the dev Mac; the VM run repeats it).
        let dir = TestDir()
        defer { dir.cleanup() }
        let j = dir.url.appending(path: "j.json")
        try #"{"dns":{"Wi-Fi":null}}"#.write(to: j, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
        p.arguments = ["-type", "dns.Wi-Fi", j.path]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        #expect(p.terminationStatus == 0 && text.trimmingCharacters(in: .whitespacesAndNewlines) == "(any)")
    }

    @Test("N1: missing journal file fails closed; the script removes only a stale journal, after the bootout")
    func staleJournalHandling() throws {
        #expect(try Self.sh(LegacyHelperRemoval.journalStaleFunction, "journalstale /nonexistent/dns-journal.json") != 0)
        let s = LegacyHelperRemoval.script
        #expect(s.contains(#"journalcheck "$D""#) && s.contains(#"journalcheck "$D2""#))
        #expect(s.contains(#"rootfile "$J" || result dns-unrestored"#) && s.contains("result dns-unrestored-manual"))
        let removal = try #require(s.range(of: #"case "$SJ" in *"$C/dns-journal.json;"*) rm -f "$C/dns-journal.json";; esac"#)).lowerBound
        #expect(removal > (try #require(s.range(of: #"launchctl bootout "system/$L""#))).lowerBound)
        // `sh -n`: the whole script with the functions still parses.
        // E2E-7 F3 review M1: `sh -n` of the wrapper doesn't look inside its quoted body, so both are parsed.
        #expect(try E2E7FixTests.parses(s) && E2E7FixTests.parses(LegacyHelperRemoval.body))
    }

    @Test("N1: the refusal is re-read while it lasts (a restarted helper replays the journal), and its copy has three ways out")
    func theJournalStateIsWatched() async throws {
        let sys = SwitchableLegacySystem(files: [LegacyAppDetector.helperPlist, LegacyAppDetector.helperBinary, LegacyAppDetector.dnsJournal], probe: .unreachable)
        let h = Harness(legacySystem: sys)
        defer { h.dir.cleanup() }
        h.env.legacy.pollInterval = .milliseconds(20)
        UIBinder.bind(h.env)
        await h.env.legacy.refresh()
        #expect(h.env.legacy.isWatching)
        #expect(await eventually { h.env.ui.connection.legacyHelper?.message.contains("restart your Mac") == true })
        #expect(h.env.ui.connection.legacyHelper?.canRemoveHelper == true)            // root decides; not a dead end
        sys.setFiles([LegacyAppDetector.helperPlist, LegacyAppDetector.helperBinary])   // the helper replayed it at login
        sys.set(.reachable(active: false, killSwitchBlocked: false))
        #expect(await eventually { h.env.ui.connection.legacyHelper?.message.contains("restart your Mac") == false })
        #expect(await eventually { !h.env.legacy.isWatching })
    }

    // MARK: N2 DNS-protection leftovers aren't a kill switch

    @Test("N2: dnsonly: only port-53 rules count as DNS protection", arguments: [
        ("block drop out quick proto tcp from any to any port = 53\nblock drop out quick proto udp from any to any port = 53\npass out quick on utun4 proto udp from any to 10.0.0.1 port = 53\npass out quick on utun4 proto tcp from any to 10.0.0.1 port = 53 flags any", true),
        ("block drop out quick proto udp from any to any port = domain", true),
        ("block drop out quick proto udp from any to any port = 53\nblock drop out all", false),       // a kill switch
        ("pass out quick proto udp from any to any port = 5353", false),
        ("", false),
    ])
    func dnsOnlyRules(_ rules: String, _ dnsOnly: Bool) throws {
        let quoted = "'" + rules.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let rc = try Self.sh(LegacyHelperRemoval.dnsOnlyFunction, "dnsonly \(quoted)")
        #expect((rc == 0) == dnsOnly, "\(rules)")
    }

    @Test("N2: port-53-only rules give their own refusal and copy, before anything is removed")
    func dnsProtectionLeftIsItsOwnReason() async throws {
        let s = LegacyHelperRemoval.script
        let refusal = try #require(s.range(of: "result dns-protection-left")).lowerBound
        #expect(refusal < (try #require(s.range(of: "launchctl bootout"))).lowerBound)
        #expect(try #require(s.range(of: "tunnelcheck \"$D\" \"$L\" \"$B\"")).lowerBound < refusal)   // a live tunnel stays "busy"
        #expect(LegacyHelperRemoval.outcome(of: "LP_RESULT=dns-protection-left") == .dnsProtectionLeft)
        let (h, _, runner) = E2E5FixTests().removalHarness(answer: .finished(output: "LP_RESULT=dns-protection-left\n"),
                                                           leaves: [LegacyAppDetector.helperPlist, LegacyAppDetector.helperBinary])
        defer { h.dir.cleanup() }
        await h.env.legacy.refresh()
        await h.env.legacy.removeHelper()
        #expect(runner.runs == 1 && h.env.legacy.removal == .failed(.dnsProtectionLeft))
        let copy = LegacyHelperCopy.removalProblem(.failed(.dnsProtectionLeft))
        #expect(copy.contains("DNS protection") && copy.contains("Restart your Mac") && !copy.contains("still connected"))
    }

    // MARK: N3 leftovers come from root

    @Test("N3: the files the script kept are reported in its output and taken from there, not from the app's lstat")
    func keptFilesComeFromTheScript() async throws {
        let out = "LP_KEPT=dns-journal /Library/Application Support/lockplus/dns-journal.json\nLP_KEPT=pf-was-enabled /Library/Application Support/lockplus/pf-was-enabled\nLP_RESULT=removed-left-state\n"
        let kept = LegacyHelperRemoval.kept(in: out)
        #expect(kept.map(\.kind) == ["dns-journal", "pf-was-enabled"])
        #expect(kept.first?.path == "/Library/Application Support/lockplus/dns-journal.json")
        #expect(LegacyHelperRemoval.kept(in: "LP_RESULT=removed\n").isEmpty)
        // 1.0.x: the data directory is root 0700, so the app's own facts see no leftovers at all.
        let (h, _, _) = E2E5FixTests().removalHarness(answer: .finished(output: out))
        defer { h.dir.cleanup() }
        await h.env.legacy.refresh()
        #expect(!h.env.legacy.facts.dnsJournal && !h.env.legacy.facts.pfWasEnabled)
        await h.env.legacy.removeHelper()
        #expect(h.env.legacy.removal == .removed(leftNetworkState: true))
        let s = LegacyHelperRemoval.script
        #expect(s.contains(#"echo "LP_KEPT=dns-journal $C/dns-journal.json""#) && s.contains(#"echo "LP_KEPT=pf-was-enabled $C/pf-was-enabled""#))
    }

    @Test("Review 650b251 INFO: removed-left-state is read like every result, from the last LP_RESULT line only")
    func leftStateUsesTheLastResult() async {
        let (h, _, _) = E2E5FixTests().removalHarness(answer: .finished(output: "LP_RESULT=removed-left-state\nLP_RESULT=removed\n"))
        defer { h.dir.cleanup() }
        await h.env.legacy.refresh()
        await h.env.legacy.removeHelper()
        #expect(h.env.legacy.removal == .removed(leftNetworkState: false))
    }

    // MARK: Fable follow-up check (d28d309, 0989a94)

    @Test("LOW-3: a socket that is there but never answers is 'not responding'; a refused or missing one is 'not running'")
    func aWedgedHelperIsNotResponding() throws {
        // sun_path holds 104 bytes: a short name in the user's Caches folder (never /tmp).
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let path = caches.appending(path: "lpt-\(UUID().uuidString.prefix(8)).sock").path
        defer { unlink(path) }
        #expect(path.utf8.count < 100)
        func bound(listen: Bool) throws -> Int32 {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8CString)
            withUnsafeMutableBytes(of: &addr.sun_path) { dst in bytes.withUnsafeBytes { dst.copyMemory(from: $0) } }
            let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            #expect(rc == 0)
            if listen { #expect(Darwin.listen(fd, 4) == 0) }
            return fd
        }
        #expect(LiveLegacySystem.probeNow(path, deadline: Date().addingTimeInterval(0.3)) == .unreachable)      // no socket
        let listener = try bound(listen: true)                       // accepts (backlog) but never replies: wedged
        #expect(LiveLegacySystem.probeNow(path, deadline: Date().addingTimeInterval(0.3)) == .notResponding)
        close(listener)                                              // the file stays, nobody listens: refused
        #expect(LiveLegacySystem.probeNow(path, deadline: Date().addingTimeInterval(0.3)) == .unreachable)
        #expect(LiveLegacySystem.combine([.unreachable, .notResponding]) == .notResponding)
        #expect(LiveLegacySystem.combine([.notResponding, .reachable(active: false, killSwitchBlocked: true)]) == .reachable(active: false, killSwitchBlocked: true))
        #expect(LiveLegacySystem.combine([.reachable(active: true, killSwitchBlocked: false), .reachable(active: false, killSwitchBlocked: true)])
                == .reachable(active: true, killSwitchBlocked: true))
    }

    @Test("LOW-3: a helper that doesn't respond is refused without an administrator prompt, with its own copy")
    func aWedgedHelperIsRefusedWithoutAPrompt() async {
        let sys = SwitchableLegacySystem(files: [LegacyAppDetector.helperPlist, LegacyAppDetector.helperBinary], probe: .notResponding)
        let runner = FakePrivilegedRunner(answer: .finished(output: "LP_RESULT=removed\n"))
        let h = Harness(legacySystem: sys, legacyHelperRunner: runner)
        defer { h.dir.cleanup() }
        UIBinder.bind(h.env)
        await h.env.legacy.refresh()
        #expect(h.env.legacy.facts.helperNotResponding && h.env.legacy.refusal == .notResponding && !h.env.legacy.canRemoveHelper)
        #expect(await eventually { h.env.ui.connection.legacyHelper?.message.contains("isn't responding") == true })
        await h.env.legacy.removeHelper()
        #expect(runner.runs == 0 && h.env.legacy.removal == .failed(.notResponding))
        #expect(LegacyHelperCopy.removalProblem(.failed(.notResponding)) == "The old helper isn't responding. Restart your Mac, then remove it.")
    }

    @Test("LOW-1: the signature check runs off the main actor and answers false for anything not ours")
    func theSignatureCheckIsOffMain() async {
        let sys = LiveLegacySystem()
        #expect(await sys.signedByOurTeam("/bin/ls") == false)
        #expect(await sys.signedByOurTeam("/bin/ls") == false)       // cached by path, mtime and size
        #expect(await sys.signedByOurTeam("/nonexistent/helper") == false)
    }
}
