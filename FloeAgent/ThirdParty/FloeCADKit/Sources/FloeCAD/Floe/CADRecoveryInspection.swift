// SPDX-License-Identifier: MPL-2.0
// FloeCADKit — E33 recovery preview / restore-copy store seam.
//
// Ordinary `FileCADDocumentStore.read()` keeps its existing proven behaviour
// for internal recovery callers: a missing current manifest promotes a verified
// `previous/` commit in place and retains the interrupted package as a sibling.
// Interactive hosts must be able to look before that happens, so this file adds
// two explicit, separate operations:
//
//   * `recoveryInspection()` is strictly read-only. It verifies the CURRENT
//     package first (`.intact`), and only when that fails does it verify the
//     real `previous/` commit. It never creates a manifest, a staging directory
//     or a sibling recovery point.
//   * `restorePreviousCopy(_:to:)` re-verifies the source fingerprint the
//     preview was built from, then copies the verified previous commit to a NEW
//     package through a sibling staging directory and an atomic rename. The
//     damaged package and its `previous/` bytes are never written.
//
// The public facade (`FloeCADDocument`) runs both off the main actor. No second
// store, serializer, renderer or package format is introduced.

import Foundation

extension FileCADDocumentStore {

    // MARK: Inspection

    /// Read-only answer for an interactive open. Never promotes `previous/`.
    func recoveryInspection() -> CADRecoveryInspection {
        do {
            _ = try verifiedPackage(at: packageURL)
            return .intact
        } catch {
            let damage = recoveryDamage(for: error)
            guard let preview = makeRecoveryPreview(damage: damage) else {
                return .damaged(damage: damage, preview: nil)
            }
            return .damaged(damage: damage, preview: preview)
        }
    }

    private func recoveryDamage(for error: Error) -> CADRecoveryDamage {
        if !fileManager.fileExists(atPath: manifestURL.path) {
            return .missingManifest
        }
        if !fileManager.fileExists(atPath: documentURL.path) {
            return .unreadableDocument(detail: "document.json is missing")
        }
        guard let storeError = error as? CADDocumentStoreError else {
            return .unreadablePackage(detail: error.localizedDescription)
        }
        switch storeError {
        case .corruptManifest(let detail):
            return .unreadableManifest(detail: detail)
        case .corruptDocument(let detail):
            return .unreadableDocument(detail: detail)
        case .integrityFailed(let detail):
            return .failedIntegrity(detail: detail)
        case .packageMissing:
            return .missingManifest
        default:
            return .unreadablePackage(detail: storeError.localizedDescription)
        }
    }

    private func makeRecoveryPreview(damage: CADRecoveryDamage) -> CADRecoveryPreview? {
        let previousManifestURL = previousURL.appendingPathComponent("manifest.json")
        // Restore refuses a linked `previous/` tree. The interactive preview
        // must apply the SAME containment BEFORE it reads any previous byte:
        // otherwise an initial `previous` symlink (or a nested link) could be
        // presented as a verified previous save while the bytes come from
        // outside the package. A damaged package without a contained previous
        // commit simply has no preview.
        guard previousDirectoryIsContained(),
              fileManager.fileExists(atPath: previousManifestURL.path),
              let verified = try? verifiedPackage(at: previousURL) else {
            return nil
        }
        return makeRecoveryPreview(damage: damage, verifiedPrevious: verified)
    }

