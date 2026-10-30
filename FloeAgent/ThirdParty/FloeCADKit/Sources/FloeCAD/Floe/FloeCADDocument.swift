//
//  FloeCADDocument.swift
//  FloeCADKit
//
//  Public entry point for one open FloeCAD document: versioned package,
//  kernel session, headless command executor, and the workbench view model the
//  Floe app embeds. Everything below the facade (kernel types, feature graph,
//  OCCT bridge) stays internal so host code cannot bypass the transaction and
//  persistence rules.
//

import Foundation
import simd

// MARK: - Public results

public nonisolated struct CADSaveOutcome: Sendable, Equatable {
    public var revision: Int
    public var contentSHA256: String
    /// ADDITIVE canonical model identity (user-editable name/unit/tolerance +
    /// document records + blobs; preview excluded); empty when the package
    /// predates the manifest field. The existing `contentSHA256` semantics
    /// are unchanged.
    public var modelSHA256: String = ""
    public var error: String?

    public var succeeded: Bool { error == nil }
}

public nonisolated struct CADDocumentSummary: Sendable, Equatable {
    public var name: String
    public var revision: Int
    public var contentSHA256: String
    public var schemaVersion: Int
    public var unit: String?
    public var tolerance: Double?
    public var bodyCount: Int
    public var sketchCount: Int
    public var featureCount: Int
    public var variableCount: Int
    public var hasAssembly: Bool
    public var drawingPageCount: Int
    public var isReadOnly: Bool
}

public nonisolated struct CADCommandOutcome: Sendable {
    public var status: Int
    public var payload: Data
    public var errorCode: String?
    public var message: String?
    public var isOK: Bool { status >= 200 && status < 300 }
}

