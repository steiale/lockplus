import AppKit
import Foundation
import os
import Security
import Synchronization

/// What the Go helper's read-only `Tunnel.Status` call says (§4.5 step 2).
enum HelperProbe: Sendable, Equatable {
    case unreachable
    /// `active`: a tunnel is connecting/connected; `killSwitchBlocked`: its kill switch holds traffic (pf anchor loaded).
    case reachable(active: Bool, killSwitchBlocked: Bool)
    /// Fable follow-up LOW-3: the socket is there but the helper doesn't answer in time (wedged), as opposed to no socket
    /// or a refused connection (not running). Go 1.2.0 treats only the latter as idle.
    case notResponding
}

/// The raw §4.5 facts (no root needed for any of them).
struct LegacyFacts: Sendable, Equatable, Codable {
    var helperInstalled = false
    /// nil = not probed (no helper installed).
    var helperReachable: Bool?
    var helperActive = false
    var killSwitchBlocked = false
    var goGUIRunning = false
    /// E2E-5 F8: the old app (bundle ID `io.github.steiale.lockplus`) is still installed; after a Finder Replace it
    /// isn't, and "Open the old LockPlus" is hidden.
    var goAppInstalled = false
    var dnsJournal = false
    var pfWasEnabled = false
    /// Fable pre-release A-4: the helper's binary without its plist (nothing launches it; it can still be removed).
    var orphanBinary = false
    /// Fable follow-up LOW-3: its socket exists but it doesn't answer (restart first; no administrator prompt).
    var helperNotResponding = false
}

/// The §4.5 policy table, one finding per state.
enum LegacyFinding: Sendable, Equatable {
    case none
    /// Helper reports an active tunnel or a kill-switch block: refuse to connect.
    case refuseConnect
    /// Helper installed, idle (or unreachable without the pf marker): allow, persistent banner.
    case helperIdle
    /// Helper installed but unreachable and `pf-was-enabled` exists: allow, warn before connecting.
    case helperCrashedWithFirewall
    /// A DNS journal or `pf-was-enabled` without a helper: banner with instructions.
    case leftoverState
    /// Fable pre-release A-4: only the helper's binary is left (no plist, no network state): removable.
    case orphanBinary

    var blocksConnect: Bool { self == .refuseConnect }
    var warnsBeforeConnect: Bool { self == .helperCrashedWithFirewall }

    static func evaluate(_ f: LegacyFacts) -> LegacyFinding {
        if f.helperInstalled {
            if f.helperReachable == true { return f.helperActive || f.killSwitchBlocked ? .refuseConnect : .helperIdle }
            return f.pfWasEnabled ? .helperCrashedWithFirewall : .helperIdle
        }
        if f.dnsJournal || f.pfWasEnabled { return .leftoverState }
        return f.orphanBinary ? .orphanBinary : .none
    }

    /// The copy the UI shows (DESIGN §4.5).
    var message: String? {
        switch self {
        case .none: nil
        case .refuseConnect:
            String(localized: "Disconnect in the old LockPlus and turn off its kill switch first.", comment: "§4.5 refuse to connect")
        case .helperIdle:
            String(localized: "The old LockPlus helper is still installed. LockPlus can remove it; macOS asks for an administrator password.", comment: "§4.5 banner (E2E-5 F1)")
        case .helperCrashedWithFirewall:
            String(localized: "The old LockPlus may have left its firewall on. If connecting fails, restart your Mac.", comment: "§4.5 warning (E2E-5 F7)")
        case .orphanBinary:
            String(localized: "A file of the old LockPlus helper is still installed. LockPlus can remove it; macOS asks for an administrator password.", comment: "§4.5 banner: only the helper's binary is left (Fable pre-release A-4)")
        case .leftoverState:
            String(localized: "The old LockPlus left network settings behind. If websites don't load, set DNS back to Automatic in System Settings › Network, then restart your Mac.", comment: "§4.5 banner (review E2E-5 F1-2: a restart clears pf, not DNS)")
        }
    }
}

