// swift-tools-version:6.2
import PackageDescription
let package = Package(name: "FloeNotesQualification", platforms: [.macOS(.v26)],
    dependencies: [.package(path: "../..")], targets: [
        .testTarget(name: "NotesTests", dependencies: [.product(name: "FloeNotes", package: "FloeAgent")], path: "Tests")
    ])