public nonisolated struct CADDocumentError: Error, LocalizedError, Sendable {
    public var code: String
    public var message: String
    public var errorDescription: String? { message }

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

// MARK: - Document

@MainActor
public final class FloeCADDocument {
    public let url: URL
    public private(set) var name: String
    public private(set) var revision: Int
    public private(set) var contentSHA256: String

    let project: Project
    let context: CADModelContext
    let store: FileCADDocumentStore
    let session: DocumentSession

    private var cachedViewModel: EditorViewModel?
    private var closed = false
    /// `session.changeCount` at the last successful commit. Used to decide
    /// whether a proposal preview must flush first; a clean document is never
    /// re-committed just to draft a preview.
    private var lastCommittedChangeCount = 0

    private init(url: URL,
                 project: Project,
                 store: FileCADDocumentStore,
                 session: DocumentSession) {
        self.url = url
        self.name = project.name
        self.store = store
        self.project = project
        self.context = CADModelContext(project: project, store: store)
        self.session = session
        self.revision = store.revision
        self.contentSHA256 = store.contentSHA256
        self.lastCommittedChangeCount = session.changeCount
    }

    // MARK: Open / create

    /// Open a `.floecad` package. A missing package throws; a package written
    /// by a newer schema opens read-only (`isReadOnly`) and never rewrites.
    /// Package reading (JSON decode + blob file I/O) runs off the main actor.
    public static func open(at url: URL) async throws -> FloeCADDocument {
        let store = FileCADDocumentStore(packageURL: url)
        let project = try await Task.detached(priority: .userInitiated) {
            try store.read()
        }.value
        let context = CADModelContext(project: project, store: store)
        let session = DocumentSession(project: project, modelContext: context)
        return FloeCADDocument(url: url, project: project, store: store, session: session)
    }

    /// Verified committed identity of a package on disk WITHOUT opening a
    /// live document: the versioned store reads the manifest, the document
    /// JSON and every blob, and the returned identity binds them (the
    /// content digest incorporates each blob's SHA-256). `modelSHA256` is the
    /// additive canonical model identity (document records + blobs, preview
    /// excluded) — nil on historical manifests that predate the field.
    /// Nil overall when the package is unreadable or corrupt. Recovery code
    /// must use this — hashing a package directory is meaningless, and
    /// trusting a bare manifest without the store's read path skips blob
    /// validation.
    public static func storedIdentity(at url: URL) async
    -> (revision: Int, contentSHA256: String, modelSHA256: String?)? {
        let store = FileCADDocumentStore(packageURL: url)
        do {
            _ = try await Task.detached(priority: .userInitiated) {
                try store.read()
            }.value
        } catch {
            return nil
        }
        return (store.revision, store.contentSHA256,
                store.modelSHA256.isEmpty ? nil : store.modelSHA256)
    }

    /// Create (or recreate) a package at `url`. An existing package is
    /// REPLACED only when `overwrite` is set, and even then it is staged and
    /// moved aside first: a failed create never deletes the previous document,
    /// which stays recoverable as the new package's `previous/` snapshot (or
    /// as a sibling backup if the swap itself failed).
    @discardableResult
    public static func create(at url: URL, name: String,
                              overwrite: Bool = false) async throws -> FloeCADDocument {
        let store = FileCADDocumentStore(packageURL: url)
        let exists = FileManager.default.fileExists(atPath: url.path)
        guard !exists || overwrite else {
            throw CADDocumentError(code: "exists",
                                   message: "A CAD document already exists at \(url.path).")
        }
        let project = Project(name: name)
        project.unitRaw = DisplayUnit.millimeters.rawValue
        let payload = try store.makePayload(project)
        try await Task.detached(priority: .userInitiated) {
            try FileCADDocumentStore.createPackage(at: url, payload: payload, overwrite: overwrite)
        }.value
        return try await open(at: url)
    }

    /// Internal factory for the proposal service's synchronous clone open and
    /// tests. The public surface uses `open`/`create`.
    static func make(url: URL, project: Project,
                     store: FileCADDocumentStore,
                     session: DocumentSession) -> FloeCADDocument {
        FloeCADDocument(url: url, project: project, store: store, session: session)
    }

    // MARK: Lifecycle

    public var isReadOnly: Bool { session.storeIsNewerThanApp }

    /// True when the in-memory document has edits that have not been written
    /// to the package. Assistant previews must flush these before snapshotting
    /// so a proposal can never be drafted against stale bytes.
    public var hasUnsavedChanges: Bool {
        session.changeCount != lastCommittedChangeCount
    }

    public func markClosed() {
        #if canImport(AVFoundation) && canImport(RealityKit) && canImport(UIKit)
        // A service-owned animation export keeps the document alive; closing
        // it must cancel the render lease and remove its staging directory
        // rather than let a late task promote a file for a released document.
        CADAnimationExportCenter.shared.cancelAll(
            documentKey: url.standardizedFileURL.path)
        #endif
        session.flushPendingAutosave()
        closed = true
        // Fence the store: waits out any in-flight commit and forbids later
        // ones, so the release/delete sequence cannot be resurrected by a
        // late asynchronous flush.
        store.revoke()
    }

    public func close() {
        markClosed()
    }

    /// True once this document was released (`close()`/`markClosed()`).
    /// A released document must never be written again: the editor's
    /// asynchronous close flush can still fire after a successful Cancel
    /// removed the package, and a late write would resurrect it (T7T).
    public var isClosed: Bool { closed }

    // MARK: Summary / queries

    public func summary() -> CADDocumentSummary {
        let document = session.document
        return CADDocumentSummary(
            name: name,
            revision: revision,
            contentSHA256: contentSHA256,
            schemaVersion: project.formatVersion,
            unit: project.unitRaw,
            tolerance: project.tolerance,
            bodyCount: document.bodies.count,
            sketchCount: document.sketches.count,
            featureCount: document.features.nodes.count,
            variableCount: document.variables.count,
            hasAssembly: session.document.assemblyData != nil,
            drawingPageCount: (try? CADDrawingSet.decode(from: session.document.drawingsData))?.pages.count ?? 0,
            isReadOnly: isReadOnly
        )
    }

    // MARK: Command execution

    /// Run one typed operation from the shared CAD command vocabulary
    /// (`AgentExec.opNames`). Never used directly by a model: the app tool
    /// gates propose/apply, grants and CAS around this call.
    @discardableResult
    public func execute(_ operation: [String: Any], documentName: String? = nil) -> CADCommandOutcome {
        let executor = CADCommandExecutor(viewModel: viewModel(), documentName: documentName ?? name)
        switch AgentExec.parse(operation) {
        case .failure(let error):
            return CADCommandOutcome(status: 400, payload: Self.jsonEnvelope(ok: false,
                                                                             error: error.code,
                                                                             message: error.message),
                                     errorCode: error.code, message: error.message)
        case .success(let op):
            let response = executor.run(op)
            return CADCommandOutcome(status: response.status,
                                     payload: response.body,
                                     errorCode: Self.errorCode(in: response.body),
                                     message: Self.errorMessage(in: response.body))
        }
    }

    public func executeJSON(_ json: Data) -> CADCommandOutcome {
        guard let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else {
            return CADCommandOutcome(status: 400,
                                     payload: Self.jsonEnvelope(ok: false, error: "bad_json",
                                                                message: "Body must be a JSON object with op/args."),
                                     errorCode: "bad_json",
                                     message: "Body must be a JSON object with op/args.")
        }
        return execute(object)
    }

    /// JSON snapshot of document state (bodies, sketches, features, units,
    /// selection, measurements) — the AI `describe/read` payload.
    public func snapshotJSON() -> Data {
        let executor = CADCommandExecutor(viewModel: viewModel(), documentName: name)
        let snapshot = executor.snapshot()
        return (try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]))
            ?? Data(#"{"ok":false}"#.utf8)
    }

    /// Deterministic measurement. Accepted requests:
    ///   {"kind":"body","bodyID":"<uuid>"}        volume mm³, surface area mm²,
    ///                                            bounds, analytic flag
    ///   {"kind":"distance","points":[[x,y,z],[x,y,z]]}
    ///   {"kind":"bounds","bodyIDs":["<uuid>",...]}
    /// Numbers come from the kernel (OCCT volume for analytic B-rep, exact
    /// triangle geometry for mesh), never from a rendered image.
    public func measureJSON(_ request: [String: Any]) -> CADCommandOutcome {
        let document = session.document
        func body(_ id: Any?) -> Body? {
            guard let raw = id as? String, let uuid = UUID(uuidString: raw) else { return nil }
            return document.bodies.first { $0.id.raw == uuid }
        }
        func vector(_ raw: Any?) -> SIMD3<Double>? {
            guard let values = raw as? [Double], values.count == 3,
                  values.allSatisfy(\.isFinite) else { return nil }
            return SIMD3(values[0], values[1], values[2])
        }
        func ok(_ payload: [String: Any]) -> CADCommandOutcome {
            var object = payload
            object["ok"] = true
            return CADCommandOutcome(status: 200,
                                     payload: (try? JSONSerialization.data(withJSONObject: object,
                                                                           options: [.sortedKeys]))
                                        ?? Data("{}".utf8),
                                     errorCode: nil, message: nil)
        }
        func fail(_ code: String, _ message: String) -> CADCommandOutcome {
            CADCommandOutcome(status: 400,
                              payload: (try? JSONSerialization.data(withJSONObject:
                                        ["ok": false, "error": code, "message": message],
                                        options: [.sortedKeys])) ?? Data("{}".utf8),
                              errorCode: code, message: message)
        }
        switch request["kind"] as? String ?? "body" {
        case "body":
            guard let target = body(request["bodyID"]) else {
                return fail("unknown_body", "bodyID must be a body UUID from the snapshot.")
            }
            var payload: [String: Any] = [
                "kind": "body",
                "bodyID": target.id.raw.uuidString,
                "name": target.name,
                "volumeMM3": MeasureKit.volume(of: target),
                "surfaceAreaMM2": MeasureKit.surfaceArea(target.render),
                "analyticBRep": target.brep != nil,
            ]
            if let bounds = MeasureKit.boundingBox(bodies: [target]) {
                payload["bounds"] = [[bounds.min.x, bounds.min.y, bounds.min.z],
                                     [bounds.max.x, bounds.max.y, bounds.max.z]]
            }
            return ok(payload)
        case "distance":
            guard let values = request["points"] as? [[Double]], values.count == 2,
                  let a = vector(values[0]), let b = vector(values[1]) else {
                return fail("bad_points", "points must be two [x,y,z] rows in mm.")
            }
            return ok(["kind": "distance", "distanceMM": simd_length(b - a),
                       "start": [a.x, a.y, a.z], "end": [b.x, b.y, b.z]])
        case "bounds":
            let ids = (request["bodyIDs"] as? [String]) ?? []
            let bodies = ids.compactMap { raw -> Body? in
                guard let uuid = UUID(uuidString: raw) else { return nil }
                return document.bodies.first { $0.id.raw == uuid }
            }
            guard bodies.count == ids.count, !bodies.isEmpty else {
                return fail("unknown_body", "bodyIDs must all resolve to document bodies.")
            }
            guard let bounds = MeasureKit.boundingBox(bodies: bodies) else {
                return fail("empty_geometry", "The selected bodies carry no geometry.")
            }
            let size = bounds.max - bounds.min
            return ok(["kind": "bounds",
                       "min": [bounds.min.x, bounds.min.y, bounds.min.z],
                       "max": [bounds.max.x, bounds.max.y, bounds.max.z],
                       "size": [size.x, size.y, size.z]])
        default:
            return fail("unsupported_measure",
                        "kind must be body, distance or bounds.")
        }
    }

    // MARK: Save

    /// Commit the document package off the main actor. Refuses to rewrite a
    /// newer schema (read-only open) and returns the new revision + content
    /// SHA for compare-and-swap. OCCT serialization of changed solids is
    /// pre-warmed detached; JSON encoding, hashing and file I/O run detached
    /// against the revision-guarded store.
    @discardableResult
    public func save() async -> CADSaveOutcome {
        // A released document is ownerless: a late editor flush (the
        // fullscreen cover dismissing after a successful Cancel already
        // deleted the package) must be a no-op rather than re-create the
        // package from the still-cached in-memory session.
        guard !closed else {
            return CADSaveOutcome(revision: revision, contentSHA256: contentSHA256,
                                  modelSHA256: store.modelSHA256,
                                  error: "The CAD document is closed and cannot be saved.")
        }
        guard !isReadOnly else {
            return CADSaveOutcome(revision: revision, contentSHA256: contentSHA256,
                                  modelSHA256: store.modelSHA256,
                                  error: "This CAD document uses a newer format and is read-only.")
        }
        // Pin the generation BEFORE any await. An edit arriving while a save
        // is in flight must not be acknowledged as part of its older payload.
        // The session path may include a newer edit during serialization; in
        // that case retaining a dirty flag is deliberately conservative.
        let savedChangeCount = session.changeCount
        if savedChangeCount == lastCommittedChangeCount, session.lastSaveError == nil {
            // No document commands ran since the validated load/last save.
            // Preserve its opaque record/B-rep bytes. Re-encoding a loaded
            // transform/sketch/feature with JSONEncoder's unspecified key
            // order (and reserializing B-reps) changes those bytes despite an
            // unchanged model. The historical model digest intentionally
            // includes them; do not redefine the digest to hide that churn.
            // Project metadata and thumbnail updates still enter the payload.
            do {
                project.modifiedAt = Date()
                let payload = try store.makePayload(project)
                let targetStore = store
                let committed = try await Task.detached(priority: .utility) {
                    try Self.writePreparedPayload(payload, to: targetStore)
                }.value
                if committed.0 >= revision {
                    revision = committed.0
                    contentSHA256 = committed.1
                }
                lastCommittedChangeCount = max(lastCommittedChangeCount, savedChangeCount)
                return CADSaveOutcome(revision: committed.0, contentSHA256: committed.1,
                                      modelSHA256: committed.2, error: nil)
            } catch {
                return CADSaveOutcome(revision: store.revision, contentSHA256: store.contentSHA256,
                                      modelSHA256: store.modelSHA256, error: error.localizedDescription)
            }
        }
        await session.saveAsync()
        if let error = session.lastSaveError {
            return CADSaveOutcome(revision: store.revision, contentSHA256: store.contentSHA256,
                                  modelSHA256: store.modelSHA256, error: error)
        }
        revision = store.revision
        contentSHA256 = store.contentSHA256
        lastCommittedChangeCount = max(lastCommittedChangeCount, savedChangeCount)
        return CADSaveOutcome(revision: revision, contentSHA256: contentSHA256,
                              modelSHA256: store.modelSHA256, error: nil)
    }

    // Keep the entire hashing/commit boundary explicitly nonisolated. With
    // default MainActor isolation, an inline detached closure can otherwise
    // infer actor isolation from its synchronous work and hop back to main,
    // blocking the actor while a competing package writer holds the gate.
    private nonisolated static func writePreparedPayload(
        _ payload: CADWritePayload, to store: FileCADDocumentStore
    ) throws -> (revision: Int, contentSHA256: String, modelSHA256: String) {
        let modelSHA = try FileCADDocumentStore.modelDigest(
            name: payload.name, unit: payload.unit, tolerance: payload.tolerance,
            document: payload.document, blobs: payload.blobs)
        let result = try store.performWrite(payload)
        return (result.revision, result.contentSHA256, modelSHA)
    }

    /// Flush only when there is something to flush; used by the proposal
    /// service so a clean document's revision/SHA identity is stable.
    @discardableResult
    func flushIfDirty() async -> CADSaveOutcome? {
        guard hasUnsavedChanges else { return nil }
        return await save()
    }

    /// The workbench's close/background/flush preview commit, with explicit
    /// viewport bytes: records `png` exactly like
    /// `EditorViewModel.saveThumbnail()` then commits through the SAME
    /// verified, revision-guarded store save. `contentSHA256` keeps its
    /// existing semantics (the preview artifact is part of it); the additive
    /// `modelSHA256` stays stable across preview-only commits.
    ///
    /// A CLOSED document is rejected BEFORE the in-memory session is touched:
    /// a late flush must neither write nor mutate a released draft.
    @discardableResult
    public func saveViewportPreview(_ png: Data?) async -> CADSaveOutcome {
        guard !closed else {
            return CADSaveOutcome(revision: revision, contentSHA256: contentSHA256,
                                  modelSHA256: store.modelSHA256,
                                  error: "The CAD document is closed and cannot be saved.")
        }
        if let png, !png.isEmpty {
            session.project.thumbnail = png
        }
        return await save()
    }

    // MARK: View model

    func viewModel() -> EditorViewModel {
        if let cachedViewModel { return cachedViewModel }
        let model = EditorViewModel(session: session)
        cachedViewModel = model
        return model
    }

    // MARK: Helpers

    private static func jsonEnvelope(ok: Bool, error: String, message: String) -> Data {
        let object: [String: Any] = ["ok": ok, "error": error, "message": message]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data(#"{"ok":false,"error":"encoding_failed","message":"\#(message)"}"#.utf8)
    }

    private static func errorCode(in data: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        return object["error"] as? String
    }

    private static func errorMessage(in data: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        return object["message"] as? String
    }
}
