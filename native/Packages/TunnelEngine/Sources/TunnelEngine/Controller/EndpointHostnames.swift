import Foundation
import LPModel

/// Review PF-R4: the endpoint hostnames a canonical payload references (lowercased, IP literals excluded). The
/// controller caches IPs only for these, so an app-supplied map (start options, pushes) can't grow the cache with
/// arbitrary names.
enum EndpointHostnames {
    static func referenced(kind: VPNProtocolKind, payload: SecretBytes) -> Set<String> {
        switch kind {
        case .openVPN: OVPNRemoteRewriter.referencedHosts(payload)
        case .wireGuard: wireGuard(payload)
        }
    }

    /// `Endpoint = host:port` lines (any case, any `[Peer]`). Only a line that starts with `Endpoint` ever becomes a
    /// `String`; key lines stay bytes.
    static func wireGuard(_ payload: SecretBytes) -> Set<String> {
        payload.withUnsafeBytes { raw in
            var hosts: Set<String> = []
            let key = Array("endpoint".utf8)
            for line in raw.split(separator: 0x0A, omittingEmptySubsequences: true) {
                var i = line.startIndex
                while i < line.endIndex, line[i] == 0x20 || line[i] == 0x09 { i += 1 }
                guard line.endIndex - i > key.count,
                      zip(line[i..<(i + key.count)], key).allSatisfy({ $0 | 0x20 == $1 }) else { continue }
                var j = i + key.count
                while j < line.endIndex, line[j] == 0x20 || line[j] == 0x09 { j += 1 }
                guard j < line.endIndex, line[j] == 0x3D else { continue }        // "="
                let value = String(decoding: line[(j + 1)...], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                guard let hp = IPAddress.splitHostPort(value), !IPAddress.isV4(hp.host), !IPAddress.isV6(hp.host) else { continue }
                hosts.insert(hp.host.lowercased())
            }
            return hosts
        }
    }
}
