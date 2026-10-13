// swift-tools-version: 5.9
import PackageDescription

// DyorLite: the Lite (Stellar) interface. SwiftUI, iOS 17+. The host app (DyorHQ, or LiteHarness for internal
// testing) gives it a key provider and, optionally, a way to sign Monad transactions for the bridge.
let package = Package(
    name: "DyorLite",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "DyorLite", targets: ["DyorLite"])],
    dependencies: [.package(path: "../StellarKit")],
    targets: [
        .target(name: "DyorLite", dependencies: [.product(name: "StellarKit", package: "StellarKit")]),
        .testTarget(name: "DyorLiteTests", dependencies: ["DyorLite"]),
    ]
)
