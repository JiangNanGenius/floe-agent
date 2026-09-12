// swift-tools-version:6.2
import PackageDescription
let package = Package(name: "FloePlatformQualification", platforms: [.macOS(.v26)], dependencies: [.package(path: "..")], targets: [
    .testTarget(name: "MediaTests", dependencies: [.product(name: "FloeMedia", package: "FloeAgent"), .product(name: "FloeTools", package: "FloeAgent")], path: "Tests/MediaTests"),
    .testTarget(name: "PersistenceTests", dependencies: [.product(name: "FloePersistence", package: "FloeAgent")], path: "Tests/PersistenceTests"),
    .testTarget(name: "EnvironmentTests", dependencies: [.product(name: "FloeEnvironments", package: "FloeAgent"), .product(name: "FloeTools", package: "FloeAgent")], path: "Tests/EnvironmentTests"),
    .testTarget(name: "PackageTests", dependencies: [.product(name: "FloePackages", package: "FloeAgent"), .product(name: "FloeEnvironments", package: "FloeAgent")], path: "Tests/PackageTests", resources: [.copy("Fixtures")])
])
