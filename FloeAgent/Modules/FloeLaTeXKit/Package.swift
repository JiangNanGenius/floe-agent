// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FloeLaTeXKit",
    platforms: [.iOS(.v26), .macOS(.v15)],
    // One dynamic product shares services and resources when the App, its
    // tools and a document editor all depend on this package.
    products: [.library(name:"FloeLaTeXKit",type:.dynamic,targets:["FloeLaTeXCore","FloeLaTeXParsing","FloeLaTeXReferences","FloeLaTeXResources","FloeLaTeXEngine","FloeLaTeXUI","FloeLaTeXWorkerResources"])],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")
    ],
    targets: [
        .target(name:"FloeLaTeXWorkerResources",path:"Backends",sources:["LaTeXWorkerResources.swift"],resources:[.copy("latex_worker.py"),.copy("worker-manifest.json")]),
        .target(name:"CLaTeXSupport",linkerSettings:[.linkedLibrary("z")]),
        .target(name: "FloeLaTeXCore", dependencies: ["ZIPFoundation"]),
        .target(name: "FloeLaTeXParsing", dependencies: ["FloeLaTeXCore"]),
        .target(name: "FloeLaTeXReferences", dependencies: ["FloeLaTeXCore"]),
        .target(name: "FloeLaTeXResources", dependencies: ["FloeLaTeXCore", "ZIPFoundation"]),
        .target(name:"FloeLaTeXEngine",dependencies:["FloeLaTeXCore","FloeLaTeXParsing","FloeLaTeXReferences","FloeLaTeXResources","FloeLaTeXWorkerResources","CLaTeXSupport"]),
        .target(name:"FloeLaTeXUI",dependencies:["FloeLaTeXCore","FloeLaTeXEngine","FloeLaTeXParsing","FloeLaTeXReferences"]),
        .testTarget(name: "FloeLaTeXCoreTests", dependencies: ["FloeLaTeXCore", "FloeLaTeXParsing", "FloeLaTeXReferences", "FloeLaTeXResources","FloeLaTeXEngine"])
    ],
    swiftLanguageModes: [.v6]
)
