// swift-tools-version: 5.9
import PackageDescription

// DyorLite: DyorHQ's Stellar screens and session. SwiftUI, iOS 17+. The host app (DyorHQ, or LiteHarness for internal
// testing) owns a `LiteSession` per account, unlocks the account's Stellar key for it and, optionally, signs Monad
// transactions for the bridge.
let package = Package(
    name: "DyorLite",
    // The package's own text is in English in code and translated in Resources/Localizable.xcstrings (LiteL10n).
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "DyorLite", targets: ["DyorLite"])],
    dependencies: [.package(path: "../StellarKit")],
    targets: [
        .target(name: "DyorLite", dependencies: [.product(name: "StellarKit", package: "StellarKit")], resources: [.process("Resources")]),
        .testTarget(name: "DyorLiteTests", dependencies: ["DyorLite"]),
    ]
)
