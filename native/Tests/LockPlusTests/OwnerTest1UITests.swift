import Foundation
import LPModel
import LPParsing
import Testing
@testable import LockPlus

/// Owner's first real-machine test: the import report's "not needed" directives carry their reason, and onboarding
/// says truthfully when macOS asks to add VPN configurations (with no profile yet: at the first import).
@MainActor @Suite("Owner test 1 UI")
struct OwnerTest1UITests {
    @Test func notNeededDirectivesCarryALocalisedReasonAndNoArguments() {
        let report = ImportReport(items: [
            ImportReportItem(.ignored, line: 3, directive: "persist-tun", .persistenceNotNeeded),
            ImportReportItem(.ignored, line: 4, directive: "nobind", .localBindingNotUsed),
            ImportReportItem(.notSupported, line: 5, directive: "plugin", .engineIgnores)])
        let got = report.items(in: .ignored).compactMap { i in i.directive.map { IgnoredDirective(name: $0, reason: i.localizedMessage()) } }
        #expect(got == [IgnoredDirective(name: "persist-tun", reason: "not needed; LockPlus keeps the tunnel up itself"),
                        IgnoredDirective(name: "nobind", reason: "local port binding isn't used")])
    }

    /// Every reason that appears in the report's ignored group has its text in the catalogue, with a German value. (The
    /// switch in `localizedMessage` has no default, so a new reason can't compile without a decision.)
    @Test func everyIgnoredReasonTextIsDefined() throws {
        let ignored: [ImportReason] = [.loggingManaged, .reconnectManaged, .persistenceNotNeeded, .localBindingNotUsed, .cipherNegotiationAutomatic,
                                       .scriptsNeverRun, .windowsOnly, .unixAccountNotUsed, .setByServer, .serverOnlyOption, .verifyHashNotSupported,
                                       .dnsManagedByLockPlus, .keepaliveTakesPrecedence, .compressionPolicyManaged, .legacyProvidersNeverLoaded,
                                       .pingTimerRemNotNeeded, .engineIgnores, .webSignInNotSupported, .wgHookNeverRun, .wgSettingNotApplied,
                                       .wgUnknownKeyPreserved, .cipherListNotApplied, .compressionNotEnforced, .rekeyReplayTuningNotApplied,
                                       .routeGatewayManaged, .mtuManaged, .routingManaged, .engineManagesItself, .obsoleteOption,
                                       .tlsVersionCapIgnored]
        // The compiled catalogue inside the app bundle (never a source file: the volume can block the host app).
        let de = try #require(Bundle.main.path(forResource: "de", ofType: "lproj").flatMap(Bundle.init(path:)), "no de.lproj in the app bundle")
        let sentinel = "\u{1}missing\u{1}"
        for r in ignored {
            let item = ImportReportItem(.ignored, directive: "x", r)
            let key = item.message()
            #expect(item.localizedMessage() == key)     // English run: the catalogue's source text is the LPModel text
            let value = de.localizedString(forKey: key, value: sentinel, table: nil)
            #expect(value != sentinel && !value.isEmpty, "no German text for \(key)")
            #expect(value != key, "German text equals English for \(key)")
        }
    }

    @Test func behaviourChangingIgnoredLinesAreNotApplied_harmlessOnesAreNotNeeded_andTheVerdictAgrees() {
        let up = ImportReportItem(.ignored, line: 5, directive: "up", .scriptsNeverRun)
        let pin = ImportReportItem(.ignored, line: 6, directive: "verify-hash", .verifyHashNotSupported)
        let web = ImportReportItem(.ignored, directive: "IV_SSO", .webSignInNotSupported)
        let persist = ImportReportItem(.ignored, line: 7, directive: "persist-tun", .persistenceNotNeeded)
        for i in [up, pin, web] { #expect(i.isNotApplied && !i.isHarmlessIgnored) }
        #expect(persist.isHarmlessIgnored && !persist.isNotApplied)

        let harmlessOnly = ImportReport(items: [persist])
        #expect(ImportVerdict(report: harmlessOnly) == .imported && !harmlessOnly.hasWarnings)
        for bad in [up, pin, web] {
            let r = ImportReport(items: [persist, bad])
            #expect(ImportVerdict(report: r) == .importedWithWarnings && r.hasWarnings)
        }
        // The UI mapping carries the same split.
        let mapped = ImportReport(items: [persist, up, pin]).items(in: .ignored).compactMap { i in
            i.directive.map { IgnoredDirective(name: $0, reason: i.localizedMessage(), harmless: i.isHarmlessIgnored) } }
        #expect(mapped.filter { !$0.harmless }.map(\.name) == ["up", "verify-hash"])
        #expect(mapped.filter(\.harmless).map(\.name) == ["persist-tun"])
    }

    @Test func aRealProfileWithScriptSecurityAndVerifyHashReportsThemNotApplied() throws {
        let text = PreviewSeed.officeOvpn + "\npersist-tun\nscript-security 2\nverify-hash \(String(repeating: "ab", count: 32))\n"
        let r = OVPNImporter.importProfile(Array(text.utf8))
        let ignored = r.report.items(in: .ignored)
        #expect(ignored.first { $0.directive == "script-security" }?.isNotApplied == true)
        #expect(ignored.first { $0.directive == "verify-hash" }?.isNotApplied == true)
        #expect(ignored.first { $0.directive == "persist-tun" }?.isHarmlessIgnored == true)
        #expect(r.verdict == .importedWithWarnings)
        #expect(r.verdict == ImportVerdict(report: r.report))
    }

    @Test func step3AndTheStep4HintFollowWhetherProfilesExist() {
        #expect(OnboardingUIModel.asksAtFirstProfile(profileCount: 0))
        #expect(!OnboardingUIModel.asksAtFirstProfile(profileCount: 1))
        #expect(VPNConfigurationHint.isVisible(profileCount: 0))
        #expect(!VPNConfigurationHint.isVisible(profileCount: 3))
    }

    /// L6: a user who allowed VPN configurations, deleted every profile and imports again is not told macOS will ask.
    @Test func onceAConfigurationExistsMacOSHasAskedAlready() {
        #expect(OnboardingUIModel.asksAtFirstProfile(profileCount: 0, configurationExists: false))
        #expect(!OnboardingUIModel.asksAtFirstProfile(profileCount: 0, configurationExists: true))
        #expect(!VPNConfigurationHint.isVisible(profileCount: 0, configurationExists: true))
        #expect(VPNConfigurationHint.isVisible(profileCount: 0, configurationExists: false))
    }

    @Test func withoutProfilesStep3ContinuesWithoutASave() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        h.env.ui.actions.allowVPNConfiguration()
        #expect(await eventually { h.env.ui.onboarding.configurationStep == .done })
    }
}
