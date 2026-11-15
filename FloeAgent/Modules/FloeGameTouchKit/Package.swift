// swift-tools-version: 6.2
// SPDX-License-Identifier: MPL-2.0
import PackageDescription
let package = Package(name: "FloeGameTouchKit", platforms: [.iOS(.v26), .macOS(.v15)],
    products: [.library(name: "FloeGameTouch", targets: ["FloeGameTouch"]),
               .library(name: "FloeGameTouchUI", targets: ["FloeGameTouchUI"])],
    dependencies: [.package(path: "../FloeGameKit")],
    targets: [
        .target(name: "FloeJoystickVendor", path: "ThirdParty/JoyStickView", resources: [.copy("LICENSE.txt")], swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "FloeGameTouch", dependencies: [.product(name: "FloeGameCore", package: "FloeGameKit"), .product(name: "FloeGameWebKit", package: "FloeGameKit")]),
        .target(name: "FloeGameTouchUI", dependencies: ["FloeGameTouch", .product(name: "FloeGameWebKit", package: "FloeGameKit"), .target(name: "FloeJoystickVendor", condition: .when(platforms: [.iOS]))]),
        .testTarget(name: "FloeGameTouchTests", dependencies: ["FloeGameTouch"])
    ], swiftLanguageModes: [.v6])
