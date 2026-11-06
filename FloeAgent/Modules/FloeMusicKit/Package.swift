// swift-tools-version: 6.2
import PackageDescription

// FloeMusicKit — standalone music studio core model, editing transactions and
// performance (DJ / keyboard) session state. Pure model: no audio runtime, no
// UI, no external dependencies. Production App integration is a separate,
// coordinator-owned stage.
let package = Package(
    name: "FloeMusicKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "FloeMusicCore", targets: ["FloeMusicCore"])
    ],
    dependencies: [],
    targets: [
        .target(name: "FloeMusicCore"),
        .testTarget(name: "FloeMusicCoreTests", dependencies: ["FloeMusicCore"])
    ],
    swiftLanguageModes: [.v6]
)
