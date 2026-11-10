// swift-tools-version: 6.2
// OpenVPN3Shim (DESIGN §2.2): ObjC++ over the openvpn3 client API, built from the vendored sources.
//   OpenVPN3Shim    client core, -DUSE_TUN_BUILDER (openvpn/tun/mac/** never compiled: nothing includes it with
//                   USE_TUN_BUILDER), OpenSSL 3.5 XCFramework, asio 1.24.0 (+7 patches), lz4 1.11.0. Extension only.
//   OpenVPN3Options OptionList parser only (no crypto, no network). Linked by the app for the import differential.
// Vendor/ holds committed RELATIVE symlinks into ../../Vendor (SPM resolves binaryTarget and header search paths
// only inside the package root; S14). Run Tools/bootstrap/vendor.sh and openssl.sh first. No unsafeFlags.
import PackageDescription

let openvpn3Headers: [CXXSetting] = [
    .headerSearchPath("../../Vendor/openvpn3"),
    .headerSearchPath("../../Vendor/asio/asio/include"),
]

let package = Package(
    name: "OpenVPN3Shim",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "OpenVPN3Shim", targets: ["OpenVPN3Shim"]),
        .library(name: "OpenVPN3Options", targets: ["OpenVPN3Options"]),
    ],
    targets: [
        .binaryTarget(name: "OpenSSL", path: "Vendor/OpenSSL.xcframework"),
        .target(
            name: "OpenVPN3Shim",
            dependencies: ["OpenSSL"],
            cSettings: [.headerSearchPath("../../Vendor/lz4/lib")],
            cxxSettings: [
                .define("USE_ASIO"), .define("ASIO_STANDALONE"), .define("ASIO_NO_DEPRECATED"),
                .define("HAVE_LZ4"), .define("USE_OPENSSL"), .define("USE_TUN_BUILDER"),
                .define("OPENVPN_CORE_API_VISIBILITY_HIDDEN"),
                .headerSearchPath("../../Vendor/lz4/lib"),
            ] + openvpn3Headers
            // No linkerSettings: with USE_TUN_BUILDER nothing references CoreFoundation/IOKit/CoreServices/
            // SystemConfiguration (S14).
        ),
        .target(
            name: "OpenVPN3Options",
            // openvpn3's buffer types use the asio namespace alias, so asio headers are needed (header-only, no I/O).
            cxxSettings: [.define("USE_ASIO"), .define("ASIO_STANDALONE"), .define("ASIO_NO_DEPRECATED")] + openvpn3Headers
        ),
        .testTarget(name: "OpenVPN3ShimTests", dependencies: ["OpenVPN3Shim", "OpenVPN3Options"]),
    ],
    cxxLanguageStandard: .cxx20
)
