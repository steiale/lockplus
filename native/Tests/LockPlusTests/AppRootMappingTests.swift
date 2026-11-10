import Foundation
import LPModel
import LPWire
import NetworkExtension
import Testing
@testable import LockPlus

/// Pure mapping and policy rules of the app root.
@MainActor @Suite("App root: mapping and configuration")
struct AppRootMappingTests {
    // MARK: lp.manual (§5.2, PENDING-FOLD 42)

    @Test func startOptionsAlwaysCarryManualAsNSNumber() {
        let o = StartOptionsBuilder.options()
        let manual = o[StartOptionKey.manual]
        #expect(manual is NSNumber)
        #expect((manual as? NSNumber)?.intValue == 1)
        #expect(Set(o.keys) == [StartOptionKey.manual])
    }

    /// Draft 9 (S2 E1): NE replays the original options on its own restart, so they carry no one-shot value; (E10) the
    /// endpoint IPs the app resolved go in `lp.endpoints`, bounded.
    @Test func startOptionsCarryOnlyTheMarkerAndEndpointIPs() {
        var hosts: [String: [String]] = ["vpn.example": ["192.0.2.1", "2001:db8::1"]]
        for i in 0..<12 { hosts["h\(i).example"] = (0..<20).map { "198.51.100.\($0)" } }
        let o = StartOptionsBuilder.options(endpoints: hosts)
        #expect(Set(o.keys) == [StartOptionKey.manual, StartOptionKey.endpoints])
        let d = try? #require(o[StartOptionKey.endpoints] as? [String: [String]])
        #expect(d?.count == StartOptionKey.maxEndpointHosts)
        #expect(d?.values.allSatisfy { $0.count <= StartOptionKey.maxIPsPerHost } == true)
        #expect(o[StartOptionKey.endpoints] is NSDictionary)                  // plist types only (the extension parses it back)
        #expect(StartOptionsBuilder.options(endpoints: ["empty.example": []])[StartOptionKey.endpoints] == nil)
    }

    // MARK: §10.1 flags, §3.3 providerConfiguration, §10.4 on-demand

    func profile(full: Bool, killSwitch: Bool, allowLAN: Bool = false, kind: VPNProtocolKind = .wireGuard, auth: AuthPolicy? = nil,
                 stayConnected: Bool = false) -> Profile {
        var policy = NetworkPolicy(killSwitch: killSwitch, allowLAN: allowLAN)
        policy.stayConnected = stayConnected
        return Profile(id: UUID(), name: "P", kind: kind, policy: policy, auth: auth, notes: "",
                       summary: ProfileSummary(endpoints: ["vpn.example:51820"], isFullTunnel: full), payloadRevision: 3,
                       payloadDigest: "d", metaRevision: 7, ownerUID: 501, createdAt: Date(), updatedAt: Date(), origin: .editor,
                       importReport: nil, engineVerified: true)
    }

    @Test func killSwitchFlagsFollowTheTable() {
        let full = ProtocolFlags(policy: NetworkPolicy(killSwitch: true, allowLAN: true), isFullTunnel: true)
        #expect(full.includeAllNetworks && !full.enforceRoutes && full.excludeLocalNetworks)
        let split = ProtocolFlags(policy: NetworkPolicy(killSwitch: true, allowLAN: true), isFullTunnel: false)
        #expect(!split.includeAllNetworks && split.enforceRoutes && split.excludeLocalNetworks)
        let off = ProtocolFlags(policy: NetworkPolicy(killSwitch: false, allowLAN: true), isFullTunnel: true)
        #expect(!off.includeAllNetworks && !off.enforceRoutes && !off.excludeLocalNetworks)
        #expect(off.excludeAPNs && off.excludeCellularServices && off.excludeDeviceCommunication)
    }

