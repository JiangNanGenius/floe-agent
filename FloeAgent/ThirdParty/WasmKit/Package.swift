// swift-tools-version:6.3
// WasmKit 0.3.1; upstream archive digest is recorded in FLOE_PATCHES.md.
// Runtime-only vendoring; see FLOE_PATCHES.md.
import PackageDescription
let package = Package(name: "WasmKit", platforms: [.macOS(.v15), .iOS(.v18)], products: [
    .library(name: "WasmKit", targets: ["WasmKit"]),
    .library(name: "WasmKitWASI", targets: ["WasmKitWASI"]),
    .library(name: "WAT", targets: ["WAT"])
], dependencies: [.package(url: "https://github.com/apple/swift-system", from: "1.5.0")], targets: [
    .target(name: "WasmKit", dependencies: ["_CWasmKit", "WasmParser", "WasmTypes", "SystemExtras", .product(name: "SystemPackage", package: "swift-system")]),
    .target(name: "_CWasmKit"),
    .target(name: "WasmParser", dependencies: ["WasmTypes", "SystemExtras", .product(name: "SystemPackage", package: "swift-system")]),
    .target(name: "WasmTypes"),
    .target(name: "WasmKitWASI", dependencies: ["WasmKit", "WASI"]),
    .target(name: "WASI", dependencies: ["WasmTypes", "SystemExtras"]),
    .target(name: "SystemExtras", dependencies: [.product(name: "SystemPackage", package: "swift-system"), .target(name: "CSystemExtras", condition: .when(platforms: [.wasi]))], swiftSettings: [.define("SYSTEM_PACKAGE_DARWIN", .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS]))]),
    .target(name: "CSystemExtras"),
    .target(name: "WAT", dependencies: ["WasmParser"])
])
