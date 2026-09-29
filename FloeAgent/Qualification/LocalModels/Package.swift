// swift-tools-version:6.2
import PackageDescription

// Deterministic, weight-free qualification for the Build 235 local-model
// fabricated-provider-name repair. It drives the production
// LocalProviderAdapter static parse/prompt boundaries with the REAL web.search
// schema and a production-shaped (synthetic) search result payload. No MLX
// weights, no network and no real inference: this is a contract/no-fabrication
// gate, not iPad or real-weight acceptance.
let package = Package(
    name: "FloeLocalModelsQualification",
    platforms: [.macOS("15.4")],
    dependencies: [.package(path: "../..")],
    targets: [
        .executableTarget(
            name: "FloeLocalModelsQualification",
            dependencies: [
                .product(name: "FloeCore", package: "FloeAgent"),
                .product(name: "FloeModels", package: "FloeAgent"),
                .product(name: "FloeProviders", package: "FloeAgent"),
                .product(name: "FloeExecution", package: "FloeAgent"),
                .product(name: "FloeAgentRuntime", package: "FloeAgent"),
                .product(name: "FloeLocalModels", package: "FloeAgent"),
                .product(name: "FloeLocalModelCatalog", package: "FloeAgent")
            ],
            path: "Sources"
        )
    ]
)
