// FloeWorkspaceTests — canvas backup package (staged, verified restore).
import Foundation
import ZIPFoundation
import CryptoKit
import Testing
@testable import FloeWorkspace
import FloeCore

@Suite("Canvas backup package")
struct CanvasBackupPackageTests {
    private func makeNode(metadata: [String: String] = [:],
                          assetPath: String? = nil) -> CanvasNode {
        var node = CanvasNode.placeholder(kind: .image,
                                          position: CanvasPoint(x: 10, y: 20), zIndex: 1)
        node.metadata = metadata
        if let assetPath {
            node.asset = CanvasAssetReference(localRelativePath: assetPath, mimeType: "image/png")
        }
        return node
    }

    private func makeProject(nodes: [CanvasNode]) -> CanvasProject {
        let document = CanvasDocument(name: "Doc", nodes: nodes)
        return CanvasProject(id: UUID(), name: "备份画布",
                             documents: [document], selectedDocumentID: document.id)
    }

    private func tempRoot(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-tests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func digest(_ data: Data) -> String {
        SHA256Placeholder.hash(data)
    }

    @Test("export carries canvas, child project WITH its assets, and materials")
    func exportRoundTripOnEmptyStore() throws {
        let childID = UUID()
        var boundNode = makeNode()
        boundNode.childProjectBinding = CanvasChildProjectBinding(
            projectID: childID, appliedRevision: 3, draftRevision: 4,
            renderedAssetID: UUID(), sourceNodeID: UUID())
        let materialNode = makeNode(assetPath: "Materials/abc-canvas-edit.png")
        let project = makeProject(nodes: [boundNode, materialNode])

        // A realistic child media project: id + one referenced asset.
        let childJSON = try JSONSerialization.data(withJSONObject: [
            "id": childID.uuidString, "revision": 4, "name": "child",
            "assets": [["relativePath": "clips/source.mp4", "originalName": "source.mp4"]]
        ] as [String: Any])
        let assetBytes = Data("video-bytes".utf8)
        let materialBytes = Data("png-bytes".utf8)
        let zip = try CanvasBackupPackage.make(
            project: project,
            childProjectData: { $0 == childID ? childJSON : nil },
            materialData: { $0 == "abc-canvas-edit.png" ? materialBytes : nil },
            assetData: { $0 == "clips/source.mp4" ? assetBytes : nil })

        let root = try tempRoot("empty")
        defer { try? FileManager.default.removeItem(at: root) }
        let restored = try CanvasBackupPackage.restore(data: zip, floeRoot: root)

        // Fresh canvas identity; chat bindings cut.
        #expect(restored.project.id != project.id)
        #expect(restored.project.workspaceID == nil)
        #expect(restored.project.agentConversationID == nil)
        #expect(restored.manifest.childProjects.count == 1)
        #expect(restored.manifest.materials.count == 1)
        #expect(restored.manifest.assets.count == 1)
        #expect(restored.manifest.missingChildProjects.isEmpty)
        #expect(restored.manifest.missingAssets.isEmpty)

        // Child project written under a NEW id with remapped inner id and the
        // asset path intact (no collision on the empty store).
        let projectsRoot = root.appendingPathComponent("MediaProjects")
        let children = try FileManager.default.contentsOfDirectory(atPath: projectsRoot.path)
        #expect(children.count == 1)
        let childData = try Data(contentsOf: projectsRoot.appendingPathComponent(children[0]))
        let childObject = try #require(JSONSerialization.jsonObject(with: childData) as? [String: Any])
        let newChildID = try #require(childObject["id"] as? String)
        #expect(newChildID != childID.uuidString.lowercased() || UUID(uuidString: newChildID) != childID)
        let childAssets = childObject["assets"] as? [[String: Any]]
        #expect(childAssets?.first?["relativePath"] as? String == "clips/source.mp4")

        // Asset bytes actually landed inside WorkbenchRoot.
        let restoredAsset = try Data(contentsOf: root.appendingPathComponent("WorkbenchRoot/clips/source.mp4"))
        #expect(restoredAsset == assetBytes)

        // Node binding remapped to the new child id.
        let restoredNode = restored.project.documents[0].nodes[0]
        #expect(restoredNode.childProjectBinding?.projectID != childID)
        #expect(UUID(uuidString: newChildID) == restoredNode.childProjectBinding?.projectID)

        // Material present under Materials/; node reference intact.
        let material = try Data(contentsOf: root.appendingPathComponent("Materials/abc-canvas-edit.png"))
        #expect(material == materialBytes)
        #expect(restored.project.documents[0].nodes[1].asset?.localRelativePath == "Materials/abc-canvas-edit.png")
    }

    @Test("same-name different-content material is remapped, not overwritten")
    func conflictingDestinationRemapped() throws {
        let node = makeNode(assetPath: "Materials/abc-canvas-edit.png")
        let project = makeProject(nodes: [node])
        let newBytes = Data("new-png".utf8)
        let zip = try CanvasBackupPackage.make(project: project,
                                               childProjectData: { _ in nil },
                                               materialData: { _ in newBytes },
                                               assetData: { _ in nil })
        let root = try tempRoot("conflict")
        defer { try? FileManager.default.removeItem(at: root) }
        // Pre-existing same-name file with DIFFERENT content.
        let materials = root.appendingPathComponent("Materials", isDirectory: true)
        try FileManager.default.createDirectory(at: materials, withIntermediateDirectories: true)
        try Data("old-png".utf8).write(to: materials.appendingPathComponent("abc-canvas-edit.png"))

        let restored = try CanvasBackupPackage.restore(data: zip, floeRoot: root)
        // Old file untouched.
        #expect(try Data(contentsOf: materials.appendingPathComponent("abc-canvas-edit.png")) == Data("old-png".utf8))
        // New bytes under a content-addressed name; node reference remapped.
        let remapped = try #require(restored.remappedMaterials["abc-canvas-edit.png"])
        #expect(remapped != "abc-canvas-edit.png")
        #expect(try Data(contentsOf: materials.appendingPathComponent(remapped)) == newBytes)
        #expect(restored.project.documents[0].nodes[0].asset?.localRelativePath == "Materials/\(remapped)")
    }

    @Test("same-name identical content reuses the existing file")
    func identicalContentReused() throws {
        let node = makeNode(assetPath: "Materials/shared.png")
        let project = makeProject(nodes: [node])
        let bytes = Data("same-bytes".utf8)
        let zip = try CanvasBackupPackage.make(project: project,
                                               childProjectData: { _ in nil },
                                               materialData: { _ in bytes },
                                               assetData: { _ in nil })
        let root = try tempRoot("identical")
        defer { try? FileManager.default.removeItem(at: root) }
        let materials = root.appendingPathComponent("Materials", isDirectory: true)
        try FileManager.default.createDirectory(at: materials, withIntermediateDirectories: true)
        try bytes.write(to: materials.appendingPathComponent("shared.png"))
        let restored = try CanvasBackupPackage.restore(data: zip, floeRoot: root)
        #expect(restored.remappedMaterials["shared.png"] == "shared.png")
        #expect(restored.project.documents[0].nodes[0].asset?.localRelativePath == "Materials/shared.png")
    }

    @Test("hostile manifest material paths are refused with zero changes")
    func hostilePathsRefused() throws {
        for hostile in ["../evil.png", "/abs/evil.png", "a/b.png", "..", ".hidden.png"] {
            let node = makeNode(assetPath: "Materials/ok.png")
            let project = makeProject(nodes: [node])
            let zip = try CanvasBackupPackage.make(project: project,
                                                   childProjectData: { _ in nil },
                                                   materialData: { _ in Data("x".utf8) },
                                                   assetData: { _ in nil })
            // Rebuild a package whose manifest carries a hostile material.
            let root = try tempRoot("hostile")
            defer { try? FileManager.default.removeItem(at: root) }
            var manifest = CanvasBackupPackage.Manifest(
                formatVersion: 1, canvasID: UUID(), canvasName: "x",
                canvasSchemaVersion: CanvasProject.currentSchemaVersion,
                exportedAt: Date(), canvasByteCount: 0, canvasSHA256: "",
                childProjects: [],
                materials: [CanvasBackupPackage.Material(
                    fileName: hostile, byteCount: 1,
                    sha256: digest(Data("x".utf8)))],
                assets: [], missingChildProjects: [], missingAssets: [])
            // canvas hash must match; recompute from the original canvas entry.
            let tempIn = FileManager.default.temporaryDirectory.appendingPathComponent("in-\(UUID().uuidString).zip")
            try zip.write(to: tempIn)
            defer { try? FileManager.default.removeItem(at: tempIn) }
            let readArchive = try Archive(url: tempIn, accessMode: .read)
            var canvasData = Data()
            if let entry = readArchive[CanvasBackupPackage.canvasEntry] {
                let canvasFile = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-\(UUID().uuidString).bin")
                _ = try readArchive.extract(entry, to: canvasFile, skipCRC32: false, progress: nil)
                canvasData = try Data(contentsOf: canvasFile)
            }
            manifest.canvasByteCount = Int64(canvasData.count)
            manifest.canvasSHA256 = digest(canvasData)
            let manifestData = try JSONEncoder().encode(manifest)
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("out-\(UUID().uuidString).zip")
            defer { try? FileManager.default.removeItem(at: out) }
            let archive = try Archive(url: out, accessMode: .create)
            var entries: [(String, Data)] = [
                (CanvasBackupPackage.manifestEntry, manifestData),
                (CanvasBackupPackage.canvasEntry, canvasData),
                ("materials/\(hostile)", Data("x".utf8))
            ]
            for (path, data) in entries {
                try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count),
                                     compressionMethod: .deflate) { position, size in
                    data.subdata(in: Int(position)..<(Int(position) + size))
                }
            }
            entries.removeAll()
            do {
                _ = try CanvasBackupPackage.restore(data: Data(contentsOf: out), floeRoot: root)
                Issue.record("hostile path '\(hostile)' was not refused")
            } catch {
                // Zero changes: nothing may exist outside the root's dirs.
                let listing = try FileManager.default.contentsOfDirectory(atPath: root.path)
                    .filter { $0 != "Materials" && $0 != "MediaProjects" && $0 != "WorkbenchRoot" }
                #expect(listing.isEmpty)
                #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("evil.png").path) == false)
            }
        }
    }

    @Test("symlinked Materials directory cannot redirect the write outside")
    func symlinkEscapeRefused() throws {
        let node = makeNode(assetPath: "Materials/ok.png")
        let project = makeProject(nodes: [node])
        let bytes = Data("png".utf8)
        let zip = try CanvasBackupPackage.make(project: project,
                                               childProjectData: { _ in nil },
                                               materialData: { _ in bytes },
                                               assetData: { _ in nil })
        let root = try tempRoot("symlink")
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-outside-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Materials", isDirectory: true),
            withDestinationURL: outside)
        do {
            _ = try CanvasBackupPackage.restore(data: zip, floeRoot: root)
            Issue.record("symlinked Materials was not refused")
        } catch {
            #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("ok.png").path) == false)
        }
    }

    @Test("duplicate zip entries are refused")
    func duplicateEntriesRefused() throws {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("dup-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: out) }
        let archive = try Archive(url: out, accessMode: .create)
        let payload = Data("a".utf8)
        for _ in 0..<2 {
            try archive.addEntry(with: "manifest.json", type: .file,
                                 uncompressedSize: Int64(payload.count),
                                 compressionMethod: .deflate) { position, size in
                payload.subdata(in: Int(position)..<(Int(position) + size))
            }
        }
        let root = try tempRoot("dup")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try CanvasBackupPackage.restore(data: Data(contentsOf: out), floeRoot: root)
            Issue.record("duplicate entries were not refused")
        } catch { /* expected */ }
    }

    @Test("a late hash failure leaves zero committed changes")
    func lateHashFailureRollsBack() throws {
        let node = makeNode(assetPath: "Materials/one.png")
        let project = makeProject(nodes: [node])
        let good = Data("good".utf8)
        let zip = try CanvasBackupPackage.make(project: project,
                                               childProjectData: { _ in nil },
                                               materialData: { _ in good },
                                               assetData: { _ in nil })
        // Rebuild with a WRONG sha for the material (simulated late failure).
        let root = try tempRoot("rollback")
        defer { try? FileManager.default.removeItem(at: root) }
        let tempIn = FileManager.default.temporaryDirectory.appendingPathComponent("rb-\(UUID().uuidString).zip")
        try zip.write(to: tempIn)
        defer { try? FileManager.default.removeItem(at: tempIn) }
        let readArchive = try Archive(url: tempIn, accessMode: .read)
        var canvasData = Data()
        if let entry = readArchive[CanvasBackupPackage.canvasEntry] {
            let canvasFile = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-\(UUID().uuidString).bin")
            _ = try readArchive.extract(entry, to: canvasFile, skipCRC32: false, progress: nil)
            canvasData = try Data(contentsOf: canvasFile)
        }
        var manifest = CanvasBackupPackage.Manifest(
            formatVersion: 1, canvasID: UUID(), canvasName: "x",
            canvasSchemaVersion: CanvasProject.currentSchemaVersion,
            exportedAt: Date(), canvasByteCount: Int64(canvasData.count),
            canvasSHA256: digest(canvasData),
            childProjects: [],
            materials: [CanvasBackupPackage.Material(
                fileName: "one.png", byteCount: Int64(good.count),
                sha256: String(repeating: "0", count: 64))],
            assets: [], missingChildProjects: [], missingAssets: [])
        let manifestData = try JSONEncoder().encode(manifest)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("rb-out-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: out) }
        let archive = try Archive(url: out, accessMode: .create)
        for (path, data) in [(CanvasBackupPackage.manifestEntry, manifestData),
                             (CanvasBackupPackage.canvasEntry, canvasData),
                             ("materials/one.png", good)] as [(String, Data)] {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count),
                                 compressionMethod: .deflate) { position, size in
                data.subdata(in: Int(position)..<(Int(position) + size))
            }
        }
        manifest.formatVersion = 1
        do {
            _ = try CanvasBackupPackage.restore(data: Data(contentsOf: out), floeRoot: root)
            Issue.record("wrong hash was not refused")
        } catch {
            // The materials file must NOT have been committed.
            #expect(FileManager.default.fileExists(
                atPath: root.appendingPathComponent("Materials/one.png").path) == false)
        }
    }

    @Test("missing child bytes are surfaced, binding preserved, restore succeeds")
    func missingChildSurfaced() throws {
        let childID = UUID()
        var node = makeNode()
        node.childProjectBinding = CanvasChildProjectBinding(projectID: childID, appliedRevision: 1)
        let project = makeProject(nodes: [node])
        let zip = try CanvasBackupPackage.make(project: project,
                                               childProjectData: { _ in nil },
                                               materialData: { _ in nil },
                                               assetData: { _ in nil })
        let root = try tempRoot("missing")
        defer { try? FileManager.default.removeItem(at: root) }
        let restored = try CanvasBackupPackage.restore(data: zip, floeRoot: root)
        #expect(restored.manifest.missingChildProjects == [childID])
        // The binding stays (dangling is surfaced, never silently dropped).
        #expect(restored.project.documents[0].nodes[0].childProjectBinding?.projectID == childID)
        // No project files written.
        let projectsRoot = root.appendingPathComponent("MediaProjects")
        #expect((try FileManager.default.contentsOfDirectory(atPath: projectsRoot.path)).isEmpty)
    }
}

/// Local SHA-256 helper for test fixtures.
private enum SHA256Placeholder {
    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
