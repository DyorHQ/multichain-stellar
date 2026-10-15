// swift-tools-version: 5.9
import PackageDescription

// StellarKit: everything DyorHQ Lite needs on the phone, with no UI.
// - StellarCore: StrKey, the XDR subset Lite signs, the transaction verifier, SEP-5 / SEP-53 / HKDF keys, ed25519
//   signing. Pure Swift + swift-crypto, so it builds and tests on Linux CI as well as iOS.
// - LiteClient: the typed Lite API client and the plan runner (verify → sign → submit → poll).
// - StellarKit: Apple-only glue (Keychain storage of the Stellar key).
let package = Package(
    name: "StellarKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "StellarCore", targets: ["StellarCore"]),
        .library(name: "LiteClient", targets: ["LiteClient"]),
        .library(name: "StellarKit", targets: ["StellarKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
    ],
    targets: [
        .target(
            name: "StellarCore",
            dependencies: [.product(name: "Crypto", package: "swift-crypto")],
            resources: [.copy("Keys/bip39-english.txt")]
        ),
        // LiteAPI's SEP-53 self-check hashes with swift-crypto where CryptoKit is missing (Linux CI).
        .target(name: "LiteClient", dependencies: ["StellarCore", .product(name: "Crypto", package: "swift-crypto")]),
        .target(name: "StellarKit", dependencies: ["StellarCore", "LiteClient"]),
        .testTarget(name: "StellarCoreTests", dependencies: ["StellarCore"], resources: [.copy("Vectors")]),
        // The API fixtures are read from the source tree (#filePath), so they are no resources of the target.
        .testTarget(name: "LiteClientTests", dependencies: ["LiteClient", "StellarCore"], exclude: ["Fixtures"]),
    ]
)
