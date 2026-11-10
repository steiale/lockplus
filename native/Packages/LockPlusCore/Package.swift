// swift-tools-version: 6.2
// LockPlusCore (DESIGN §2.2): Foundation-only modules shared by the app and the extension.
// MUST NOT depend on AppKit, SwiftUI, NetworkExtension, Security or CryptoKit.
// No configuration-dependent conditions here: SwiftPM knows only debug/release, so LP_DEV_SIGNING and
// LP_FAULT_INJECTION live in the Xcode targets' xcconfigs (§2.2, §5.3).
import PackageDescription

/// SC1 concurrency settings (ref/swift-concurrency §2.2) + MemberImportVisibility (Conflicts z).
/// Swift 6 language mode is the default for tools 6.x; default actor isolation stays nonisolated.
let lpSwiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "LockPlusCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "LPModel", targets: ["LPModel"]),
        .library(name: "LPParsing", targets: ["LPParsing"]),
        .library(name: "LPWire", targets: ["LPWire"]),
        .library(name: "LPXPCClient", targets: ["LPXPCClient"]),
        .library(name: "LPRouteProbe", targets: ["LPRouteProbe"]),
    ],
    targets: [
        // Domain types shared by every layer (errors, protocol kinds).
        .target(name: "LPModel", swiftSettings: lpSwiftSettings),
        // WireGuard / OpenVPN parsers and validators (§8.1, §9.1). Fuzzed on macOS (§15.4).
        .target(name: "LPParsing", dependencies: ["LPModel"], swiftSettings: lpSwiftSettings),
        // XPC protocol, wire messages, size-capped codec and the signing requirement constants (§5.2, §5.3).
        .target(name: "LPWire", dependencies: ["LPModel"], swiftSettings: lpSwiftSettings),
        // The app's TunnelServiceClient (§5.4). Foundation + Synchronization only.
        .target(name: "LPXPCClient", dependencies: ["LPModel", "LPWire"], swiftSettings: lpSwiftSettings),

        // RouteProbe (§9.3): Darwin PF_ROUTE RTM_GET; used by the app at import and by the extension at start.
        .target(name: "LPRouteProbe", dependencies: ["LPParsing"], swiftSettings: lpSwiftSettings),

        .testTarget(name: "LPModelTests", dependencies: ["LPModel"], swiftSettings: lpSwiftSettings),
        .testTarget(name: "LPParsingTests", dependencies: ["LPParsing"], swiftSettings: lpSwiftSettings),
        .testTarget(name: "LPWireTests", dependencies: ["LPWire"], swiftSettings: lpSwiftSettings),
        .testTarget(name: "LPRouteProbeTests", dependencies: ["LPRouteProbe"], swiftSettings: lpSwiftSettings),
        .testTarget(name: "LPXPCClientTests", dependencies: ["LPXPCClient", "LPWire"], swiftSettings: lpSwiftSettings),
    ]
)
