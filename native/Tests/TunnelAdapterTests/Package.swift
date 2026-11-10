// swift-tools-version: 6.2
// Unit tests for the LockPlusTunnel adapters that run without NetworkExtension (DESIGN §15.1). The sysex target has
// no test target and Tunnel/ is a synchronized folder, so this package lives outside it and compiles the NE-free
// Tunnel sources through relative symlinks (Sources/*/X.swift -> native/Tunnel/X.swift). Run: swift test.
// WireGuardGoBackend (needs libwg-go.a), PacketTunnelProvider and EngineAssembly (NE) are not part of it.
import PackageDescription

let lpSwiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "TunnelAdapterTests",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(path: "../../Packages/LockPlusCore"),
        .package(path: "../../Packages/TunnelEngine"),
        .package(path: "../../Packages/OpenVPN3Shim"),
    ],
    targets: [
        // The adapters as the Release extension compiles them (no LP_DEV_SIGNING).
        .target(
            name: "TunnelAdapters",
            dependencies: [
                .product(name: "LPModel", package: "LockPlusCore"),
                .product(name: "LPParsing", package: "LockPlusCore"),
                .product(name: "LPWire", package: "LockPlusCore"),
                .product(name: "TunnelEngine", package: "TunnelEngine"),
                .product(name: "OpenVPN3Shim", package: "OpenVPN3Shim"),
            ],
            swiftSettings: lpSwiftSettings
        ),
        // The secret-store prefix as Debug/FaultInjection compile it.
        .target(
            name: "TunnelAdaptersDev",
            dependencies: [.product(name: "TunnelEngine", package: "TunnelEngine")],
            swiftSettings: lpSwiftSettings + [.define("LP_DEV_SIGNING")]
        ),
        .testTarget(
            name: "TunnelAdapterTests",
            dependencies: [
                "TunnelAdapters", "TunnelAdaptersDev",
                .product(name: "LPModel", package: "LockPlusCore"),
                .product(name: "LPParsing", package: "LockPlusCore"),
                .product(name: "LPWire", package: "LockPlusCore"),
                .product(name: "TunnelEngine", package: "TunnelEngine"),
                .product(name: "TunnelEngineTestSupport", package: "TunnelEngine"),
                .product(name: "OpenVPN3Shim", package: "OpenVPN3Shim"),
            ],
            swiftSettings: lpSwiftSettings
        ),
    ]
)
