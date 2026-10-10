// FloeWorkspaceTests — canvas backup carrying EDITABLE native CAD packages.
//
// The canvas ZIP backup must carry the `.floecad` document bundle (not only
// the node's PNG render), restore it under the new canvas identity, rewrite
// the node binding, refuse missing/corrupt payloads without touching existing
// data, and stay compatible with older backups that predate the field.
import Foundation
import ZIPFoundation
import CryptoKit
import Testing
@testable import FloeWorkspace
import FloeCore

@Suite("Canvas backup native CAD packages")
struct NativeCADBackupTests {

    private let bindingKey = CADCanvasNodePlanner.MetadataKeys.sourcePath

    private func tempRoot(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nativecad-backup-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func layout(root: URL, includeNativeCAD: Bool = true) throws -> CanvasBackupPackage.ExportLayout {
        let projects = root.appendingPathComponent("MediaProjects", isDirectory: true)
        let materials = root.appendingPathComponent("Materials", isDirectory: true)
        let fallback = root.appendingPathComponent("WorkbenchRoot", isDirectory: true)
        let drafts = root.appendingPathComponent(
            CanvasDrawingNodePlanner.draftRootDirectoryName, isDirectory: true)
        let native = root.appendingPathComponent("CanvasCAD", isDirectory: true)
        for url in [projects, materials, fallback, drafts] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        if includeNativeCAD {
            try FileManager.default.createDirectory(at: native, withIntermediateDirectories: true)
        }
        return CanvasBackupPackage.ExportLayout(
            projectsRoot: projects, materialsRoot: materials,
            fallbackMediaRoot: fallback, cadDraftsRoot: drafts,
            nativeCADRoot: includeNativeCAD ? native : nil)
    }

    private func makeProject(canvasID: UUID, packageName: String) -> CanvasProject {
        var node = CanvasNode.placeholder(kind: .file,
                                          position: CanvasPoint(x: 10, y: 20), zIndex: 1)
        node.metadata = [
            bindingKey: "canvas-cad:\(canvasID.uuidString)/\(packageName)",
            "editor": "native-cad",
        ]
        let document = CanvasDocument(name: "Doc", nodes: [node])
        return CanvasProject(id: canvasID, name: "CAD 画布",
                             documents: [document], selectedDocumentID: document.id)
    }

    /// Writes a synthetic `.floecad` bundle (the real package is a directory
    /// of JSON + blob files; byte-level transport is what is under test).
    private func writePackage(root: URL, canvasID: UUID, name: String,
                              files: [String: Data]) throws -> URL {
        let directory = root.appendingPathComponent("CanvasCAD", isDirectory: true)
            .appendingPathComponent(canvasID.uuidString, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (relative, data) in files {
            let url = directory.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
        return directory
    }

    private func packageFiles() -> [String: Data] {
        [
            "manifest.json": Data(#"{"formatVersion":1}"#.utf8),
            "document.json": Data(#"{"name":"Widget","bodies":[]}"#.utf8),
            "blobs/0-body.bin": Data([0x01, 0x02, 0x03, 0x04]),
            "blobs/empty.bin": Data(),
        ]
    }

    // MARK: Round trip

    @Test("export carries the editable package; restore rewrites identity and bytes")
    func nativeCADPackageRoundTrip() throws {
        let exportRoot = try tempRoot("export")
        defer { try? FileManager.default.removeItem(at: exportRoot) }
        let restoredRoot = try tempRoot("restore")
        defer { try? FileManager.default.removeItem(at: restoredRoot) }
        _ = try layout(root: restoredRoot)

        let canvasID = UUID()
        let name = "Widget.floecad"
        let originalDirectory = try writePackage(
            root: exportRoot, canvasID: canvasID, name: name, files: packageFiles())
        let project = makeProject(canvasID: canvasID, packageName: name)
        let destination = exportRoot.appendingPathComponent("canvas.floeCanvas")
        try CanvasBackupPackage.exportToURL(project: project, destination: destination,
                                            layout: try layout(root: exportRoot))

        // Manifest truth: the package and all four files (including an EMPTY
        // file) are carried; nothing is listed missing.
        let archive = try Archive(url: destination, accessMode: .read)
        let manifestEntry = try #require(archive.first { $0.path == CanvasBackupPackage.manifestEntry })
        let manifestFile = exportRoot.appendingPathComponent("manifest.json")
        _ = try archive.extract(manifestEntry, to: manifestFile)
        let manifest = try JSONDecoder().decode(CanvasBackupPackage.Manifest.self,
                                                from: Data(contentsOf: manifestFile))
        #expect(manifest.nativeCADPackages.count == 1)
        #expect(manifest.nativeCADPackages.first?.fileName == name)
        #expect(manifest.nativeCADPackages.first?.files.count == 4)
        #expect(manifest.missingNativeCADPackages.isEmpty)

        // Remove the source package before restoring: the ZIP alone must carry it.
        try FileManager.default.removeItem(at: originalDirectory)

        let restored = try CanvasBackupPackage.restore(fileURL: destination,
                                                       floeRoot: restoredRoot)
        #expect(restored.restoredNativeCADPackageCount == 1)
        #expect(restored.project.id != canvasID)

        let restoredDirectory = restoredRoot.appendingPathComponent("CanvasCAD", isDirectory: true)
            .appendingPathComponent(restored.project.id.uuidString, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        for (relative, data) in packageFiles() {
            let url = restoredDirectory.appendingPathComponent(relative)
            #expect(FileManager.default.fileExists(atPath: url.path), "missing restored \(relative)")
            #expect(try Data(contentsOf: url) == data, "bytes changed for \(relative)")
        }

        // The node binding now points at the restored canvas identity.
        let node = try #require(restored.project.documents.first?.nodes.first)
        let expectedKey = "canvas-cad:\(restored.project.id.uuidString)/\(name)"
        #expect(node.metadata[bindingKey] == expectedKey)
        // Immutable references survive only when their bytes were carried; the
        // package itself is a clone independent of the original canvas.
        #expect(!FileManager.default.fileExists(atPath: originalDirectory.path))
    }

    @Test("a bound package that is missing on disk is reported, not invented")
    func missingBoundPackageIsReported() throws {
        let root = try tempRoot("missing")
        defer { try? FileManager.default.removeItem(at: root) }
        let canvasID = UUID()
        let project = makeProject(canvasID: canvasID, packageName: "Absent.floecad")
        let destination = root.appendingPathComponent("canvas.floeCanvas")
        try CanvasBackupPackage.exportToURL(project: project, destination: destination,
                                            layout: try layout(root: root))
        let archive = try Archive(url: destination, accessMode: .read)
        let manifestEntry = try #require(archive.first { $0.path == CanvasBackupPackage.manifestEntry })
        let manifestFile = root.appendingPathComponent("manifest.json")
        _ = try archive.extract(manifestEntry, to: manifestFile)
        let manifest = try JSONDecoder().decode(CanvasBackupPackage.Manifest.self,
                                                from: Data(contentsOf: manifestFile))
        #expect(manifest.nativeCADPackages.isEmpty)
        #expect(manifest.missingNativeCADPackages == ["Absent.floecad"])
    }

    // MARK: Rejection without destroying existing data

    private func tamperArchive(_ destination: URL,
                               removeNativeEntry: Bool) throws {
        guard let archive = Archive(url: destination, accessMode: .update) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let entry = try #require(archive.first { $0.path.hasPrefix("nativecad/") },
                                 "the exported archive must carry native package entries")
        let entryBytes: Data
        if removeNativeEntry {
            entryBytes = Data()
        } else {
            entryBytes = Data("corrupted-payload".utf8)
        }
        try archive.remove(entry)
        if !removeNativeEntry {
            try archive.addEntry(with: entry.path, type: .file,
                                 uncompressedSize: Int64(entryBytes.count),
                                 compressionMethod: .deflate) { _, _ in entryBytes }
        }
    }

    @Test("a missing native entry refuses the import and creates no new canvas")
    func missingEntryRefused() throws {
        let exportRoot = try tempRoot("missing-entry")
        defer { try? FileManager.default.removeItem(at: exportRoot) }
        let restoredRoot = try tempRoot("missing-entry-restore")
        defer { try? FileManager.default.removeItem(at: restoredRoot) }
        _ = try layout(root: restoredRoot)

        let canvasID = UUID()
        _ = try writePackage(root: exportRoot, canvasID: canvasID,
                             name: "Widget.floecad", files: packageFiles())
        let destination = exportRoot.appendingPathComponent("canvas.floeCanvas")
        try CanvasBackupPackage.exportToURL(
            project: makeProject(canvasID: canvasID, packageName: "Widget.floecad"),
            destination: destination, layout: try layout(root: exportRoot))

        // A pre-existing package of ANOTHER canvas must survive the refusal.
        let existingCanvas = UUID()
        let sentinel = try writePackage(root: restoredRoot, canvasID: existingCanvas,
                                        name: "Existing.floecad",
                                        files: ["keep.bin": Data([0xAA])])

        try tamperArchive(destination, removeNativeEntry: true)
        #expect(throws: (any Error).self) {
            _ = try CanvasBackupPackage.restore(fileURL: destination, floeRoot: restoredRoot)
        }
        #expect(try Data(contentsOf: sentinel.appendingPathComponent("keep.bin")) == Data([0xAA]),
                "a refused import must not touch existing package data")
        let canvasDirectories = try FileManager.default.contentsOfDirectory(
            at: restoredRoot.appendingPathComponent("CanvasCAD", isDirectory: true),
            includingPropertiesForKeys: nil)
        #expect(canvasDirectories.map(\.lastPathComponent) == [existingCanvas.uuidString],
                "a refused import must not create a new canvas package directory")
    }

    @Test("a corrupt native entry (hash mismatch) refuses the import")
    func corruptEntryRefused() throws {
        let exportRoot = try tempRoot("corrupt-entry")
        defer { try? FileManager.default.removeItem(at: exportRoot) }
        let restoredRoot = try tempRoot("corrupt-entry-restore")
        defer { try? FileManager.default.removeItem(at: restoredRoot) }
        _ = try layout(root: restoredRoot)

        let canvasID = UUID()
        _ = try writePackage(root: exportRoot, canvasID: canvasID,
                             name: "Widget.floecad", files: packageFiles())
        let destination = exportRoot.appendingPathComponent("canvas.floeCanvas")
        try CanvasBackupPackage.exportToURL(
            project: makeProject(canvasID: canvasID, packageName: "Widget.floecad"),
            destination: destination, layout: try layout(root: exportRoot))

        try tamperArchive(destination, removeNativeEntry: false)
        #expect(throws: (any Error).self) {
            _ = try CanvasBackupPackage.restore(fileURL: destination, floeRoot: restoredRoot)
        }
        let canvasDirectory = restoredRoot.appendingPathComponent("CanvasCAD", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: canvasDirectory, includingPropertiesForKeys: nil)) ?? []
        #expect(entries.isEmpty, "a refused import must not leave a partial package")
    }

