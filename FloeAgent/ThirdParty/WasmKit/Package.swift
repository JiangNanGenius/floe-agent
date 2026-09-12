// swift-tools-version:6.0
// WasmKit 0.2.2, revision 5c389084423c08136040ab8a41f73d4e76fb7b21.
// Runtime-only vendoring; see FLOE_PATCHES.md.
import PackageDescription
let package = Package(name: "WasmKit", platforms: [.macOS(.v15), .iOS(.v18)], products: [
    .library(name: "WasmKit", targets: ["WasmKit"]),
    .library(name: "WasmKitWASI", targets: ["WasmKitWASI"]),
    .library(name: "WAT", targets: ["WAT"])
], dependencies: [.package(url: "https://github.com/apple/swift-system", from: "1.5.0")], targets: [
    .target(name: "WasmKit", dependencies: ["_CWasmKit", "WasmParser", "WasmTypes", "SystemExtras", .product(name: "SystemPackage", package: "swift-system")], exclude: ["CMakeLists.txt"]),
    .target(name: "_CWasmKit"),
    .target(name: "WasmParser", dependencies: ["WasmTypes", .product(name: "SystemPackage", package: "swift-system")], exclude: ["CMakeLists.txt"]),
    .target(name: "WasmTypes", exclude: ["CMakeLists.txt"]),
    .target(name: "WasmKitWASI", dependencies: ["WasmKit", "WASI"], exclude: ["CMakeLists.txt"]),
    .target(name: "WASI", dependencies: ["WasmTypes", "SystemExtras"], exclude: ["CMakeLists.txt"]),
    .target(name: "SystemExtras", dependencies: [.product(name: "SystemPackage", package: "swift-system"), .target(name: "CSystemExtras", condition: .when(platforms: [.wasi]))], exclude: ["CMakeLists.txt"], swiftSettings: [.define("SYSTEM_PACKAGE_DARWIN", .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS]))]),
    .target(name: "CSystemExtras"),
    .target(name: "WAT", dependencies: ["WasmParser"], exclude: ["CMakeLists.txt"])
])
