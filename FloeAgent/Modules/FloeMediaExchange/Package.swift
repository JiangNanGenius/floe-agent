// swift-tools-version: 6.2
// SPDX-License-Identifier: MPL-2.0
import PackageDescription

let package = Package(
    name: "FloeMediaExchange",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "MediaExchangeBridge", targets: ["MediaExchangeBridge"]),
        .library(name: "MediaExchangeCore", targets: ["MediaExchangeCore"]),
        .library(name: "MediaExchangeClipper", targets: ["MediaExchangeClipper"]),
        .library(name: "MediaExchangeFCPXML", targets: ["MediaExchangeFCPXML"])
    ],
    dependencies: [
        .package(path: "../.."),
        // The standalone bridge consumes only FloeWorkbench from its parent.
        // Keep its logging ABI on the same reviewed pin as the full App graph.
        .package(url: "https://github.com/apple/swift-log.git", exact: "1.15.0"),
        .package(url: "https://github.com/mattt/EventSource.git", exact: "1.5.1"),
        .package(url: "https://github.com/apple/swift-asn1.git", exact: "1.7.1"),
        .package(url: "https://github.com/apple/swift-collections.git", exact: "1.6.0"),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", exact: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-jinja.git", exact: "2.4.2"),
        .package(url: "https://github.com/tayloraswift/swift-png", exact: "4.5.1"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
        .package(path: "../../ThirdParty/Clipper2")
    ],
    targets: [
        .target(name: "MediaExchangeBridge", dependencies: ["MediaExchangeCore",
            .product(name: "FloeWorkbench", package: "FloeAgent")]),
        .target(name: "MediaExchangeCore", dependencies: [.product(name: "ZIPFoundation", package: "ZIPFoundation"), .product(name: "PNG", package: "swift-png")],
            resources: [.copy("Resources/ag-psd-bundle.js"), .copy("Resources/adapter.js"), .copy("Resources/THIRD_PARTY_NOTICES.md"),
                .copy("Resources/LICENSE-Apache-2.0.txt"), .copy("Resources/SwiftPNG-NOTICE.txt"), .copy("Resources/H-NOTICE.txt")],
            linkerSettings: [.linkedFramework("JavaScriptCore"), .linkedFramework("ImageIO"),
                .linkedFramework("CoreGraphics"), .linkedFramework("UniformTypeIdentifiers")]),
        .target(name: "MediaExchangeClipper", dependencies: ["MediaExchangeCore", .product(name: "Clipper2C", package: "Clipper2")]),
        .target(name: "MediaExchangeFCPXML", dependencies: ["MediaExchangeCore"]),
        .testTarget(name: "MediaExchangeBridgeTests", dependencies: ["MediaExchangeBridge", "MediaExchangeCore",
            .product(name: "FloeWorkbench", package: "FloeAgent")]),
        .testTarget(name: "MediaExchangeCoreTests", dependencies: ["MediaExchangeCore"]),
        .testTarget(name: "MediaExchangeClipperTests", dependencies: ["MediaExchangeClipper"]),
        .testTarget(name: "MediaExchangeFCPXMLTests", dependencies: ["MediaExchangeFCPXML"])
    ]
)
