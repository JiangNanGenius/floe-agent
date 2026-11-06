// swift-tools-version: 6.2
import PackageDescription

// Independent meeting core for the Floe notes-embedded meetings workspace.
// Production App integration is separate and owned by the coordinator.
let package = Package(
    name: "FloeMeetings",
    defaultLocalization: "en",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "FloeMeetings", targets: ["FloeMeetings"]),
        .library(name: "FloeMeetingsAV", targets: ["FloeMeetingsAV"])
    ],
    dependencies: [
        // Same pinned version as the main FloeAgent package (FloeAgent/Package.swift).
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.8.0")
    ],
    targets: [
        .target(
            name: "FloeMeetings",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(
            name: "FloeMeetingsAV",
            dependencies: ["FloeMeetings"]
        ),
        .testTarget(
            name: "FloeMeetingsTests",
            dependencies: ["FloeMeetings", "FloeMeetingsAV"]
        )
    ],
    swiftLanguageModes: [.v6]
)
