// swift-tools-version:6.2
import PackageDescription
let package = Package(name: "FloeCapabilityHub", platforms: [.macOS(.v15)], dependencies: [.package(path: "../FloeAgent/ThirdParty/WasmKit")], targets: [
    .executableTarget(name: "CapabilityAssembler", dependencies: [.product(name: "WAT", package: "WasmKit")])
])
