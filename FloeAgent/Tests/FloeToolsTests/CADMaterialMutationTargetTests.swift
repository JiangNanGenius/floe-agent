import Foundation
import Testing
@testable import FloeTools

@Suite("CAD material write targets")
struct CADMaterialMutationTargetTests {
    private func arguments(_ action: String, _ operation: String, global: Bool = false) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: ["action": operation, "global": global])
        return ["action": action, "path": "part.floecad", "payload": String(decoding: data, as: UTF8.self)]
    }

    @Test("Editing parameters and materials pins the shared document")
    func documentWrites() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CADTargetTests", isDirectory: true)
        let expected = root.appendingPathComponent("part.floecad").resolvingSymlinksInPath().path
        for (action, operation) in [("material", "apply"), ("material", "update"), ("material", "applyFaces"), ("material", "mapping"), ("material", "libraryImport"), ("parameters", "update"), ("parameters", "updateSketchEntity"), ("parameters", "undo"), ("parameters", "redo")] {
            let targets = try #require(TypedMutationContract.resolveMutableTargets(for: "cad.document", arguments: try arguments(action, operation), workspaceRootURL: root, serviceStorePaths: [:]))
            #expect(targets == [.init(path: expected, role: .sourceWrite)])
        }
        #expect(TypedMutationContract.specs(for: "cad.document", arguments: try arguments("material", "list")).isEmpty)
        #expect(TypedMutationContract.specs(for: "cad.document", arguments: try arguments("parameters", "list")).isEmpty)
    }

    @Test("A personal-library export needs the trusted shared store as well as document identity")
    func personalLibraryWrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CADTargetTests", isDirectory: true)
        let shared = FileManager.default.temporaryDirectory.appendingPathComponent("CADPersonalLibrary", isDirectory: true)
        var args = try arguments("material", "libraryExport", global: true)
        args["storeKey"] = "attacker-selected-store"
        args["output"] = "/unrelated/library.json"
        #expect(TypedMutationContract.resolveMutableTargets(for: "cad.document", arguments: args, workspaceRootURL: root, serviceStorePaths: [:]) == nil)
        let targets = try #require(TypedMutationContract.resolveMutableTargets(for: "cad.document", arguments: args, workspaceRootURL: root, serviceStorePaths: [TypedMutationContract.cadMaterialLibraryStoreKey: shared.path]))
        #expect(targets.count == 2)
        #expect(targets.contains(.init(path: root.appendingPathComponent("part.floecad").resolvingSymlinksInPath().path, role: .pinned)))
        #expect(targets.contains(.init(path: shared.appendingPathComponent("library.json").resolvingSymlinksInPath().path, role: .sourceWrite)))
    }

    @Test("Canvas CAD writes use only the exact native launch binding")
    func nativeCanvasWriteIdentity() throws {
        let key = "canvas-cad:8A8D0AD7-2089-4CFD-8E74-AF302A74410A/part.floecad"
        let owned = FileManager.default.temporaryDirectory.appendingPathComponent("CanvasCADTargets/part.floecad")
        let map = [TypedMutationContract.cadCanvasBindingPrefix + key: owned.path]
        var args = try arguments("material", "apply")
        args["path"] = key
        #expect(TypedMutationContract.resolveMutableTargets(for: "cad.document", arguments: args, workspaceRootURL: nil, serviceStorePaths: [:]) == nil)
        let resolved = try #require(TypedMutationContract.resolveMutableTargets(for: "cad.document", arguments: args, workspaceRootURL: nil, serviceStorePaths: map))
        #expect(resolved == [.init(path: owned.resolvingSymlinksInPath().path, role: .sourceWrite)])
        args["path"] = key.replacingOccurrences(of: "part.floecad", with: "other.floecad")
        #expect(TypedMutationContract.resolveMutableTargets(for: "cad.document", arguments: args, workspaceRootURL: nil, serviceStorePaths: map) == nil)
        // Model-provided paths or a generic root never create a binding.
        args["canonicalPath"] = owned.path
        #expect(TypedMutationContract.resolveMutableTargets(for: "cad.document", arguments: args, workspaceRootURL: owned.deletingLastPathComponent(), serviceStorePaths: map) == nil)
    }

    @Test("Canvas CAD export uses the bound package directory, not another task root")
    func nativeCanvasExportIdentity() throws {
        let key = "canvas-cad:8A8D0AD7-2089-4CFD-8E74-AF302A74410A/part.floecad"
        let owned = FileManager.default.temporaryDirectory.appendingPathComponent("CanvasCADTargets/part.floecad")
        let unrelated = FileManager.default.temporaryDirectory.appendingPathComponent("DifferentTask")
        let args: [String: Any] = ["action": "export", "path": key, "output": "model.glb"]
        let resolved = try #require(TypedMutationContract.resolveMutableTargets(for: "cad.document", arguments: args, workspaceRootURL: unrelated, serviceStorePaths: [TypedMutationContract.cadCanvasBindingPrefix + key: owned.path]))
        #expect(resolved == [.init(path: owned.deletingLastPathComponent().appendingPathComponent("model.glb").resolvingSymlinksInPath().path, role: .outputWrite)])
    }
}
