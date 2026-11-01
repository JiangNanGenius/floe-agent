// SPDX-License-Identifier: MPL-2.0
// FloeApp — DEBUG-only E26 native UI fixture for IGES open surfaces.
//
// Launch with `-ui-testing --ui-test-cad-fixture` plus exactly ONE of:
//   --ui-test-cad-iges-surface-import
//   --ui-test-cad-iges-surface-export
//
// The fixture builds a REAL workspace-owned `.floecad` package through the
// same `FloeCADDocument` services the product uses:
//   * a closed plate Extrude (analytic B-rep),
//   * a mesh-only OBJ import (a genuine mesh body with no exact B-rep),
//   * for the export flow, ONE exact open IGES surface imported through the
//     production `nativeImportData` path.
//
// The IGES bytes themselves come from OCCT's own writer over a standalone
// exact face (`CADDebugFixtures.openSurfaceIGES`) — never a hand-authored
// string, a renamed mesh or a copied glTF payload.
//
// The import flow additionally drafts a pending import proposal through the
// SAME host action the assistant uses (`CadDocumentCenter.threeDAction`
// kind=import), so `FilePreviewView` shows its shipped pre-Apply banner:
// exact open surface, the move/rotate/scale/material/IGES limit, and the
// Apply/Discard buttons. Nothing is fabricated: the proposal preview is the
// real throwaway-copy import, the source bytes are content-addressed in their
// file name, and the test reads that identity back from the real banner.
//
// Everything here is DEBUG-only and gated on the two launch arguments. The
// fixture owns a fixed synthetic conversation/workspace under
// `PrivateTasks/<fixed UUID>` and removes only that directory when reseeding;
// no user conversation, workspace or file is read, changed or deleted.
//
// Root owns compilation and the real Simulator run; this file is source-ready.

#if DEBUG && canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeCAD
import FloeCore
import FloeModels
import FloePersistence
import FloeWorkbench

@MainActor
enum CADIGESSurfaceUIFixture {
    enum Mode: String, CaseIterable {
        /// A pending exact-open-surface import proposal over a plate + mesh
        /// document: the pre-Apply banner flow, then Apply.
        case importPreview = "--ui-test-cad-iges-surface-import"
        /// A saved plate + exact open surface + mesh document: the part-scope
        /// IGES exchange receipt and the explicit partial-export consent flow.
        case exportCoverage = "--ui-test-cad-iges-surface-export"

        static func selected(from arguments: [String]) -> Mode? {
            allCases.first { arguments.contains($0.rawValue) }
        }
    }

    struct Prepared {
        let workspaceRelativePath: String
        let conversationID: UUID
    }

    /// Fixed synthetic identities. They are never a user's task/workspace.
    static let conversationID = UUID(uuidString: "E26C0DE0-0000-4000-8000-00000000E261")!
    static let conversationTitle = "E26 IGES open-surface fixture"
    static let documentName = "E26 IGES open surface"
    static let documentRelativePath = "IGESOpenSurface.floecad"
    static let meshFileName = "MeshOnly.obj"
    static let meshBodyName = "MeshOnly.obj"

    /// Build/open the fixture workspace and return the relative path the real
    /// `FilePreviewView` should present.
    static func prepare(mode: Mode,
                        in environment: AppEnvironment) async throws -> Prepared {
        try await waitForPersistence(environment)
        try await ensureFixtureConversation(environment)
        try await environment.workspaceCenter.openTaskWorkspace(conversationID: conversationID)
        guard let root = environment.workspaceCenter.currentRootURL else {
            throw fixtureError("The E26 fixture could not open its task workspace.")
        }
        // Never delete anything but this fixture's own app-private task root.
        // A synthetic conversation could only have been reassigned by an
        // external actor; refuse instead of touching that directory.
        guard let workspace = environment.workspaceCenter.currentWorkspace,
              workspace.kind == .privateTask,
              workspace.internalRelativePath == "PrivateTasks/\(conversationID.uuidString)" else {
            throw fixtureError("The E26 fixture workspace is not its own private task root.")
        }
        // Reset ONLY this fixture's private-task directory so every run starts
        // from the same saved package. The synthetic conversation id is not
        // used by product data or another fixture.
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let seed = try await seedDocument(mode: mode, root: root)
        var proposalID: UUID?
        if mode == .importPreview {
            let sourceURL = root.appendingPathComponent(seed.sourceFileName)
            try seed.igesData.write(to: sourceURL, options: .atomic)
            guard try FloeDigest.sha256Hex(ofFileAt: sourceURL).lowercased()
                    == seed.sourceSHA256.lowercased() else {
                throw fixtureError("The written IGES source bytes do not match their digest.")
            }
            proposalID = try await draftImportProposal(
                sourceFileName: seed.sourceFileName,
                sourceSHA256: seed.sourceSHA256,
                documentURL: seed.documentURL,
                root: root,
                environment: environment)
        }
        try writeManifest(mode: mode, seed: seed, proposalID: proposalID)
        return Prepared(workspaceRelativePath: documentRelativePath,
                        conversationID: conversationID)
    }

    // MARK: - Fixture document