/// System reads for the detector; live = the paths below, tests use fixtures.
protocol LegacySystemReading: Sendable {
    func fileExists(_ path: String) -> Bool
    /// Every known helper's socket (LockPlus 1.x, WireGuide+): reachable if one answers, active if one is.
    func probeHelper() async -> HelperProbe
    /// The old LockPlus (`io.github.steiale.lockplus`) or WireGuide+ (`io.github.steiale.wireguide-plus`) runs.
    @MainActor func goGUIRunning() -> Bool
    /// Where the old app is installed (nil: not installed). Never this app.
    @MainActor func goAppURL() -> URL?
    /// Migration matrix: whether a binary is signed by our team (M53GHX9FAY). `com.wireguide.helper` is upstream
    /// WireGuide's live label; only a helper we signed under it (WireGuide+ 1.0.0) is ours.
    func signedByOurTeam(_ path: String) async -> Bool
    /// WireGuide+ 1.0.0's GUI (`com.korjwl1.wireguide`, upstream WireGuide's ID): asked only when its helper is ours.
    @MainActor func wireGuide100Running() -> Bool
    /// Migration matrix: the old WireGuide+ app (`io.github.steiale.wireguide-plus`), outside the Trash; nil if absent.
    @MainActor func wireGuidePlusAppURL() -> URL?
    @MainActor func wireGuidePlusRunning() -> Bool
    /// Moves the old app to the Trash (the user confirmed); true when it is there.
    @MainActor func moveToTrash(_ url: URL) async -> Bool
}

extension LegacySystemReading {
    @MainActor func goAppURL() -> URL? { nil }
    func signedByOurTeam(_ path: String) async -> Bool { false }
    @MainActor func wireGuide100Running() -> Bool { false }
    @MainActor func wireGuidePlusAppURL() -> URL? { nil }
    @MainActor func wireGuidePlusRunning() -> Bool { false }
    @MainActor func moveToTrash(_ url: URL) async -> Bool { false }
}

/// The old WireGuide+ app is still installed (the 1.x update put LockPlus next to it): offered for the Trash.
struct OldAppNotice: Sendable, Equatable {
    var url: URL
    /// It runs: "Quit WireGuide+ first" instead of the Move button.
    var running: Bool
}

/// One generation of the old app's root helper (migration matrix, docs: DESIGN §13.3a).
struct LegacyHelperPaths: Sendable, Equatable {
    let label: String
    let plist: String
    let binary: String
    let socket: String
    let dataDir: String
    var dnsJournal: String { dataDir + "/dns-journal.json" }
    var pfWasEnabled: String { dataDir + "/pf-was-enabled" }

    /// LockPlus 1.0.57–1.1.0 (Developer ID, identifier `lockplus-helper`).
    static let lockplus = LegacyHelperPaths(label: "io.github.steiale.lockplus.helper",
                                            plist: "/Library/LaunchDaemons/io.github.steiale.lockplus.helper.plist",
                                            binary: "/Library/PrivilegedHelperTools/io.github.steiale.lockplus.helper",
                                            socket: "/var/run/lockplus/lockplus.sock", dataDir: "/Library/Application Support/lockplus")
    /// WireGuide+ 1.0.1–1.0.56 (early builds weren't Developer ID signed: identified by label, path and root owner).
    static let wireGuidePlus = LegacyHelperPaths(label: "io.github.steiale.wireguide-plus.helper",
                                                 plist: "/Library/LaunchDaemons/io.github.steiale.wireguide-plus.helper.plist",
                                                 binary: "/Library/PrivilegedHelperTools/io.github.steiale.wireguide-plus.helper",
                                                 socket: "/var/run/wireguide-plus/wireguide-plus.sock",
                                                 dataDir: "/Library/Application Support/wireguide-plus")
    /// WireGuide+ 1.0.0 used upstream WireGuide's names: ours only when the binary is signed by our team.
    static let upstreamLabel = LegacyHelperPaths(label: "com.wireguide.helper", plist: "/Library/LaunchDaemons/com.wireguide.helper.plist",
                                                 binary: "/Library/PrivilegedHelperTools/com.wireguide.helper",
                                                 socket: "/var/run/wireguide/wireguide.sock", dataDir: "/Library/Application Support/wireguide")
    /// Always ours (the third only after the signature check).
    static let ours: [LegacyHelperPaths] = [.lockplus, .wireGuidePlus]
}

