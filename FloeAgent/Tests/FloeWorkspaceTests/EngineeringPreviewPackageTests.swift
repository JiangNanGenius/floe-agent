// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeWorkspace

@Suite("Read-only engineering preview packages")
struct EngineeringPreviewPackageTests {
    @Test func explicitReferencesStayGuardedAndNeverFetchRemoteResources() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = #"{"buffers":[{"uri":"part.bin"}],"images":[{"uri":"https://example.com/texture.png"},{"uri":"../secret.png"},{"uri":".env.png"},{"uri":"private.png"}]}"#
        try Data(model.utf8).write(to: root.appendingPathComponent("part.gltf"))
        try Data([0, 1, 2]).write(to: root.appendingPathComponent("part.bin"))
        try Data("secret".utf8).write(to: root.appendingPathComponent(".env.png"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("private.png"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        let package = try EngineeringPreviewPackage.load(path: "part.gltf", service: WorkspaceFileService(guard: WorkspacePathGuard(rootURL: root)))
        #expect(package.files.map(\.name) == ["part.gltf", "part.bin"])
        #expect(package.missingReferences.count == 4)
        #expect(package.kind == .mesh)
        #expect(try Data(contentsOf: root.appendingPathComponent("part.gltf")) == Data(model.utf8))
    }
    @Test func nestedMaterialReferencesAndMissingFilesAreVisible() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("materials"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("mtllib materials/model.mtl\nv 0 0 0\n".utf8).write(to: root.appendingPathComponent("model.obj"))
        try Data("newmtl red\nmap_Kd texture.png\nmap_Ks missing.png\n".utf8).write(to: root.appendingPathComponent("materials/model.mtl"))
        try Data([1]).write(to: root.appendingPathComponent("materials/texture.png"))
        let result = try EngineeringPreviewPackage.load(path: "model.obj", service: WorkspaceFileService(guard: WorkspacePathGuard(rootURL: root)))
        #expect(result.files.map(\.name) == ["model.obj", "materials/model.mtl", "materials/texture.png"])
        #expect(result.missingReferences == ["materials/missing.png"])
    }
    @Test func limitsAndUnsupportedDecodersAreExplicit() throws {
        #expect(EngineeringPreviewKind.identify("BOARD.DXF") == .dxf)
        #expect(EngineeringPreviewKind.identify("part.step") == .unsupported)
        #expect(EngineeringPreviewKind.identify("drawing.dwg") == .dwg)
        #expect(EngineeringPreviewKind.identify("report.pdf") == nil)
        #expect(throws: Error.self) { try EngineeringPreviewPackage.single(name: "part.stl", bytes: Data(count: EngineeringPreviewPackage.maximumBytes + 1)) }
        let remote = try EngineeringPreviewPackage.single(name: "part.obj", bytes: Data("mtllib missing.mtl\n".utf8))
        #expect(remote.missingReferences == ["missing.mtl"])
    }
}
