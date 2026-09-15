// swift-tools-version:6.2
import PackageDescription
let package = Package(name: "FloeServiceQualification", platforms: [.macOS(.v26)],
    dependencies: [.package(path: "../..")], targets: [
        .testTarget(name: "ServiceTests", dependencies: [
            .product(name: "FloeExecution", package: "FloeAgent"),
            .product(name: "FloePersistence", package: "FloeAgent"),
            .product(name: "FloeCore", package: "FloeAgent"),
            .product(name: "FloeTools", package: "FloeAgent")
        ], path: "Tests")
    ])
