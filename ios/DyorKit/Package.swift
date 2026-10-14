// swift-tools-version: 5.9
import PackageDescription

// DyorKit: the platform-independent core of the DyorHQ iOS app. Everything that talks to Monad, the trading
// venues and Perpl lives here so it can be unit-tested with `swift test` on macOS without a simulator.
let package = Package(
    name: "DyorKit",
    // DyorKit's own text (step labels, errors) is in English in code and translated in Resources/Localizable.xcstrings.
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "DyorKit", targets: ["DyorKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/attaswift/BigInt.git", "5.7.0"..<"7.0.0"),
        // ECDSA secp256k1 (libsecp256k1) for importing and signing with a user's own wallet, on-device.
        .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1", exact: "0.21.1"),
    ],
    targets: [
        .target(name: "DyorKit", dependencies: [
            .product(name: "BigInt", package: "BigInt"),
            .product(name: "P256K", package: "swift-secp256k1"),
        ], resources: [.process("Resources")]),
        .testTarget(name: "DyorKitTests", dependencies: ["DyorKit"], resources: [.copy("Fixtures")]),
    ]
)
