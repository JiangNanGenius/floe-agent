// swift-tools-version: 6.2
//
// FloeCADKit — Floe's native CAD kernel package.
//
// Geometry kernel extraction (with modifications) from OpenShape3D
// (https://github.com/laanlabs/OpenShape3D, commit 30b3c7c1784754f237466e093ab42ff085175d40,
// MIT). See UPSTREAM.md and PATCHES.md beside this manifest for provenance,
// the exact patch list and the LGPL relink statement for OCCT.
import PackageDescription

let package = Package(
    name: "FloeCADKit",
    platforms: [
        .iOS(.v26)
    ],
    products: [
        .library(name: "FloeCAD", targets: ["FloeCAD"])
    ],
    dependencies: [
        // Pinned to the exact revision used by upstream OpenShape3D 30b3c7c.
        .package(url: "https://github.com/nicklockwood/Euclid.git", exact: "0.9.6")
    ],
    targets: [
        // OCCT 7.8.1 static slices, built by upstream scripts/build_occt_ios.sh.
        // LGPL-2.1 + Open CASCADE exception; relink route recorded in
        // ThirdParty/FloeCADKit/OCCT_RELINK.md.
        .binaryTarget(name: "OCCT", path: "Vendor/OCCT.xcframework"),

        // ObjC++ façade over OCCT plus the LAPACK shim used by the sketch
        // solver. Swift never sees OCCT C++ headers.
        .target(
            name: "OCCTShim",
            path: "Sources/OCCTShim",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("../../Vendor/OCCT.xcframework/ios-arm64/Headers")
            ],
            linkerSettings: [
                .linkedFramework("Accelerate")
            ]
        ),

        // Extracted kernel, feature graph, renderer and editor state machine.
        // Swift 5 language mode matches upstream; the default MainActor
        // isolation mirrors the upstream Xcode project setting.
        .target(
            name: "FloeCAD",
            dependencies: [
                "OCCTShim",
                "OCCT",
                .product(name: "Euclid", package: "Euclid")
            ],
            path: "Sources/FloeCAD",
            exclude: [
                // App-shell coupled; Floe adaptations are added back as they
                // are ported (see PATCHES.md).
                "Model/ProjectArchive.swift",
                "Model/ProjectFolder.swift",
                "Model/SampleDesigns.swift"
            ],
            resources: [
                .copy("Shaders")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .defaultIsolation(MainActor.self)
            ],
            linkerSettings: [
                .linkedFramework("Accelerate"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("ModelIO"),
                .linkedFramework("CoreText"),
                .linkedFramework("ImageIO"),
                .linkedFramework("UniformTypeIdentifiers")
            ]
        ),

        .testTarget(
            name: "FloeCADKitTests",
            dependencies: [
                "FloeCAD",
                .product(name: "Euclid", package: "Euclid")
            ],
            path: "Tests/FloeCADKitTests",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .defaultIsolation(MainActor.self)
            ]
        )
    ],
    cxxLanguageStandard: .cxx20
)