/// `LegacyAppDetector` (DESIGN §4.5, app side: the extension can't see pf). Read-only: one `Tunnel.Status` call,
/// never anything that changes the Go helper's state. Root state is never touched.
enum LegacyAppDetector {
    static let helperPlist = LegacyHelperPaths.lockplus.plist
    static let helperBinary = LegacyHelperPaths.lockplus.binary
    static let socketPath = LegacyHelperPaths.lockplus.socket
    static let dnsJournal = LegacyHelperPaths.lockplus.dnsJournal
    static let pfWasEnabled = LegacyHelperPaths.lockplus.pfWasEnabled
    static let goBundleID = "io.github.steiale.lockplus"
    /// WireGuide+ 1.0.1–1.0.56 (`WireGuide+.app`, executable `wireguide-plus`).
    static let wireGuidePlusBundleID = "io.github.steiale.wireguide-plus"

    /// The helpers that are ours on this Mac: LockPlus's and WireGuide+'s, and `com.wireguide.helper` only when its
    /// binary is signed by our team (otherwise it is upstream WireGuide's and LockPlus leaves it alone).
    static func helpers(_ sys: any LegacySystemReading) async -> [LegacyHelperPaths] {
        let up = LegacyHelperPaths.upstreamLabel
        guard sys.fileExists(up.binary) else { return LegacyHelperPaths.ours }
        let upstreamIsOurs = await sys.signedByOurTeam(up.binary)
        return LegacyHelperPaths.ours + (upstreamIsOurs ? [up] : [])
    }

    @MainActor static func facts(_ sys: any LegacySystemReading) async -> LegacyFacts {
        var f = LegacyFacts()
        let helpers = await helpers(sys)
        f.helperInstalled = helpers.contains { sys.fileExists($0.plist) }
        f.dnsJournal = helpers.contains { sys.fileExists($0.dnsJournal) }
        f.pfWasEnabled = helpers.contains { sys.fileExists($0.pfWasEnabled) }
        // Fable follow-up INFO: WireGuide+ 1.0.0's GUI counts only when its helper is ours (upstream WireGuide running
        // never blocks a removal).
        f.goGUIRunning = sys.goGUIRunning() || (helpers.contains(.upstreamLabel) && sys.wireGuide100Running())
        f.goAppInstalled = sys.goAppURL() != nil
        f.orphanBinary = helpers.contains { !sys.fileExists($0.plist) && sys.fileExists($0.binary) }
        if f.helperInstalled {
            switch await sys.probeHelper() {
            case .unreachable: f.helperReachable = false
            case .notResponding:
                f.helperReachable = false
                f.helperNotResponding = true
            case .reachable(let active, let blocked):
                f.helperReachable = true
                f.helperActive = active
                f.killSwitchBlocked = blocked
            }
        }
        return f
    }

    /// The Go IPC frame: 4-byte big-endian length + JSON-RPC 2.0 (`internal/ipc/framing.go`).
    static func statusRequestFrame() -> [UInt8] {
        let body = Array(#"{"jsonrpc":"2.0","id":1,"method":"Tunnel.Status"}"#.utf8)
        let n = UInt32(body.count)
        return [UInt8(n >> 24), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)] + body
    }

    /// Parses the reply to request id 1 (`domain.ConnectionStatus`: `state`, `kill_switch_blocked`).
    static func parseStatusReply(_ body: [UInt8]) -> HelperProbe? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(body)) as? [String: Any], obj["id"] as? Int == 1,
              let result = obj["result"] as? [String: Any] else { return nil }
        let state = result["state"] as? String ?? "disconnected"
        return .reachable(active: state == "connected" || state == "connecting",
                          killSwitchBlocked: result["kill_switch_blocked"] as? Bool ?? false)
    }
}

/// Live reads. The socket probe runs on its own serial queue with a 2 s deadline (never a blocking connect on the
/// cooperative pool, §4.5 step 2). The Go IPC authenticates by uid only, which is why this read-only call works.
struct LiveLegacySystem: LegacySystemReading {
    private static let queue = DispatchQueue(label: "lockplus.legacy-helper")

    func fileExists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    @MainActor func goGUIRunning() -> Bool {
        [LegacyAppDetector.goBundleID, LegacyAppDetector.wireGuidePlusBundleID].contains {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
        }
    }

