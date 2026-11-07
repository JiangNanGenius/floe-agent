// swift-tools-version: 6.2
// SPDX-License-Identifier: MPL-2.0
import PackageDescription
let package = Package(name: "FloeFontKit", platforms: [.iOS(.v26), .macOS(.v15)],
    products: [.library(name: "FloeFontKit", targets: ["FloeFontKit"])],
    dependencies: [.package(path: "../FloeHeavyEditorSupport"),.package(url:"https://github.com/weichsel/ZIPFoundation.git",exact:"0.9.20")],
    targets: [
        .binaryTarget(name:"FloeFontCompiler",path:"Vendor/FloeFontCompiler.xcframework"),
        .target(name:"FloeFontKit",dependencies:["FloeHeavyEditorSupport","FloeFontCompiler","ZIPFoundation"],resources:[.copy("Resources/Web")]),
        .testTarget(name:"FloeFontKitTests",dependencies:["FloeFontKit","FloeHeavyEditorSupport"],resources:[.copy("Fixtures")])
    ],swiftLanguageModes:[.v6])
