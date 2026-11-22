// swift-tools-version: 6.2
// SPDX-License-Identifier: MPL-2.0
import PackageDescription

let package = Package(
    name: "FloeDeviceLink",
    platforms: [.macOS(.v15), .iOS(.v26)],
    products: [
        .library(name: "FloeDeviceLink", targets: ["FloeDeviceLink"]),
        .library(name: "FloeDeviceSync", targets: ["FloeDeviceSync"])
    ],
    dependencies: [
        .package(url: "https://github.com/n0-computer/iroh-ffi.git", exact: "1.2.0"),
        .package(path: "../FloeDesktopSync")
    ],
    targets: [
        .target(
            name: "FloeDeviceLink",
            dependencies: [.product(name: "IrohLib", package: "iroh-ffi")]
        ),
        .target(name: "FloeDeviceSync", dependencies: [
            "FloeDeviceLink",
            .product(name: "FloeDesktopSync", package: "FloeDesktopSync")
        ]),
        .testTarget(name: "FloeDeviceLinkTests", dependencies: ["FloeDeviceLink"]),
        .testTarget(name: "FloeDeviceSyncTests", dependencies: ["FloeDeviceSync", "FloeDeviceLink"])
    ],
    swiftLanguageModes: [.v6]
)