    @MainActor func wireGuide100Running() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.korjwl1.wireguide").isEmpty
    }

    /// Fable follow-up LOW-1: the strict check hashes the whole file, so it runs on the detector's serial queue (never
    /// the main actor) and is cached by path, modification time and size.
    private static let signatureCache = Mutex<[String: (mtime: Int, size: Int64, ours: Bool)]>([:])

    func signedByOurTeam(_ path: String) async -> Bool {
        await withCheckedContinuation { (k: CheckedContinuation<Bool, Never>) in
            Self.queue.async { @Sendable in
                var st = stat()
                guard lstat(path, &st) == 0 else { k.resume(returning: false); return }
                let mtime = Int(st.st_mtimespec.tv_sec), size = Int64(st.st_size)
                if let c = Self.signatureCache.withLock({ $0[path] }), c.mtime == mtime, c.size == size {
                    k.resume(returning: c.ours)
                    return
                }
                let ours = Self.checkSignedByOurTeam(path)
                Self.signatureCache.withLock { $0[path] = (mtime, size, ours) }
                k.resume(returning: ours)
            }
        }
    }

    /// Signed by team M53GHX9FAY (any identifier): a static check of the file, nothing is executed.
    private static func checkSignedByOurTeam(_ path: String) -> Bool {
        var code: SecStaticCode?
        var req: SecRequirement?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(#"anchor apple generic and certificate leaf[subject.OU] = "M53GHX9FAY""# as CFString, [], &req) == errSecSuccess,
              let req else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), req) == errSecSuccess
    }

    /// Launch Services may still name a deleted or trashed copy: only an existing bundle outside the Trash counts.
    @MainActor func wireGuidePlusAppURL() -> URL? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: LegacyAppDetector.wireGuidePlusBundleID),
              url.standardizedFileURL != Bundle.main.bundleURL.standardizedFileURL,
              !url.path.contains("/.Trash/"), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    @MainActor func wireGuidePlusRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: LegacyAppDetector.wireGuidePlusBundleID).isEmpty
    }

    @MainActor func moveToTrash(_ url: URL) async -> Bool {
        // The bundle must still be the old app (a Launch Services answer can be stale): its Info.plist names its ID.
        guard Bundle(url: url)?.bundleIdentifier == LegacyAppDetector.wireGuidePlusBundleID else { return false }
        return await withCheckedContinuation { (k: CheckedContinuation<Bool, Never>) in
            NSWorkspace.shared.recycle([url]) { @Sendable moved, error in k.resume(returning: error == nil && !moved.isEmpty) }
        }
    }

    @MainActor func goAppURL() -> URL? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: LegacyAppDetector.goBundleID),
              url.standardizedFileURL != Bundle.main.bundleURL.standardizedFileURL,
              !url.path.contains("/.Trash/"), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func probeHelper() async -> HelperProbe {
        await withCheckedContinuation { (k: CheckedContinuation<HelperProbe, Never>) in
            Self.queue.async { @Sendable in
                // Every known helper's socket (migration matrix: WireGuide+'s too), in parallel under one shared 2 s
                // deadline (Fable follow-up INFO: §4.5 promises ≤ 2 s).
                let deadline = Date().addingTimeInterval(2)
                let sockets = LegacyHelperPaths.ours.map(\.socket)
                let results = Mutex([HelperProbe](repeating: .unreachable, count: sockets.count))
                DispatchQueue.concurrentPerform(iterations: sockets.count) { i in
                    let r = Self.probeNow(sockets[i], deadline: deadline)
                    results.withLock { $0[i] = r }
                }
                k.resume(returning: Self.combine(results.withLock { $0 }))
            }
        }
    }

    /// Any answer wins (active or blocked if one is); otherwise a wedged helper; otherwise none running.
    static func combine(_ probes: [HelperProbe]) -> HelperProbe {
        var out = HelperProbe.unreachable
        for p in probes {
            switch (out, p) {
            case (.reachable(let a0, let b0), .reachable(let a, let b)): out = .reachable(active: a0 || a, killSwitchBlocked: b0 || b)
            case (_, .reachable): out = p
            case (.unreachable, .notResponding): out = .notResponding
            default: break
            }
        }
        return out
    }

    /// FA nit: only a socket owned by this user (the Go helper creates it 0600 for the GUI user) is talked to.
    static func socketIsOurs(_ path: String, uid: uid_t = getuid()) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFSOCK && st.st_uid == uid
    }

    static func probeNow(_ socketPath: String, deadline: Date) -> HelperProbe {
        guard socketIsOurs(socketPath) else { return .unreachable }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .unreachable }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketPath.utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return .unreachable }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in path.withUnsafeBytes { dst.copyMemory(from: $0) } }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) } }
        // Fable follow-up LOW-3: a refused connect (no listener) is "not running"; a connect, write or reply that runs
        // into the deadline on a socket that is there is "not responding".
        if rc != 0 {
            guard errno == EINPROGRESS else { return .unreachable }
            guard wait(fd, events: Int16(POLLOUT), until: deadline) else { return .notResponding }
            var err: Int32 = 0
            var elen = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &elen) == 0, err == 0 else { return .unreachable }
        }
        let frame = LegacyAppDetector.statusRequestFrame()
        var sent = 0
        while sent < frame.count {
            guard wait(fd, events: Int16(POLLOUT), until: deadline) else { return .notResponding }
            let n = frame[sent...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n <= 0 { if errno == EAGAIN { continue }; return .unreachable }
            sent += n
        }
        // Up to 3 frames (skip notifications), each ≤ 64 KiB: a status reply is small.
        for _ in 0..<3 {
            var timedOut = false
            guard let header = readExactly(fd, 4, deadline, timedOut: &timedOut) else { return timedOut ? .notResponding : .unreachable }
            let n = Int(header[0]) << 24 | Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            guard n > 0, n <= 64 << 10 else { return .unreachable }
            guard let body = readExactly(fd, n, deadline, timedOut: &timedOut) else { return timedOut ? .notResponding : .unreachable }
            if let probe = LegacyAppDetector.parseStatusReply(body) { return probe }
        }
        return .unreachable
    }

    private static func wait(_ fd: Int32, events: Int16, until deadline: Date) -> Bool {
        let ms = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
        guard ms > 0 else { return false }
        var p = pollfd(fd: fd, events: events, revents: 0)
        return poll(&p, 1, ms) == 1 && p.revents & events != 0
    }

    private static func readExactly(_ fd: Int32, _ count: Int, _ deadline: Date, timedOut: inout Bool) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            guard wait(fd, events: Int16(POLLIN), until: deadline) else { timedOut = true; return nil }
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress! + got, count - got) }
            if n == 0 { return nil }
            if n < 0 { if errno == EAGAIN { continue }; return nil }
            got += n
        }
        return buf
    }
}

