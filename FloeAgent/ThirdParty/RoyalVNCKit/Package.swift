// swift-tools-version: 6.0
import PackageDescription

// Minimal library slice of upstream 92d4427c73817d8f849bb289ff190aa4b40c44ea.
// See FLOE_PATCHES.md. Demo targets and Windows-only zlib are not shipped.
let package = Package(
    name: "RoyalVNCKit",
    platforms: [.macOS(.v11), .iOS(.v15), .macCatalyst(.v15), .tvOS(.v15), .visionOS(.v1)],
    products: [.library(name: "RoyalVNCKit", type: .dynamic, targets: ["RoyalVNCKit"])],
    dependencies: [
        .package(url: "https://github.com/royalapplications/CryptoSwift.git", revision: "a59b4d91ebb22011656c830f874fe7152e183a57"),
        .package(url: "https://github.com/tayloraswift/swift-jpeg", from: "2.0.0"),
        .package(url: "https://github.com/tayloraswift/swift-png", from: "4.4.0")
    ],
    targets: [
        .target(name: "RoyalVNCKitC"),
        .target(name: "d3des"),
        .target(name: "Z", linkerSettings: [.linkedLibrary("z")]),
        .target(name: "RoyalVNCKit", dependencies: [
            "RoyalVNCKitC", "d3des", "Z", "CryptoSwift",
            .product(name: "JPEG", package: "swift-jpeg", condition: .when(platforms: [.linux])),
            .product(name: "PNG", package: "swift-png", condition: .when(platforms: [.linux]))
        ], swiftSettings: [.swiftLanguageMode(.v5), .unsafeFlags(["-enable-library-evolution"])])
    ]
)
