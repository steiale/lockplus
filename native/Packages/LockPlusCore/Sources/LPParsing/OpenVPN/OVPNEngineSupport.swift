import LPModel
// EngineSupport: how openvpn3 treats each allowlisted directive (DESIGN §8.1 [4], §8.2).
// The table itself is GENERATED (OVPNEngineSupport.generated.swift); this file holds the types and the conditional
// rules the table cannot express, which the normalizer applies.

/// The engine class of an allowlisted directive.
public enum OVPNEngineClass: Sendable, Equatable, Hashable {
    /// Passed to openvpn3 and honoured.
    case mapped
    /// openvpn3 ignores it with a warning: dropped from the canonical text, listed under "Will be ignored".
    case ignoredWarn(String)
    /// openvpn3 ignores it silently: dropped from the canonical text, listed under "Will be ignored".
    case ignoredSilent
    /// Engine-fatal or unwanted but harmless: dropped with a note (reviewed override, `EngineSupportOverrides`).
    case dropped(String)
    /// Import is rejected ("Not supported").
    case unsupported(String)
}

extension OVPNEngineSupport {
    /// The class of `name`, or nil when the directive is not on the allowlist (forbidden).
    public static func classify(_ name: String) -> OVPNEngineClass? { table[name] }

    /// Directives whose repetition is meaningful (lists). Every other mapped directive is a singleton: a repeat is
    /// deduplicated keeping the LAST occurrence, like openvpn 2.x and openvpn3 (§8.1 [5], draft 7), because [7b]
    /// otherwise rejects "Unused options, probably specified multiple times".
    public static let repeatable: Set<String> = [
        "remote", "route", "route-ipv6", "dhcp-option", "dns", "pull-filter", "setenv", "connection",
        "ignore-unknown-option", "http-proxy-option", "redirect-gateway", "redirect-private", "peer-fingerprint",
    ]
}