/// Preview mode and tests.
struct FixtureLegacySystem: LegacySystemReading {
    var files: Set<String> = []
    var probe: HelperProbe = .unreachable
    var guiRunning = false
    var appInstalled = false
    func fileExists(_ path: String) -> Bool { files.contains(path) }
    func probeHelper() async -> HelperProbe { probe }
    @MainActor func goGUIRunning() -> Bool { guiRunning }
    @MainActor func goAppURL() -> URL? { appInstalled ? URL(fileURLWithPath: "/Applications/LockPlus.app") : nil }
}

/// The app-side state the UI reads (§4.5): refreshed at launch, before every connect while a helper may be installed,
/// by Diagnostics "Run All", and every `pollInterval` while the old helper refuses connecting (E2E-5 F3), so the
/// notice clears when the old tunnel goes down.
@MainActor @Observable final class LegacyHelperStore {
    private(set) var facts = LegacyFacts()
    private(set) var finding = LegacyFinding.none
    /// E2E-5 F1: "Remove Old Helper"; nil until the user asked.
    private(set) var removal: LegacyHelperRemovalState?
    /// Migration matrix: the old WireGuide+ app is still installed (offered for the Trash); nil when it isn't.
    private(set) var oldApp: OldAppNotice?
    /// The last move to the Trash failed (the banner says so).
    private(set) var oldAppTrashFailed = false
    @ObservationIgnored private let system: any LegacySystemReading
    @ObservationIgnored private let runner: any PrivilegedScriptRunning
    @ObservationIgnored private let log = Logger(subsystem: "io.github.steiale.lockplus.mac", category: "lifecycle")
    /// E2E-5 F3: how often a refusing helper is re-read (tests shorten it).
    @ObservationIgnored var pollInterval: Duration = .seconds(5)
    /// E2E-7 F3 review L4: whether LockPlus's own tunnel is up (set by `AppEnvironment`), to explain a "busy" from root.
    @ObservationIgnored var nativeTunnelUp: @MainActor () -> Bool = { false }
    @ObservationIgnored private var watch: Task<Void, Never>?
    @ObservationIgnored private var removalInFlight = false