    private struct SeedResult {
        let documentURL: URL
        let workspaceRoot: URL
        let documentRevision: Int
        let documentContentSHA256: String
        let bodyCount: Int
        let sketchCount: Int
        let featureCount: Int
        let sourceFileName: String
        let sourceSHA256: String
        let sourceByteCount: Int
        let igesData: Data
    }

    private static func seedDocument(mode: Mode, root: URL) async throws -> SeedResult {
        let documentURL = root.appendingPathComponent(documentRelativePath)
        let document = try await FloeCADDocument.create(at: documentURL, name: documentName)
        do {
            // A real closed plate through the typed feature vocabulary.
            let sketch = try run(document,
                                 #"{"op":"sketch.create","args":{"name":"Plate"}}"#)
            guard let sketchID = sketch["sketchID"] as? String else {
                throw fixtureError("The E26 fixture plate sketch was not created.")
            }
            try run(document, """
            {"op":"sketch.addEntities","args":{"sketchID":"\(sketchID)",
             "entities":[{"kind":"rect","min":[0,0],"max":[100,60]}]}}
            """)
            try run(document, """
            {"op":"feature.extrude","args":{"sketchID":"\(sketchID)",
             "seedPoint":[50,30],"distance":10}}
            """)

            // A real mesh-only body through the production OBJ import path:
            // no analytic or exact open-surface B-rep, so exchange coverage
            // must exclude it from IGES.
            let mesh = document.nativeImportData(Data(meshOBJ.utf8), format: "obj",
                                                 fileName: meshFileName, unitScale: nil)
            guard mesh.isOK else {
                throw fixtureError("The E26 fixture mesh import failed: "
                    + "\(mesh.errorCode ?? "") \(mesh.message ?? "")")
            }

            // Real OCCT-written IGES bytes for one standalone exact face.
            // Offset only places the sheet clear of the plate and mesh in
            // the viewport; it is still the same OCCT-written open face.
            let igesData = try CADDebugFixtures.openSurfaceIGES(
                offset: SIMD3<Double>(200, 0, 0))
            let digest = FloeDigest.sha256Hex(igesData).lowercased()
            let sourceFileName = "OpenSurface-\(digest.prefix(12)).igs"

            if mode == .exportCoverage {
                let imported = document.nativeImportData(
                    igesData, format: "iges", fileName: sourceFileName, unitScale: nil)
                guard imported.isOK else {
                    throw fixtureError("The E26 fixture IGES surface import failed: "
                        + "\(imported.errorCode ?? "") \(imported.message ?? "")")
                }
                let payload = (try? JSONSerialization.jsonObject(with: imported.payload))
                    as? [String: Any] ?? [:]
                guard (payload["solidsImported"] as? Int) == 0,
                      (payload["surfacesImported"] as? Int) == 1,
                      (payload["openSurfaceBodies"] as? Int) == 1 else {
                    throw fixtureError(
                        "The E26 fixture IGES file must import exactly one exact open surface, "
                            + "not a solid or mesh: \(payload)")
                }
                let rowsOutcome = document.nativeQueryJSON(["scope": "bodies"])
                let rows = (try? JSONSerialization.jsonObject(with: rowsOutcome.payload))
                    as? [String: Any]
                let openSurfaces = (rows?["rows"] as? [[String: Any]] ?? [])
                    .filter { ($0["openSurfaceBRep"] as? Bool) == true }
                guard rowsOutcome.isOK, openSurfaces.count == 1 else {
                    throw fixtureError(
                        "The E26 fixture surface body must keep exactly one exact open handle.")
                }
            }

            let save = await document.save()
            guard save.succeeded else {
                throw fixtureError("The E26 fixture package could not be saved: "
                    + (save.error ?? "unknown error"))
            }
            let summary = document.summary()
            let result = SeedResult(
                documentURL: documentURL,
                workspaceRoot: root,
                documentRevision: document.revision,
                documentContentSHA256: document.contentSHA256,
                bodyCount: summary.bodyCount,
                sketchCount: summary.sketchCount,
                featureCount: summary.featureCount,
                sourceFileName: sourceFileName,
                sourceSHA256: digest,
                sourceByteCount: igesData.count,
                igesData: igesData)
            // The bridge/FilePreviewView must own the live session; a second
            // instance on the same package is never allowed.
            document.close()
            return result
        } catch {
            document.close()
            throw error
        }
    }

    // MARK: - Real import proposal

    private static func draftImportProposal(sourceFileName: String,
                                            sourceSHA256: String,
                                            documentURL: URL,
                                            root: URL,
                                            environment: AppEnvironment) async throws -> UUID {
        let request: [String: Any] = [
            "kind": "import",
            "summary": "Import \(sourceFileName) (IGES)",
            "payload": [
                "path": sourceFileName,
                "format": "iges",
            ],
        ]
        let requestJSON = String(
            decoding: try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]),
            as: UTF8.self)
        let access = CadDocumentCenter.uiAccess(
            workspaceRoot: root, conversationID: conversationID, environmentID: nil)
        let reply = try await environment.cadDocumentCenter.threeDAction(
            documentID: documentRelativePath, requestJSON: requestJSON, access: access)
        guard let data = reply.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["ok"] as? Bool == true,
              let proposal = object["proposal"] as? [String: Any],
              let rawID = proposal["id"] as? String,
              let proposalID = UUID(uuidString: rawID) else {
            throw fixtureError("The E26 import proposal was refused: \(reply)")
        }
        let info = object["import"] as? [String: Any] ?? [:]
        guard (info["geometry_class"] as? String) == "surface",
              (info["solid_bodies"] as? Int) == 0,
              (info["surface_bodies"] as? Int) == 1,
              (info["open_surface_bodies"] as? Int) == 1 else {
            throw fixtureError(
                "The E26 import preview must classify exactly one exact open surface: \(info)")
        }
        // The banner reads THIS in-process list and frozen import spec; verify
        // the real service state rather than trusting the reply alone.
        guard FloeCAD3DBridge.shared.pendingProposals(for: documentURL)
                .contains(where: { $0.id == proposalID }) else {
            throw fixtureError("The E26 import proposal is not pending for its document.")
        }
        guard let spec = FloeCAD3DBridge.shared.importSpec(for: proposalID),
              spec.sourceSHA256.lowercased() == sourceSHA256.lowercased(),
              spec.fileName == sourceFileName else {
            throw fixtureError("The E26 import proposal does not freeze the exact source bytes.")
        }
        return proposalID
    }

    // MARK: - Workspace/store setup

    private static func waitForPersistence(_ environment: AppEnvironment) async throws {
        let deadline = Date().addingTimeInterval(90)
        while !environment.persistenceReady {
            guard Date() < deadline else {
                throw fixtureError("The App database was not ready for the E26 fixture.")
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private static func ensureFixtureConversation(_ environment: AppEnvironment) async throws {
        if try await environment.conversationStore.conversation(id: conversationID) == nil {
            try await environment.conversationStore.saveConversation(ConversationRecord(
                id: conversationID,
                title: conversationTitle,
                createdAt: Date(),
                updatedAt: Date()))
        }
    }

    // MARK: - Manifest (app-owned fixture evidence)

    private static func writeManifest(mode: Mode, seed: SeedResult,
                                      proposalID: UUID?) throws {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let directory = support
            .appendingPathComponent("FloeAgent/CADFixtures/E26IGESSurfaceUI", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var manifest: [String: Any] = [
            "schema": 1,
            "mode": mode.rawValue,
            "generated_at": ISO8601DateFormatter().string(from: Date()),
            "fixture_origin": "OCCT debugStandaloneFace + debugWriteIGES single open face; "
                + "closed plate Extrude and mesh-only OBJ import through production document services",
            "conversation_id": conversationID.uuidString,
            "workspace_root": seed.workspaceRoot.path,
            "document_relative_path": documentRelativePath,
            // Pre-Apply saved identity. The import flow's Apply commits a
            // later revision; Root reads that receipt from the real UI run.
            "base_document_revision": seed.documentRevision,
            "base_document_content_sha256": seed.documentContentSHA256,
            "base_body_count": seed.bodyCount,
            "base_sketch_count": seed.sketchCount,
            "base_feature_count": seed.featureCount,
            "source_file_name": seed.sourceFileName,
            "source_sha256": seed.sourceSHA256,
            "source_byte_count": seed.sourceByteCount,
            "source_representation": "exact OCCT IGES standalone face (open sheet)",
            "mesh_body": meshBodyName,
            "note": "The UI test reads the content-addressed source name from the shipped "
                + "banner and asserts the same digest on the imported body row. "
                + "No bytes were authored outside the native OCCT writer.",
        ]
        if let proposalID {
            manifest["proposal_id"] = proposalID.uuidString
        }
        let data = try JSONSerialization.data(withJSONObject: manifest,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
    }

    // MARK: - Helpers

    @discardableResult
    private static func run(_ document: FloeCADDocument,
                            _ json: String) throws -> [String: Any] {
        let outcome = document.executeJSON(Data(json.utf8))
        guard outcome.isOK,
              let object = try? JSONSerialization.jsonObject(with: outcome.payload)
                as? [String: Any] else {
            throw fixtureError("The E26 fixture command failed: "
                + "\(outcome.errorCode ?? "") \(outcome.message ?? json)")
        }
        return object
    }

    private static func fixtureError(_ message: String) -> CADDocumentError {
        CADDocumentError(code: "fixture_failed", message: message)
    }

    /// One real 10 mm cube as ASCII OBJ. It is a legitimate mesh-only body
    /// (the importer recomputes normals); it is not used as proof of any
    /// surface/IGES path.
    private static let meshOBJ = """
    v 150 0 0
    v 160 0 0
    v 160 10 0
    v 150 10 0
    v 150 0 10
    v 160 0 10
    v 160 10 10
    v 150 10 10
    f 1 2 3
    f 1 3 4
    f 5 8 7
    f 5 7 6
    f 1 5 6
    f 1 6 2
    f 2 6 7
    f 2 7 3
    f 3 7 8
    f 3 8 4
    f 4 8 5
    f 4 5 1
    """
}
#endif
