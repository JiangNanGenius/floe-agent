// swift-tools-version: 6.2
// Candidate only: this package lives under Local/Scratch and is not part of the
// FloeMac or FloeAgent Xcode projects. It references the existing FloeToolbox
// package read-only so the candidate reuses the real catalog, recognition,
// export and signal-analysis code instead of duplicating it.
import PackageDescription

let package = Package(
    name: "FloeMacToolboxMedia",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FloeMacMediaCore", targets: ["FloeMacMediaCore"]),
        .library(name: "FloeMacMediaSystem", targets: ["FloeMacMediaSystem"]),
        .library(name: "FloeMacMediaUI", targets: ["FloeMacMediaUI"]),
    ],
    dependencies: [
        .package(name: "FloeToolbox", path: "../../../FloeAgent/Modules/FloeToolbox"),
    ],
    targets: [
        .target(
            name: "FloeMacMediaCore",
            dependencies: [
                .product(name: "FloeToolboxCore", package: "FloeToolbox"),
                .product(name: "FloeToolboxUtilities", package: "FloeToolbox"),
            ]
        ),
        .target(
            name: "FloeMacMediaSystem",
            dependencies: [
                "FloeMacMediaCore",
                .product(name: "FloeToolboxCore", package: "FloeToolbox"),
                .product(name: "FloeToolboxUtilities", package: "FloeToolbox"),
            ]
        ),
        .target(
            name: "FloeMacMediaUI",
            dependencies: ["FloeMacMediaCore", "FloeMacMediaSystem"]
        ),
        .testTarget(
            name: "FloeMacMediaCoreTests",
            dependencies: [
                "FloeMacMediaCore",
                .product(name: "FloeToolboxCore", package: "FloeToolbox"),
                .product(name: "FloeToolboxUtilities", package: "FloeToolbox"),
            ]
        ),
        .testTarget(
            name: "FloeMacMediaSystemTests",
            dependencies: ["FloeMacMediaSystem", "FloeMacMediaCore"]
        ),
        .testTarget(
            name: "FloeMacMediaUITests",
            dependencies: ["FloeMacMediaUI"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
