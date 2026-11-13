import AppKit
import LPModel
import SwiftUI
import Testing
@testable import LockPlus

/// 2.0.2 connection self-test section (EN; run with `-testLanguage de` for the DE set, "-de" suffix).
extension ScreenshotTests {
    @Test("Diagnostics, connection test", arguments: ["empty", "disconnected", "ok", "leak", "inconclusive", "split"])
    func selfTest(_ name: String) async throws {
        var r = ConnectionSelfTestTests.report()
        switch name {
        case "leak":
            r.ipv4 = .outsideTunnel(interface: "en0"); r.ipv6 = .outsideTunnel(interface: "en0")
            r.dns = .mismatch("10.8.0.1 is reached via en0, not the tunnel (utun4)"); r.overall = .problem
        case "inconclusive":
            r.ipv4 = .unreachable("timed out"); r.ipv6 = .noIPv6Here; r.dns = .unknown("a test query didn't complete"); r.overall = .inconclusive
        case "split":
            r.ipv4 = .outsideExpected; r.ipv6 = .outsideExpected; r.dnsApplicable = false
        default: break
        }
        let report: SelfTestReport? = (name == "empty" || name == "disconnected") ? nil : r
        let view = SelfTestContent(report: report, running: false, canRun: name != "disconnected") {}
            .padding(20).background(BrandCanvasBackground())
        try await Self.renderBoth(view, size: CGSize(width: 640, height: report == nil ? 150 : 420), name: "selftest-\(name)")
    }
}