    private func makeRecoveryPreview(damage: CADRecoveryDamage,
                                     verifiedPrevious verified: CADVerifiedPackage)
    -> CADRecoveryPreview {
        let currentManifestData = try? Data(contentsOf: manifestURL)
        let currentDocumentData = try? Data(contentsOf: documentURL)
        let currentManifest = currentManifestData.flatMap {
            try? JSONDecoder().decode(CADManifest.self, from: $0)
        }

        var contents = recoveryContents(from: verified.document)
        contents.hasPreviewImage = verified.thumbnail != nil
        let recordedCounts = verified.manifest.counts
        let decodedCounts = recoveryDecodedCounts(from: verified.document)
        let versionNames = visibleVersionDirectoryNames()
        let otherItems = otherTopLevelItems()
        let blobItems = currentBlobItems()
        let newerResources = newerResourcePaths(previous: verified,
                                                currentBlobItems: Set(blobItems.keys))
        let unclaimed = unclaimedPreviousResources(previous: verified)
        let damagedPreviewMissing = currentManifest?.thumbnailSHA256 != nil
            && !fileManager.fileExists(
                atPath: packageURL.appendingPathComponent("blobs/thumbnail.img").path)

        let facts = CADRecoveryFacts(
            previous: recoveryIdentity(from: verified.manifest),
            contents: contents,
            recordedManifestCounts: recordedCounts,
            decodedRecordCounts: decodedCounts,
            supportedSchemaVersion: CADDocumentFormat.supportedVersion,
            previousHasOpaqueAssociations: verified.formatAssessment.isOpaqueReadOnly,
            previousHasUnrecognizedFields: hasUnrecognizedFields(verified.document,
                                                                data: verified.documentData),
            namedVersionCountInDamagedPackage: versionNames.count,
            otherItemCountInDamagedPackage: otherItems.count,
            newerResourceCountInDamagedPackage: newerResources.count,
            damagedPreviewMissing: damagedPreviewMissing,
            unclaimedPreviousResourceCount: unclaimed)

        let fingerprint = recoveryFingerprint(
            previous: verified,
            currentManifestData: currentManifestData,
            currentDocumentData: currentDocumentData,
            damagedVersionNames: versionNames,
            damagedAuxiliaryItems: otherItems,
            damagedBlobItems: blobItems)

        return CADRecoveryPreview(
            sourceURL: packageURL,
            damage: damage,
            previous: facts.previous,
            contents: contents,
            report: CADRecoveryReport.build(from: facts),
            sourceFingerprint: fingerprint,
            previewImage: verified.thumbnail,
            currentRevisionClaim: currentManifest?.revision,
            currentModifiedAtClaim: currentManifest?.modifiedAt,
            currentReportedCounts: currentManifest.flatMap {
                $0.counts.isEmpty ? nil : $0.counts
            },
            previousOpensReadOnly: verified.manifest.schemaVersion > CADDocumentFormat.supportedVersion
                || verified.formatAssessment.isOpaqueReadOnly)
    }

    private func recoveryIdentity(from manifest: CADManifest) -> CADRecoveryIdentity {
        CADRecoveryIdentity(
            name: manifest.name,
            revision: manifest.revision,
            contentSHA256: manifest.contentSHA256,
            modelSHA256: manifest.modelSHA256,
            schemaVersion: manifest.schemaVersion,
            createdAt: manifest.createdAt,
            modifiedAt: manifest.modifiedAt,
            unit: manifest.unit,
            tolerance: manifest.tolerance,
            appBuild: manifest.appBuild)
    }

    private func recoveryContents(from document: CADDocumentRecord) -> CADRecoveryContents {
        var contents = CADRecoveryContents()
        contents.bodies = document.bodies.count
        contents.sketches = document.sketches.count
        contents.planes = document.planes.count
        contents.axes = document.axes.count
        contents.images = document.images.count
        contents.symbols = document.symbols.count
        contents.features = document.features.count
        contents.variables = document.variables.count
        contents.hasAssembly = document.assembly?.isEmpty == false
        if let drawings = document.drawings, !drawings.isEmpty {
            contents.hasDrawings = true
            contents.drawingPageCount = (try? CADDrawingSet.decode(from: drawings))?.pages.count
        }
        if let materials = document.materials, !materials.isEmpty {
            contents.hasMaterials = true
            contents.materialCount = (try? JSONDecoder().decode(
                CADMaterialLibrary.self, from: materials))?.entries.count
        }
        if let animation = document.animation, !animation.isEmpty {
            contents.hasAnimation = true
            contents.animationCount = (try? JSONDecoder().decode(
                CADAnimationDocument.self, from: animation))?.clips.count
        }
        contents.hasScripts = document.scripts?.isEmpty == false
        contents.hasSceneSettings = document.sceneSettings?.isEmpty == false
        return contents
    }

    private func recoveryDecodedCounts(from document: CADDocumentRecord) -> [String: Int] {
        [
            "bodies": document.bodies.count,
            "sketches": document.sketches.count,
            "planes": document.planes.count,
            "axes": document.axes.count,
            "images": document.images.count,
            "symbols": document.symbols.count,
            "features": document.features.count,
            "variables": document.variables.count,
        ]
    }

