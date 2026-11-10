import Foundation
import LPModel
import Testing
@testable import LockPlus

/// Fable L5–L7 and nits.
@MainActor @Suite("Fable lows and nits", .serialized)
struct FableLowTests {
    @Test func keptLiteralsStayOnlyInDNSAndRoutes() {
        var i = DiagnosticsInputs()
        i.profiles = [.init(id: UUID(), name: "P", kind: "wg", endpoints: ["10.8.0.1:51820"], isFullTunnel: true, dnsServers: ["10.8.0.1"],
                            policy: NetworkPolicy(killSwitch: true), engineVerified: true, importReport: [])]
        i.scutilDNS = FixtureDNSSystem.preview.scutil
        i.appLog = [LogLine(date: Date(), level: .info, source: .app, category: "dns", message: "server 10.8.0.1")]
        let files = DiagnosticsBundle.files(i, redactor: DiagnosticsBundle.redactor(for: i, salt: Data(repeating: 3, count: 16)))
        func text(_ n: String) -> String { files.first { $0.name == n }!.text }
        #expect(text("dns.txt").contains("10.8.0.1"))
        #expect(!text("profiles.json").contains("10.8.0.1"))
        #expect(!text("logs-app.txt").contains("10.8.0.1"))
    }

    @Test func crashReportsAreNeverReadThroughASymlink() throws {
        let dir = TestDir()
        defer { dir.cleanup() }
        let real = dir.url.appending(path: "secret.txt")
        try Data("secret".utf8).write(to: real)
        let link = dir.url.appending(path: "LockPlus-1.ips")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(AtomicFile.readNoFollow(link, maxBytes: 1 << 20) == nil)
        #expect(AtomicFile.readNoFollow(real, maxBytes: 1 << 20) == Data("secret".utf8))
        #expect(AtomicFile.readNoFollow(dir.url, maxBytes: 1 << 20) == nil)    // not a regular file
    }

    @Test func onlyOurOwnSocketIsProbed() {
        #expect(!LiveLegacySystem.socketIsOurs("/nonexistent/lockplus.sock"))
        #expect(!LiveLegacySystem.socketIsOurs("/etc/hosts"))                 // not a socket
    }

    @Test func theMigrationMarkerPathIsHomeRelative() {
        #expect(GoAppMigrator.homeRelative("/Users/x/Library/Application Support/lockplus", home: "/Users/x") == "~/Library/Application Support/lockplus")
        #expect(GoAppMigrator.homeRelative("/opt/elsewhere", home: "/Users/x") == "/opt/elsewhere")
    }

    @Test func aSecondInstanceQuits() async {
        let h = Harness()
        defer { h.dir.cleanup() }
        try? AtomicFile.ensureDirectory(h.dir.url)
        let other = InstanceLock.tryAcquire(at: h.dir.data.instanceLock)      // "another LockPlus"
        #expect(other != nil)
        await h.env.acquireInstanceLock(attempts: 2, interval: .milliseconds(10))
        #expect(h.hooks.calls.contains("alreadyRunning"))
        withExtendedLifetime(other) {}
    }

    @Test func digestOverBytesMatchesTheStringForm() {
        let text = "[Interface]\nPrivateKey = x\n"
        let bytes = Array(text.utf8)
        #expect(bytes.withUnsafeBytes { PayloadDigest.sha256Hex(bytes: $0) } == PayloadDigest.sha256Hex(text))
    }
}
