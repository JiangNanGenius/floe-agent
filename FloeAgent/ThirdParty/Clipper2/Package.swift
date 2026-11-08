// swift-tools-version: 6.2
import PackageDescription

// Minimal, source-only packaging of the pinned Clipper2 polygon library.
//
// Only the two translation units needed for boolean clipping and offsetting
// are compiled; examples, CMake files, tests and the C#/Delphi wrappers are
// deliberately absent. `Clipper2C` is a thin C ABI used by the Swift
// qualification adapter. See PIN.txt and THIRD_PARTY_NOTICES.md.
let package = Package(
    name: "Clipper2",
    platforms: [
        .macOS(.v15),
        .iOS(.v26)
    ],
    products: [
        .library(name: "Clipper2C", targets: ["Clipper2C"])
    ],
    targets: [
        .target(
            name: "Clipper2Cpp",
            path: "Sources/Clipper2Cpp",
            sources: [
                "src/clipper.engine.cpp",
                "src/clipper.offset.cpp"
            ],
            publicHeadersPath: "include",
            cxxSettings: [
                .unsafeFlags(["-std=c++17"])
            ]
        ),
        .target(
            name: "Clipper2C",
            dependencies: ["Clipper2Cpp"],
            path: "Sources/Clipper2C",
            publicHeadersPath: "include",
            cxxSettings: [
                .unsafeFlags(["-std=c++17"])
            ]
        )
    ]
)
