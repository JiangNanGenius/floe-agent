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
        .package(url: "https://github.com/nicklockwood/Euclid.git", exact: "0.9.6"),
        // ShapeScript interpreter 1.11.6 (MIT), pinned to the reviewed master
        // revision. Evaluated headlessly for generated mesh geometry; imports
        // are refused by the delegate and evaluation is deadline/geometry
        // bounded (see Kernel/ShapeScriptKit.swift).
        .package(url: "https://github.com/nicklockwood/ShapeScript.git",
                 revision: "cda3024b2f17ac06aef23aae7ddcf39c217c6237")
    ],
    targets: [
        // OCCT 7.8.1 static slices, built by upstream scripts/build_occt_ios.sh.
        // LGPL-2.1 + Open CASCADE exception; relink route recorded in
        // ThirdParty/FloeCADKit/OCCT_RELINK.md.
        .binaryTarget(name: "OCCT", path: "Vendor/OCCT.xcframework"),

        // Byte-exact qualified xatlas archives; this target packages, not rebuilds, the algorithm.
        .binaryTarget(name: "XAtlasCore", path: "Vendor/XAtlasCore.xcframework"),
        .target(name: "XAtlasShim", dependencies: ["XAtlasCore"], path: "Sources/XAtlasShim",
                publicHeadersPath: "include", cxxSettings: [.headerSearchPath("Private")]),

        // Manifold 3.5.4, Apache-2.0. Fixed serial core; provenance and
        // byte hashes are recorded beside the three native archive slices.
        .binaryTarget(name: "ManifoldCore", path: "Vendor/ManifoldCore.xcframework"),
        .target(name: "ManifoldShim", dependencies: ["ManifoldCore"],
                path: "Sources/ManifoldShim", publicHeadersPath: "include",
                cxxSettings: [.headerSearchPath("../../Vendor/ManifoldCore.xcframework/ios-arm64/Headers")]),

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
                "XAtlasShim",
                "ManifoldShim",
                .product(name: "Euclid", package: "Euclid"),
                .product(name: "ShapeScript", package: "ShapeScript")
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
                .copy("Shaders"),
                .copy("Building/Support")
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
