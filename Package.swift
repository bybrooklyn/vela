// swift-tools-version: 6.1

import PackageDescription

var products: [Product] = [
    .library(name: "VelaDomain", targets: ["VelaDomain"]),
    .library(name: "VelaCrypto", targets: ["VelaCrypto"]),
    .library(name: "VelaStorage", targets: ["VelaStorage"]),
    .library(name: "VelaTransport", targets: ["VelaTransport"]),
    .library(name: "VelaCore", targets: ["VelaCore"]),
    .library(name: "VelaSignalBridge", targets: ["VelaSignalBridge"]),
    .library(name: "VelaSignalCLI", targets: ["VelaSignalCLI"]),
    .executable(name: "vela-demo", targets: ["VelaDemo"]),
]

var targets: [Target] = [
    // SQLCipher compiled from its amalgamation rather than linking the system
    // sqlite3, which has no encryption. CommonCrypto is used as the crypto
    // provider so nothing beyond the OS is required — no OpenSSL, no Homebrew.
    .target(
        name: "CSQLite",
        cSettings: [
            .define("SQLITE_HAS_CODEC"),
            .define("SQLCIPHER_CRYPTO_CC"),
            // SQLCipher installs its codec through these hooks; without them
            // the amalgamation refuses to compile.
            .define("SQLITE_EXTRA_INIT", to: "sqlcipher_extra_init"),
            .define("SQLITE_EXTRA_SHUTDOWN", to: "sqlcipher_extra_shutdown"),
            // SQLite's internal asserts reference fields that only exist under
            // SQLITE_DEBUG. NDEBUG is how the amalgamation is meant to ship.
            .define("NDEBUG"),
            .define("SQLITE_TEMP_STORE", to: "2"),
            .define("SQLITE_THREADSAFE", to: "1"),
            .define("SQLITE_ENABLE_FTS5"),
            .define("SQLITE_OMIT_DEPRECATED"),
            // Apple SDK headers and the vendored amalgamation both define
            // MIN/MAX. This warning originates in external C source; keep
            // warning policy unchanged for first-party Swift targets.
            .unsafeFlags(["-Wno-ambiguous-macro"]),
            .headerSearchPath("include"),
        ],
        linkerSettings: [
            .linkedFramework("Security"),
            .linkedFramework("Foundation"),
        ]
    ),
    .target(name: "VelaDomain"),
    .target(
        name: "VelaCrypto",
        dependencies: ["VelaDomain"]
    ),
    .target(
        name: "VelaStorage",
        dependencies: ["VelaDomain", "VelaCrypto", "CSQLite"]
    ),
    .target(
        name: "VelaTransport",
        dependencies: ["VelaDomain"]
    ),
    .target(
        name: "VelaCore",
        dependencies: ["VelaDomain", "VelaCrypto", "VelaStorage", "VelaTransport"]
    ),
    .target(
        name: "VelaSignalBridge",
        dependencies: ["VelaDomain", "VelaCrypto", "VelaTransport"]
    ),
    .target(
        name: "VelaSignalCLI",
        dependencies: ["VelaDomain", "VelaCrypto", "VelaTransport", "VelaCore"]
    ),
    .executableTarget(
        name: "VelaDemo",
        dependencies: ["VelaCore", "VelaStorage", "VelaTransport", "VelaCrypto", "VelaDomain"]
    ),
    .testTarget(
        name: "VelaDomainTests",
        dependencies: ["VelaDomain"]
    ),
    .testTarget(
        name: "VelaStorageTests",
        dependencies: ["VelaStorage", "VelaDomain", "VelaCrypto", "CSQLite"]
    ),
    .testTarget(
        name: "VelaCoreTests",
        dependencies: ["VelaCore", "VelaStorage", "VelaTransport", "VelaCrypto", "VelaDomain"]
    ),
    .testTarget(
        name: "VelaCryptoTests",
        dependencies: ["VelaCrypto", "VelaDomain"]
    ),
    .testTarget(
        name: "VelaSignalBridgeTests",
        dependencies: ["VelaSignalBridge", "VelaCrypto", "VelaDomain"]
    ),
    .testTarget(
        name: "VelaSignalCLITests",
        dependencies: ["VelaSignalCLI", "VelaDomain", "VelaCrypto", "VelaTransport"]
    ),
]

#if os(macOS)
products.append(.executable(name: "VelaMacApp", targets: ["VelaMacApp"]))
targets.append(
    .executableTarget(
        name: "VelaMacApp",
        dependencies: [
            "VelaCore",
            "VelaDomain",
            "VelaCrypto",
            "VelaStorage",
            "VelaTransport",
            "VelaSignalBridge",
            "VelaSignalCLI",
        ],
        path: "MacClient/Sources",
        swiftSettings: [
            .define("VELA_DEVELOPMENT_MODE", .when(configuration: .debug)),
        ]
    )
)
#endif

let package = Package(
    name: "Vela",
    platforms: [
        // macOS 26 for Liquid Glass (glassEffect, GlassEffectContainer,
        // scrollEdgeEffect). Gating every view on availability would mean two
        // parallel UI code paths.
        .macOS("26.0")
    ],
    products: products,
    targets: targets
)
