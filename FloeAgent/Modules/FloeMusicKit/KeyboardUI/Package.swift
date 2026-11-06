// swift-tools-version: 6.2
import PackageDescription

// FloeMusicKeyboard — reusable electronic-keyboard performance panel (UI only).
// The package renders keys and translates touches into owner-tagged performance
// events delivered to a host-injected sink. Audio engine, audio session and
// storage stay host-owned; this package never creates a second engine.
//
// Upstream key rendering is AudioKit/Keyboard, pinned by exact commit. Tonic is
// pinned to the same revision the upstream demo resolved for this Keyboard
// commit, so the transitive `from: "2.0.0"` requirement has no float.
let package = Package(
    name: "FloeMusicKeyboard",
    defaultLocalization: "en",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "FloeMusicKeyboard", targets: ["FloeMusicKeyboard"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/AudioKit/Keyboard",
            revision: "3b1a7bfd6f2e49f23ee9fb317a8fde2c3152f371"
        ),
        .package(
            url: "https://github.com/AudioKit/Tonic",
            revision: "8f103c6765af93bc1d2c3e18eb35f02718b0613d"
        )
    ],
    targets: [
        .target(
            name: "FloeMusicKeyboard",
            dependencies: [
                .product(name: "Keyboard", package: "Keyboard"),
                .product(name: "Tonic", package: "Tonic")
            ],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "FloeMusicKeyboardTests",
            dependencies: ["FloeMusicKeyboard"]
        )
    ],
    swiftLanguageModes: [.v6]
)