    private func hasUnrecognizedFields(_ document: CADDocumentRecord, data: Data) -> Bool {
        guard let raw = try? JSONSerialization.jsonObject(with: data) else { return false }
        guard let knownData = try? JSONEncoder().encode(document),
              let known = try? JSONSerialization.jsonObject(with: knownData) else {
            return false
        }
        return Self.hasUnknownFields(raw, comparedTo: known)
    }

    // MARK: Damaged-package inventory (read-only)

    /// Visible named-version checkpoint directories in the damaged package.
    /// They are deliberately NOT part of the verified `previous/` commit.
    private func visibleVersionDirectoryNames() -> [String] {
        let versions = packageURL.appendingPathComponent("versions", isDirectory: true)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: versions,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]) else { return [] }
        return entries.compactMap { entry in
            guard let values = try? entry.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                values.isDirectory == true, values.isSymbolicLink != true else {
                return nil
            }
            return entry.lastPathComponent
        }.sorted()
    }

    /// Top-level entries of the damaged package that are not part of the
    /// committed package layout. Sizes (-1 for directories) make changes to
    /// this inventory part of the preview fingerprint.
    private func otherTopLevelItems() -> [String: Int] {
        let known: Set<String> = ["manifest.json", "document.json", "blobs",
                                  "previous", "versions"]
        guard let entries = try? fileManager.contentsOfDirectory(
            at: packageURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []) else { return [:] }
        var result: [String: Int] = [:]
        for entry in entries where !known.contains(entry.lastPathComponent) {
            let values = try? entry.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isDirectory == true {
                result[entry.lastPathComponent] = -1
            } else {
                let attributes = try? fileManager.attributesOfItem(atPath: entry.path)
                result[entry.lastPathComponent] =
                    (attributes?[.size] as? NSNumber)?.intValue ?? 0
            }
        }
        return result
    }

    /// Regular files under the damaged package's `blobs/`, relative to the
    /// package root. Only sizes are collected; the current document cannot
    /// attribute them, so their content is never used as identity.
    private func currentBlobItems() -> [String: Int] {
        let blobRoot = packageURL.appendingPathComponent("blobs", isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: blobRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey,
                                         .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]) else { return [:] }
        let rootPath = packageURL.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        var result: [String: Int] = [:]
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]),
                values.isSymbolicLink != true, values.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard path.hasPrefix(rootPath) else { continue }
            let relative = String(path.dropFirst(rootPath.count))
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            result[relative] = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        }
        return result
    }

    /// Blob paths that exist only in the damaged current package. They are not
    /// copied; the report lists them as retained in the original.
    private func newerResourcePaths(previous: CADVerifiedPackage,
                                    currentBlobItems current: Set<String>) -> Set<String> {
        let previousPaths = Set(previous.blobs.keys)
        return current.subtracting(previousPaths).subtracting(["blobs/thumbnail.img"])
    }

    /// Files under `previous/blobs/` that the previous document does not
    /// reference. A byte-identical copy keeps them; the report discloses them.
    private func unclaimedPreviousResources(previous: CADVerifiedPackage) -> Int {
        var referenced = Set<String>()
        for body in previous.document.bodies {
            if let path = body.meshBlob { referenced.insert(path) }
            if let path = body.brepBlob { referenced.insert(path) }
        }
        for image in previous.document.images {
            if let path = image.imageBlob { referenced.insert(path) }
        }
        return previous.blobs.keys.filter { !referenced.contains($0) }.count
    }

    /// Regular files under `previous/` that are not the verified manifest,
    /// document or an attributed blob. They are copied verbatim, so their
    /// digests are part of the preview fingerprint.
    private func previousExtraFiles() -> [String: Data] {
        guard let enumerator = fileManager.enumerator(
            at: previousURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey,
                                         .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]) else { return [:] }
        let rootPath = previousURL.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        var result: [String: Data] = [:]
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]),
                values.isSymbolicLink != true, values.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard path.hasPrefix(rootPath) else { continue }
            let relative = String(path.dropFirst(rootPath.count))
            if relative == "manifest.json" || relative == "document.json" { continue }
            if relative.hasPrefix("blobs/") { continue }
            if let data = try? Data(contentsOf: url) { result[relative] = data }
        }
        return result
    }

    // MARK: Fingerprint

    private func recoveryFingerprint(previous: CADVerifiedPackage,
                                     currentManifestData: Data?,
                                     currentDocumentData: Data?,
                                     damagedVersionNames: [String],
                                     damagedAuxiliaryItems: [String: Int],
                                     damagedBlobItems: [String: Int]) -> String {
        var blobs: [String: String] = [:]
        for (path, data) in previous.blobs {
            blobs[path] = Self.sha256(data)
        }
        var extras: [String: String] = [:]
        for (path, data) in previousExtraFiles() {
            extras[path] = Self.sha256(data)
        }
        return CADRecoveryFingerprint.make(
            currentManifestSHA256: currentManifestData.map { Self.sha256($0) },
            currentDocumentSHA256: currentDocumentData.map { Self.sha256($0) },
            previousManifestSHA256: Self.sha256(previous.manifestData),
            previousDocumentSHA256: Self.sha256(previous.documentData),
            previousThumbnailSHA256: previous.thumbnail.map { Self.sha256($0) },
            previousBlobs: blobs,
            previousExtraFiles: extras,
            damagedVersionNames: damagedVersionNames,
            damagedAuxiliaryItems: damagedAuxiliaryItems,
            damagedBlobItems: damagedBlobItems)
    }

    // MARK: Restore to a new package

    /// Re-verify the preview's source, copy the verified `previous/` commit to a
    /// NEW package through staging + an atomic rename, and verify the result.
    /// The source package (including `previous/`) is only read.
    ///
    /// The whole operation runs under the existing per-package gate for BOTH
    /// the source and the destination, in canonical order, so two cooperating
    /// restores (or a restore and a commit) can never cross the
    /// verify -> fingerprint -> stage -> promote window. The gate is released
    /// before this synchronous body returns; no UI/user await is ever made
    /// while it is held.
    ///
    /// Cancellation of the CALLER is deliberately not a cancellation of this
    /// atomic step: once the copy exists, aborting between staging and
    /// promotion would be worse than finishing. Hosts fence their presentation
    /// separately and record the honest "copied" outcome for a late result.
    func restorePreviousCopy(_ preview: CADRecoveryPreview,
                             to destinationURL: URL) throws -> CADRecoveryRestoreResult {
        let source = packageURL.standardizedFileURL.resolvingSymlinksInPath()
        let previewSource = preview.sourceURL.standardizedFileURL.resolvingSymlinksInPath()
        guard source == previewSource else { throw CADRecoveryError.sourceMismatch }

        let requestedDestination = destinationURL.standardizedFileURL
        let resolvedDestination = requestedDestination.resolvingSymlinksInPath()

        // Path containment uses the fully resolved forms so a symlinked
        // parent or a `..` component cannot escape the damaged package's
        // folder. The destination must stay a sibling, never inside the
        // source, and never an ancestor of it.
        guard resolvedDestination.path != source.path,
              !resolvedDestination.path.hasPrefix(source.path + "/"),
              !source.path.hasPrefix(resolvedDestination.path + "/") else {
            throw CADRecoveryError.destinationInsideSource
        }
        let sourceParent = source.deletingLastPathComponent()
        let destinationParent = resolvedDestination.deletingLastPathComponent()
        // The copy is written next to the damaged package: same workspace or
        // canvas container (never an arbitrary external folder), and the same
        // volume so the staging rename stays atomic.
        guard destinationParent.standardizedFileURL == sourceParent.standardizedFileURL else {
            throw CADRecoveryError.destinationOutsideSource
        }
        // A recovered copy is a package, not an arbitrary renamed item. Keep
        // the exact package extension the store reads.
        guard source.pathExtension.lowercased() == Self.packageExtension,
              requestedDestination.pathExtension.lowercased() == Self.packageExtension else {
            throw CADRecoveryError.destinationNotPackage(requestedDestination)
        }
        // lstat-style existence: a dangling symbolic link occupies the
        // destination and must never be replaced by the atomic rename.
        guard !entryExists(requestedDestination) else {
            throw CADRecoveryError.destinationExists(requestedDestination)
        }

        // Deterministic acquisition order prevents two-gate deadlocks.
        let gatePaths = [source.path, resolvedDestination.path].sorted()
        let firstGate = URL(fileURLWithPath: gatePaths[0])
        let secondGate = URL(fileURLWithPath: gatePaths[1])
        CADPackageGate.acquire(firstGate)
        defer { CADPackageGate.release(firstGate) }
        CADPackageGate.acquire(secondGate)
        defer { CADPackageGate.release(secondGate) }

        // Re-check both the destination and every source fact INSIDE the gate:
        // the preview was created before either lock was taken.
        guard !entryExists(requestedDestination) else {
            throw CADRecoveryError.destinationExists(requestedDestination)
        }
        let previousManifestURL = previousURL.appendingPathComponent("manifest.json")
        guard previousDirectoryIsContained(),
              fileManager.fileExists(atPath: previousManifestURL.path) else {
            // A link, a file or a missing tree is not a verified previous
            // commit. A link is an explicit containment refusal.
            if entryExists(previousURL) { throw CADRecoveryError.sourceNotContained }
            throw CADRecoveryError.noVerifiedPrevious
        }
        guard let verified = try? verifiedPackage(at: previousURL) else {
            throw CADRecoveryError.noVerifiedPrevious
        }

        let currentManifestData = try? Data(contentsOf: manifestURL)
        let currentDocumentData = try? Data(contentsOf: documentURL)
        let versionNames = visibleVersionDirectoryNames()
        let otherItems = otherTopLevelItems()
        let blobItems = currentBlobItems()
        let fingerprint = recoveryFingerprint(
            previous: verified,
            currentManifestData: currentManifestData,
            currentDocumentData: currentDocumentData,
            damagedVersionNames: versionNames,
            damagedAuxiliaryItems: otherItems,
            damagedBlobItems: blobItems)
        // The user reviewed a specific state. A changed damaged package, a
        // changed previous commit or a changed named-version inventory refuses
        // instead of applying a stale preview.
        guard fingerprint == preview.sourceFingerprint else {
            throw CADRecoveryError.sourceChanged
        }

        let requestedParent = requestedDestination.deletingLastPathComponent()
        var parentIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: destinationParent.path,
                                     isDirectory: &parentIsDirectory),
              parentIsDirectory.boolValue else {
            throw CADRecoveryError.destinationParentMissing(requestedParent)
        }

        let staging = destinationParent.appendingPathComponent(
            ".\(requestedDestination.lastPathComponent).restore-\(UUID().uuidString)")
        do {
            // Copy, then verify the copy. The source `previous/` bytes are
            // never moved, renamed or written.
            try fileManager.copyItem(at: previousURL, to: staging)
            // `copyItem` reproduces symbolic links as links. Refuse a link
            // that appeared after the pre-copy scan so the new package cannot
            // point outside itself.
            guard !containsSymbolicLink(staging) else {
                throw CADRecoveryError.sourceNotContained
            }
            let staged = try verifiedPackage(at: staging)
            guard verifiedPackage(staged, matches: verified) else {
                throw CADRecoveryError.copyFailed(
                    "the last saved version changed while it was being copied")
            }
            try CADDocumentFaultInjection.beforeRecoveryCopyPromotion?()
            // A cooperating writer cannot reach here while the destination
            // gate is held; this re-check still fails closed for a late
            // (non-cooperating) creation instead of renaming over it.
            guard !entryExists(requestedDestination) else {
                throw CADRecoveryError.destinationExists(requestedDestination)
            }
            try fileManager.moveItem(at: staging, to: resolvedDestination)
        } catch let error as CADRecoveryError {
            removeStaging(staging)
            throw error
        } catch {
            removeStaging(staging)
            if entryExists(requestedDestination) {
                throw CADRecoveryError.destinationExists(requestedDestination)
            }
            throw CADRecoveryError.copyFailed(error.localizedDescription)
        }

        do {
            let restored = try verifiedPackage(at: resolvedDestination)
            guard verifiedPackage(restored, matches: verified) else {
                throw CADRecoveryError.verificationFailed(
                    "the recovered copy does not match the verified previous save")
            }
            return CADRecoveryRestoreResult(
                // Report the path the caller asked for (its workspace/canvas
                // URL), not the symlink-resolved operational path.
                packageURL: requestedDestination,
                revision: restored.manifest.revision,
                contentSHA256: restored.manifest.contentSHA256,
                modelSHA256: restored.modelSHA256,
                sourceURL: packageURL,
                sourceFingerprint: fingerprint,
                report: preview.report)
        } catch {
            // Never leave an unverified directory at the requested path, but
            // retain the bytes for diagnosis instead of deleting them.
            let unverified = destinationParent.appendingPathComponent(
                ".\(requestedDestination.lastPathComponent).unverified-\(UUID().uuidString)")
            try? fileManager.moveItem(at: resolvedDestination, to: unverified)
            if let recovery = error as? CADRecoveryError { throw recovery }
            throw CADRecoveryError.verificationFailed(error.localizedDescription)
        }
    }

    // MARK: Containment helpers (preview + restore copy)

    /// The single containment rule for the `previous/` tree: it must be a real
    /// directory (not a link) and it must not contain any symbolic link,
    /// including a dangling one. Preview uses it before reading a single
    /// previous byte; restore uses the same rule inside its package gates.
    private func previousDirectoryIsContained() -> Bool {
        directoryEntryIsRealDirectory(previousURL) && !containsSymbolicLink(previousURL)
    }

    /// lstat-style existence: a dangling symbolic link is an entry and must be
    /// treated as an occupied destination.
    private func entryExists(_ url: URL) -> Bool {
        (try? fileManager.attributesOfItem(atPath: url.path)) != nil
    }

    private func directoryEntryIsRealDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    /// True when any entry under `root` (including a dangling link) is a
    /// symbolic link. Refuses the whole tree instead of previewing/copying a
    /// linked resource.
    private func containsSymbolicLink(_ root: URL) -> Bool {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []) else { return true }
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?
                .isSymbolicLink == true {
                return true
            }
        }
        return false
    }

    /// Exact byte identity between the verified previous commit and the staged
    /// / promoted copy. A manifest-only check would accept a mixed copy; this
    /// compares the decoded documents, every blob and the optional preview.
    private func verifiedPackage(_ candidate: CADVerifiedPackage,
                                 matches reference: CADVerifiedPackage) -> Bool {
        candidate.manifestData == reference.manifestData
            && candidate.documentData == reference.documentData
            && candidate.thumbnail == reference.thumbnail
            && candidate.modelSHA256 == reference.modelSHA256
            && candidate.blobs == reference.blobs
    }

    private func removeStaging(_ url: URL) {
        if entryExists(url) { try? fileManager.removeItem(at: url) }
    }
}

