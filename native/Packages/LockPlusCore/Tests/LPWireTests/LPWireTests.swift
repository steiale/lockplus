import Foundation
import LPModel
import LPWire
import Security
import Testing

@Suite struct LPWireCodecTests {
    @Test func roundTripsAndCapsBeforeDecoding() throws {
        let h = ClientHello(appVersion: "2.0.0", appBuild: "200000")
        let d = try LPWire.encode(h)
        #expect(try LPWire.decode(ClientHello.self, d, max: LPMethod.hello.requestLimit) == h)
        #expect(throws: LPError(.payloadTooLarge, detail: "ClientHello \(d.count) > 4")) {
            try LPWire.decode(ClientHello.self, d, max: 4)
        }
    }

    @Test func garbageIsMalformedAndNeverEchoed() {
        let secret = Data("password=hunter2".utf8)
        #expect(throws: LPError(.malformedRequest, detail: "decode ClientHello")) {
            try LPWire.decode(ClientHello.self, secret, max: 4096)
        }
    }

    @Test func replyErrorHalf() throws {
        #expect(LPWire.decodeError(nil) == nil)
        #expect(LPWire.decodeError(LPWire.encodeError(LPError(.notOwner))) == LPError(.notOwner))
        #expect(LPWire.decodeError(Data([1, 2, 3])) == LPError(.malformedRequest, detail: "reply error"))
        #expect(throws: LPError(.notOwner)) {
            try LPWire.decodeReply(TunnelSnapshot.self, result: nil, error: LPWire.encodeError(LPError(.notOwner)), max: 1024)
        }
    }

    @Test func limitsMatchDesign() {
        #expect(LPMethod.hello.requestLimit == 4096)
        #expect(LPMethod.provisionProfile.requestLimit == 300 * 1024)
        #expect(LPMethod.validateProfile.requestLimit == 300 * 1024)
        #expect(LPMethod.answerAuth.requestLimit == 8 * 1024)
        #expect(LPMethod.statistics.requestLimit == 16 * 1024)
        #expect(LPMethod.listProvisioned.replyLimit == 160 * 1024)
    }

    @Test func timeoutsMatchDesignAndServerDeadlineIsOneSecondLess() {
        let expected: [LPMethod: Duration] = [
            .hello: .seconds(3), .tunnelSnapshot: .seconds(2), .statistics: .seconds(2), .pendingAuthPrompt: .seconds(2),
            .prepareStartAuth: .seconds(2), .cancelAuth: .seconds(2), .provisionProfile: .seconds(10),
            .removeProfile: .seconds(10), .wipeAllSecrets: .seconds(10), .validateProfile: .seconds(5),
            .answerAuth: .seconds(5), .measureLatency: .seconds(6), .pushEndpoints: .seconds(2),
        ]
        for (m, t) in expected { #expect(m.timeout == t, "\(m)") }
        for m in LPMethod.allCases { #expect(m.serverDeadline == m.timeout - .seconds(1)) }
    }

    @Test func secretBearingMethods() {
        #expect(Set(LPMethod.allCases.filter(\.carriesSecrets)) == [.provisionProfile, .updateCredentials, .answerAuth])
    }

    @Test func credentialCaps() {
        #expect(CredentialRecord(username: Data("u".utf8), password: Data("p".utf8)).isWithinLimits)
        #expect(!CredentialRecord(username: Data("a\nb".utf8)).isWithinLimits)
        #expect(!CredentialRecord(password: Data(count: 1025)).isWithinLimits)
        #expect(CredentialRecord(keyPassphrase: Data("x\ny".utf8)).isWithinLimits)   // passphrase: length cap only
        #expect(!CredentialRecord(proxyPassword: Data("a\rb".utf8)).isWithinLimits)
        #expect(!CredentialRecord(proxyUsername: Data(count: 513)).isWithinLimits)
    }

    @Test func nonOwnerSeesNoContent() {
        let e = TunnelEvent(kind: .authRequired, profileID: UUID(), snapshot: TunnelSnapshot(endpoint: "203.0.113.9:1194"))
        let r = e.redactedForNonOwner
        #expect(r.kind == .anyTunnelStateChanged && r.profileID == nil && r.snapshot == nil && r.prompt == nil)
    }

    @Test func transportErrorMapping() {
        func ns(_ c: Int) -> NSError { NSError(domain: NSCocoaErrorDomain, code: c) }
        #expect(XPCTransportFailure(ns(4097)) == .interrupted)
        #expect(XPCTransportFailure(ns(4099)) == .invalid)
        #expect(XPCTransportFailure(ns(4101)) == .replyInvalid)
        #expect(XPCTransportFailure(ns(4102)) == .codeSigningRequirementFailure)
        #expect(XPCTransportFailure(ns(4102)).lpError.code == .unauthorizedPeer)
        #expect(XPCTransportFailure(ns(4099)).lpError.code == .extensionUnavailable)
    }
}

/// The Release requirement strings, as reviewed text (DESIGN §5.3). The Unit/UnitRelease `RequirementTests` bundle in
/// the Xcode project checks the target-level ActiveRequirements.swift; this checks the package constants.
@Suite struct SigningRequirementTests {
    static let releaseApp = #"anchor apple generic and identifier "io.github.steiale.lockplus.mac" and (certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13]) and certificate leaf[subject.OU] = "M53GHX9FAY""#
    static let releaseExt = #"anchor apple generic and identifier "io.github.steiale.lockplus.mac.tunnel" and (certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13]) and certificate leaf[subject.OU] = "M53GHX9FAY""#

    @Test func releaseStringsAreTheReviewedLiterals() {
        #expect(SigningRequirements.appReq(signer: SigningRequirements.releaseSigner) == Self.releaseApp)
        #expect(SigningRequirements.extReq(signer: SigningRequirements.releaseSigner) == Self.releaseExt)
        #expect(!SigningRequirements.releaseSigner.contains("113635.100.6.2.1]"))
    }

    @Test(arguments: [releaseApp, releaseExt])
    func compiles(_ text: String) {
        var req: SecRequirement?
        #expect(SecRequirementCreateWithString(text as CFString, [], &req) == errSecSuccess)
        var back: CFString?
        #expect(SecRequirementCopyString(req!, [], &back) == errSecSuccess)
        #expect((back as String?)?.contains("M53GHX9FAY") == true)
    }
}

@Suite struct RequestReplyTests {
    @Test func roundTrips() throws {
        let id = UUID()
        func rt<T: Codable & Equatable>(_ v: T) throws { #expect(try LPWire.decode(T.self, try LPWire.encode(v), max: 64 * 1024) == v) }
        try rt(CancelAuthRequest(promptID: id))
        try rt(PendingAuthPromptReply(prompt: nil))
        try rt(ListProvisionedReply(entries: [ProvisionedEntry(id: id, revision: 3, digest: "ab")]))
        try rt(ValidateProfileReply(error: LPError(.unsupportedDirective, detail: "script-security"), warnings: ["w"]))
        try rt(TunnelStatistics(profileID: id, sessionID: nil, sessionStart: nil, rxBytes: 1, txBytes: 2,
                                lastHandshakeAt: nil, sampledAt: Date(timeIntervalSince1970: 1)))
        try rt(SessionSummariesReply(sessions: [SessionSummary(id: id, profileID: id, start: .distantPast, end: .distantPast,
                                                               rxBytes: 0, txBytes: 0, endReason: "user")]))
        try rt(MeasureLatencyReply(results: [LatencyResult(endpoint: "h:1", rttMilliseconds: 3, error: nil)]))
    }

    /// S16: the largest legal listProvisioned reply (500 entries with full-length digests) fits its reply cap.
    @Test func listProvisionedCapHoldsMaxEntries() throws {
        let e = (0..<ListProvisionedReply.maxEntries).map { _ in
            ProvisionedEntry(id: UUID(), revision: .max, digest: String(repeating: "f", count: 64))
        }
        let d = try LPWire.encode(ListProvisionedReply(entries: e))
        #expect(d.count <= LPMethod.listProvisioned.replyLimit)
        #expect(try LPWire.decode(ListProvisionedReply.self, d, max: LPMethod.listProvisioned.replyLimit).entries.count == e.count)
    }

    /// M1: recentLogs/setLogLevel are not part of the v2.0 surface.
    @Test func noLogMethods() {
        #expect(!LPMethod.allCases.contains { $0.rawValue == "recentLogs" || $0.rawValue == "setLogLevel" })
    }

    /// The app reaches `AuthAnswer` through this alias (its own module has a UI `AuthAnswer`).
    @Test func wireAuthAnswerAliasIsTheWireType() throws {
        let a = WireAuthAnswer(promptID: UUID(), username: nil, password: Data("p".utf8), response: nil, save: false)
        let back = try LPWire.decode(AuthAnswer.self, try LPWire.encode(a), max: 8192)
        #expect(back.promptID == a.promptID && back.password == a.password)
    }

    /// S5: decoded values outside the §5.2 ranges are rejected after decoding.
    @Test func postDecodeLimits() throws {
        let long = ClientHello(appVersion: String(repeating: "9", count: 65), appBuild: "1")
        #expect(throws: LPError(.malformedRequest, detail: "limits ClientHello")) {
            try LPWire.decode(ClientHello.self, try LPWire.encode(long), max: 4096)
        }
        let bad = AuthAnswer(promptID: UUID(), username: Data("a\nb".utf8), password: nil, response: nil, save: false)
        #expect(throws: LPError.self) { try LPWire.decode(AuthAnswer.self, try LPWire.encode(bad), max: 8192) }
        let big = ProvisionRequest(profileID: UUID(), kind: .openVPN, revision: 1, payload: Data(count: LPMaxPayloadBytes + 1), credentials: nil)
        #expect(throws: LPError.self) { try LPWire.decode(ProvisionRequest.self, try LPWire.encode(big), max: 1 << 20) }
        let pa = PrepareStartAuth(profileID: UUID(), kind: .dynamicChallenge)
        #expect(throws: LPError.self) { try LPWire.decode(PrepareStartAuth.self, try LPWire.encode(pa), max: 4096) }
    }

    /// S5: decode fuzz over every request type: random and mutated inputs never trap and only ever fail with
    /// `.malformedRequest`/`.payloadTooLarge`; anything that decodes is within its limits.
    @Test func decodeFuzzOverRequestTypes() throws {
        var rng = SystemRandomNumberGenerator()
        let id = UUID()
        let seeds: [Data] = try [
            LPWire.encode(ClientHello(appVersion: "2", appBuild: "1")), LPWire.encode(EmptyRequest()),
            LPWire.encode(ProfileRequest(profileID: id)),
            LPWire.encode(ProvisionRequest(profileID: id, kind: .wireGuard, revision: 1, payload: Data("x".utf8),
                                           credentials: CredentialRecord(username: Data("u".utf8)))),
            LPWire.encode(UpdateCredentialsRequest(profileID: id, credentials: CredentialRecord(password: Data("p".utf8)))),
            LPWire.encode(CancelAuthRequest(promptID: id)), LPWire.encode(PrepareStartAuth(profileID: id, kind: .userPass)),
            LPWire.encode(AuthAnswer(promptID: id, username: nil, password: Data("p".utf8), response: nil, save: true)),
            LPWire.encode(ValidateProfileRequest(kind: .openVPN, payload: Data("client".utf8))),
            LPWire.encode(SessionSummariesRequest(after: id)),
            LPWire.encode(PushEndpointsRequest(profileID: id, endpoints: ["vpn.example": ["192.0.2.1", "2001:db8::1"]])),
        ]
        func probe(_ d: Data) {
            func one<T: Decodable>(_ t: T.Type) {
                do throws(LPError) { _ = try LPWire.decode(t, d, max: 300 * 1024) } catch {
                    #expect(error.code == .malformedRequest || error.code == .payloadTooLarge)
                }
            }
            one(ClientHello.self); one(EmptyRequest.self); one(ProfileRequest.self); one(ProvisionRequest.self)
            one(UpdateCredentialsRequest.self); one(CancelAuthRequest.self); one(PrepareStartAuth.self); one(AuthAnswer.self)
            one(ValidateProfileRequest.self); one(SessionSummariesRequest.self)
            one(PushEndpointsRequest.self)
        }
        for _ in 0..<300 {
            var d = seeds.randomElement(using: &rng)!
            for _ in 0..<Int.random(in: 1...8, using: &rng) where !d.isEmpty {
                d[Int.random(in: 0..<d.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng)
            }
            probe(d)
            probe(Data((0..<Int.random(in: 0...64, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }))
        }
    }

    // MARK: pushEndpoints (PENDING-FOLD 50)

    @Test func pushEndpointsIsANonSecretTwoReplyMethod() throws {
        #expect(!LPMethod.pushEndpoints.carriesSecrets && !LPMethod.pushEndpoints.repliesErrorOnly)
        #expect(LPMethod.pushEndpoints.requestLimit == 16 * 1024)
        let id = UUID()
        func rt<T: Codable & Equatable>(_ v: T) throws { #expect(try LPWire.decode(T.self, try LPWire.encode(v), max: 16 * 1024) == v) }
        try rt(PushEndpointsRequest(profileID: id, endpoints: ["vpn.example": ["192.0.2.1"]]))
        for o in [PushEndpointsReply.Outcome.retrying, .unchanged, .notHeld] { try rt(PushEndpointsReply(outcome: o)) }
    }

    /// The largest legal request (8 hostnames of 253 bytes, 16 full-length IPv6 literals each) fits the 16 KiB cap.
    @Test func pushEndpointsWorstCaseFitsItsCap() throws {
        var m: [String: [String]] = [:]
        for i in 0..<EndpointMapRules.maxHosts {
            let label = String(repeating: "a", count: 61) + String(format: "%02d", i)
            m[[label, label, label, String(repeating: "b", count: 253 - 3 * 64)].joined(separator: ".")] =
                (0..<EndpointMapRules.maxIPsPerHost).map { String(format: "2001:0db8:ffff:ffff:ffff:ffff:ffff:%04x", $0) }
        }
        #expect(m.keys.allSatisfy { $0.utf8.count == 253 })
        let d = try LPWire.encode(PushEndpointsRequest(profileID: UUID(), endpoints: m))
        #expect(d.count <= LPMethod.pushEndpoints.requestLimit)
        #expect(try LPWire.decode(PushEndpointsRequest.self, d, max: LPMethod.pushEndpoints.requestLimit).endpoints == m)
    }

    /// Strict: one bad host or IP rejects the whole request; nothing is silently dropped.
    @Test(arguments: [
        [:],                                                                       // empty
        ["vpn.example": []],                                                      // a host without IPs
        ["vpn.example": ["vpn.example"]],                                         // not an IP literal
        ["vpn.example": ["192.0.2.1:443"]],                                       // a port
        ["vpn.example": ["[2001:db8::1]"]],                                       // brackets
        ["vpn.example": ["fe80::1%en0"]],                                         // a zone
        ["vpn.example": ["192.0.2.1", "192.0.2.1"]],                              // a duplicate
        ["vpn.example": (0...16).map { "192.0.2.\($0)" }],                        // 17 IPs
        ["192.0.2.9": ["192.0.2.1"]],                                             // an IP literal as the hostname
        ["": ["192.0.2.1"]], ["vpn example": ["192.0.2.1"]], ["vpn/../x": ["192.0.2.1"]],
        [String(repeating: "a", count: 254): ["192.0.2.1"]],                      // > 253 bytes
        Dictionary(uniqueKeysWithValues: (0...8).map { ("h\($0).example", ["192.0.2.1"]) }),   // 9 hosts
    ] as [[String: [String]]])
    func pushEndpointsRejectsAnyBadEntry(_ m: [String: [String]]) throws {
        let d = try LPWire.encode(PushEndpointsRequest(profileID: UUID(), endpoints: m))
        #expect(throws: LPError(.malformedRequest, detail: "limits PushEndpointsRequest")) {
            try LPWire.decode(PushEndpointsRequest.self, d, max: LPMethod.pushEndpoints.requestLimit)
        }
    }

    /// One rule on both sides: only a start held BEFORE Connected on a reason fresh IPs can fix.
    @Test func pushAppliesOnlyToARecoverableHeldStart() {
        let id = UUID()
        func snap(_ r: HoldReason?, before: Bool = true, phase: TunnelPhase = .held, pid: UUID? = nil) -> TunnelSnapshot {
            TunnelSnapshot(profileID: pid ?? id, phase: phase, holdReason: r, holdBeforeConnected: before)
        }
        for c in PushEndpointsRequest.recoverableCodes { #expect(PushEndpointsRequest.appliesTo(snap(.blockedAfterFailure(c)), profileID: id)) }
        #expect(PushEndpointsRequest.recoverableCodes == [.dnsResolutionFailed, .connectTimeout, .peerUnreachable, .endpointInterfaceUnusable])
        #expect(!PushEndpointsRequest.appliesTo(snap(.blockedAfterFailure(.serverIdentityMismatch)), profileID: id))
        #expect(!PushEndpointsRequest.appliesTo(snap(.nonRetryable(.dnsResolutionFailed)), profileID: id))
        #expect(!PushEndpointsRequest.appliesTo(snap(.blockedAfterFailure(.connectTimeout), before: false), profileID: id))
        #expect(PushEndpointsRequest.appliesTo(snap(.blockedAfterFailure(.connectTimeout), phase: .connecting), profileID: id))   // a retry
        // E2E-2: a WireGuard retry waits for its handshake in .establishing (the extension refuses it for OpenVPN).
        #expect(PushEndpointsRequest.appliesTo(snap(.blockedAfterFailure(.connectTimeout), phase: .establishing), profileID: id))
        #expect(!PushEndpointsRequest.appliesTo(snap(.blockedAfterFailure(.connectTimeout), phase: .connected), profileID: id))
        #expect(!PushEndpointsRequest.appliesTo(snap(.blockedAfterFailure(.connectTimeout), pid: UUID()), profileID: id))
        #expect(!PushEndpointsRequest.appliesTo(snap(nil), profileID: id))
    }

    @Test func endpointMapRulesAcceptTheResolverShapes() {
        #expect(EndpointMapRules.isValid(["vpn.example.com": ["192.0.2.1", "2001:db8::1"], "VPN-2.example.": ["::ffff:192.0.2.7"],
                                          "_srv.example": ["198.51.100.1"]]))
    }

    /// Review simplification: one filter for both sides of `pushEndpoints`; its output always passes `isValid`.
    @Test func sanitizedIsTheSharedFilter() {
        let m = EndpointMapRules.sanitized(["B.example": ["192.0.2.1", "192.0.2.1", "nope", "fe80::1%en0"], "b.example": ["192.0.2.9"],
                                            "192.0.2.5": ["192.0.2.6"], "empty.example": [],
                                            "many.example": (0..<20).map { "198.51.100.\($0)" }])
        #expect(m == ["b.example": ["192.0.2.1"], "many.example": (0..<16).map { "198.51.100.\($0)" }])
        #expect(EndpointMapRules.isValid(m))
        let wide = EndpointMapRules.sanitized(Dictionary(uniqueKeysWithValues: (0..<12).map { ("h\($0).example", ["192.0.2.1"]) }))
        #expect(wide.count == EndpointMapRules.maxHosts && EndpointMapRules.sanitized([:]).isEmpty)
    }

    @Test func protocolKindRawValuesFollowDesign() {
        #expect(VPNProtocolKind.wireGuard.rawValue == "wg")
        #expect(VPNProtocolKind.openVPN.rawValue == "ovpn")
    }
}
