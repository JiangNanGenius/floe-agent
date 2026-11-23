// swift-tools-version: 6.2
// SPDX-License-Identifier: MPL-2.0
import PackageDescription

// Native visual-novel runtime host. It owns the dlopen lifecycle of the
// bundled ShioriKrkr Kirikiri engine (embedded, signed, never linked), the
// per-game sandbox staging and the on-device run loop. The App integrates it
// through the game workspace; this package has no UIKit/Metal requirement for
// its core and exposes the Metal surface only on iOS-family platforms.
let package = Package(
    name: "FloeVisualNovelRuntime",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "FloeVisualNovelRuntime", targets: ["FloeVisualNovelRuntime"])
    ],
    targets: [
        .target(name: "FloeVisualNovelRuntime"),
        .testTarget(name: "FloeVisualNovelRuntimeTests", dependencies: ["FloeVisualNovelRuntime"])
    ],
    swiftLanguageModes: [.v6]
)
