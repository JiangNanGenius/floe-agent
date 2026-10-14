// swift-tools-version:6.2
import PackageDescription

// Standalone native-macOS qualification for the Floe media-enhancement (T2)
// pipeline. It compiles the production FloeMedia sources through the parent
// package (local path dependency) and runs real VideoToolbox / Core ML work on
// synthetic and pinned fixtures. Simulator execution is not evidence here:
// Apple excludes the VTFrameProcessor frame-rate/super-resolution headers from
// Simulator builds, so this host is the native-processor proof.
//
// Build (isolated scratch on the internal SSD):
//   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
//   swift build --package-path FloeAgent/Qualification/MediaEnhancement \
//     --scratch-path ~/Library/Caches/CodexBuild/Floe/capability-closure-20261014/media \
//     --jobs 3
let package = Package(
    name: "FloeMediaEnhancementQualification",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "FloeMediaEnhancementQualification",
            dependencies: [
                .product(name: "FloeCore", package: "FloeAgent"),
                .product(name: "FloeTools", package: "FloeAgent"),
                .product(name: "FloeMedia", package: "FloeAgent")
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "FloeMediaEnhancementTests",
            dependencies: [
                "FloeMediaEnhancementQualification",
                .product(name: "FloeCore", package: "FloeAgent"),
                .product(name: "FloeTools", package: "FloeAgent"),
                .product(name: "FloeMedia", package: "FloeAgent")
            ],
            // Canonical tests live in FloeAgent/Tests/FloeMediaTests; this
            // symlink lets the standalone harness compile and run them.
            path: "Tests/FloeMediaTests"
        )
    ]
)