    init(system: any LegacySystemReading, runner: any PrivilegedScriptRunning = FakePrivilegedRunner()) {
        self.system = system
        self.runner = runner
    }

    /// The banner offers "Remove Old Helper…" for an installed, idle helper (§4.5 row 2; E2E-5 F1).
    /// Not while the old app runs (review E2E-5 F1-1: its health monitor would reinstall the helper behind a second,
    /// Go-branded administrator prompt), and not while an unreachable helper's DNS journal waits for its replay (F1-2).
    var canRemoveHelper: Bool { refusal == nil && removal != .removing }

    /// Why the removal can't run now (nil: it can).
    /// Fable pre-release A-4: a helper binary left without its plist (`.orphanBinary`, or next to leftover network state)
    /// is removable too (the script pins its signature); a DNS journal nothing would replay refuses with that reason,
    /// not "busy".
    var refusal: LegacyHelperRemovalState.Failure? {
        if finding.blocksConnect || finding == .helperCrashedWithFirewall { return .busy }
        switch finding {
        case .helperIdle, .orphanBinary: break
        case .leftoverState where facts.orphanBinary: break
        default: return .busy
        }
        if facts.goGUIRunning { return .oldAppRunning }
        if facts.helperNotResponding { return .notResponding }       // Fable follow-up LOW-3: no prompt for a wedged helper
        // E2E-6 N1: an un-replayed DNS journal no longer refuses here. Only root can read it and tell whether it would
        // still restore anything (set back to Automatic, it wouldn't): the script decides (`journalstale`).
        return nil
    }

    /// E2E-6 N1: the helper isn't running and its DNS journal is still there (the banner explains; the poll notices
    /// when a restarted helper replays it).
    var dnsJournalUnreplayed: Bool { facts.helperReachable != true && facts.dnsJournal }

    /// E2E-5 F1, DESIGN §13.3a: one privileged run of `LegacyHelperRemoval.script` after one administrator
    /// authentication. Re-reads the helper first and refuses while it protects the Mac (§4.5); the script checks again as
    /// root. The result is verified by reading the facts again.
    /// Pre-release review M4: one removal at a time. The flag is set before the first await (the re-read), so a
    /// double-click can't reach a second administrator prompt; `defer` resets it on every exit.
    func removeHelper() async {
        guard !removalInFlight, removal != .removing else { return }
        removalInFlight = true
        defer { removalInFlight = false }
        await refresh()
        // Review LOW: nothing to remove (it went away meanwhile, e.g. the Go 1.2 "Farewell"): no "was removed" strip
        // for a removal LockPlus didn't do; the refreshed finding drops the banner.
        guard facts.helperInstalled || facts.orphanBinary else { removal = nil; return }
        // Review E2E-5 F1-6: the same rule as the button, enforced here.
        guard canRemoveHelper else { removal = .failed(refusal ?? .busy); return }
        removal = .removing
        log.notice("removing the old Go helper (administrator authentication)")
        let result = await runner.runAsAdministrator(script: LegacyHelperRemoval.script, prompt: LegacyHelperRemoval.prompt)
        await refresh()
        let next: LegacyHelperRemovalState
        switch result {
        case .cancelled: next = .cancelled
        case .failed(let message): next = .failed(.couldNotRun(message))
        case .finished(let output):
            switch LegacyHelperRemoval.outcome(of: output) {
            case .removed?, .removedLeftState?:
                // Verified here too: the helper's plist must be gone. E2E-6 N3: what was kept comes from the script (root can
                // see into 1.0.x's root-only data directory; this app can't).
                let kept = !LegacyHelperRemoval.kept(in: output).isEmpty || LegacyHelperRemoval.outcome(of: output) == .removedLeftState
                next = facts.helperInstalled || facts.orphanBinary ? .failed(.incomplete)
                    : .removed(leftNetworkState: kept || facts.dnsJournal || facts.pfWasEnabled, staleTunnel: LegacyHelperRemoval.staleTunnel(in: output))
            case .busy?:
                // Review L5: only a tunnel-state busy can be LockPlus's own utun; a pf busy (a kill switch, also WireGuide's)
                // and a busy without a reason line keep the plain copy, which names the kill switch.
                next = .failed(LegacyHelperRemoval.busyFromTunnelState(in: output) && nativeTunnelUp() ? .busyWhileConnected : .busy)
            case .dnsUnrestored?: next = .failed(.dnsNotRestored)
            case .dnsUnrestoredManual?: next = .failed(.dnsRestartRestores)
            case .dnsProtectionLeft?: next = .failed(.dnsProtectionLeft)
            case .oldAppRunning?: next = .failed(.oldAppRunning)
            case .notGoPlist?, .notGoBinary?: next = .failed(.notTheOldHelper)
            case .stillRunning?, .incomplete?, nil: next = .failed(.incomplete)
            }
        }
        removal = next
        log.notice("old Go helper removal: \(String(describing: next), privacy: .public)")
    }

