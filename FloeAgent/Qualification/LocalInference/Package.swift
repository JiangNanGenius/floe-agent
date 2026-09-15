// swift-tools-version:6.2
import PackageDescription
let package = Package(name: "FloeLocalInferenceQualification", platforms: [.macOS(.v26)],
    dependencies: [.package(path: "../..")], targets: [
        .executableTarget(name: "FloeLocalInferenceQualification", dependencies: [
            .product(name: "FloeLocalModels", package: "FloeAgent"),
            .product(name: "FloeLocalModelCatalog", package: "FloeAgent")
        ], path: "Sources")
    ])
