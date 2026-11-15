// swift-tools-version: 6.2
// SPDX-License-Identifier: MPL-2.0
//
// FloeLinuxVideo: public VideoToolbox/CoreMedia/CoreVideo host backend for the
// interpreted ARM64 Linux guest's virtio-media device, plus an additive typed
// native-codec broker for formats without a standard stateful V4L2 mapping.
//
// The frozen host C ABI (ABI 1) lives in FloeLinuxVideoNative/include and is
// unchanged from the reviewed source. FloeLinuxVideoBroker is a separate
// public header/target; it does not extend or reinterpret ABI 1.
import PackageDescription

let package = Package(
    name: "FloeLinuxVideo",
    platforms: [
        .iOS(.v26),
        .macOS(.v15)
    ],
    products: [
        .library(name: "FloeLinuxVideoNative", targets: ["FloeLinuxVideoNative"]),
        .library(name: "FloeLinuxVideoHost", targets: ["FloeLinuxVideoHost"]),
        .library(name: "FloeLinuxVideoBroker", targets: ["FloeLinuxVideoBroker"])
    ],
    targets: [
        .target(
            name: "FloeLinuxVideoNative",
            path: "Sources/FloeLinuxVideoNative",
            publicHeadersPath: "include"
        ),
        .target(
            name: "FloeLinuxVideoHost",
            dependencies: ["FloeLinuxVideoNative"],
            path: "Sources/FloeLinuxVideoHost",
            publicHeadersPath: "Include",
            cSettings: [
                .headerSearchPath("."),
                .headerSearchPath("Include")
            ],
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ImageIO"),
                .linkedFramework("VideoToolbox")
            ]
        ),
        .target(
            name: "FloeLinuxVideoBroker",
            dependencies: ["FloeLinuxVideoNative", "FloeLinuxVideoHost"],
            path: "Sources/FloeLinuxVideoBroker",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
                .unsafeFlags(["-std=c11"])
            ]
        )
    ]
)