// MARK: - Public facade

extension FloeCADDocument {
    // The package target uses default MainActor isolation. Keep the detached
    // body explicitly nonisolated (the same rule as
    // `writePreparedPayload`): otherwise an inline closure can infer MainActor
    // isolation from the synchronous store call, hop back to the actor and
    // block it while the package gate or a large copy is in progress.
    private nonisolated static func inspectRecovery(
        _ store: FileCADDocumentStore
    ) -> CADRecoveryInspection {
        store.recoveryInspection()
    }

    private nonisolated static func restoreRecoveryCopy(
        _ store: FileCADDocumentStore,
        preview: CADRecoveryPreview,
        destination: URL
    ) throws -> CADRecoveryRestoreResult {
        try store.restorePreviousCopy(preview, to: destination)
    }

    /// Non-mutating inspection for an interactive open. Runs off the main
    /// actor; ordinary `open(at:)` and its auto-recovery are unchanged.
    public static func recoveryInspection(at url: URL) async -> CADRecoveryInspection {
        let store = FileCADDocumentStore(packageURL: url)
        return await Task.detached(priority: .userInitiated) {
            inspectRecovery(store)
        }.value
    }

    /// Create a NEW package from the verified `previous/` commit described by
    /// `preview`. The damaged package and its `previous/` bytes are untouched;
    /// a changed source is refused.
    public static func restorePreviousCopy(
        _ preview: CADRecoveryPreview,
        to destinationURL: URL
    ) async throws -> CADRecoveryRestoreResult {
        let store = FileCADDocumentStore(packageURL: preview.sourceURL)
        return try await Task.detached(priority: .userInitiated) {
            try restoreRecoveryCopy(store, preview: preview, destination: destinationURL)
        }.value
    }
}
