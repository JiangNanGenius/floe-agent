// swift-tools-version: 6.2
import PackageDescription

// Embedded native macOS VNC remote desktop for the Mac toolbox.
// Consumes the vendored RoyalVNCKit read-only; no FloeMac host or FloeAgent
// sources are modified by this package.
let package = Package(
    name: "FloeMacVNC",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FloeMacVNC", targets: ["FloeMacVNC"]),
    ],
    dependencies: [
        .package(path: "../../../FloeAgent/ThirdParty/RoyalVNCKit"),
    ],
    targets: [
        .target(
            name: "FloeMacVNC",
            dependencies: [
                .product(name: "RoyalVNCKit", package: "RoyalVNCKit"),
            ]
        ),
        .testTarget(
            name: "FloeMacVNCTests",
            dependencies: [
                "FloeMacVNC",
                .product(name: "RoyalVNCKit", package: "RoyalVNCKit"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
