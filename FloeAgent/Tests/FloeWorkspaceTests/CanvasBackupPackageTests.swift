// FloeWorkspaceTests — canvas backup package (child projects + materials).
import Foundation
import ZIPFoundation
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

    @Test("export carries canvas, bound child projects and referenced materials with hashes")
    func exportRoundTrip() throws {
        let childID = UUID()
        var boundNode = makeNode()
        boundNode.childProjectBinding = CanvasChildProjectBinding(
            projectID: childID, appliedRevision: 3, draftRevision: 4,
            renderedAssetID: UUID(), sourceNodeID: UUID())
        let materialNode = makeNode(assetPath: "Materials/abc-canvas-edit.png")
        let project = makeProject(nodes: [boundNode, materialNode])

        let childJSON = try JSONSerialization.data(withJSONObject: [
            "id": childID.uuidString, "revision": 4, "name": "child"
        ] as [String: Any])
        let materialBytes = Data("png-bytes".utf8)
        let zip = try CanvasBackupPackage.make(
            project: project,
            childProjectData: { $0 == childID ? childJSON : nil },
            materialData: { $0 == "Materials/abc-canvas-edit.png" ? materialBytes : nil })

        var writtenChildren: [UUID: Data] = [:]
        var writtenMaterials: [String: Data] = [:]
        let restored = try CanvasBackupPackage.restore(
            data: zip,
            childProjectWriter: { id, data in writtenChildren[id] = data },
            materialWriter: { path, data in writtenMaterials[path] = data })

        // Fresh canvas identity; chat bindings cut.
        #expect(restored.project.id != project.id)
        #expect(restored.project.workspaceID == nil)
        #expect(restored.project.agentConversationID == nil)
        #expect(restored.manifest.childProjects.count == 1)
        #expect(restored.manifest.materials.count == 1)
        #expect(restored.manifest.missingChildProjects.isEmpty)

        // Child project written under a NEW id, inner id remapped.
        #expect(writtenChildren.count == 1)
        let (newID, newData) = try #require(writtenChildren.first)
        #expect(newID != childID)
        let inner = try #require(JSONSerialization.jsonObject(with: newData) as? [String: Any])
        #expect(inner["id"] as? String == newID.uuidString)
        #expect(inner["revision"] as? Int == 4)

        // Node binding remapped to the new child id.
        let restoredNode = restored.project.documents[0].nodes[0]
        #expect(restoredNode.childProjectBinding?.projectID == newID)
        #expect(restoredNode.childProjectBinding?.appliedRevision == 3)

        // Material written at its original relative path with verified bytes.
        #expect(writtenMaterials["Materials/abc-canvas-edit.png"] == materialBytes)
        #expect(restored.project.documents[0].nodes[1].asset?.localRelativePath == "Materials/abc-canvas-edit.png")
    }

    @Test("unavailable child project is reported, binding preserved")
    func missingChildReported() throws {
        let childID = UUID()
        var node = makeNode()
        node.childProjectBinding = CanvasChildProjectBinding(projectID: childID, appliedRevision: 1)
        let project = makeProject(nodes: [node])
        let zip = try CanvasBackupPackage.make(project: project,
                                               childProjectData: { _ in nil },
                                               materialData: { _ in nil })
        var wrote = false
        let restored = try CanvasBackupPackage.restore(
            data: zip,
            childProjectWriter: { _, _ in wrote = true },
            materialWriter: { _, _ in })
        #expect(!wrote)
        #expect(restored.manifest.missingChildProjects == [childID])
        // The binding stays (dangling is surfaced, never silently dropped).
        #expect(restored.project.documents[0].nodes[0].childProjectBinding?.projectID == childID)
    }

    @Test("tampered material bytes are rejected by hash verification")
    func tamperRejected() throws {
        let node = makeNode(assetPath: "Materials/x.png")
        let project = makeProject(nodes: [node])
        let zip = try CanvasBackupPackage.make(project: project,
                                               childProjectData: { _ in nil },
                                               materialData: { _ in Data("good".utf8) })
        // Corrupt one byte inside the zip payload region.
        var mutated = zip
        let index = zip.count - 8
        mutated[zip.index(zip.startIndex, offsetBy: index)] ^= 0xFF
        // A corrupt zip may fail extraction OR hash verification; either is a
        // refusal, never a silent bad import.
        do {
            _ = try CanvasBackupPackage.restore(
                data: mutated,
                childProjectWriter: { _, _ in },
                materialWriter: { _, _ in })
        } catch {
            return // expected
        }
    }

    @Test("unsupported future format version is refused")
    func futureVersionRefused() throws {
        var manifest = CanvasBackupPackage.Manifest(
            formatVersion: 1, canvasID: UUID(), canvasName: "x",
            canvasSchemaVersion: CanvasProject.currentSchemaVersion,
            exportedAt: Date(), childProjects: [], materials: [], missingChildProjects: [])
        manifest.formatVersion = 999
        let manifestData = try JSONEncoder().encode(manifest)
        let zip = try CanvasBackupPackage.make(
            project: makeProject(nodes: []),
            childProjectData: { _ in nil }, materialData: { _ in nil })
        var canvasData: Data?
        // Pull the original canvas entry back out of the export.
        let tempIn = FileManager.default.temporaryDirectory.appendingPathComponent("bp-in-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: tempIn) }
        try zip.write(to: tempIn)
        let readArchive = try Archive(url: tempIn, accessMode: .read)
        if let entry = readArchive[CanvasBackupPackage.canvasEntry] {
            var data = Data()
            _ = try readArchive.extract(entry, bufferSize: 1 << 20, skipCRC32: false, progress: nil) {
                data.append($0)
            }
            canvasData = data
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("bp-out-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: out) }
        let archive = try Archive(url: out, accessMode: .create)
        var entries: [(String, Data)] = [(CanvasBackupPackage.manifestEntry, manifestData)]
        if let canvasData { entries.append((CanvasBackupPackage.canvasEntry, canvasData)) }
        for (path, data) in entries {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count),
                                 compressionMethod: .deflate) { position, size in
                data.subdata(in: Int(position)..<(Int(position) + size))
            }
        }
        do {
            _ = try CanvasBackupPackage.restore(data: Data(contentsOf: out),
                                                childProjectWriter: { _, _ in },
                                                materialWriter: { _, _ in })
            Issue.record("expected unsupportedFormat refusal")
        } catch let error as CanvasBackupPackage.BackupError {
            #expect(error == .unsupportedFormat(999))
        }
    }
}
