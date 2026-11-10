import Darwin
import Foundation
import LPParsing

/// DESIGN §9.3 (draft 9, S2 E10): the APP resolves a profile's endpoint hostnames right before `startVPNTunnel` and
/// passes `[hostname: [IP]]` in the start options (`lp.endpoints`). Under `includeAllNetworks` the provider never
/// resolves (a provider `getaddrinfo` blocked for 30 s and failed in S2); it uses these IPs, then its cache.
///
/// Runs in the app while no tunnel of ours is up (a profile switch waits for `.disconnected` first, §6.2), so the
/// system resolver answers. Every hostname is resolved concurrently on RouteProbe's queue with a per-host deadline;
/// a slow or failing host is simply left out (the extension then falls back to its cache).
public enum StartEndpointResolver {
    public static let perHostDeadline: DispatchTimeInterval = .seconds(3)
    public static let maxHosts = 8
    public static let maxIPsPerHost = 16

    /// `endpoints`: the profile summary's "host:port" strings (IPv6 bracketed) or bare hosts. IP literals need no entry.
    public static func resolve(_ endpoints: [String], deadline: DispatchTimeInterval = perHostDeadline,
                               lookup: @escaping @Sendable (String) -> [String] = lookupIPs) async -> [String: [String]] {
        let hosts = hostnames(endpoints)
        return await withTaskGroup(of: (String, [String]).self) { g in
            for h in hosts {
                g.addTask {
                    let joined = await RouteProbe.race(deadline: deadline) { @Sendable in
                        let ips = lookup(h)
                        return ips.isEmpty ? nil : ips.joined(separator: " ")
                    }
                    return (h, joined.map { $0.split(separator: " ").map(String.init) } ?? [])
                }
            }
            var out: [String: [String]] = [:]
            for await (h, ips) in g where !ips.isEmpty { out[h] = Array(ips.prefix(maxIPsPerHost)) }
            return out
        }
    }

    /// The distinct hostnames (lowercased, ≤ 8) of `endpoints`; IP literals and malformed entries are dropped.
    public static func hostnames(_ endpoints: [String]) -> [String] {
        var out: [String] = []
        for e in endpoints {
            let host = (HostPort.split(e)?.host ?? e).lowercased()
            guard !host.isEmpty, IPAddress.parse(host) == nil, Hostname.isValid(host.hasSuffix(".") ? String(host.dropLast()) : host),
                  !out.contains(host) else { continue }
            out.append(host)
            if out.count == maxHosts { break }
        }
        return out
    }

    /// `getaddrinfo` (all results, v4 first, de-duplicated) as numeric strings.
    public static func lookupIPs(_ host: String) -> [String] {
        RouteProbe.resolve(host: host, port: "0").compactMap { ss in
            var s = ss
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let rc = withUnsafePointer(to: &s) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getnameinfo($0, socklen_t($0.pointee.sa_len), &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST)
                }
            }
            guard rc == 0 else { return nil }
            let text = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            return text.split(separator: "%").first.map(String.init)      // drop a link-local zone (not a server IP)
        }
    }
}
