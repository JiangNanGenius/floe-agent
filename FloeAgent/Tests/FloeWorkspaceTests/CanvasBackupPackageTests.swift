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
                // Zero changes: nothing may exist outside the root's owned dirs.
                let listing = try FileManager.default.contentsOfDirectory(atPath: root.path)
                    .filter {
                        $0 != "Materials" && $0 != "MediaProjects"
                            && $0 != "WorkbenchRoot"
                            && $0 != CanvasDrawingNodePlanner.draftRootDirectoryName
                    }
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

    @Test("export fails explicitly when a referenced material's bytes are missing")
    func missingMaterialFailsExport() throws {
        let node = makeNode(assetPath: "Materials/gone.png")
        let project = makeProject(nodes: [node])
        do {
            _ = try CanvasBackupPackage.make(project: project,
                                             childProjectData: { _ in nil },
                                             materialData: { _ in nil },
                                             assetData: { _ in nil })
            Issue.record("missing material bytes must fail the export")
        } catch {
            // expected: explicit, named failure
        }
    }

    // MARK: - Production file-backed export/import (registry entry points)

    private struct ProductionLayout {
        var root: URL
        var projectsRoot: URL
        var materialsRoot: URL
        var fallbackMediaRoot: URL
        var cadDraftsRoot: URL

        var exportLayout: CanvasBackupPackage.ExportLayout {
            CanvasBackupPackage.ExportLayout(
                projectsRoot: projectsRoot, materialsRoot: materialsRoot,
                fallbackMediaRoot: fallbackMediaRoot,
                cadDraftsRoot: cadDraftsRoot)
        }
    }

    private func productionLayout(_ label: String) throws -> ProductionLayout {
        let root = try tempRoot(label)
        let projects = root.appendingPathComponent("MediaProjects", isDirectory: true)
        let materials = root.appendingPathComponent("Materials", isDirectory: true)
        let fallback = root.appendingPathComponent("WorkbenchRoot", isDirectory: true)
        let drafts = root.appendingPathComponent(
            CanvasDrawingNodePlanner.draftRootDirectoryName, isDirectory: true)
        for url in [projects, materials, fallback, drafts] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return ProductionLayout(
            root: root, projectsRoot: projects,
            materialsRoot: materials, fallbackMediaRoot: fallback,
            cadDraftsRoot: drafts)
    }

    private func writeChildProject(_ id: UUID, into projectsRoot: URL,
                                   taskWorkspacePath: String?,
                                   assetPaths: [String]) throws {
        var object: [String: Any] = [
            "id": id.uuidString, "revision": 3, "name": "child",
            "assets": assetPaths.map { ["relativePath": $0, "originalName": $0] }
        ]
        if let taskWorkspacePath { object["taskWorkspacePath"] = taskWorkspacePath }
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: projectsRoot.appendingPathComponent(
            "media-project-\(id.uuidString.lowercased()).json"))
    }

    @Test("production export honors each child's recorded media root and restores file-backed")
    func productionExportHonorsPerChildMediaRoots() throws {
        let layout = try productionLayout("prod")
        defer { try? FileManager.default.removeItem(at: layout.root) }

        // Child A records its own task workspace; its asset exists ONLY there.
        let workspaceA = layout.root.appendingPathComponent("TaskWorkspaceA", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspaceA.appendingPathComponent("clips"), withIntermediateDirectories: true)
        let aBytes = Data("a-video".utf8)
        try aBytes.write(to: workspaceA.appendingPathComponent("clips/a.mp4"))
        let childA = UUID()
        try writeChildProject(childA, into: layout.projectsRoot,
                              taskWorkspacePath: workspaceA.path,
                              assetPaths: ["clips/a.mp4"])

        // Child B has no recorded path: falls back to WorkbenchRoot.
        try FileManager.default.createDirectory(
            at: layout.fallbackMediaRoot.appendingPathComponent("audio"),
            withIntermediateDirectories: true)
        let bBytes = Data("b-audio".utf8)
        try bBytes.write(to: layout.fallbackMediaRoot.appendingPathComponent("audio/b.wav"))
        let childB = UUID()
        try writeChildProject(childB, into: layout.projectsRoot,
                              taskWorkspacePath: nil, assetPaths: ["audio/b.wav"])

        let materialBytes = Data("mat".utf8)
        try materialBytes.write(to: layout.materialsRoot.appendingPathComponent("mat.png"))

        var nodeA = makeNode()
        nodeA.childProjectBinding = CanvasChildProjectBinding(projectID: childA, appliedRevision: 3)
        var nodeB = CanvasNode.placeholder(kind: .video,
                                           position: CanvasPoint(x: 30, y: 40), zIndex: 2)
        nodeB.childProjectBinding = CanvasChildProjectBinding(projectID: childB, appliedRevision: 3)
        let materialNode = makeNode(assetPath: "Materials/mat.png")
        let project = makeProject(nodes: [nodeA, nodeB, materialNode])

        let destination = layout.root.appendingPathComponent("export.floeCanvas")
        try CanvasBackupPackage.exportToURL(
            project: project, destination: destination, layout: layout.exportLayout)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(try CanvasBackupPackage.looksLikeZipArchive(at: destination))

        // Plain legacy JSON is not mistaken for a zip (first-bytes detection).
        let legacyJSON = layout.root.appendingPathComponent("legacy.json")
        try CanvasProjectCodec.encode(project).write(to: legacyJSON)
        #expect(try !CanvasBackupPackage.looksLikeZipArchive(at: legacyJSON))

        // No export staging directories are retained by the builder.
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            atPath: FileManager.default.temporaryDirectory.path)) ?? []
        #expect(leftovers.filter { $0.hasPrefix("canvas-backup-") }.isEmpty)

        // Restore through the file-backed production entry point.
        let restoredRoot = try tempRoot("prod-restored")
        defer { try? FileManager.default.removeItem(at: restoredRoot) }
        let restored = try CanvasBackupPackage.restore(
            fileURL: destination, floeRoot: restoredRoot)
        #expect(restored.project.id != project.id)
        #expect(restored.manifest.childProjects.count == 2)
        #expect(restored.manifest.assets.count == 2)
        #expect(restored.manifest.materials.count == 1)
        #expect(restored.manifest.missingChildProjects.isEmpty)
        #expect(restored.manifest.missingAssets.isEmpty)

        // Restored child projects are app-owned copies: taskWorkspacePath is
        // cleared so assets resolve from the restored WorkbenchRoot.
        let childFiles = try FileManager.default.contentsOfDirectory(
            at: restoredRoot.appendingPathComponent("MediaProjects"),
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        #expect(childFiles.count == 2)
        for file in childFiles {
            let object = try #require(
                JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            #expect(object["taskWorkspacePath"] == nil)
            #expect((object["assets"] as? [[String: Any]])?.isEmpty == false)
        }

        // Bytes landed under the restored fallback media root.
        #expect(try Data(contentsOf: restoredRoot
            .appendingPathComponent("WorkbenchRoot/clips/a.mp4")) == aBytes)
        #expect(try Data(contentsOf: restoredRoot
            .appendingPathComponent("WorkbenchRoot/audio/b.wav")) == bBytes)
        #expect(try Data(contentsOf: restoredRoot
            .appendingPathComponent("Materials/mat.png")) == materialBytes)

        // A second canvas restores independently from the same package.
        let secondRoot = try tempRoot("prod-restored-2")
        defer { try? FileManager.default.removeItem(at: secondRoot) }
        let second = try CanvasBackupPackage.restore(
            fileURL: destination, floeRoot: secondRoot)
        #expect(second.project.id != restored.project.id)
        #expect(second.manifest.childProjects.count == 2)
    }

    @Test("export preflight refuses traversal, symlink escape, oversize and missing material before writing")
    func exportPreflightRefusesHostileSources() throws {
        // Traversal in a child asset path.
        do {
            let layout = try productionLayout("preflight-traversal")
            defer { try? FileManager.default.removeItem(at: layout.root) }
            let child = UUID()
            try writeChildProject(child, into: layout.projectsRoot,
                                  taskWorkspacePath: layout.root.path,
                                  assetPaths: ["../escape.bin"])
            var node = makeNode()
            node.childProjectBinding = CanvasChildProjectBinding(projectID: child, appliedRevision: 1)
            let project = makeProject(nodes: [node])
            let destination = layout.root.appendingPathComponent("out.floeCanvas")
            #expect(throws: CanvasBackupPackage.BackupError.self) {
                try CanvasBackupPackage.exportToURL(
                    project: project, destination: destination, layout: layout.exportLayout)
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }

        // Symlink escaping the media root.
        do {
            let layout = try productionLayout("preflight-symlink")
            defer { try? FileManager.default.removeItem(at: layout.root) }
            let outside = layout.root.appendingPathComponent("outside-secret.bin")
            try Data("secret".utf8).write(to: outside)
            let link = layout.fallbackMediaRoot.appendingPathComponent("link.bin")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            let child = UUID()
            try writeChildProject(child, into: layout.projectsRoot,
                                  taskWorkspacePath: nil, assetPaths: ["link.bin"])
            var node = makeNode()
            node.childProjectBinding = CanvasChildProjectBinding(projectID: child, appliedRevision: 1)
            let project = makeProject(nodes: [node])
            let destination = layout.root.appendingPathComponent("out.floeCanvas")
            #expect(throws: CanvasBackupPackage.BackupError.self) {
                try CanvasBackupPackage.exportToURL(
                    project: project, destination: destination, layout: layout.exportLayout)
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }

        // Oversize payload (bounded through the layout's caps).
        do {
            let layout = try productionLayout("preflight-oversize")
            defer { try? FileManager.default.removeItem(at: layout.root) }
            try FileManager.default.createDirectory(
                at: layout.fallbackMediaRoot.appendingPathComponent("clips"),
                withIntermediateDirectories: true)
            try Data(repeating: 0, count: 100).write(
                to: layout.fallbackMediaRoot.appendingPathComponent("clips/big.mp4"))
            let child = UUID()
            try writeChildProject(child, into: layout.projectsRoot,
                                  taskWorkspacePath: nil, assetPaths: ["clips/big.mp4"])
            var node = makeNode()
            node.childProjectBinding = CanvasChildProjectBinding(projectID: child, appliedRevision: 1)
            let project = makeProject(nodes: [node])
            let destination = layout.root.appendingPathComponent("out.floeCanvas")
            let bounded = CanvasBackupPackage.ExportLayout(
                projectsRoot: layout.projectsRoot, materialsRoot: layout.materialsRoot,
                fallbackMediaRoot: layout.fallbackMediaRoot, maximumEntryBytes: 16)
            #expect(throws: CanvasBackupPackage.BackupError.self) {
                try CanvasBackupPackage.exportToURL(
                    project: project, destination: destination, layout: bounded)
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }

        // Missing referenced material.
        do {
            let layout = try productionLayout("preflight-material")
            defer { try? FileManager.default.removeItem(at: layout.root) }
            let node = makeNode(assetPath: "Materials/gone.png")
            let project = makeProject(nodes: [node])
            let destination = layout.root.appendingPathComponent("out.floeCanvas")
            #expect(throws: CanvasBackupPackage.BackupError.self) {
                try CanvasBackupPackage.exportToURL(
                    project: project, destination: destination, layout: layout.exportLayout)
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
    }

    @Test("CAD drawing node in Materials roundtrips through production export/import")
    func cadDrawingMaterialNodeRoundtrips() throws {
        let layout = try productionLayout("cad-materials")
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let drawingBytes = Data("dxf-drawing-bytes".utf8)
        let fileName = "\(UUID().uuidString)-plate.dxf"
        try drawingBytes.write(to: layout.materialsRoot.appendingPathComponent(fileName))
        var node = CanvasNode.placeholder(
            kind: .file, position: CanvasPoint(x: 10, y: 20), zIndex: 1)
        node.text = "plate.dxf"
        node.asset = CanvasAssetReference(
            contentHash: digest(drawingBytes),
            localRelativePath: "Materials/\(fileName)",
            mimeType: "image/vnd.dxf", byteCount: Int64(drawingBytes.count))
        let project = makeProject(nodes: [node])

        let destination = layout.root.appendingPathComponent("cad.floeCanvas")
        try CanvasBackupPackage.exportToURL(
            project: project, destination: destination, layout: layout.exportLayout)

        let restoredRoot = try tempRoot("cad-materials-restored")
        defer { try? FileManager.default.removeItem(at: restoredRoot) }
        let restored = try CanvasBackupPackage.restore(
            fileURL: destination, floeRoot: restoredRoot)
        #expect(restored.manifest.materials.map(\.fileName) == [fileName])
        #expect(restored.manifest.externalNodeAssets.isEmpty)
        #expect(try Data(contentsOf: restoredRoot
            .appendingPathComponent("Materials/\(fileName)")) == drawingBytes)
        let restoredNode = try #require(restored.project.documents[0].nodes.first)
        #expect(restoredNode.kind == .file)
        #expect(restoredNode.asset?.localRelativePath == "Materials/\(fileName)")
        #expect(restoredNode.asset?.contentHash == digest(drawingBytes))
    }

    @Test("node asset outside Materials (WorkbenchRoot) is carried and remapped")
    func externalNodeAssetRoundtrips() throws {
        let layout = try productionLayout("cad-external")
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let drawingBytes = Data("dwg-drawing-bytes".utf8)
        try FileManager.default.createDirectory(
            at: layout.fallbackMediaRoot.appendingPathComponent("drawings"),
            withIntermediateDirectories: true)
        try drawingBytes.write(to: layout.fallbackMediaRoot
            .appendingPathComponent("drawings/plate.dwg"))
        var node = CanvasNode.placeholder(
            kind: .file, position: CanvasPoint(x: 0, y: 0), zIndex: 1)
        node.asset = CanvasAssetReference(
            contentHash: digest(drawingBytes),
            localRelativePath: "WorkbenchRoot/drawings/plate.dwg",
            mimeType: "image/vnd.dwg", byteCount: Int64(drawingBytes.count))
        let project = makeProject(nodes: [node])

        let destination = layout.root.appendingPathComponent("external.floeCanvas")
        try CanvasBackupPackage.exportToURL(
            project: project, destination: destination, layout: layout.exportLayout)

        let restoredRoot = try tempRoot("cad-external-restored")
        defer { try? FileManager.default.removeItem(at: restoredRoot) }
        let restored = try CanvasBackupPackage.restore(
            fileURL: destination, floeRoot: restoredRoot)
        #expect(restored.manifest.externalNodeAssets.map(\.relativePath)
            == ["WorkbenchRoot/drawings/plate.dwg"])
        #expect(restored.manifest.missingExternalNodeAssets.isEmpty)
        #expect(try Data(contentsOf: restoredRoot
            .appendingPathComponent("WorkbenchRoot/drawings/plate.dwg")) == drawingBytes)
        let restoredNode = try #require(restored.project.documents[0].nodes.first)
        #expect(restoredNode.asset?.localRelativePath == "WorkbenchRoot/drawings/plate.dwg")
    }

    @Test("node asset outside the packable roots refuses export explicitly")
    func externalNodeAssetOutsideRootsRefused() throws {
        let layout = try productionLayout("cad-unsafe")
        defer { try? FileManager.default.removeItem(at: layout.root) }
        var node = CanvasNode.placeholder(
            kind: .file, position: CanvasPoint(x: 0, y: 0), zIndex: 1)
        node.asset = CanvasAssetReference(
            contentHash: "h", localRelativePath: "Elsewhere/plate.dwg",
            mimeType: "image/vnd.dwg", byteCount: 3)
        let project = makeProject(nodes: [node])
        let destination = layout.root.appendingPathComponent("out.floeCanvas")
        #expect(throws: CanvasBackupPackage.BackupError.self) {
            try CanvasBackupPackage.exportToURL(
                project: project, destination: destination, layout: layout.exportLayout)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("an unapplied CAD draft is streamed into the package and restored resumable")
    func unappliedCADDraftRoundTrips() throws {
        let layout = try productionLayout("cad-draft")
        defer { try? FileManager.default.removeItem(at: layout.root) }

        // The node still carries the original bytes; the draft on disk is
        // newer unapplied user work.
        let originalBytes = Data("original-dwg".utf8)
        let originalFileName = "\(UUID().uuidString)-plate.dwg"
        try originalBytes.write(to: layout.materialsRoot.appendingPathComponent(originalFileName))
        let nodeID = UUID()
        var node = CanvasNode(
            id: nodeID, kind: .file, text: "plate.dwg",
            position: .init(x: 0, y: 0), size: .init(width: 200, height: 120),
            asset: CanvasAssetReference(
                contentHash: digest(originalBytes),
                localRelativePath: "Materials/\(originalFileName)",
                mimeType: "image/vnd.dwg",
                byteCount: Int64(originalBytes.count)))
        let project = makeProject(nodes: [node])

        let draftBytes = Data("edited-dwg-with-new-line".utf8)
        let nodeDraftDirectory = layout.cadDraftsRoot
            .appendingPathComponent(project.id.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent(nodeID.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(
            at: nodeDraftDirectory, withIntermediateDirectories: true)
        try draftBytes.write(to: nodeDraftDirectory.appendingPathComponent("plate.dwg"))
        let descriptor = CanvasDrawingNodePlanner.CanvasDrawingDraftDescriptor(
            canvasID: project.id, nodeID: nodeID,
            sourceAssetID: node.asset!.id,
            sourceContentHash: digest(originalBytes),
            sourceRelativePath: "Materials/\(originalFileName)",
            stagedRelativePath: "\(project.id.uuidString.lowercased())/\(nodeID.uuidString.lowercased())/plate.dwg",
            stagedContentHash: digest(draftBytes))
        try JSONEncoder().encode(descriptor).write(
            to: nodeDraftDirectory.appendingPathComponent("plate.draft.json"))

        let destination = layout.root.appendingPathComponent("draft.floeCanvas")
        try CanvasBackupPackage.exportToURL(
            project: project, destination: destination, layout: layout.exportLayout)
        // The manifest truth: exactly one unapplied draft, no missing entries.
        let exportedArchive = try Archive(url: destination, accessMode: .read)
        let exportedManifestData = try #require(exportedArchive
            .first { $0.path == CanvasBackupPackage.manifestEntry })
        let exportedManifestFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("m-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: exportedManifestFile) }
        _ = try exportedArchive.extract(
            exportedManifestData, to: exportedManifestFile)
        let exportedManifest = try JSONDecoder().decode(
            CanvasBackupPackage.Manifest.self,
            from: Data(contentsOf: exportedManifestFile))
        #expect(exportedManifest.cadDrafts.count == 1)
        #expect(exportedManifest.cadDrafts.first?.nodeID == nodeID)

        let restoredRoot = try tempRoot("cad-draft-restored")
        defer { try? FileManager.default.removeItem(at: restoredRoot) }
        let restored = try CanvasBackupPackage.restore(
            fileURL: destination, floeRoot: restoredRoot)
        #expect(restored.restoredDraftNodeIDs == [nodeID])

        // Draft bytes landed under the NEW canvas id, SAME node id. The
        // package entry basenames are index/owner-derived; read them from
        // the manifest rather than assuming the source staging basename.
        let carriedDraft = try #require(restored.manifest.cadDrafts.first)
        let restoredDrawingName = (carriedDraft.drawingFile as NSString).lastPathComponent
        let restoredDescriptorName = (carriedDraft.descriptorFile as NSString).lastPathComponent
        let restoredDraftDirectory = restoredRoot
            .appendingPathComponent(CanvasDrawingNodePlanner.draftRootDirectoryName, isDirectory: true)
            .appendingPathComponent(restored.project.id.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent(nodeID.uuidString.lowercased(), isDirectory: true)
        #expect(try Data(contentsOf: restoredDraftDirectory
            .appendingPathComponent(restoredDrawingName)) == draftBytes)
        let restoredDescriptor = try JSONDecoder().decode(
            CanvasDrawingNodePlanner.CanvasDrawingDraftDescriptor.self,
            from: Data(contentsOf: restoredDraftDirectory
                .appendingPathComponent(restoredDescriptorName)))
        #expect(restoredDescriptor.canvasID == restored.project.id)
        // Baseline semantics preserved: the node still carries the original
        // hash, so reopening resumes this draft rather than treating it as a
        // foreign or applied copy.
        #expect(restoredDescriptor.sourceContentHash == digest(originalBytes))
        #expect(restoredDescriptor.stagedContentHash == digest(draftBytes))
        #expect(restoredDescriptor.appliedContentHash == nil)
        let restoredNode = try #require(restored.project.documents[0].nodes.first)
        #expect(restoredNode.asset?.contentHash == digest(originalBytes))
    }

    @Test("CAD revision history bytes are carried, restored, and remapped on collision")
    func cadRevisionHistoryRoundTrips() throws {
        // Two scenarios share the fixture builder: clean restore and a
        // destination collision that must remap history paths.
        func buildExport(label: String) throws -> (ProductionLayout, URL, CanvasProject, CanvasNode, String) {
            let layout = try productionLayout(label)
            let originalBytes = Data("original-dwg".utf8)
            let v2Bytes = Data("second-version-dwg".utf8)
            try originalBytes.write(to: layout.materialsRoot.appendingPathComponent("orig.dwg"))
            try v2Bytes.write(to: layout.materialsRoot.appendingPathComponent("v2.dwg"))

            let nodeID = UUID()
            var node = CanvasNode(
                id: nodeID, kind: .file, text: "plate.dwg",
                position: .init(x: 0, y: 0), size: .init(width: 200, height: 120),
                asset: CanvasAssetReference(
                    contentHash: String(repeating: "c", count: 64),
                    localRelativePath: "Materials/v2.dwg",
                    mimeType: "image/vnd.dwg",
                    byteCount: Int64(v2Bytes.count)))
            let originalRevision = CanvasDrawingRevision(
                assetID: UUID(),
                contentHash: digest(originalBytes),
                relativePath: "Materials/orig.dwg",
                byteCount: Int64(originalBytes.count), kind: .original)
            let adoptedRevision = CanvasDrawingRevision(
                assetID: node.asset!.id,
                contentHash: digest(v2Bytes),
                relativePath: "Materials/v2.dwg",
                byteCount: Int64(v2Bytes.count), kind: .adopt)
            let historyEntry = try CanvasDrawingRevisionHistory.metadata(
                [originalRevision, adoptedRevision])
            node.metadata.merge(historyEntry) { _, new in new }
            let project = makeProject(nodes: [node])
            let destination = layout.root.appendingPathComponent("history.floeCanvas")
            try CanvasBackupPackage.exportToURL(
                project: project, destination: destination,
                layout: layout.exportLayout)
            return (layout, destination, project, node, "Materials/orig.dwg")
        }

        // Clean: both revision paths restore verbatim.
        let (layout, destination, _, _, origPath) = try buildExport(label: "cad-history")
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let restoredRoot = try tempRoot("cad-history-restored")
        defer { try? FileManager.default.removeItem(at: restoredRoot) }
        let restored = try CanvasBackupPackage.restore(
            fileURL: destination, floeRoot: restoredRoot)
        #expect(restored.manifest.cadRevisionAssets.map(\.relativePath) == [origPath])
        #expect(try Data(contentsOf: restoredRoot
            .appendingPathComponent("Materials/orig.dwg")) == Data("original-dwg".utf8))
        let restoredNode = try #require(restored.project.documents[0].nodes.first)
        let restoredHistory = CanvasDrawingRevisionHistory.revisions(from: restoredNode)
        #expect(restoredHistory.map(\.relativePath)
            == ["Materials/orig.dwg", "Materials/v2.dwg"])

        // Collision: pre-existing different bytes at the revision path force
        // a remap; the node's history is rewritten to the new path.
        let (layout2, destination2, _, _, _) = try buildExport(label: "cad-history-collision")
        defer { try? FileManager.default.removeItem(at: layout2.root) }
        let collidedRoot = try tempRoot("cad-history-collided")
        defer { try? FileManager.default.removeItem(at: collidedRoot) }
        let materials = collidedRoot.appendingPathComponent("Materials", isDirectory: true)
        try FileManager.default.createDirectory(at: materials, withIntermediateDirectories: true)
        try Data("unrelated-old-original".utf8).write(
            to: materials.appendingPathComponent("orig.dwg"))
        let collided = try CanvasBackupPackage.restore(
            fileURL: destination2, floeRoot: collidedRoot)
        let remappedPath = try #require(collided.remappedRevisionPaths["Materials/orig.dwg"])
        #expect(remappedPath != "Materials/orig.dwg")
        #expect(remappedPath.hasPrefix("Materials/"))
        #expect(try Data(contentsOf: collidedRoot.appendingPathComponent(remappedPath))
            == Data("original-dwg".utf8))
        let collidedHistoryNode = try #require(collided.project.documents[0].nodes.first)
        let collidedHistory = CanvasDrawingRevisionHistory.revisions(from: collidedHistoryNode)
        #expect(collidedHistory.map(\.relativePath)
            == [remappedPath, "Materials/v2.dwg"])
    }

    @Test("unclosable raw CAD history refuses export without creating the destination")
    func unclosableHistoryRefused() throws {
        let layout = try productionLayout("cad-history-raw")
        defer { try? FileManager.default.removeItem(at: layout.root) }
        var node = CanvasNode(
            kind: .file, text: "p.dwg",
            position: .init(x: 0, y: 0), size: .init(width: 200, height: 120),
            asset: CanvasAssetReference(
                contentHash: String(repeating: "a", count: 64),
                localRelativePath: "Materials/p.dwg",
                mimeType: "image/vnd.dwg", byteCount: 3))
        node.metadata[CanvasDrawingRevisionHistory.metadataKey] = "{not valid json"
        try Data("dwg".utf8).write(to: layout.materialsRoot.appendingPathComponent("p.dwg"))
        let project = makeProject(nodes: [node])
        let destination = layout.root.appendingPathComponent("out.floeCanvas")
        #expect(throws: FloeError.self) {
            try CanvasBackupPackage.exportToURL(
                project: project, destination: destination,
                layout: layout.exportLayout)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("bounded in-memory CAD draft API carries owned drafts and rejects foreign ownership")
    func inMemoryCADDraftAPI() throws {
        let draftBytes = Data("draft-dwg".utf8)
        let originalBytes = Data("original-dwg".utf8)
        var node = CanvasNode(
            kind: .file, text: "p.dwg",
            position: .init(x: 0, y: 0), size: .init(width: 200, height: 120),
            asset: CanvasAssetReference(
                contentHash: digest(originalBytes),
                localRelativePath: "Materials/p.dwg",
                mimeType: "image/vnd.dwg",
                byteCount: Int64(originalBytes.count)))
        let project = makeProject(nodes: [node])
        let descriptor = CanvasDrawingNodePlanner.CanvasDrawingDraftDescriptor(
            canvasID: project.id, nodeID: node.id,
            sourceAssetID: node.asset!.id,
            sourceContentHash: digest(originalBytes),
            sourceRelativePath: "Materials/p.dwg",
            stagedRelativePath: "\(project.id.uuidString.lowercased())/\(node.id.uuidString.lowercased())/p.dwg",
            stagedContentHash: digest(draftBytes))
        let descriptorJSON = try JSONEncoder().encode(descriptor)
        let source = CanvasBackupPackage.CADDraftSource(
            descriptor: descriptor, descriptorJSON: descriptorJSON,
            drawingData: draftBytes)
        let zip = try CanvasBackupPackage.make(
            project: project,
            childProjectData: { _ in nil },
            materialData: { _ in originalBytes },
            assetData: { _ in nil },
            cadDraftSources: { [source] })
        let restoredRoot = try tempRoot("cad-inmemory")
        defer { try? FileManager.default.removeItem(at: restoredRoot) }
        let restored = try CanvasBackupPackage.restore(data: zip, floeRoot: restoredRoot)
        #expect(restored.restoredDraftNodeIDs == [node.id])

        // A draft whose descriptor claims a different canvas is refused
        // instead of being silently exported.
        var foreignDescriptor = descriptor
        foreignDescriptor.canvasID = UUID()
        let foreignSource = CanvasBackupPackage.CADDraftSource(
            descriptor: foreignDescriptor,
            descriptorJSON: try JSONEncoder().encode(foreignDescriptor),
            drawingData: draftBytes)
        #expect(throws: CanvasBackupPackage.BackupError.self) {
            _ = try CanvasBackupPackage.make(
                project: project,
                childProjectData: { _ in nil },
                materialData: { _ in originalBytes },
                assetData: { _ in nil },
                cadDraftSources: { [foreignSource] })
        }
    }

    @Test("manifest written before external node assets decodes with empty lists")
    func legacyManifestDecodes() throws {
        let canvasID = UUID()
        let legacy = """
        {"formatVersion":1,"canvasID":"\(canvasID.uuidString)","canvasName":"x",
         "canvasSchemaVersion":7,"exportedAt":0,"canvasByteCount":0,"canvasSHA256":"",
         "childProjects":[],"materials":[],"assets":[],
         "missingChildProjects":[],"missingAssets":[]}
        """
        let manifest = try JSONDecoder().decode(
            CanvasBackupPackage.Manifest.self, from: Data(legacy.utf8))
        #expect(manifest.canvasID == canvasID)
        #expect(manifest.externalNodeAssets.isEmpty)
        #expect(manifest.missingExternalNodeAssets.isEmpty)
    }
}

/// Local SHA-256 helper for test fixtures.
private enum SHA256Placeholder {
    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
