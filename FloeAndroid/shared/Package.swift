// swift-tools-version: 6.4
import PackageDescription

// A narrow overlay: source links reuse the original implementation without resolving
// iOS-only binary dependencies in FloeAgent/Package.swift.
let package = Package(
    name: "FloeAndroidCore",
    platforms: [.macOS(.v15)],
    products: [.library(name: "FloeAndroidCore", type: .dynamic, targets: ["FloeAndroidCore"])],
    targets: [
        .target(name: "FloeSharedModels"),
        .target(name: "FloeAndroidCore", dependencies: ["FloeSharedModels"]),
        .testTarget(name: "FloeAndroidCoreTests", dependencies: ["FloeAndroidCore"])
    ]
)
