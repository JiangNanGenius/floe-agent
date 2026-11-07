// swift-tools-version: 6.2
import PackageDescription

// Compile the production numerical source directly without the unrelated App,
// Linux, media or model dependency graphs. No replacement implementation.
let package = Package(
    name: "FloeScientificAnalysisQualification",
    platforms: [.iOS(.v26), .macOS(.v15)],
    targets: [
        .target(name: "FloeScientificAnalysisQualification", path: "Sources",
                swiftSettings: [.swiftLanguageMode(.v6),
                                .enableUpcomingFeature("NonisolatedNonsendingByDefault")]),
        .testTarget(name: "ScientificAnalysisTests", dependencies: ["FloeScientificAnalysisQualification"],
                    path: "Tests", swiftSettings: [.define("FLOE_SCIENTIFIC_CORE_ONLY"), .swiftLanguageMode(.v6)])
    ]
)
