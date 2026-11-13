// swift-tools-version: 6.2
// ProfileValidator (PLAN-2.0.2 §1.2): the profile checks that must not run in root.
//   LPOptionsParser      [6] (ShimOptionsParser, openvpn3's OptionList) and the report rules (ProfileCheckRules).
//                        Linked by the extension and the validator service (round 1, Fable N5: the extension links no [7]).
//   LPEngineCheck        [1]–[7] for OpenVPN/WireGuard payloads (OpenVPNEngineCheck, WireGuardEngineCheck). No ZIPFoundation.
//                        Linked by the validator service only.
//   LPValidatorService   the service's exported object, the zip reader (ZIPFoundation) and the listener delegate.
//                        Linked by the validator service only.
// Foundation + OpenVPN3Shim only; MUST NOT depend on AppKit, SwiftUI, NetworkExtension or Sparkle.
import PackageDescription

let lpSwiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "ProfileValidator",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "LPOptionsParser", targets: ["LPOptionsParser"]),
        .library(name: "LPEngineCheck", targets: ["LPEngineCheck"]),
        .library(name: "LPValidatorService", targets: ["LPValidatorService"]),
    ],
    dependencies: [
        .package(path: "../LockPlusCore"),
        .package(path: "../OpenVPN3Shim"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),   // same pin as the app (pins.sh)
    ],
    targets: [
        .target(
            name: "LPOptionsParser",
            dependencies: [
                .product(name: "LPModel", package: "LockPlusCore"),
                .product(name: "LPParsing", package: "LockPlusCore"),
                .product(name: "OpenVPN3Shim", package: "OpenVPN3Shim"),
            ],
            swiftSettings: lpSwiftSettings
        ),
        .target(
            name: "LPEngineCheck",
            dependencies: [
                "LPOptionsParser",
                .product(name: "LPModel", package: "LockPlusCore"),
                .product(name: "LPParsing", package: "LockPlusCore"),
                .product(name: "LPWire", package: "LockPlusCore"),
                .product(name: "OpenVPN3Shim", package: "OpenVPN3Shim"),
            ],
            swiftSettings: lpSwiftSettings
        ),
        .target(
            name: "LPValidatorService",
            dependencies: [
                "LPEngineCheck",
                .product(name: "LPModel", package: "LockPlusCore"),
                .product(name: "LPParsing", package: "LockPlusCore"),
                .product(name: "LPWire", package: "LockPlusCore"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            swiftSettings: lpSwiftSettings
        ),
        .testTarget(
            name: "LPEngineCheckTests",
            dependencies: [
                "LPEngineCheck",
                "LPOptionsParser",
                .product(name: "LPModel", package: "LockPlusCore"),
                .product(name: "LPParsing", package: "LockPlusCore"),
                .product(name: "LPWire", package: "LockPlusCore"),
            ],
            resources: [.copy("Golden")],
            swiftSettings: lpSwiftSettings
        ),
        .testTarget(
            name: "LPValidatorServiceTests",
            dependencies: [
                "LPValidatorService",
                "LPEngineCheck",
                .product(name: "LPModel", package: "LockPlusCore"),
                .product(name: "LPParsing", package: "LockPlusCore"),
                .product(name: "LPWire", package: "LockPlusCore"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            swiftSettings: lpSwiftSettings
        ),
    ]
)