    @Test func providerConfigurationCarriesTheFoldedKeys() throws {
        let otp = AuthPolicy(needsUserPass: true, staticChallenge: StaticChallenge(text: "OTP", echo: true, concat: false))
        let p = profile(full: true, killSwitch: true, kind: .openVPN, auth: otp)
        let v = ProviderConfigurationValues(profile: p, hasOnDemandRules: true)
        let d = v.dictionary
        #expect(d["v"] as? Int == 1)
        #expect(d["profileID"] as? String == p.id.uuidString)
        #expect(d["kind"] as? String == "ovpn")
        #expect((d["revision"] as? NSNumber)?.uint64Value == 3)
        #expect((d["metaRev"] as? NSNumber)?.uint64Value == 7)
        #expect((d["ownerUID"] as? NSNumber)?.uint32Value == 501)
        #expect(d["onDemand"] as? Bool == true)                                    // PENDING-FOLD 1
        let auth = try #require(d["auth"] as? [String: Any])
        #expect(auth["kind"] as? String == "staticChallenge")                     // PENDING-FOLD 1
        #expect(auth["interactive"] as? Bool == true)
        let size = try PropertyListSerialization.data(fromPropertyList: d, format: .binary, options: 0).count
        #expect(size <= ProviderConfigurationValues.maxEncodedBytes)
        #expect(ProviderConfigurationValues.stored(d) == .init(revision: 3, metaRev: 7, ownerUID: 501))
        let wg = ProviderConfigurationValues(profile: profile(full: false, killSwitch: false), hasOnDemandRules: false).dictionary
        #expect(wg["kind"] as? String == "wg" && wg["auth"] == nil && wg["onDemand"] as? Bool == false)
    }

    @Test func autoConnectRulesOrderTrustedFirstPortalLast() {
        var r = AutoConnectRules()
        r.enabled = true
        r.trustedSSIDs = ["Home"]
        let plan = OnDemandPlan.autoConnect(r, paused: false)
        #expect(plan.enabled)
        #expect(plan.rules.first == OnDemandRuleSpec(action: .disconnect, interface: .wiFi, ssids: ["Home"]))
        #expect(plan.rules.last == OnDemandPlan.portalIgnore)
        #expect(plan.rules.contains { $0.action == .connect && $0.interface == .wiFi && $0.probeURL?.scheme == "https" })
        #expect(plan.rules.contains { $0.action == .ignore && $0.interface == .ethernet })
        #expect(!OnDemandPlan.autoConnect(r, paused: true).enabled)
    }

