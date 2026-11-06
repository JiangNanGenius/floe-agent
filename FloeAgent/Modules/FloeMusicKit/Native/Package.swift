// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FloeMusicNative",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [.library(name: "FloeMusicNative", targets: ["FloeMusicNative"])],
    dependencies: [
        .package(path: ".."),
        .package(url: "https://github.com/AudioKit/AudioKit", revision: "97a35fe04cd8e3d13b8744e1216b8673f825bef6"),
        .package(url: "https://github.com/AudioKit/AudioKitEX", revision: "c33dac0f581e4ef5bf179e550394f3152aafabfd"),
        .package(url: "https://github.com/AudioKit/SoundpipeAudioKit", revision: "d8afd31b3710a0efd5f9ecb11f1169ca493795e9"),
        .package(url: "https://github.com/AudioKit/Tonic", revision: "8f103c6765af93bc1d2c3e18eb35f02718b0613d"),
        .package(url: "https://github.com/AudioKit/KissFFT", exact: "1.0.0")
    ],
    targets: [
        .target(name: "CLame", path: "Vendor/LAME",
                exclude: ["COPYING", "LICENSE", "UPSTREAM.json"],
                sources: ["libmp3lame"], publicHeadersPath: "include",
                cSettings: [.define("HAVE_CONFIG_H"), .define("LAME_LIBRARY_BUILD"), .headerSearchPath("."), .headerSearchPath("libmp3lame")]),
        .target(name: "FloeMusicNative", dependencies: [
            .product(name: "FloeMusicCore", package: "FloeMusicKit"),
            .product(name: "AudioKit", package: "AudioKit"),
            .product(name: "AudioKitEX", package: "AudioKitEX"),
            .product(name: "SoundpipeAudioKit", package: "SoundpipeAudioKit"), "CLame"
        ]),
        .testTarget(name: "FloeMusicNativeTests", dependencies: ["FloeMusicNative", .product(name: "FloeMusicCore", package: "FloeMusicKit")])
    ],
    swiftLanguageModes: [.v6]
)