    // MARK: Duplicate / ambiguous payloads

    /// Rewrites the archive's manifest in place (used to simulate hostile or
    /// ambiguous backups the exporter itself would never write).
    private func rewriteManifest(_ destination: URL,
                                 mutate: (inout CanvasBackupPackage.Manifest) -> Void) throws {
        guard let archive = Archive(url: destination, accessMode: .update) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let entry = try #require(archive.first { $0.path == CanvasBackupPackage.manifestEntry })
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifest-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: temporary) }
        _ = try archive.extract(entry, to: temporary)
        var manifest = try JSONDecoder().decode(CanvasBackupPackage.Manifest.self,
                                                from: Data(contentsOf: temporary))
        mutate(&manifest)
        let bytes = try JSONEncoder().encode(manifest)
        try archive.remove(entry)
        try archive.addEntry(with: CanvasBackupPackage.manifestEntry, type: .file,
                             uncompressedSize: Int64(bytes.count),
                             compressionMethod: .deflate) { _, _ in bytes }
    }

    private func exportOnePackageArchive(_ label: String) throws -> (URL, URL) {
        let root = try tempRoot(label)
        let canvasID = UUID()
        _ = try writePackage(root: root, canvasID: canvasID,
                             name: "Widget.floecad", files: packageFiles())
        let destination = root.appendingPathComponent("canvas.floeCanvas")
        try CanvasBackupPackage.exportToURL(
            project: makeProject(canvasID: canvasID, packageName: "Widget.floecad"),
            destination: destination, layout: try layout(root: root))
        return (root, destination)
    }

    @Test("duplicate package identities are refused instead of ambiguously remapped")
    func duplicateIdentityRefused() throws {
        let (root, destination) = try exportOnePackageArchive("dup-identity")
        defer { try? FileManager.default.removeItem(at: root) }
        let restoredRoot = try tempRoot("dup-identity-restore")
        defer { try? FileManager.default.removeItem(at: restoredRoot) }
        _ = try layout(root: restoredRoot)

        try rewriteManifest(destination) { manifest in
            if let first = manifest.nativeCADPackages.first {
                manifest.nativeCADPackages.append(first)
            }
        }
        #expect(throws: (any Error).self) {
            _ = try CanvasBackupPackage.restore(fileURL: destination, floeRoot: restoredRoot)
        }
    }

    @Test("duplicate normalized file paths inside a package are refused")
    func duplicateNormalizedPathRefused() throws {
        let (root, destination) = try exportOnePackageArchive("dup-path")
        defer { try? FileManager.default.removeItem(at: root) }
        let restoredRoot = try tempRoot("dup-path-restore")
        defer { try? FileManager.default.removeItem(at: restoredRoot) }
        _ = try layout(root: restoredRoot)

        try rewriteManifest(destination) { manifest in
            guard var package = manifest.nativeCADPackages.first,
                  let firstFile = package.files.first else { return }
            // Same destination, different entry name: without a guard the
            // second write would silently overwrite the first.
            var colliding = firstFile
            colliding.file = "nativecad/9999-collision.bin"
            package.files.append(colliding)
            manifest.nativeCADPackages[0] = package
        }
        #expect(throws: (any Error).self) {
            _ = try CanvasBackupPackage.restore(fileURL: destination, floeRoot: restoredRoot)
        }
    }

    // MARK: Missing packages

    @Test("a missing bound package is rebound to the NEW canvas namespace, never the original")
    func missingPackageReboundToNewNamespace() throws {
        let root = try tempRoot("missing-rebind")
        defer { try? FileManager.default.removeItem(at: root) }
        let restoredRoot = try tempRoot("missing-rebind-restore")
        defer { try? FileManager.default.removeItem(at: restoredRoot) }
        _ = try layout(root: restoredRoot)

        let canvasID = UUID()
        let name = "Absent.floecad"
        let destination = root.appendingPathComponent("canvas.floeCanvas")
        try CanvasBackupPackage.exportToURL(
            project: makeProject(canvasID: canvasID, packageName: name),
            destination: destination, layout: try layout(root: root))

        let restored = try CanvasBackupPackage.restore(fileURL: destination,
                                                       floeRoot: restoredRoot)
        let node = try #require(restored.project.documents.first?.nodes.first)
        let expected = CanvasCADBindingKey.key(canvasID: restored.project.id,
                                               packageFileName: name)
        #expect(node.metadata[bindingKey] == expected,
                "a missing package must not leave a binding into the ORIGINAL canvas")
        #expect(node.metadata[bindingKey] != CanvasCADBindingKey.key(canvasID: canvasID,
                                                                     packageFileName: name))
        // And it truly stays missing: no directory was invented.
        let absent = restoredRoot.appendingPathComponent("CanvasCAD", isDirectory: true)
            .appendingPathComponent(restored.project.id.uuidString, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: absent.path))
    }

    // MARK: Compatibility

    @Test("older backups without the native-CAD fields still decode and restore")
    func legacyManifestWithoutNativeFieldsDecodes() throws {
        // A manifest JSON written before the field existed.
        let legacyJSON = Data("""
        {"formatVersion":1,"canvasID":"\(UUID().uuidString)","canvasName":"Old",
         "canvasSchemaVersion":1,"canvasByteCount":0,"canvasSHA256":"",
         "childProjects":[],"materials":[],"assets":[],
         "missingChildProjects":[],"missingAssets":[]}
        """.utf8)
        let manifest = try JSONDecoder().decode(CanvasBackupPackage.Manifest.self, from: legacyJSON)
        #expect(manifest.nativeCADPackages.isEmpty)
        #expect(manifest.missingNativeCADPackages.isEmpty)
        #expect(manifest.externalNodeAssets.isEmpty)

        // And a full export with no native root restores cleanly.
        let root = try tempRoot("legacy")
        defer { try? FileManager.default.removeItem(at: root) }
        let restoredRoot = try tempRoot("legacy-restore")
        defer { try? FileManager.default.removeItem(at: restoredRoot) }
        _ = try layout(root: restoredRoot)
        let document = CanvasDocument(name: "Doc", nodes: [])
        let project = CanvasProject(
            id: UUID(), name: "Legacy",
            documents: [document],
            selectedDocumentID: document.id)
        let destination = root.appendingPathComponent("legacy.floeCanvas")
        try CanvasBackupPackage.exportToURL(
            project: project, destination: destination,
            layout: try layout(root: root, includeNativeCAD: false))
        let restored = try CanvasBackupPackage.restore(fileURL: destination,
                                                       floeRoot: restoredRoot)
        #expect(restored.restoredNativeCADPackageCount == 0)
    }
}