    /// §10.4 (E2E-1 finding): two connect rules per interface, ours first, Apple's HTTPS page second, then Ignore.
    @Test func connectRulesProbeOurHostThenApplesThenIgnore() {
        var r = AutoConnectRules()
        r.enabled = true
        r.connectOnEthernet = true
        let rules = OnDemandPlan.autoConnect(r, paused: false).rules
        let own = URL(string: "https://steiale.github.io/lockplus-updates/probe.txt")!
        let apple = URL(string: "https://www.apple.com/library/test/success.html")!
        #expect(OnDemandPlan.probeURLs == [own, apple])
        #expect(OnDemandPlan.probeURLs.allSatisfy { $0.scheme == "https" })
        #expect(Set(OnDemandPlan.probeURLs.compactMap { $0.host() }).count == 2)           // independent hosts (N7)
        #expect(rules == [
            OnDemandRuleSpec(action: .connect, interface: .wiFi, probeURL: own),
            OnDemandRuleSpec(action: .connect, interface: .wiFi, probeURL: apple),
            OnDemandRuleSpec(action: .connect, interface: .ethernet, probeURL: own),
            OnDemandRuleSpec(action: .connect, interface: .ethernet, probeURL: apple),
            OnDemandPlan.portalIgnore,
        ])
        let stay = OnDemandPlan.stayConnected(paused: false).rules
        #expect(stay == [OnDemandRuleSpec(action: .connect, interface: .any, probeURL: own),
                         OnDemandRuleSpec(action: .connect, interface: .any, probeURL: apple),
                         OnDemandPlan.portalIgnore])
    }

    @Test func otpProfilesAreNeverTheAutoProfile() {
        let otp = profile(full: true, killSwitch: true, kind: .openVPN, auth: AuthPolicy(needsUserPass: true, appendOTP: true))
        var r = AutoConnectRules()
        r.enabled = true
        r.profileID = otp.id
        #expect(OnDemandPlan.plan(for: otp, rules: r, paused: false) == nil)
        let stay = profile(full: true, killSwitch: true, stayConnected: true)
        #expect(OnDemandPlan.plan(for: stay, rules: AutoConnectRules(), paused: false)?.rules.first?.interface == .any)
    }

    // MARK: NEVPNStatus, extension state, snapshot → DerivedStateInputs

    @Test func nevpnStatusMapsOneToOne() {
        #expect(TunnelStatus(NEVPNStatus.connected) == .connected)
        #expect(TunnelStatus(NEVPNStatus.reasserting) == .reasserting)
        #expect(TunnelStatus(NEVPNStatus.disconnecting) == .disconnecting)
        #expect(TunnelStatus(NEVPNStatus.invalid) == .invalid)
    }

    @Test func extensionReadiness() {
        #expect(ExtensionMapping.readiness(.ready(version: "2"), endedWithoutResult: false) == .ready)
        #expect(ExtensionMapping.readiness(.unknown, endedWithoutResult: false) == .activating)
        #expect(ExtensionMapping.readiness(.unknown, endedWithoutResult: true) == .failed)     // canceled, no successor
        #expect(ExtensionMapping.readiness(.needsUserApproval, endedWithoutResult: false) == .needsUserApproval)
        #expect(ExtensionMapping.readiness(.failed(.unauthorizedPeer), endedWithoutResult: false) == .failed)
        #expect(ExtensionMapping.link(.idle) == .validated)
        #expect(ExtensionMapping.link(.reconnecting(since: Date())) == .reconnecting)
        #expect(ExtensionMapping.link(.unavailable(LPError(.timeout))) == .unavailable)
    }

    @Test func snapshotOfAnotherProfileIsIgnored() {
        let mine = UUID()
        let s = TunnelSnapshot(profileID: UUID(), phase: .reasserting, attempt: 3)
        #expect(UIMapping.snapshotFacts(s, profileID: mine) == SnapshotFacts())
        let own = TunnelSnapshot(profileID: mine, phase: .held, attempt: 2, holdReason: .blockedAfterFailure(.engineDied),
                                 startLatch: StartLatch(code: .authFailed, kind: .hard, notBefore: nil, revision: 1))
        let f = UIMapping.snapshotFacts(own, profileID: mine)
        #expect(f.phase == .held && f.attempt == 2 && f.holdReason == .blockedAfterFailure(.engineDied))
        #expect(f.startLatch == StartLatchUI(code: .authFailed, kind: .hard))
    }

    @Test func inputsDriveTheTableRows() {
        let p = profile(full: true, killSwitch: true)
        let snap = TunnelSnapshot(profileID: p.id, phase: .reasserting, attempt: 2,
                                  holdReason: .blockedAfterFailure(.serverIdentityMismatch))
        let i = UIMapping.inputs(profile: p, fallbackName: "", status: .reasserting, observedError: nil, userStoppedSinceError: false,
                                 snapshot: snap, awaitingApproval: false, pausedUntil: nil, readiness: .ready,
                                 link: .validated, switchingTo: nil, now: Date())
        #expect(i.condition.row == "7")
        var link = i
        link.status = .connected
        link.snapshot = SnapshotFacts()
        link.link = .reconnecting
        #expect(link.condition.row == "4a")
        var ext = i
        ext.extensionReadiness = .needsUserApproval
        #expect(ext.condition.row == "1")
    }

    @Test func disconnectErrorMapping() {
        let lp = NSError(domain: LPTunnelError.errorDomain, code: LPErrorCode.endpointInterfaceUnusable.rawValue,
                         userInfo: [LPTunnelError.detailKey: "bridge100"])
        let (e, detail) = ConnectionStore.observedError(lp)
        #expect(e.code == .endpointInterfaceUnusable && detail == "bridge100")
        #expect(ConnectionStore.observedError(NSError(domain: NEVPNConnectionErrorDomain, code: 12)).0.code == .engineDied)
        #expect(ConnectionStore.observedError(NSError(domain: NEVPNConnectionErrorDomain, code: 14)).0.code == .extensionUnavailable)
        #expect(ConnectionStore.observedError(NSError(domain: "x", code: 1)).0.code == .engineFatal)
    }

    // MARK: Settings, sessions, rates

    @Test func appearanceMapsBothWays() {
        for (a, ui) in [(AppSettings.Appearance.system, AppAppearance.system), (.light, .light), (.dark, .dark)] {
            var s = AppSettings()
            s.appearance = a
            let m = SettingsUIModel()
            UIMapping.apply(s, to: m)
            #expect(m.appearance == ui)
            var back = AppSettings()
            UIMapping.read(m, into: &back)
            #expect(back.appearance == a)
        }
    }

    @Test func settingsRoundTripThroughTheUIModel() {
        var s = AppSettings()
        s.menuBarIconStyle = .color
        s.notifications = .connectDisconnect
        s.newProfileDefaults.allowLAN = true
        let m = SettingsUIModel()
        UIMapping.apply(s, to: m)
        #expect(m.iconStyle == .color && m.notifications == .connectAndDisconnect && m.defaultAllowLocalNetwork)
        m.rateLabel = .download
        var back = s
        UIMapping.read(m, into: &back)
        #expect(back.menuBarRateLabel == .download && back.menuBarIconStyle == .color && back.notifications == .connectDisconnect)
    }

    @Test func settingsDecodeLeniently() throws {
        let s = try AtomicFile.decoder().decode(AppSettings.self, from: Data(#"{"menuBarIconStyle":"sparkly","onboardingComplete":true}"#.utf8))
        #expect(s.onboardingComplete && s.menuBarIconStyle == .color)
    }

    /// UI review 2026-11-09: the menu bar icon defaults to the colour tile. Schema 1 wrote the old default into every
    /// file, so a stored monochrome moves to the new default; a choice stored under schema 2 is kept.
    @Test func iconStyleDefaultsToColourAndMigratesOnce() throws {
        func decode(_ json: String) throws -> AppSettings { try AtomicFile.decoder().decode(AppSettings.self, from: Data(json.utf8)) }
        #expect(AppSettings().menuBarIconStyle == .color && AppSettings().schema == 2)
        #expect(try decode(#"{"schema":1,"menuBarIconStyle":"monochrome"}"#).menuBarIconStyle == .color)
        #expect(try decode(#"{"menuBarIconStyle":"monochrome"}"#).menuBarIconStyle == .color)       // no schema key = 1
        #expect(try decode(#"{"schema":1,"menuBarIconStyle":"color"}"#).menuBarIconStyle == .color)
        #expect(try decode(#"{"schema":2,"menuBarIconStyle":"monochrome"}"#).menuBarIconStyle == .monochrome)
        var chosen = AppSettings()
        chosen.menuBarIconStyle = .monochrome
        let back = try decode(String(decoding: try AtomicFile.encoder().encode(chosen), as: UTF8.self))
        #expect(back.menuBarIconStyle == .monochrome && back.schema == 2)
    }

    @Test func iconMayBeHiddenAfterFiveLaunchesWithoutTheMenu() {
        var s = AppSettings()
        let now = Date()
        s.launches = (0..<5).map { now.addingTimeInterval(Double($0 - 5) * 3600) }
        #expect(s.iconMayBeHidden)
        s.menuOpenedLaunches = [now.addingTimeInterval(-3600)]
        #expect(!s.iconMayBeHidden)
    }

    @Test func rateMeterCommitsBytesAndTimeTogether() {
        var m = RateMeter()
        let t0 = Date()
        #expect(m.ingest(rx: 0, tx: 0, at: t0) == nil)
        #expect(m.ingest(rx: 500, tx: 50, at: t0.addingTimeInterval(0.2)) == nil)       // too close: baseline unchanged
        #expect(m.ingest(rx: 1000, tx: 100, at: t0.addingTimeInterval(1)) == Rate(down: 1000, up: 100))
        #expect(m.ingest(rx: 10, tx: 10, at: t0.addingTimeInterval(2)) == Rate(down: 0, up: 0))   // counter reset
    }

    @Test func profileNamesAreUniqueCaseAndDiacriticInsensitively() {
        #expect(ProfileNameRules.validate(" Büro ", existing: ["buro"]) == .failure(.duplicate))
        #expect(ProfileNameRules.validate("", existing: []) == .failure(.empty))
        #expect(ProfileNameRules.validate("a\u{7}b", existing: []) == .failure(.controlCharacter))
        #expect(ProfileNameRules.unique("Work", existing: ["Work", "Work 2"]) == "Work 3")
    }
}
