import Foundation
import LPModel
import Observation
import os

/// `DiagnosticsStore` (DESIGN §11.2, §10.2 L-DNS-3): runs `DNSVerifier` 3 s after every `.connected` and on demand
/// ("Run All", ⌘R), and feeds the derived state's "DNS through tunnel" input and the Diagnostics check rows.
@MainActor @Observable
final class DiagnosticsStore {
    /// The derived-state input for the current session; `.pending` = not checked yet (never flags anything).
    private(set) var dns: DNSVerdict = .pending
    private(set) var dnsResult: DNSCheckResult?
    private(set) var resolvers: [DNSResolver] = []
    private(set) var dnsProfileID: UUID?

    @ObservationIgnored private let system: any DNSSystemReading
    @ObservationIgnored private let profiles: ProfilesStore
    @ObservationIgnored private let delay: Duration
    @ObservationIgnored private var verifyTask: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "io.github.steiale.lockplus.mac", category: "diagnostics")

    init(system: any DNSSystemReading, profiles: ProfilesStore, delay: Duration = DNSVerifier.delayAfterConnect) {
        self.system = system
        self.profiles = profiles
        self.delay = delay
    }

    /// From ConnectionStore's status stream: `.connected` schedules a check; anything else makes it pending again.
    func statusChanged(_ id: UUID, _ status: TunnelStatus) {
        if status == .connected {
            schedule(id)                         // §10.2: after EVERY .connected, a reassert included
        } else if dnsProfileID == id {
            verifyTask?.cancel()
            dns = .pending
            dnsResult = nil
            if status != .reasserting { dnsProfileID = nil }
        }
    }

    private func schedule(_ id: UUID) {
        verifyTask?.cancel()
        dnsProfileID = id
        dns = .pending
        let delay = self.delay
        verifyTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await self.verify(id)
        }
    }

    /// On demand (Diagnostics "Run All") or after the delay.
    func verify(_ id: UUID) async {
        guard let p = profiles.profile(id) else { return }
        let expected = p.summary.dnsServers.map(Self.stripPort)
        let catchAll = p.summary.isFullTunnel || p.policy.dnsMode == .tunnelOnly
        let (result, resolvers) = await DNSVerifier.verify(system: system, expectedServers: expected, catchAll: catchAll)
        guard !Task.isCancelled else { return }
        dnsProfileID = id
        dnsResult = result
        self.resolvers = resolvers
        dns = Self.verdict(result)
        switch result {
        case .ok: log.notice("DNS verified")
        case .mismatch(let d): log.error("DNS mismatch: \(d, privacy: .private(mask: .hash))")
        case .unknown(let r): log.notice("DNS unverified: \(r, privacy: .public)")
        }
    }

    nonisolated static func verdict(_ r: DNSCheckResult) -> DNSVerdict {
        switch r {
        case .ok: .verified
        case .mismatch: .overridden
        case .unknown: .unverified
        }
    }

    /// "1.1.1.1:53" → "1.1.1.1"; "[2001:db8::1]:53" → "2001:db8::1" (PENDING-FOLD 4). A bare IPv6 stays.
    nonisolated static func stripPort(_ s: String) -> String {
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") { return String(s[s.index(after: s.startIndex)..<close]) }
        if s.filter({ $0 == ":" }).count == 1, let colon = s.firstIndex(of: ":") { return String(s[..<colon]) }
        return s
    }

    /// The Diagnostics "DNS" row (UI-CONCEPT §6.11): `?` is never rendered green.
    func dnsCheck(connected: Bool) -> DiagnosticCheck {
        guard connected else {
            return DiagnosticCheck(kind: .dns, result: .unknown,
                                   summary: String(localized: "Not tested while disconnected", comment: "Diagnostics DNS row"), detail: "")
        }
        let detail = resolvers.map { r in
            let tag = r.isTunnel ? String(localized: "tunnel", comment: "Resolver tag") : String(localized: "not tunnel", comment: "Resolver tag")
            return "#\(r.index) \(r.domain ?? "*") \(r.nameservers.joined(separator: ", ")) \(r.interface ?? "?") [\(tag)]"
        }.joined(separator: "\n")
        switch dnsResult {
        case .ok?:
            let first = resolvers.first { $0.domain == nil }
            return DiagnosticCheck(kind: .dns, result: .pass,
                                   summary: String(localized: "Tunnel resolver \(first?.nameservers.first ?? "") owns all domains", comment: "Diagnostics DNS row"),
                                   detail: detail)
        case .mismatch(let d)?:
            return DiagnosticCheck(kind: .dns, result: .fail,
                                   summary: String(localized: "Another resolver took over DNS", comment: "Diagnostics DNS row"), detail: d + "\n" + detail)
        case .unknown(let r)?:
            return DiagnosticCheck(kind: .dns, result: .unknown,
                                   summary: String(localized: "Couldn't verify DNS", comment: "Diagnostics DNS row (never shown as safe)"), detail: r + "\n" + detail)
        case nil:
            return DiagnosticCheck(kind: .dns, result: .unknown,
                                   summary: String(localized: "Not checked yet", comment: "Diagnostics DNS row"), detail: "")
        }
    }
}

/// Preview mode and tests: a fixed resolver answer, no process spawn, no lookups.
struct FixtureDNSSystem: DNSSystemReading {
    var scutil: String?
    var global: [String]?
    var probe = true

    func scutilDNS() async -> String? { scutil }
    func globalDNSServers() -> [String]? { global }
    func probeResolution() async -> Bool { probe }

    /// A healthy full tunnel: utun4 with 10.8.0.1 owns the default.
    static let preview = FixtureDNSSystem(scutil: """
        DNS configuration

        resolver #1
          nameserver[0] : 10.8.0.1
          if_index : 23 (utun4)
          flags    : Request A records
          reach    : 0x00000003 (Reachable,Transient Connection)

        resolver #2
          domain   : local
          options  : mdns
          timeout  : 5
          order    : 300000

        DNS configuration (for scoped queries)

        resolver #1
          nameserver[0] : 192.168.1.1
          if_index : 6 (en0)
        """, global: ["10.8.0.1"])
}
