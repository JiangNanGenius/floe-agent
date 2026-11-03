// swift-tools-version: 6.0
import PackageDescription

// Floe Android port of the fixed RoyalVNCKit slice pinned at
// 92d4427c73817d8f849bb289ff190aa4b40c44ea (MIT). See FLOE_PATCHES.md for
// the Android port changes and the omitted Apple-only UI/ObjC sources.
// The product is STATIC because the code is linked into the single
// libFloeAndroidCore.so; no second native library is packaged.
let package = Package(
    name: "RoyalVNCKit",
    products: [
        .library(name: "RoyalVNCKit", targets: ["RoyalVNCKit"])
    ],
    dependencies: [
        // Exact donor pin (CryptoSwift 1.9-era); declares Android support.
        .package(url: "https://github.com/royalapplications/CryptoSwift.git",
                 revision: "a59b4d91ebb22011656c830f874fe7152e183a57")
    ],
    targets: [
        .target(name: "d3des"),
        .target(name: "Z", linkerSettings: [.linkedLibrary("z")]),
        .target(name: "RoyalVNCKit", dependencies: [
            "d3des", "Z",
            .product(name: "CryptoSwift", package: "CryptoSwift")
        ], swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
