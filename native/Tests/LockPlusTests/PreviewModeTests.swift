import Foundation
import LPModel
import LPWire
import Testing
@testable import LockPlus

/// Preview mode must come up with every fixture profile and never select live backends.
@MainActor @Suite("Preview mode")
struct PreviewModeTests {
    @Test func everySeedProfileImports() async {
        let service = PreviewTunnelService(world: PreviewWorld())
        for (name, text) in PreviewSeed.files {
            let a = await ImportCoordinator.analyse(fileName: name, bytes: Array(text.utf8), service: service, probe: NoRouteProbe())
            #expect(a.canonical != nil, "\(name): \(a.report.plainText())")
            #expect(a.engineVerified, "\(name)")
        }
    }

    @Test func previewEnvironmentStartsWithTheFixtures() async throws {
        let dir = TestDir()
        defer { dir.cleanup() }
        var b = AppEnvironment.previewBackends()
        b.dataDirectory = dir.data
        let env = AppEnvironment(backends: b)
        await env.start()
        #expect(env.profiles.profiles.count == PreviewSeed.files.count, "\(env.profiles.problems.map(\.message))")
        #expect(await eventually(.seconds(10)) { env.extensionStore.state == .ready(version: "2.0.0 (preview)") },
                "\(env.extensionStore.state)")
        #expect(env.ui.profiles.profiles.count == PreviewSeed.files.count)
        #expect(env.ui.onboarding.isPresented)
        #expect(env.ui.onboarding.migration?.profileNames == ["old-office"])
        env.stop()
    }

    @Test func modeDetection() {
        #expect(AppMode.detect(["LP_PREVIEW_MODE": "1"], defaults: UserDefaults(suiteName: "lp.test.\(UUID())")!) == .preview)
        #expect(AppMode.detect([:], defaults: UserDefaults(suiteName: "lp.test.\(UUID())")!) == .live)
    }
}
