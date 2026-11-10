import AppKit
import Foundation
import LPModel
import Testing
@testable import LockPlus

/// Hosted in LockPlus.app. The host must not touch the system extension under XCTest (no activation request).
@MainActor @Suite struct AppSmokeTests {
    /// The HOST's state, not the helper (review): the running app delegate took the inert path, so no menu bar, no
    /// activation request, preview backends.
    @Test func hostSkipsExtensionActivationUnderTests() throws {
        #expect(AppDelegate.isRunningTests)
        let delegate = try #require(AppDelegate.current)
        #expect(delegate.env.mode == .preview)
        #expect(delegate.env.systemExtensions == nil)                    // no SystemExtensionManager, so no request
        #expect(!((delegate.env.managers as? SerializedVPNManager)?.inner is NEManagerStore))
        #expect(!delegate.hasMenuBar)
    }

    @Test func embeddedExtensionIsFoundAndVersioned() {
        let m = SystemExtensionManager(bundle: .main, quiescer: NoTunnelsQuiescer())
        #expect(m.extensionIdentifier == "io.github.steiale.lockplus.mac.tunnel")
        #expect(m.embeddedVersion?.shortVersion == "2.0.0")
        // NEMachServiceName is a dot-descendant of the app group and carries the build number (§2.5, §2.6).
        let name = m.machServiceName ?? ""
        #expect(name.hasPrefix("M53GHX9FAY.io.github.steiale.lockplus.mac.tunnel.v"))
        #expect(name.hasSuffix(m.embeddedVersion?.bundleVersion ?? "?"))
        #expect(m.state == .unknown)
    }
}
