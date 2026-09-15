// swift-tools-version:6.2
import PackageDescription
let package = Package(name: "FloePlatformQualification", platforms: [.macOS(.v26)], dependencies: [.package(path: ".."), .package(path: "../ThirdParty/WasmKit")], targets: [
    .testTarget(name: "IDEWorkspaceTests", dependencies: [.product(name: "FloeWorkspace", package: "FloeAgent")], path: "Tests/IDEWorkspaceTests"),
    .testTarget(name: "WasmCommandTests", dependencies: [.product(name: "FloeExecution", package: "FloeAgent"), .product(name: "WAT", package: "WasmKit")], path: "Tests/WasmCommandTests"),
    .testTarget(name: "ConversationSearchQualificationTests", dependencies: [.product(name: "FloeAgentRuntime", package: "FloeAgent"), .product(name: "FloePersistence", package: "FloeAgent")], path: "Tests/SearchTests"),
    .testTarget(name: "SkillHubTests", dependencies: [.product(name: "FloeSkills", package: "FloeAgent")], path: "Tests/SkillHubTests"),
    .testTarget(name: "MediaTests", dependencies: [.product(name: "FloeMedia", package: "FloeAgent"), .product(name: "FloeTools", package: "FloeAgent")], path: "Tests/MediaTests"),
    .testTarget(name: "PersistenceTests", dependencies: [.product(name: "FloePersistence", package: "FloeAgent")], path: "Tests/PersistenceTests"),
    .testTarget(name: "EnvironmentTests", dependencies: [.product(name: "FloeEnvironments", package: "FloeAgent"), .product(name: "FloeTools", package: "FloeAgent")], path: "Tests/EnvironmentTests"),
    .testTarget(name: "PackageTests", dependencies: [.product(name: "FloePackages", package: "FloeAgent"), .product(name: "FloeEnvironments", package: "FloeAgent")], path: "Tests/PackageTests", resources: [.copy("Fixtures")])
])
