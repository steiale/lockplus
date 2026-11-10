// swift-tools-version: 6.2
// TunnelEngine (DESIGN §2.2): the extension's engine-independent core and the XPC listener (§5.1).
// Depends on LockPlusCore, NetworkExtension, Network, Security, CryptoKit, Synchronization, os.
// MUST NOT depend on AppKit, SwiftUI, Sparkle or LocalAuthentication.
// WireGuardKitGo (libwg-go) and OpenVPN3Shim are linked by the LockPlusTunnel target, not by this package.
import PackageDescription

let lpSwiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "TunnelEngine",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "TunnelEngine", targets: ["TunnelEngine"]),
        .library(name: "TunnelEngineTestSupport", targets: ["TunnelEngineTestSupport"]),
    ],
    dependencies: [
        .package(path: "../LockPlusCore"),
    ],
    targets: [
        .target(
            name: "TunnelEngine",
            dependencies: [
                .product(name: "LPModel", package: "LockPlusCore"),
                .product(name: "LPParsing", package: "LockPlusCore"),
                .product(name: "LPWire", package: "LockPlusCore"),
            ],
            swiftSettings: lpSwiftSettings
        ),
        // Fakes and ManualClock for the TunnelEngine tests (§2.1 Tests/, §15.1).
        .target(
            name: "TunnelEngineTestSupport",
            dependencies: ["TunnelEngine"],
            swiftSettings: lpSwiftSettings
        ),
        .testTarget(
            name: "TunnelEngineTests",
            dependencies: ["TunnelEngine", "TunnelEngineTestSupport"],
            swiftSettings: lpSwiftSettings
        ),
        // XPC listener + app client end to end over an in-process anonymous listener (§5.3, §5.4, §15.1).
        .testTarget(
            name: "TunnelEngineXPCTests",
            dependencies: [
                "TunnelEngine",
                .product(name: "LPXPCClient", package: "LockPlusCore"),
                .product(name: "LPWire", package: "LockPlusCore"),
            ],
            swiftSettings: lpSwiftSettings
        ),
    ]
)
