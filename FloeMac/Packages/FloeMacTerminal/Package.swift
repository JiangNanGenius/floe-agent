// swift-tools-version: 6.2
import PackageDescription

// FloeMacTerminal — the built-in interactive Mac terminal tool.
//
// Reuses the same pinned SwiftTerm dependency as FloeAgent
// (FloeAgent/Package.swift pins exact 1.10.0). No custom terminal
// emulator: rendering, input and PTY resize all come from SwiftTerm's
// macOS LocalProcessTerminalView.
//
// Scope: manual user-triggered local PTY sessions only. Nothing in this
// package exposes the PTY to model-authored code; there is no public
// send/exec API, only the SwiftUI view and its lifecycle owner.
let package = Package(
    name: "FloeMacTerminal",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FloeMacTerminal", targets: ["FloeMacTerminal"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.10.0"),
    ],
    targets: [
        .target(
            name: "FloeMacTerminal",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
        .testTarget(
            name: "FloeMacTerminalTests",
            dependencies: ["FloeMacTerminal"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
