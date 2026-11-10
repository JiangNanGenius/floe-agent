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
        // Reviewed production XeTeX/XDV closure; the old GPL-bearing native
        // experiment is a separate package and cannot satisfy this identity.
        .binaryTarget(name:"FloeTeXNativeXDVBinary",path:"Native/Production/Vendor/FloeTeXNativeXDV.xcframework"),
        .target(name:"FloeTeXNativeXDV",dependencies:[.target(name:"FloeTeXNativeXDVBinary",condition:.when(platforms:[.iOS]))],path:"Sources/FloeTeXNativeXDVBridge",publicHeadersPath:"include"),
        .target(name:"FloeLaTeXWorkerResources",path:"Backends",sources:["LaTeXWorkerResources.swift"],resources:[.copy("latex_worker.py"),.copy("worker-manifest.json")]),
        .target(name:"CLaTeXSupport",linkerSettings:[.linkedLibrary("z")]),
        .target(name: "FloeLaTeXCore", dependencies: ["ZIPFoundation"]),
        .target(name: "FloeLaTeXParsing", dependencies: ["FloeLaTeXCore"]),
        .target(name: "FloeLaTeXReferences", dependencies: ["FloeLaTeXCore"]),
        .target(name: "FloeLaTeXResources", dependencies: ["FloeLaTeXCore", "ZIPFoundation"]),
        // These two uncalled rustix wrappers are not public native ABI. Keep
        // their private visibility so dead stripping removes their unused
        // filesystem-statistics imports; no disk-space use is claimed.
        .target(name:"FloeLaTeXEngine",dependencies:["FloeLaTeXCore","FloeLaTeXParsing","FloeLaTeXReferences","FloeLaTeXResources","FloeLaTeXWorkerResources","CLaTeXSupport",.target(name:"FloeTeXNativeXDV",condition:.when(platforms:[.iOS]))],linkerSettings:[.unsafeFlags(["-Xlinker","-dead_strip","-Xlinker","-unexported_symbol","-Xlinker","__RNvNtNtNtC*_6rustix7backend2fs8syscalls7fstatfs","-Xlinker","-unexported_symbol","-Xlinker","__RNvNtNtNtC*_6rustix7backend2fs8syscalls8fstatvfs"],.when(platforms:[.iOS])),.linkedLibrary("c++",.when(platforms:[.iOS])),.linkedLibrary("iconv",.when(platforms:[.iOS])),.linkedLibrary("z",.when(platforms:[.iOS])),.linkedFramework("CoreText",.when(platforms:[.iOS])),.linkedFramework("CoreGraphics",.when(platforms:[.iOS])),.linkedFramework("ImageIO",.when(platforms:[.iOS])),.linkedFramework("Security",.when(platforms:[.iOS])),.linkedFramework("SystemConfiguration",.when(platforms:[.iOS]))]),
        .target(name:"FloeLaTeXUI",dependencies:["FloeLaTeXCore","FloeLaTeXEngine","FloeLaTeXParsing","FloeLaTeXReferences"]),
        .testTarget(name: "FloeLaTeXCoreTests", dependencies: ["FloeLaTeXCore", "FloeLaTeXParsing", "FloeLaTeXReferences", "FloeLaTeXResources","FloeLaTeXEngine"])
    ],
    swiftLanguageModes: [.v6]
)
