import AppKit
import Foundation
import os

/// E2E-5 F5: LockPlus 1.0.x's "Launch at startup" was a per-user LaunchAgent,
/// `~/Library/LaunchAgents/io.github.steiale.lockplus.gui.plist` (label `io.github.steiale.lockplus.gui`, program
/// `…/LockPlus.app/Contents/MacOS/lockplus`, `RunAtLoad`; Go `internal/autostart/install.go` before a87c280). After a
/// Finder Replace that path is the native binary (the volume is case-insensitive), so a second LockPlus starts at
/// every login. The app removes exactly that file, in the user domain (no administrator), only when it is a regular
/// file of this user whose label and program are the Go agent's, and offers its own launch at login instead. It never
/// boots the job out: the job may be this very process.
///
/// Go 1.1.0 used `SMAppService.mainApp` instead. Its Background Task Management item belongs to the Go bundle ID and
/// can't be removed through any API another app may call; the migration report explains it (§13.1 step 6).
///
/// Migration matrix: WireGuide+ 1.0.1–1.0.56 had the same agent under its own name,
/// `io.github.steiale.wireguide-plus.gui.plist` (program `…/WireGuide+.app/Contents/MacOS/wireguide-plus`). It keeps
/// launching the old app (which restarts its helper) after the update installs LockPlus next to it: removed the same way.
enum LegacyLaunchAgent {
    struct Agent: Sendable, Equatable {
        let label: String
        /// The executable at the end of the program path (`….app/Contents/MacOS/<executable>`).
        let executable: String
        var fileName: String { label + ".plist" }
    }
    static let lockplus = Agent(label: "io.github.steiale.lockplus.gui", executable: "lockplus")
    static let wireGuidePlus = Agent(label: "io.github.steiale.wireguide-plus.gui", executable: "wireguide-plus")
    static let agents = [lockplus, wireGuidePlus]
    static let label = lockplus.label
    static let fileName = lockplus.fileName
    private static let log = Logger(subsystem: "io.github.steiale.lockplus.mac", category: "lifecycle")

    static func url(home: String, agent: Agent = lockplus) -> URL {
        URL(fileURLWithPath: home, isDirectory: true).appending(path: "Library/LaunchAgents/\(agent.fileName)")
    }

    /// The old app's agent: its label, and a program (`ProgramArguments[0]`, or `Program`) inside an app bundle's
    /// `Contents/MacOS/<executable>`.
    static func isGoAgent(_ data: Data, agent: Agent = lockplus) -> Bool {
        guard data.count <= 64 << 10,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["Label"] as? String == agent.label,
              let program = (plist["ProgramArguments"] as? [String])?.first ?? plist["Program"] as? String else { return false }
        return program.hasSuffix(".app/Contents/MacOS/\(agent.executable)")
    }

    /// Removes every old agent that is there (LockPlus 1.0.x's, WireGuide+'s). Returns true when one was removed (the
    /// user had "Launch at startup" on).
    @discardableResult
    static func retire(home: String, uid: uid_t = getuid()) -> Bool {
        var any = false
        for agent in agents where retire(home: home, agent: agent, uid: uid) { any = true }
        return any
    }

    private static func retire(home: String, agent: Agent, uid: uid_t) -> Bool {
        let path = url(home: home, agent: agent).path
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        guard st.st_mode & S_IFMT == S_IFREG, st.st_uid == uid,
              let data = FileManager.default.contents(atPath: path), isGoAgent(data, agent: agent) else {
            log.notice("a LaunchAgent named like LockPlus 1.x's was left alone: not the old app's")
            return false
        }
        do {
            try FileManager.default.removeItem(atPath: path)
            log.notice("removed LockPlus 1.x's LaunchAgent (launch at startup)")
            return true
        } catch {
            log.error("couldn't remove LockPlus 1.x's LaunchAgent: \((error as NSError).code, privacy: .public)")
            return false
        }
    }
}

/// How this process was started, read once at launch (E2E-5 F5): a second instance started by the old app's agent or
/// as a login item quits silently instead of showing "LockPlus is already running" at every login.
struct LaunchContext: Sendable, Equatable {
    /// launchd started this process for the Go agent's label.
    var byGoLaunchAgent = false
    /// The open-application event says "launched as a login item" (the classic `keyAELaunchedAsLogInItem` flag).
    var asLoginItem = false

    var quietIfAlreadyRunning: Bool { byGoLaunchAgent || asLoginItem }

    @MainActor static var current = LaunchContext()

    /// `applicationWillFinishLaunching`: the launch event is still current then.
    @MainActor static func capture(environment: [String: String] = ProcessInfo.processInfo.environment) {
        var c = LaunchContext()
        c.byGoLaunchAgent = LegacyLaunchAgent.agents.contains { environment["XPC_SERVICE_NAME"] == $0.label }
        if let e = NSAppleEventManager.shared().currentAppleEvent, e.eventClass == kCoreEventClass, e.eventID == kAEOpenApplication,
           e.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem {
            c.asLoginItem = true
        }
        current = c
    }
}
