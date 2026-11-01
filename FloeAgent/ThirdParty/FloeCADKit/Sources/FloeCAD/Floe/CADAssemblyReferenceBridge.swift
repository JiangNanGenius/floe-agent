//
//  CADAssemblyReferenceBridge.swift
//  FloeCADKit
//
//  App-owned staging bridge for external native part references (E01).
//
//  AUTHORITY BOUNDARY
//  ------------------
//  The kernel and the persisted assembly never open, resolve or scan an
//  external path. This bridge is called by the App only AFTER its existing
//  file/asset/workspace authority produced a user-authorized URL. It:
//
//    1. verifies the committed source identity through
//       `FloeCADDocument.storedIdentity` and an optional expected SHA-256
//       (compare-and-swap);
//    2. opens the source read-only enough to read its already-verified bodies;
//    3. refuses unsupported/future schemas and the target document itself;
//    4. copies the selected body into an immutable local staged body (owning
//       a deserialized B-rep when possible), and records only opaque identity,
//       versions and hashes — never a path — in `CADAssembly.partReferences`;
//    5. commits the body + assembly mutation as ONE undoable command.
//
//  An update re-reads the SAME source body identity, rejects a stale expected
//  source hash or staged-geometry hash, and replaces only the staged body. All
//  shared instances (including instances nested inside several subassemblies)
//  therefore see the new geometry; independent copies keep their owned
//  geometry/material state.
//

import Foundation

@MainActor
public final class CADAssemblyReferenceBridge {
    public init() {}

    private static let expectedExtension = "floecad"

    // MARK: - Inspection