    /// Migration matrix: moves the old WireGuide+ app to the Trash after the user confirmed. Never while it runs.
    func trashOldApp() async {
        await refresh()
        guard let app = oldApp, !app.running else { return }
        let moved = await system.moveToTrash(app.url)
        log.notice("old WireGuide+ app moved to the Trash: \(moved, privacy: .public)")
        oldAppTrashFailed = !moved
        await refresh()
    }

    /// The removal's strip was dismissed.
    func clearRemoval() { if removal != .removing { removal = nil } }

    /// The cached fact, or a fresh `lstat` of the helper plist (cheap, no root): whether a connect must re-read it.
    var helperMayBePresent: Bool { facts.helperInstalled || LegacyHelperPaths.ours.contains { system.fileExists($0.plist) } }

    func refresh() async {
        let before = finding
        facts = await LegacyAppDetector.facts(system)
        let app = system.wireGuidePlusAppURL().map { OldAppNotice(url: $0, running: system.wireGuidePlusRunning()) }
        if app != oldApp { oldApp = app }
        finding = LegacyFinding.evaluate(facts)
        // Review LOW: a change is a notice; the unchanged finding of every 5 s poll while refusing is debug only.
        if finding != before {
            log.notice("legacy Go app finding: \(String(describing: self.finding), privacy: .public)")
        } else if finding.blocksConnect {
            log.debug("legacy Go app finding unchanged: \(String(describing: self.finding), privacy: .public)")
        }
        if watchWorthy { watchWhileRefusing() }
    }

    /// Re-read while connecting is refused, and while the old app's running holds back the removal (so the banner
    /// offers it as soon as the old app quits).
    private var watchWorthy: Bool {
        finding.blocksConnect || ((finding == .helperIdle || finding == .orphanBinary) && facts.goGUIRunning)
            || (finding != .none && dnsJournalUnreplayed)        // E2E-6 N1: until the restarted helper replays it
            || (finding != .none && facts.helperNotResponding)
    }

    /// A poll loop runs (tests: polling has stopped, without a negative sleep).
    var isWatching: Bool { watch != nil }

    /// One poll loop at a time, ending as soon as the finding no longer refuses.
    private func watchWhileRefusing() {
        guard watch == nil else { return }
        watch = Task { @MainActor [weak self] in
            while let interval = self?.pollInterval {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                await self.refresh()
                if !self.watchWorthy { break }
            }
            self?.watch = nil
        }
    }

    /// The Diagnostics "Old LockPlus helper" row.
    var check: DiagnosticCheck {
        let detail = (try? String(decoding: JSONEncoder().encode(facts), as: UTF8.self)) ?? ""
        return switch finding {
        case .none:
            DiagnosticCheck(kind: .oldHelper, result: .pass, summary: String(localized: "Not installed", comment: "Diagnostics old-helper row"), detail: detail)
        case .helperIdle, .leftoverState, .orphanBinary:
            DiagnosticCheck(kind: .oldHelper, result: .warning, summary: finding.message ?? "", detail: detail)
        case .refuseConnect, .helperCrashedWithFirewall:
            DiagnosticCheck(kind: .oldHelper, result: .fail, summary: finding.message ?? "", detail: detail)
        }
    }

    /// legacy.json in the diagnostics bundle (§14.2).
    var findingsJSON: String {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? e.encode(facts)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// "Open the old LockPlus" (the refusal's button; hidden when the old app is gone, E2E-5 F8).
    func openOldApp() {
        guard let url = system.goAppURL() else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
