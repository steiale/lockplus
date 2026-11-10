import Foundation
import LPModel
import os
import SystemConfiguration

/// One resolver from `scutil --dns` (the unscoped section).
struct DNSResolver: Sendable, Equatable {
    var index: Int
    /// nil = the default resolver (no `domain` line).
    var domain: String?
    var searchDomains: [String] = []
    var nameservers: [String] = []
    var interface: String?

    var isTunnel: Bool { interface?.hasPrefix("utun") ?? false }
}

/// DESIGN §10.2 L-DNS-3. `.unknown` is never shown as safe: the banner says "Couldn't verify DNS" (c9e9ffd).
enum DNSCheckResult: Sendable, Equatable {
    case ok
    /// An MDM profile or another VPN overrode our resolver.
    case mismatch(String)
    case unknown(String)
}

/// What the verifier needs from the system; `LiveDNSSystem` is the real one, tests pass fixtures.
protocol DNSSystemReading: Sendable {
    /// `scutil --dns`, spawned as the user, read-only. nil = couldn't run.
    func scutilDNS() async -> String?
    /// `SCDynamicStoreCopyValue("State:/Network/Global/DNS")` `ServerAddresses`.
    func globalDNSServers() -> [String]?
    /// Resolves a random label under `lockplus-check.invalid` through the system resolver; true = the query completed
    /// (an NXDOMAIN answer counts).
    func probeResolution() async -> Bool
}

enum DNSVerifier {
    /// §10.2: 3 s after every `.connected`.
    static let delayAfterConnect: Duration = .seconds(3)

    /// Parses the unscoped part of `scutil --dns` (stops at "for scoped queries").
    static func parse(_ text: String) -> [DNSResolver] {
        var out: [DNSResolver] = []
        var cur: DNSResolver?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("DNS configuration (") { break }
            if line.hasPrefix("resolver #"), let n = Int(line.dropFirst("resolver #".count)) {
                if let cur { out.append(cur) }
                cur = DNSResolver(index: n)
                continue
            }
            guard cur != nil, let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if key == "domain" {
                cur?.domain = value
            } else if key.hasPrefix("search domain[") {
                cur?.searchDomains.append(value)
            } else if key.hasPrefix("nameserver[") {
                cur?.nameservers.append(value)
            } else if key == "if_index", let open = value.firstIndex(of: "("), let close = value.lastIndex(of: ")"), open < close {
                cur?.interface = String(value[value.index(after: open)..<close])
            }
        }
        if let cur { out.append(cur) }
        return out
    }

    /// The rule, pure: resolver #1 (the default) carries the plan's servers, or — when the servers were pushed and
    /// aren't known to the app — belongs to the tunnel interface; with a catch-all plan the tunnel owns the default.
    static func evaluate(resolvers: [DNSResolver], globalServers: [String]?, expectedServers: [String], catchAll: Bool,
                         probeCompleted: Bool) -> DNSCheckResult {
        guard let first = resolvers.first(where: { $0.domain == nil }) else { return .unknown("no default resolver") }
        let expected = Set(expectedServers.map(normalize))
        if !expected.isEmpty {
            let servers = first.nameservers.map(normalize)
            if servers.isEmpty { return .unknown("the default resolver lists no servers") }
            if let foreign = servers.first(where: { !expected.contains($0) }) {
                return .mismatch("resolver #\(first.index) uses \(foreign)\(first.interface.map { " (\($0))" } ?? "")")
            }
            if let g = globalServers?.first.map(normalize), !expected.contains(g) {
                return .mismatch("the global DNS state lists \(g) first")
            }
        }
        if catchAll || expected.isEmpty {
            guard let ifname = first.interface else { return .unknown("the default resolver has no interface") }
            if !first.isTunnel { return .mismatch("resolver #\(first.index) belongs to \(ifname), not the tunnel") }
        }
        return probeCompleted ? .ok : .unknown("a test query didn't complete")
    }

    /// Strips a `%scope` suffix and lowercases (IPv6).
    static func normalize(_ s: String) -> String {
        String(s.split(separator: "%", maxSplits: 1).first ?? Substring(s)).lowercased()
    }

    static func verify(system: any DNSSystemReading, expectedServers: [String], catchAll: Bool) async -> (DNSCheckResult, [DNSResolver]) {
        guard let text = await system.scutilDNS() else { return (.unknown("scutil --dns didn't run"), []) }
        let resolvers = parse(text)
        let probe = await system.probeResolution()
        return (evaluate(resolvers: resolvers, globalServers: system.globalDNSServers(), expectedServers: expectedServers,
                         catchAll: catchAll, probeCompleted: probe), resolvers)
    }
}

struct LiveDNSSystem: DNSSystemReading {
    func scutilDNS() async -> String? {
        await ProcessRunner.run("/usr/sbin/scutil", ["--dns"], timeout: .seconds(3))
    }

    func globalDNSServers() -> [String]? {
        guard let store = SCDynamicStoreCreate(nil, "io.github.steiale.lockplus.mac" as CFString, nil, nil),
              let v = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any] else { return nil }
        return v["ServerAddresses"] as? [String]
    }

    /// A random label under `lockplus-check.invalid` (§10.2 step 3). The lookup runs off the cooperative pool and is
    /// abandoned after 3 s (review M6: a TaskGroup would wait for the blocking getaddrinfo before returning).
    /// mDNSResponder may answer `.invalid` itself (RFC 6761), so a completed lookup proves only that the system
    /// resolver responds, never that DNS goes through the tunnel; the resolver checks above carry that.
    func probeResolution() async -> Bool {
        let label = "lp" + UUID().uuidString.prefix(8).lowercased() + ".lockplus-check.invalid"
        return await withDeadline(.seconds(3), onTimeout: false) {
            await Blocking.run {
                var res: UnsafeMutablePointer<addrinfo>?
                let rc = getaddrinfo(label, nil, nil, &res)
                if let res { freeaddrinfo(res) }
                return rc == 0 || rc == EAI_NONAME || rc == EAI_NODATA
            }
        }
    }
}