    /// Read-only source inspection used by the native picker before a body is
    /// chosen. The URL must already have been authorized by the App host.
    public func inspectSource(at sourceURL: URL,
                              isCancelled: @Sendable () -> Bool = { false })
    async -> [String: Any] {
        if isCancelled() {
            return failure("cancelled", Self.cancelledMessage)
        }
        let prepared = prepareSourceURL(sourceURL, target: nil)
        guard case .success(let url) = prepared else {
            return failure("invalid_source", prepared.failureMessage)
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let identity = await FloeCADDocument.storedIdentity(at: url) else {
            return failure("source_unreadable",
                           "The native CAD package could not be verified; nothing was read.")
        }
        if isCancelled() {
            return failure("cancelled", Self.cancelledMessage)
        }
        do {
            let source = try await FloeCADDocument.open(at: url)
            defer { source.close() }
            if isCancelled() {
                return failure("cancelled", Self.cancelledMessage)
            }
            guard source.contentSHA256 == identity.contentSHA256 else {
                return failure("source_changed",
                               "The source package changed while it was being inspected; nothing was changed.")
            }
            let summary = source.summary()
            guard summary.schemaVersion <= FloeCADDocument.supportedPackageSchemaVersion else {
                return failure("source_newer_schema",
                               "This source package was written by a newer FloCAD format "
                                + "(\(summary.schemaVersion)); staging it is not supported in this build.")
            }
            let bodies = source.session.document.bodies.map { body -> [String: Any] in
                [
                    "id": body.id.raw.uuidString,
                    "name": body.name,
                    "triangleCount": body.render.triangleCount,
                    "hasAnalyticBRep": body.brep != nil,
                    "isHidden": body.isHidden,
                ]
            }
            return [
                "ok": true,
                "mutated": false,
                "documentName": summary.name,
                "sourceRevision": identity.revision,
                "sourceContentHash": identity.contentSHA256,
                "sourceSchemaVersion": summary.schemaVersion,
                "verifierSchemaVersion": FloeCADDocument.supportedPackageSchemaVersion,
                "bodyCount": bodies.count,
                "bodies": bodies,
            ]
        } catch {
            return failure("source_unreadable",
                           "The native CAD package could not be opened: \(error.localizedDescription)")
        }
    }

    // MARK: - Attach

    /// Stage one source body into `document` and place one shared reference
    /// instance. The returned dictionary contains `referenceID`, `instanceID`,
    /// `stagedBodyID`, the pinned source identity and the staged geometry hash.
    public func attach(sourceURL: URL,
                       to document: FloeCADDocument,
                       name: String? = nil,
                       sourceBodyID: UUID? = nil,
                       sourceDocumentID: UUID = UUID(),
                       expectedSourceContentHash: String? = nil,
                       transform: CADTransform = .identity,
                       isCancelled: @Sendable () -> Bool = { false }) async -> [String: Any] {
        if document.isReadOnly {
            return failure("document_read_only",
                           "This document is read-only; the part reference was not added.")
        }
        if isCancelled() {
            return failure("cancelled", Self.cancelledMessage)
        }
        let prepared = prepareSourceURL(sourceURL, target: document)
        guard case .success(let url) = prepared else {
            return failure("invalid_source", prepared.failureMessage)
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let identity = await FloeCADDocument.storedIdentity(at: url) else {
            return failure("source_unreadable",
                           "The native CAD package could not be verified; nothing was read.")
        }
        if isCancelled() {
            return failure("cancelled", Self.cancelledMessage)
        }
        if let expectedSourceContentHash, expectedSourceContentHash != identity.contentSHA256 {
            return failure("source_changed",
                           "The source package changed after it was selected; re-select it and try again.")
        }

        do {
            let source = try await FloeCADDocument.open(at: url)
            defer { source.close() }
            if isCancelled() {
                return failure("cancelled", Self.cancelledMessage)
            }
            guard source.contentSHA256 == identity.contentSHA256 else {
                return failure("source_changed",
                               "The source package changed while it was being staged; nothing was read.")
            }
            let summary = source.summary()
            guard summary.schemaVersion <= FloeCADDocument.supportedPackageSchemaVersion else {
                return failure("source_newer_schema",
                               "This source package was written by a newer FloCAD format "
                                + "(\(summary.schemaVersion)); staging it is not supported in this build.")
            }
            let sourceBodies = source.session.document.bodies
            guard !sourceBodies.isEmpty else {
                return failure("source_empty", "The source document has no solid body to reference.")
            }
            let body: Body
            if let sourceBodyID {
                guard let match = sourceBodies.first(where: { $0.id.raw == sourceBodyID }) else {
                    return failure("source_body_missing",
                                   "The selected source body no longer exists in this source document.")
                }
                body = match
            } else if sourceBodies.count == 1 {
                body = sourceBodies[0]
            } else {
                return failure("source_body_required",
                               "The source document contains \(sourceBodies.count) bodies; "
                                + "choose one explicitly before referencing it.")
            }
            guard !body.render.positions.isEmpty, !body.render.indices.isEmpty else {
                return failure("source_body_empty",
                               "The selected source body has no renderable geometry.")
            }

            #if DEBUG
            await Self.referenceMutationSuspensionForTesting?(document.url)
            #endif
            if isCancelled() {
                return failure("cancelled", Self.cancelledMessage)
            }
            if let refusal = await targetIdentityFailure(for: document) {
                return refusal
            }
            if isCancelled() {
                return failure("cancelled", Self.cancelledMessage)
            }
            guard let staged = stagedBody(from: body, in: document) else {
                return failure("source_geometry_unavailable",
                               "The source geometry could not be copied; nothing was changed.")
            }
            let stagedBodyID = staged.id.raw
            let reference = CADPartReference(
                name: normalizedName(name) ?? body.name,
                sourceDocumentID: sourceDocumentID,
                sourceBodyID: body.id.raw,
                sourceDocumentName: summary.name,
                sourceBodyName: body.name,
                verifierSchemaVersion: FloeCADDocument.supportedPackageSchemaVersion,
                sourceSchemaVersion: summary.schemaVersion,
                sourceRevision: identity.revision,
                sourceContentHash: identity.contentSHA256,
                stagedBodyID: stagedBodyID,
                stagedGeometryHash: CADAssemblyGeometryDigest.digest(of: staged))

            let service = CADAssemblyService(document: document)
            return service.attachStagedReference(
                reference: reference,
                stagedBody: staged,
                instanceName: normalizedName(name),
                transform: transform)
        } catch {
            return failure("source_unreadable",
                           "The native CAD package could not be opened: \(error.localizedDescription)")
        }
    }

    // MARK: - Check / update

    /// Explicitly check the source against the persisted pin. This is a
    /// DIAGNOSIS: it never mutates the document and never drops cached
    /// geometry. A missing source is a successful check with `available:false`.
    public func check(referenceID: UUID,
                      sourceURL: URL,
                      in document: FloeCADDocument,
                      isCancelled: @Sendable () -> Bool = { false }) async -> [String: Any] {
        if isCancelled() {
            return failure("cancelled", Self.cancelledMessage)
        }
        let assembly: CADAssembly
        do {
            assembly = try CADAssembly.decode(from: document.session.document.assemblyData)
        } catch {
            return failure("corrupt_assembly",
                           "The stored assembly JSON could not be read; it was left untouched.")
        }
        guard let reference = assembly.partReference(referenceID) else {
            return failure("unknown_reference", "No part reference with that id.")
        }
        let staged = document.session.document.bodies.first { $0.id.raw == reference.stagedBodyID }
        let cachedGeometry = staged.map { !$0.render.positions.isEmpty } ?? false

        let prepared = prepareSourceURL(sourceURL, target: document)
        guard case .success(let url) = prepared else {
            return diagnosis(reference: reference, cachedGeometry: cachedGeometry,
                             available: false, reason: prepared.failureMessage)
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let identity = await FloeCADDocument.storedIdentity(at: url) else {
            return diagnosis(reference: reference, cachedGeometry: cachedGeometry,
                             available: false, reason: "The native CAD package is missing or unreadable.")
        }
        if isCancelled() {
            return failure("cancelled", Self.cancelledMessage)
        }
        do {
            let source = try await FloeCADDocument.open(at: url)
            defer { source.close() }
            if isCancelled() {
                return failure("cancelled", Self.cancelledMessage)
            }
            guard source.contentSHA256 == identity.contentSHA256 else {
                return failure("source_changed",
                               "The source package changed while it was being checked; nothing was changed.")
            }
            let summary = source.summary()
            guard summary.schemaVersion <= FloeCADDocument.supportedPackageSchemaVersion else {
                return diagnosis(reference: reference, cachedGeometry: cachedGeometry,
                                 available: false,
                                 reason: "The source was written by a newer FloCAD format (\(summary.schemaVersion)).")
            }
            guard let body = source.session.document.bodies.first(where: { $0.id.raw == reference.sourceBodyID }) else {
                return diagnosis(reference: reference, cachedGeometry: cachedGeometry,
                                 available: false,
                                 reason: "The referenced source body no longer exists in the source document.")
            }
            let geometryHash = CADAssemblyGeometryDigest.digest(of: body)
            let updateAvailable = identity.contentSHA256 != reference.sourceContentHash
                || geometryHash != reference.stagedGeometryHash
            return [
                "ok": true,
                "mutated": false,
                "available": true,
                "referenceID": reference.id.uuidString,
                "name": reference.name,
                "cachedGeometryAvailable": cachedGeometry,
                "pinnedSourceRevision": reference.sourceRevision,
                "sourceRevision": identity.revision,
                "pinnedSourceContentHash": reference.sourceContentHash,
                "sourceContentHash": identity.contentSHA256,
                "pinnedSourceSchemaVersion": reference.sourceSchemaVersion,
                "pinnedVerifierSchemaVersion": reference.verifierSchemaVersion,
                "sourceSchemaVersion": summary.schemaVersion,
                "verifierSchemaVersion": FloeCADDocument.supportedPackageSchemaVersion,
                "pinnedStagedGeometryHash": reference.stagedGeometryHash,
                "sourceGeometryHash": geometryHash,
                "updateAvailable": updateAvailable,
                "missing": false,
            ]
        } catch {
            return diagnosis(reference: reference, cachedGeometry: cachedGeometry,
                             available: false,
                             reason: "The native CAD package could not be read: \(error.localizedDescription)")
        }
    }

    /// Explicitly apply a newer verified source revision. Compare-and-swap
    /// requires the caller to echo the currently pinned source and staged
    /// hashes; a mismatch, missing source body or unsupported schema leaves
    /// the document byte-for-byte unchanged (cached geometry included).
    public func update(referenceID: UUID,
                       sourceURL: URL,
                       in document: FloeCADDocument,
                       expectedSourceContentHash: String? = nil,
                       expectedStagedGeometryHash: String? = nil,
                       isCancelled: @Sendable () -> Bool = { false }) async -> [String: Any] {
        if document.isReadOnly {
            return failure("document_read_only",
                           "This document is read-only; the reference was not updated.")
        }
        if isCancelled() {
            return failure("cancelled", Self.cancelledMessage)
        }
        let assembly: CADAssembly
        do {
            assembly = try CADAssembly.decode(from: document.session.document.assemblyData)
        } catch {
            return failure("corrupt_assembly",
                           "The stored assembly JSON could not be read; it was left untouched.")
        }
        guard let reference = assembly.partReference(referenceID) else {
            return failure("unknown_reference", "No part reference with that id.")
        }
        if let expectedSourceContentHash, expectedSourceContentHash != reference.sourceContentHash {
            return failure("stale_reference",
                           "The reference was pinned to a different source revision; "
                            + "reload the reference before updating.")
        }
        if let expectedStagedGeometryHash, expectedStagedGeometryHash != reference.stagedGeometryHash {
            return failure("stale_reference",
                           "The staged geometry changed since this update was prepared; "
                            + "reload the reference before updating.")
        }
        guard let staged = document.session.document.bodies.first(where: { $0.id.raw == reference.stagedBodyID }) else {
            return failure("missing_staged_body",
                           "The cached staged body is missing; the reference could not be updated safely.")
        }

        let prepared = prepareSourceURL(sourceURL, target: document)
        guard case .success(let url) = prepared else {
            return failure("invalid_source", prepared.failureMessage)
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let identity = await FloeCADDocument.storedIdentity(at: url) else {
            return failure("source_missing",
                           "The source package is missing or unreadable; cached geometry was retained.")
        }
        if isCancelled() {
            return failure("cancelled", Self.cancelledMessage)
        }
        do {
            let source = try await FloeCADDocument.open(at: url)
            defer { source.close() }
            if isCancelled() {
                return failure("cancelled", Self.cancelledMessage)
            }
            guard source.contentSHA256 == identity.contentSHA256 else {
                return failure("source_changed",
                               "The source package changed while it was being updated; cached geometry was retained.")
            }
            let summary = source.summary()
            guard summary.schemaVersion <= FloeCADDocument.supportedPackageSchemaVersion else {
                return failure("source_newer_schema",
                               "This source package was written by a newer FloCAD format "
                                + "(\(summary.schemaVersion)); the cached geometry was retained.")
            }
            guard let body = source.session.document.bodies.first(where: { $0.id.raw == reference.sourceBodyID }) else {
                return failure("source_body_missing",
                               "The referenced source body no longer exists; cached geometry was retained.")
            }
            let geometryHash = CADAssemblyGeometryDigest.digest(of: body)
            if identity.contentSHA256 == reference.sourceContentHash,
               geometryHash == reference.stagedGeometryHash {
                return [
                    "ok": true,
                    "mutated": false,
                    "upToDate": true,
                    "referenceID": reference.id.uuidString,
                    "message": "The source is already at the pinned revision.",
                ]
            }

            #if DEBUG
            await Self.referenceMutationSuspensionForTesting?(document.url)
            #endif
            if isCancelled() {
                return failure("cancelled", Self.cancelledMessage)
            }
            if let refusal = await targetIdentityFailure(for: document) {
                return refusal
            }
            if isCancelled() {
                return failure("cancelled", Self.cancelledMessage)
            }
            guard let replacement = stagedBody(from: body,
                                               in: document,
                                               bodyID: reference.stagedBodyID,
                                               name: staged.name) else {
                return failure("source_geometry_unavailable",
                               "The source geometry could not be copied; the previous reference was retained.")
            }
            var updated = reference
            updated.sourceDocumentName = summary.name
            updated.sourceBodyName = body.name
            updated.verifierSchemaVersion = FloeCADDocument.supportedPackageSchemaVersion
            updated.sourceSchemaVersion = summary.schemaVersion
            updated.sourceRevision = identity.revision
            updated.sourceContentHash = identity.contentSHA256
            updated.stagedGeometryHash = geometryHash
            updated.pinnedAt = Date()
            updated.lastCheckedAt = Date()
            updated.availableSourceRevision = nil
            updated.availableSourceContentHash = nil
            updated.availableSchemaVersion = nil
            updated.missingReason = nil

            let service = CADAssemblyService(document: document)
            return service.applyStagedReferenceUpdate(
                updatedReference: updated,
                stagedBody: replacement,
                expectedStagedGeometryHash: reference.stagedGeometryHash,
                expectedSourceContentHash: reference.sourceContentHash)
        } catch {
            return failure("source_unreadable",
                           "The native CAD package could not be read; cached geometry was retained: "
                            + error.localizedDescription)
        }
    }

    // MARK: - Helpers

    static let cancelledMessage =
        "The reference operation was cancelled before any document change."

    #if DEBUG
    /// Deterministic suspension AFTER all asynchronous source reads and
    /// BEFORE the final cancellation/target fence plus mutation. Public only
    /// in DEBUG so the App host test can cancel the REAL runtime token at the
    /// exact late-source-load point; absent in release. The production path
    /// performs the same fences without a probe.
    public static var referenceMutationSuspensionForTesting: (@MainActor (URL) async -> Void)?
    #endif

    /// The target must still be the SAME committed package the live document
    /// represents when the source read finishes. A foreign commit, a closed
    /// document or a now read-only package refuses before any mutation; an
    /// already-running atomic commit is handled by the caller, never undone.
    private func targetIdentityFailure(for document: FloeCADDocument) async -> [String: Any]? {
        if document.isClosed {
            return failure("target_changed",
                           "The target CAD document was closed while the source was being read; nothing was changed.")
        }
        if document.isReadOnly {
            return failure("target_changed",
                           "The target CAD document became read-only while the source was being read; nothing was changed.")
        }
        guard let identity = await FloeCADDocument.storedIdentity(at: document.url) else {
            return failure("target_changed",
                           "The target CAD package could not be verified after the source was read; nothing was changed.")
        }
        if identity.revision != document.revision
            || identity.contentSHA256 != document.contentSHA256 {
            // This document's own commit may have landed while the verified
            // read was in flight and its main-actor adoption is queued. Give
            // that adoption one cooperative turn, then require an exact
            // match. A FOREIGN commit stays mismatched and is refused.
            await Task.yield()
            guard identity.revision == document.revision,
                  identity.contentSHA256 == document.contentSHA256 else {
                return failure("target_changed",
                               "The target CAD document changed on disk while the source was being read; nothing was changed. Reopen it and try again.")
            }
        }
        // Verification itself suspends too. Closing the document during that
        // read or the adoption yield must not authorize a late direct write.
        guard !document.isClosed, !document.isReadOnly else {
            return failure("target_changed",
                           "The target CAD document is no longer writable; nothing was changed.")
        }
        return nil
    }

    private enum PreparedURL {
        case success(URL)
        case failure(String)

        var failureMessage: String {
            if case .failure(let message) = self { return message }
            return ""
        }
    }

    private func prepareSourceURL(_ url: URL, target: FloeCADDocument?) -> PreparedURL {
        guard url.pathExtension.lowercased() == Self.expectedExtension else {
            return .failure("Only a native .floecad package can be referenced in this build.")
        }
        let source = url.standardizedFileURL.resolvingSymlinksInPath()
        if let target {
            let own = target.url.standardizedFileURL.resolvingSymlinksInPath()
            if source.path == own.path {
                return .failure("A document cannot reference itself. Choose a different source document.")
            }
        }
        return .success(url)
    }

    private func stagedBody(from source: Body,
                            in document: FloeCADDocument,
                            bodyID: UUID? = nil,
                            name: String? = nil) -> Body? {
        let stagedID = bodyID.map { BodyID(raw: $0) } ?? BodyID()
        let existing = bodyID.flatMap { id in
            document.session.document.bodies.first { $0.id.raw == id }
        }
        let finalName: String
        if let existing {
            finalName = name ?? existing.name
        } else {
            finalName = document.session.document.uniqueBodyName(
                base: name ?? source.name + " Reference")
        }
        var staged = Body(id: stagedID,
                          name: finalName,
                          transform: source.transform,
                          primitive: source.primitive,
                          render: source.render,
                          revision: 0)
        staged.material = source.material
        staged.materialFaceBindings = source.materialFaceBindings
        // The staged body is an internal definition; every visible
        // appearance comes from an assembly occurrence.
        staged.isHidden = true
        staged.euclid = source.euclid
        // Own the exact shape through the same serialize/deserialize path the
        // document package uses; a shared live handle would couple the staged
        // body to the source document's lifetime. A referenced IGES surface
        // must stay an exact surface, not become a render-only mesh.
        if let exact = source.brep ?? source.surfaceBRep {
            guard let data = OCCTKernel.serialize(exact),
                  let owned = OCCTKernel.deserialize(data) else { return nil }
            if owned.containsSolid {
                staged.brep = owned
            } else {
                staged.surfaceBRep = owned
            }
        }
        return staged
    }

    private func normalizedName(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func diagnosis(reference: CADPartReference,
                           cachedGeometry: Bool,
                           available: Bool,
                           reason: String) -> [String: Any] {
        [
            "ok": true,
            "mutated": false,
            "available": available,
            "missing": true,
            "missingReason": reason,
            "referenceID": reference.id.uuidString,
            "name": reference.name,
            "cachedGeometryAvailable": cachedGeometry,
            "pinnedSourceRevision": reference.sourceRevision,
            "pinnedSourceContentHash": reference.sourceContentHash,
            "pinnedSourceSchemaVersion": reference.sourceSchemaVersion,
            "pinnedStagedGeometryHash": reference.stagedGeometryHash,
            "updateAvailable": false,
        ]
    }

    private func failure(_ code: String, _ message: String) -> [String: Any] {
        ["ok": false, "mutated": false, "error": code, "message": message]
    }
}
