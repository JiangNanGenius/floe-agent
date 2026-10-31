//
//  CADNamedVersionTests.swift
//  FloeCADKitTests
//
//  E34 user-named design versions. These regressions exercise the REAL
//  package store, save kernel, session load/undo boundary and checkpoint
//  verification. Bodies are tiny render-only meshes, so the suite does not
//  require an OCCT operation to prove the version transaction.
//

import XCTest
import simd
import CryptoKit
@testable import FloeCAD

/// One-shot async gate used by the real-cancellation tests. It never blocks a
/// thread or the run loop: the detached child suspends on a continuation and
/// the test resumes it after cancelling the real parent task.
private nonisolated final class NamedVersionAsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if released {
                lock.unlock()
                continuation.resume()
                return
            }
            waiter = continuation
            lock.unlock()
        }
    }

    func release() {
        lock.lock()
        released = true
        let pending = waiter
        waiter = nil
        lock.unlock()
        pending?.resume()
    }
}

/// A small lock-protected flag for bounded "must not have returned yet" checks.
/// It observes facts only; it never turns a timed observation into a pass for a
/// real failure.
private nonisolated final class NamedVersionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var marked = false

    func mark() {
        lock.lock()
        marked = true
        lock.unlock()
    }

    var isMarked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return marked
    }
}

/// A REAL FileManager failure, not a fake-success store. It fails only the
/// final same-directory promotion of an owned `.pending-<uuid>` checkpoint.
private nonisolated final class PromotionFailingFileManager: FileManager, @unchecked Sendable {
    var failPendingPromotion = false
    var promotionAttempts = 0

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if failPendingPromotion,
           srcURL.lastPathComponent.hasPrefix(".pending-"),
           srcURL.deletingLastPathComponent().standardizedFileURL.path
               == dstURL.deletingLastPathComponent().standardizedFileURL.path {
            promotionAttempts += 1
            throw NSError(
                domain: NSCocoaErrorDomain, code: 512,
                userInfo: [NSLocalizedDescriptionKey:
                    "injected actual FileManager failure at final checkpoint promotion"])
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}

@MainActor
final class CADNamedVersionTests: XCTestCase {
    private var workDir: URL!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeCADVersions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        CADDocumentFaultInjection.beforeCommit = nil
        CADDocumentFaultInjection.beforeCreateSwap = nil
        CADDocumentFaultInjection.beforeVersionTransfer = nil
        CADDocumentFaultInjection.afterVersionTransfer = nil
        CADDocumentFaultInjection.beforeStagedPromotion = nil
        CADDocumentFaultInjection.beforeVersionRecoveryCarry = nil
        CADDocumentFaultInjection.beforeNamedVersionPromotion = nil
        #if DEBUG
        CADNamedVersionTestHooks.afterCheckpointLoad = nil
        CADNamedVersionTestHooks.beforeRestoreCommit = nil
        CADNamedVersionWorkHooks.afterCheckpointStaged = nil
        CADNamedVersionWorkHooks.afterCheckpointLoaded = nil
        CADNamedVersionWorkHooks.afterListLoaded = nil
        CADNamedVersionWorkHooks.beforeRecoveryListGate = nil
        #endif
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - Fixtures

    private func makeDocument(_ name: String = "Versions") async throws -> (FloeCADDocument, URL) {
        let url = workDir.appendingPathComponent("\(name).floecad")
        let document = try await FloeCADDocument.create(at: url, name: name)
        return (document, url)
    }

    @discardableResult
    private func addTriangle(_ document: FloeCADDocument, name: String,
                             offset: Float = 0,
                             material: BodyMaterialSpec? = nil,
                             title: String? = nil) -> UUID {
        let mesh = RenderMesh(
            positions: [SIMD3(offset, 0, 0), SIMD3(offset + 10, 0, 0), SIMD3(offset, 10, 0)],
            normals: [SIMD3(0, 0, 1), SIMD3(0, 0, 1), SIMD3(0, 0, 1)],
            indices: [0, 1, 2])
        var body = Body(id: BodyID(), name: name, transform: .identity, primitive: nil,
                        render: mesh, revision: 1)
        body.material = material
        // A test fixture with a multi-megabyte body name passes a small undo
        // title so the in-memory undo stack does not duplicate the record.
        document.session.perform(AddBodyCommand(body: body, title: title))
        return body.id.raw
    }

    @discardableResult
    private func save(_ document: FloeCADDocument,
                      file: StaticString = #filePath,
                      line: UInt = #line) async throws -> CADSaveOutcome {
        let outcome = await document.save()
        XCTAssertTrue(outcome.succeeded, outcome.error ?? "save failed", file: file, line: line)
        return outcome
    }

    /// Force the real public create path through the final-promotion fault after
    /// its format-floor commit, and return the retained checkpoint id. The
    /// failure is injected at the same seam R3 uses; this helper never bypasses
    /// verification or the package gate.
    private func forciblyRetainCheckpoint(_ document: FloeCADDocument,
                                          name: String,
                                          file: StaticString = #filePath,
                                          line: UInt = #line) async throws -> UUID {
        CADDocumentFaultInjection.beforeNamedVersionPromotion = {
            throw NSError(domain: "FloeCADVersionTest", code: 77,
                          userInfo: [NSLocalizedDescriptionKey:
                            "injected final promotion failure"])
        }
        defer { CADDocumentFaultInjection.beforeNamedVersionPromotion = nil }
        do {
            _ = try await document.createNamedVersion(name: name)
            XCTFail("a checkpoint that never became visible must not be reported as success",
                    file: file, line: line)
            throw CADNamedVersionError.saveFailed("unexpected create success")
        } catch let error as CADNamedVersionError {
            guard case let .promotionFailed(id, _, _, _, _) = error else {
                throw error
            }
            return id
        }
    }

    private func manifestObject(_ package: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: package.appendingPathComponent("manifest.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func siblingDebris(_ package: URL) -> [String] {
        let parent = package.deletingLastPathComponent()
        let name = package.lastPathComponent
        return ((try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? [])
            .filter {
                $0.contains(".failed-") || $0.contains(".rotate-")
                    || $0.contains(".staging-") || $0.contains(".restore-")
            }
            .filter { $0.hasPrefix(".\(name).") }
    }

    private func versionDirectory(_ id: UUID, in package: URL) -> URL {
        package.appendingPathComponent("versions/\(id.uuidString)", isDirectory: true)
    }

    private func recoveryDirectory(_ id: UUID, in package: URL) -> URL {
        package.appendingPathComponent("versions/.pending-\(id.uuidString)",
                                       isDirectory: true)
    }

    private func recoveryMarkerURL(_ id: UUID, in package: URL) -> URL {
        recoveryDirectory(id, in: package)
            .appendingPathComponent(CADNamedVersionRecoveryMarker.fileName)
    }

    private func jsonObject(_ raw: String) throws -> [String: Any] {
        let data = Data(raw.utf8)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Copy one verified visible checkpoint to an unmarked `.pending-<uuid>`
    /// path. This models a live/incomplete staging entry: it must never be
    /// listed, promoted or deleted by the recovery surface.
    private func installUnmarkedStagingCopy(of versionID: UUID,
                                            as id: UUID,
                                            in package: URL) throws {
        let source = versionDirectory(versionID, in: package)
        let destination = recoveryDirectory(id, in: package)
        try FileManager.default.copyItem(at: source, to: destination)
        // A visible checkpoint normally has no marker; remove any leftover so
        // this fixture models genuinely unmarked staging.
        try? FileManager.default.removeItem(
            at: destination.appendingPathComponent(CADNamedVersionRecoveryMarker.fileName))
        let recordURL = destination.appendingPathComponent("version.json")
        let data = try Data(contentsOf: recordURL)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["id"] = id.uuidString
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: recordURL, options: .atomic)
    }

    /// Exact content hashes of every non-hidden regular package file, keyed by
    /// package-relative path. Used to prove a failed checkpoint operation did
    /// not rewrite the manifest/document/blobs of the current commit or any
    /// existing checkpoint.
    private func packageFileHashes(_ package: URL) throws -> [String: String] {
        let manager = FileManager.default
        let root = package.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard let enumerator = manager.enumerator(
            at: package,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]) else { return [:] }
        var hashes: [String: String] = [:]
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let resolved = file.standardizedFileURL.resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(root) else { continue }
            let relative = String(resolved.path.dropFirst(root.count))
            let digest = SHA256.hash(data: try Data(contentsOf: file))
                .map { String(format: "%02x", $0) }.joined()
            hashes[relative] = digest
        }
        return hashes
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func hiddenVersionEntries(in package: URL) throws -> [String] {
        let versions = package.appendingPathComponent("versions", isDirectory: true)
        guard FileManager.default.fileExists(atPath: versions.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: versions.path)
            .filter { $0.hasPrefix(".") }
    }

    private func tinyPNG() -> Data {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Z4xQAAAAASUVORK5CYII=")!
    }

    private func setMaterialLibrary(_ library: CADMaterialLibrary,
                                    on document: FloeCADDocument) throws {
        document.session.perform(SetMaterialLibraryDataCommand(
            before: document.project.materialsData,
            after: try JSONEncoder().encode(library)))
    }

    private func installWholeDocumentAssets(_ document: FloeCADDocument,
                                            bodyID: UUID,
                                            libraryName: String = "Painted") throws {
        let texture = CADMaterialTexture(slot: .baseColor, bytes: tinyPNG())
        let definition = CADMaterialDefinition(
            name: libraryName, baseColor: SIMD4(0.2, 0.4, 0.9, 1),
            metallic: 0.7, roughness: 0.25, textures: [texture])
        let library = CADMaterialLibrary(entries: [definition])
        document.session.perform(SetMaterialLibraryDataCommand(
            before: document.project.materialsData,
            after: try JSONEncoder().encode(library)))
        var applied = BodyMaterialSpec(baseColor: SIMD4(0.2, 0.4, 0.9, 1),
                                       metallic: 0.7, roughness: 0.25)
        applied.materialID = definition.id.raw.uuidString
        applied.materialName = definition.name
        applied.baseColorTexture = texture.bytes
        document.session.perform(SetMaterialCommand(
            bodyIDs: [BodyID(raw: bodyID)],
            material: applied,
            document: document.session.document))
        let externalReference = CADPartReference(
            name: "External part",
            sourceDocumentID: UUID(),
            sourceBodyID: UUID(),
            sourceDocumentName: "referenced-source.floecad",
            sourceBodyName: "Bracket",
            verifierSchemaVersion: Project.currentFormatVersion,
            sourceSchemaVersion: Project.currentFormatVersion,
            sourceRevision: 3,
            sourceContentHash: String(repeating: "a", count: 64),
            stagedBodyID: bodyID,
            stagedGeometryHash: String(repeating: "b", count: 64))
        document.session.perform(SetAssemblyDataCommand(
            before: document.project.assemblyData,
            after: try JSONEncoder().encode(CADAssembly(
                instances: [CADAssemblyInstance(name: "Part", bodyID: UUID(uuidString: bodyID.uuidString)!)],
                partReferences: [externalReference]))))
        document.session.perform(SetDrawingsDataCommand(
            before: document.project.drawingsData,
            after: try JSONEncoder().encode(CADDrawingSet.standardSheet(
                for: bodyID, title: "Version Sheet"))))
        document.session.perform(SetSceneSettingsDataCommand(
            before: document.project.sceneSettingsData,
            after: try JSONEncoder().encode(CADSceneSettings(showsGrid: true))))
        document.session.perform(SetScriptsDataCommand(
            before: document.project.scriptsData,
            after: Data(#"{"records":[]}"#.utf8)))
        document.session.perform(SetAnimationDataCommand(
            before: document.project.animationData,
            after: try JSONEncoder().encode(CADAnimationDocument())))
    }

    // MARK: - Two named versions, exact compare, restore, undo boundary

    func testTwoNamedVersionsExactCompareRestoreUndoBoundaryAndReopen() async throws {
        let (document, url) = try await makeDocument()
        let first = addTriangle(document, name: "Base Plate")
        try await save(document)

        let base = try await document.createNamedVersion(name: "Base")
        XCTAssertEqual(base.revision, document.revision)
        XCTAssertLessThan(base.version.sourceRevision, base.revision,
                          "the first checkpoint raises the named-version floor with a new revision")
        let versionsAfterBase = try await document.namedVersions()
        XCTAssertEqual(versionsAfterBase.count, 1)
        XCTAssertEqual(base.version.contentSHA256, document.contentSHA256)
        XCTAssertFalse(base.version.isRecovery)
        let revisionAtBase = document.revision

        addTriangle(document, name: "Second Part", offset: 40)
        try await save(document)
        let versionsAfterSave = try await document.namedVersions()
        XCTAssertEqual(versionsAfterSave.map(\.name), ["Base"],
                       "an ordinary commit must not delete stored versions")
        let edited = try await document.createNamedVersion(name: "Edited")
        XCTAssertGreaterThan(edited.version.sourceRevision, revisionAtBase)
        XCTAssertNotEqual(base.version.contentSHA256, edited.version.contentSHA256)

        // Read-only compare: named version against the committed current.
        let beforeCompareRevision = document.revision
        let comparison = try await document.compareNamedVersion(base.version.id)
        XCTAssertEqual(document.revision, beforeCompareRevision, "compare must not write")
        XCTAssertFalse(comparison.identical)
        XCTAssertTrue(comparison.revisionChanged)
        XCTAssertTrue(comparison.changedSections.contains("geometry"))
        let addedSecondPart = comparison.differences.contains {
            $0.section == "geometry" && $0.change == "added" && $0.name == "Second Part"
        }
        XCTAssertTrue(addedSecondPart, "the actual added body must be reported")

        // Restore Base: revision advances, the old design is recoverable, and
        // undo/redo starts a new boundary.
        let restored = try await document.restoreNamedVersion(base.version.id)
        XCTAssertFalse(restored.alreadyCurrent)
        XCTAssertEqual(restored.previousRevision, document.revision - 1)
        XCTAssertEqual(restored.revision, document.revision)
        XCTAssertEqual(document.summary().bodyCount, 1)
        XCTAssertFalse(document.session.undoStack.canUndo,
                       "restore must start a fresh undo boundary")
        XCTAssertFalse(document.session.undoStack.canRedo)
        XCTAssertNotNil(restored.recoveryVersion)

        let recoveryRows = try await document.namedVersions()
        let recovery = try XCTUnwrap(recoveryRows.first { $0.id == restored.recoveryVersion?.id })
        XCTAssertTrue(recovery.isRecovery)
        XCTAssertEqual(recovery.counts["bodies"], 2,
                       "recovery checkpoint is the exact pre-restore design")

        let nowSame = try await document.compareNamedVersion(base.version.id)
        XCTAssertTrue(nowSame.identical)
        XCTAssertTrue(nowSame.contentIdentical)

        // One ordinary edit can be undone to the restored state; there is no
        // second undo crossing the restore boundary.
        addTriangle(document, name: "After Restore")
        XCTAssertTrue(document.session.undoStack.canUndo)
        document.session.undo()
        XCTAssertEqual(document.summary().bodyCount, 1)
        XCTAssertFalse(document.session.undoStack.canUndo)

        try await save(document)
        let revisionAfterEdit = document.revision
        document.close()

        let reopened = try await FloeCADDocument.open(at: url)
        XCTAssertEqual(reopened.summary().bodyCount, 1)
        XCTAssertEqual(reopened.revision, revisionAfterEdit)
        let persisted = try await reopened.namedVersions()
        XCTAssertEqual(Set(persisted.filter { !$0.isRecovery }.map(\.name)), ["Base", "Edited"])
        XCTAssertTrue(persisted.contains { $0.isRecovery })
        reopened.close()
    }

    // MARK: - Versions survive ordinary commits and failed commits

    func testOrdinarySavePreservesVersionsAndFailedCommitKeepsCheckpoints() async throws {
        let (document, url) = try await makeDocument("Rotation")
        addTriangle(document, name: "First")
        try await save(document)
        _ = try await document.createNamedVersion(name: "One")

        addTriangle(document, name: "Second", offset: 30)
        try await save(document)
        _ = try await document.createNamedVersion(name: "Two")
        let versionsBeforeFailure = try await document.namedVersions()
        XCTAssertEqual(Set(versionsBeforeFailure.map(\.name)), ["One", "Two"])

        let committedRevision = document.revision
        let committedContent = document.contentSHA256
        addTriangle(document, name: "Third", offset: 60)
        CADDocumentFaultInjection.beforeCommit = {
            throw NSError(domain: "FloeCADVersionTest", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "injected version-save failure"])
        }
        let failed = await document.save()
        CADDocumentFaultInjection.beforeCommit = nil
        XCTAssertFalse(failed.succeeded)
        XCTAssertEqual(document.revision, committedRevision)
        XCTAssertEqual(document.contentSHA256, committedContent)
        let versionsAfterFailure = try await document.namedVersions()
        XCTAssertEqual(Set(versionsAfterFailure.map(\.name)), ["One", "Two"],
                       "a failed commit must not delete or corrupt stored versions")

        document.close()
        let reopened = try await FloeCADDocument.open(at: url)
        let reopenedVersions = try await reopened.namedVersions()
        XCTAssertEqual(Set(reopenedVersions.map(\.name)), ["One", "Two"])
        XCTAssertEqual(reopened.revision, committedRevision)
        reopened.close()
    }

    // MARK: - Whole document assets

    func testWholeDocumentAssetsRoundTripThroughVersionAndRestore() async throws {
        let (document, url) = try await makeDocument("Full")
        let bodyID = addTriangle(document, name: "Painted Part")
        try installWholeDocumentAssets(document, bodyID: bodyID)
        try await save(document)

        let assets = (
            materials: document.project.materialsData,
            assembly: document.project.assemblyData,
            drawings: document.project.drawingsData,
            scene: document.project.sceneSettingsData,
            scripts: document.project.scriptsData,
            animation: document.project.animationData)
        let base = try await document.createNamedVersion(name: "Full Assembly")

        // Change every section, then checkpoint the changed design.
        document.session.perform(SetMaterialLibraryDataCommand(
            before: document.project.materialsData,
            after: try JSONEncoder().encode(CADMaterialLibrary())))
        document.session.perform(SetAssemblyDataCommand(
            before: document.project.assemblyData,
            after: try JSONEncoder().encode(CADAssembly())))
        document.session.perform(SetDrawingsDataCommand(
            before: document.project.drawingsData, after: nil))
        document.session.perform(SetSceneSettingsDataCommand(
            before: document.project.sceneSettingsData,
            after: try JSONEncoder().encode(CADSceneSettings(showsGrid: false))))
        document.session.perform(SetScriptsDataCommand(
            before: document.project.scriptsData, after: nil))
        document.session.perform(SetAnimationDataCommand(
            before: document.project.animationData, after: nil))
        addTriangle(document, name: "Extra", offset: 80)
        try await save(document)
        let edited = try await document.createNamedVersion(name: "Stripped")

        let comparison = try await document.compareNamedVersion(base.version.id,
                                                                against: edited.version.id)
        for section in ["geometry", "materials", "assembly", "drawings", "presentation", "scripts"] {
            XCTAssertTrue(comparison.changedSections.contains(section),
                          "missing \(section) in \(comparison.changedSections)")
        }
        XCTAssertFalse(comparison.identical)

        document.close()
        let reopened = try await FloeCADDocument.open(at: url)
        let restore = try await reopened.restoreNamedVersion(base.version.id)
        XCTAssertFalse(restore.alreadyCurrent)
        XCTAssertEqual(reopened.project.materialsData, assets.materials)
        XCTAssertEqual(reopened.project.assemblyData, assets.assembly)
        let restoredAssembly = try CADAssembly.decode(from: reopened.project.assemblyData)
        XCTAssertEqual(restoredAssembly.partReferences.first?.sourceDocumentName,
                       "referenced-source.floecad",
                       "external part reference metadata restores without copying the external file")
        XCTAssertEqual(reopened.project.drawingsData, assets.drawings)
        XCTAssertEqual(reopened.project.sceneSettingsData, assets.scene)
        XCTAssertEqual(reopened.project.scriptsData, assets.scripts)
        XCTAssertEqual(reopened.project.animationData, assets.animation)
        let restoredBody = try XCTUnwrap(reopened.session.document.bodies.first)
        XCTAssertNotNil(restoredBody.material?.baseColorTexture,
                        "embedded texture bytes must survive the whole-document checkpoint")
        XCTAssertEqual(restoredBody.material?.materialName, "Painted")
        reopened.close()
    }

    // MARK: - Conflict / refusal

    func testRestoreConflictAndInvalidNameLeaveCurrentUntouched() async throws {
        let (document, _) = try await makeDocument("Conflict")
        addTriangle(document, name: "Only")
        try await save(document)
        _ = try await document.createNamedVersion(name: "Stable")
        addTriangle(document, name: "Second", offset: 30)
        try await save(document)
        let currentRevision = document.revision
        let currentContent = document.contentSHA256
        let bodyCount = document.summary().bodyCount

        let versions = try await document.namedVersions()
        let stable = try XCTUnwrap(versions.first { $0.name == "Stable" })
        do {
            _ = try await document.restoreNamedVersion(stable.id,
                                                       expectedRevision: currentRevision + 1)
            XCTFail("stale revision must be refused")
        } catch let error as CADNamedVersionError {
            guard case .revisionMismatch = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(document.revision, currentRevision)
        XCTAssertEqual(document.contentSHA256, currentContent)
        XCTAssertEqual(document.summary().bodyCount, bodyCount)

        for bad in ["", "   ", "Bad/Name", "Bad\\Name", "..", String(repeating: "x", count: 121)] {
            do {
                _ = try await document.createNamedVersion(name: bad)
                XCTFail("invalid version name must be refused: \(bad)")
            } catch let error as CADNamedVersionError {
                guard case .invalidName = error else {
                    return XCTFail("unexpected error for \(bad): \(error)")
                }
            }
        }

        do {
            _ = try await document.createNamedVersion(name: "stable")
            XCTFail("duplicate names must be refused case-insensitively")
        } catch let error as CADNamedVersionError {
            guard case .duplicateName = error else {
                return XCTFail("unexpected duplicate error: \(error)")
            }
        }

        let directories = try FileManager.default.contentsOfDirectory(
            at: document.url.appendingPathComponent("versions"), includingPropertiesForKeys: nil)
            .map(\.lastPathComponent)
            .filter { !$0.hasPrefix(".") }
        XCTAssertTrue(directories.allSatisfy { UUID(uuidString: $0) != nil },
                      "user names must never become directory names")
    }

    // MARK: - Corrupt / incompatible checkpoints

    func testCorruptAndIncompatibleCheckpointsNeverOverwriteCurrent() async throws {
        let (document, url) = try await makeDocument("Corrupt")
        addTriangle(document, name: "Keep")
        try await save(document)
        let version = try await document.createNamedVersion(name: "Checkpoint")
        let currentRevision = document.revision
        let currentContent = document.contentSHA256
        let bodyCount = document.summary().bodyCount
        let directory = versionDirectory(version.version.id, in: url)

        // Corrupt the checkpoint's document bytes. Compare/restore must refuse
        // with the checkpoint error and must not silently compare a partial
        // state or touch the current package.
        let documentURL = directory.appendingPathComponent("document.json")
        let original = try Data(contentsOf: documentURL)
        try (original + Data("{corrupt".utf8)).write(to: documentURL)
        do {
            _ = try await document.compareNamedVersion(version.version.id)
            XCTFail("corrupt checkpoint must not compare")
        } catch let error as CADNamedVersionError {
            guard case .corrupt = error else {
                return XCTFail("unexpected compare error: \(error)")
            }
        }
        do {
            _ = try await document.restoreNamedVersion(version.version.id)
            XCTFail("corrupt checkpoint must not restore")
        } catch let error as CADNamedVersionError {
            guard case .corrupt = error else {
                return XCTFail("unexpected restore error: \(error)")
            }
        }
        XCTAssertEqual(document.revision, currentRevision)
        XCTAssertEqual(document.contentSHA256, currentContent)
        XCTAssertEqual(document.summary().bodyCount, bodyCount)

        // A missing record is listed as an unusable row instead of vanishing.
        try FileManager.default.removeItem(at: directory.appendingPathComponent("version.json"))
        let rows = try await document.namedVersions()
        let row = try XCTUnwrap(rows.first { $0.id == version.version.id })
        XCTAssertFalse(row.isUsable)
        XCTAssertNotNil(row.issue)

        // Deleting that checkpoint removes only its directory.
        let deletion = try await document.deleteNamedVersion(version.version.id)
        XCTAssertTrue(deletion.deleted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(document.revision, currentRevision)
        XCTAssertEqual(document.summary().bodyCount, bodyCount)

        // A newer record version is refused actionably (never downgraded or
        // overwritten) and still leaves the current document alone.
        let future = try await document.createNamedVersion(name: "Future")
        let futureDir = versionDirectory(future.version.id, in: url)
        let recordURL = futureDir.appendingPathComponent("version.json")
        let recordData = try Data(contentsOf: recordURL)
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: recordData) as? [String: Any])
        record["recordVersion"] = 2
        try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            .write(to: recordURL)

        let listed = try await document.namedVersions()
        let futureRow = try XCTUnwrap(listed.first { $0.id == future.version.id })
        XCTAssertFalse(futureRow.isUsable)
        do {
            _ = try await document.restoreNamedVersion(future.version.id)
            XCTFail("future checkpoint must not restore")
        } catch let error as CADNamedVersionError {
            guard case .incompatible = error else {
                return XCTFail("unexpected future error: \(error)")
            }
        }
        XCTAssertEqual(document.revision, currentRevision)
        XCTAssertEqual(document.contentSHA256, currentContent)
        XCTAssertEqual(document.summary().bodyCount, bodyCount)
    }

    // MARK: - Interrupted-commit recovery carries versions or warns

    func testInterruptedRecoveryCarriesVersionsOrWarns() async throws {
        let (document, url) = try await makeDocument("Recovery")
        addTriangle(document, name: "Solid")
        try await save(document)
        _ = try await document.createNamedVersion(name: "Keep")
        document.close()
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("previous/manifest.json").path))

        // Simulate an interrupted commit: the current manifest is missing, but
        // the last complete commit is under previous/. The current root still
        // carries versions, which recovery must carry forward.
        try FileManager.default.removeItem(at: url.appendingPathComponent("manifest.json"))
        let recovered = try await FloeCADDocument.open(at: url)
        let recoveredRows = try await recovered.namedVersions()
        XCTAssertEqual(recoveredRows.map(\.name), ["Keep"])
        let recoveredFloor = try XCTUnwrap(try manifestObject(url)["schemaVersion"] as? Int)
        XCTAssertGreaterThanOrEqual(recoveredFloor, CADDocumentFormat.namedVersionFormatVersion,
                                    "carrying versions forward must keep the floor")
        XCTAssertFalse(recovered.session.loadWarning?.contains("named versions") == true)
        recovered.close()

        // Now make the carry fail. Opening still recovers the document, but
        // must not claim the checkpoint came with it.
        try FileManager.default.removeItem(at: url.appendingPathComponent("manifest.json"))
        CADDocumentFaultInjection.beforeVersionRecoveryCarry = {
            throw NSError(domain: "FloeCADVersionTest", code: 30,
                          userInfo: [NSLocalizedDescriptionKey: "injected version carry failure"])
        }
        let recoveredWithoutVersions = try await FloeCADDocument.open(at: url)
        CADDocumentFaultInjection.beforeVersionRecoveryCarry = nil
        let missingCarryRows = try await recoveredWithoutVersions.namedVersions()
        XCTAssertEqual(missingCarryRows.count, 0)
        XCTAssertTrue(recoveredWithoutVersions.session.loadWarning?
            .contains("named versions") == true,
            "a failed version carry must be surfaced, not silently reported as recovered")
        recoveredWithoutVersions.close()
    }

    // MARK: - Delete only the checkpoint

    func testDeleteVersionLeavesDocumentOtherVersionsAndExternalFiles() async throws {
        let (document, url) = try await makeDocument("Delete")
        addTriangle(document, name: "Solid")
        try await save(document)
        let first = try await document.createNamedVersion(name: "Keep me")
        let second = try await document.createNamedVersion(name: "Delete me")
        let external = workDir.appendingPathComponent("referenced-part.step")
        let externalBytes = Data("ISO-10303-21; external project file".utf8)
        try externalBytes.write(to: external)
        let revision = document.revision
        let content = document.contentSHA256

        let deletion = try await document.deleteNamedVersion(second.version.id)
        XCTAssertTrue(deletion.deleted)
        XCTAssertNil(deletion.cleanupIssue)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: versionDirectory(second.version.id, in: url).path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: versionDirectory(first.version.id, in: url).path))
        XCTAssertEqual(try Data(contentsOf: external), externalBytes,
                       "deleting a version must never delete external project files")
        XCTAssertEqual(document.revision, revision)
        XCTAssertEqual(document.contentSHA256, content)

        let rows = try await document.namedVersions()
        XCTAssertEqual(rows.map(\.id), [first.version.id])
        let comparison = try await document.compareNamedVersion(first.version.id)
        XCTAssertTrue(comparison.identical,
                      "remaining checkpoint still verifies against the unchanged current document")
    }

    // MARK: - Version floor / branch / race / cancellation / transfer recovery

    func testNamedVersionCreationRaisesOnlyVersionPackageFloor() async throws {
        let (document, url) = try await makeDocument("Floor")
        addTriangle(document, name: "Solid")
        try await save(document)
        let before = try XCTUnwrap(try manifestObject(url)["schemaVersion"] as? Int)
        XCTAssertLessThan(before, CADDocumentFormat.namedVersionFormatVersion)

        let base = try await document.createNamedVersion(name: "Base")
        let after = try XCTUnwrap(try manifestObject(url)["schemaVersion"] as? Int)
        XCTAssertGreaterThanOrEqual(after, CADDocumentFormat.namedVersionFormatVersion)
        XCTAssertEqual(document.project.formatVersion, CADDocumentFormat.namedVersionFormatVersion)
        XCTAssertTrue(document.project.hasNamedVersions)
        XCTAssertGreaterThan(document.revision, base.version.sourceRevision)

        addTriangle(document, name: "After", offset: 20)
        try await save(document)
        let versionsAfterSave = try await document.namedVersions()
        XCTAssertEqual(versionsAfterSave.count, 1)
        let afterSave = try XCTUnwrap(try manifestObject(url)["schemaVersion"] as? Int)
        XCTAssertGreaterThanOrEqual(afterSave, CADDocumentFormat.namedVersionFormatVersion)
        document.close()

        let (legacy, legacyURL) = try await makeDocument("Legacy")
        addTriangle(legacy, name: "Legacy solid")
        try await save(legacy)
        let legacyFloor = try XCTUnwrap(try manifestObject(legacyURL)["schemaVersion"] as? Int)
        XCTAssertLessThan(legacyFloor, CADDocumentFormat.namedVersionFormatVersion,
                          "a document without versions must not be blanket-bumped")
        legacy.close()
    }

    func testFailedVersionCreationBeforeFloorCommitLeavesLegacyFloor() async throws {
        let (document, url) = try await makeDocument("FloorFail")
        addTriangle(document, name: "Solid")
        try await save(document)
        let revision = document.revision
        let content = document.contentSHA256
        let before = try XCTUnwrap(try manifestObject(url)["schemaVersion"] as? Int)

        CADDocumentFaultInjection.beforeCommit = {
            throw NSError(domain: "FloeCADVersionTest", code: 7,
                          userInfo: [NSLocalizedDescriptionKey: "injected floor bump failure"])
        }
        do {
            _ = try await document.createNamedVersion(name: "Should not exist")
            XCTFail("injected floor-commit failure must be reported")
        } catch {
            // expected
        }
        CADDocumentFaultInjection.beforeCommit = nil

        XCTAssertEqual(document.revision, revision)
        XCTAssertEqual(document.contentSHA256, content)
        let rowsAfterFailure = try await document.namedVersions()
        XCTAssertTrue(rowsAfterFailure.isEmpty)
        let after = try XCTUnwrap(try manifestObject(url)["schemaVersion"] as? Int)
        XCTAssertEqual(after, before, "a failed creation must not raise the floor")
        XCTAssertEqual(siblingDebris(url), [])
        document.close()
    }

    func testRestoreAsNamedBranchKeepsSameDocumentIdentity() async throws {
        let (document, url) = try await makeDocument("Branch")
        addTriangle(document, name: "Base")
        try await save(document)
        let base = try await document.createNamedVersion(name: "Base")
        addTriangle(document, name: "Edited", offset: 30)
        try await save(document)

        let restored = try await document.restoreNamedVersion(
            base.version.id, createBranch: true)
        XCTAssertFalse(restored.alreadyCurrent)
        XCTAssertEqual(document.url, url, "in-place restore keeps the same document identity")
        let branch = try XCTUnwrap(restored.branchVersion)
        XCTAssertEqual(branch.parentVersionID, base.version.id)
        XCTAssertEqual(branch.restoredFromVersionID, base.version.id)
        XCTAssertEqual(branch.sourceRevision, restored.revision)
        XCTAssertTrue(branch.name.contains("Branch"))
        XCTAssertNotNil(restored.recoveryVersion)
        XCTAssertNil(restored.branchIssue)

        let comparison = try await document.compareNamedVersion(branch.id)
        XCTAssertTrue(comparison.identical)
        XCTAssertTrue(comparison.contentIdentical)
        let rows = try await document.namedVersions()
        XCTAssertTrue(rows.contains { $0.id == branch.id && $0.parentVersionID == base.version.id })
        document.close()
    }

    func testRestoreRejectsEditDuringCheckpointLoad() async throws {
        let (document, _) = try await makeDocument("Race")
        addTriangle(document, name: "Base")
        try await save(document)
        let base = try await document.createNamedVersion(name: "Base")
        addTriangle(document, name: "Current", offset: 20)
        try await save(document)
        let bodyCount = document.summary().bodyCount
        let versionCount = try await document.namedVersions().count

        CADNamedVersionTestHooks.afterCheckpointLoad = {
            _ = self.addTriangle(document, name: "Race edit", offset: 50)
        }
        do {
            _ = try await document.restoreNamedVersion(base.version.id)
            XCTFail("an edit during checkpoint load must refuse the restore")
        } catch let error as CADNamedVersionError {
            guard case .documentBusy = error else {
                return XCTFail("unexpected race error: \(error)")
            }
        }
        CADNamedVersionTestHooks.afterCheckpointLoad = nil
        let versionsAfterRefusal = try await document.namedVersions()
        XCTAssertEqual(versionsAfterRefusal.count, versionCount,
                       "the refused restore must not create a recovery checkpoint")
        XCTAssertEqual(document.summary().bodyCount, bodyCount + 1,
                       "the user's racing edit is preserved")
        document.close()
    }

    func testCancellationAfterCheckpointLoadCreatesNoRecovery() async throws {
        let (document, _) = try await makeDocument("Cancel")
        addTriangle(document, name: "Base")
        try await save(document)
        let base = try await document.createNamedVersion(name: "Base")
        addTriangle(document, name: "Current", offset: 20)
        try await save(document)
        let revision = document.revision
        let content = document.contentSHA256
        let versionCount = try await document.namedVersions().count

        CADNamedVersionTestHooks.beforeRestoreCommit = {
            throw CancellationError()
        }
        do {
            _ = try await document.restoreNamedVersion(base.version.id)
            XCTFail("cancellation must abort the restore")
        } catch is CancellationError {
            // expected
        }
        CADNamedVersionTestHooks.beforeRestoreCommit = nil
        XCTAssertEqual(document.revision, revision)
        XCTAssertEqual(document.contentSHA256, content)
        let versionsAfterCancel = try await document.namedVersions()
        XCTAssertEqual(versionsAfterCancel.count, versionCount,
                       "cancellation must remove the provisional recovery checkpoint")
        document.close()
    }

    func testCommitVersionTransferFailureRestoresOldPackage() async throws {
        let cases: [(name: String, install: () -> Void)] = [
            ("beforeVersionTransfer", {
                CADDocumentFaultInjection.beforeVersionTransfer = {
                    throw NSError(domain: "FloeCADVersionTest", code: 20,
                                  userInfo: [NSLocalizedDescriptionKey: "injected before version transfer"])
                }
            }),
            ("afterVersionTransfer", {
                CADDocumentFaultInjection.afterVersionTransfer = {
                    throw NSError(domain: "FloeCADVersionTest", code: 21,
                                  userInfo: [NSLocalizedDescriptionKey: "injected after version transfer"])
                }
            }),
            ("beforeStagedPromotion", {
                CADDocumentFaultInjection.beforeStagedPromotion = {
                    throw NSError(domain: "FloeCADVersionTest", code: 22,
                                  userInfo: [NSLocalizedDescriptionKey: "injected staged promotion failure"])
                }
            }),
        ]
        for testCase in cases {
            let (document, url) = try await makeDocument("Transfer-\(testCase.name)")
            addTriangle(document, name: "Solid")
            try await save(document)
            _ = try await document.createNamedVersion(name: "One")
            _ = try await document.createNamedVersion(name: "Two")
            let revision = document.revision
            let content = document.contentSHA256
            testCase.install()
            addTriangle(document, name: "Edit", offset: 40)
            let failed = await document.save()
            XCTAssertFalse(failed.succeeded, "\(testCase.name) must fail the save")
            document.close()
            CADDocumentFaultInjection.beforeVersionTransfer = nil
            CADDocumentFaultInjection.afterVersionTransfer = nil
            CADDocumentFaultInjection.beforeStagedPromotion = nil

            let reopened = try await FloeCADDocument.open(at: url)
            XCTAssertEqual(reopened.revision, revision,
                           "\(testCase.name) must restore the old revision")
            XCTAssertEqual(reopened.contentSHA256, content,
                           "\(testCase.name) must restore the old content")
            let reopenedRows = try await reopened.namedVersions()
            XCTAssertEqual(Set(reopenedRows.map(\.name)), ["One", "Two"],
                           "\(testCase.name) must preserve both checkpoints")
            reopened.close()
            XCTAssertEqual(siblingDebris(url), [], "\(testCase.name) left recovery debris")
        }
    }

    // MARK: - R3: failed create cleanup / real cancellation / promotion window

    /// The create catch path must clean up only its own hidden pending entry.
    /// A REAL FileManager failure at the final promotion (after staging, copy
    /// and verification) must leave every existing user checkpoint, recovery
    /// checkpoint and unknown retained entry byte-for-byte intact.
    func testActualFileManagerPromotionFailureKeepsEveryExistingCheckpointExact() async throws {
        let (document, url) = try await makeDocument("PromotionPreserve")
        addTriangle(document, name: "Base")
        try await save(document)
        let first = try await document.createNamedVersion(name: "One")
        addTriangle(document, name: "Second", offset: 20)
        try await save(document)
        let second = try await document.createNamedVersion(name: "Two")

        let store = CADNamedVersionStore(packageURL: url)
        let recovery = try await store.create(
            name: "Recovery copy",
            expectedRevision: document.revision,
            expectedContentSHA256: document.contentSHA256,
            isRecovery: true,
            note: "retained recovery checkpoint")

        // Entries this build does not understand must never be swept away by
        // another checkpoint's cleanup.
        let versionsURL = url.appendingPathComponent("versions", isDirectory: true)
        let retained = versionsURL.appendingPathComponent("retained-note.json")
        let retainedBytes = Data(#"{"retained":"do not delete"}"#.utf8)
        try retainedBytes.write(to: retained)
        let hiddenRetained = versionsURL.appendingPathComponent(".retained-foreign",
                                                                 isDirectory: true)
        try FileManager.default.createDirectory(at: hiddenRetained,
                                                withIntermediateDirectories: true)
        let hiddenBytes = Data("foreign retained bytes".utf8)
        try hiddenBytes.write(to: hiddenRetained.appendingPathComponent("payload.bin"))

        let before = try packageFileHashes(url)
        let revision = document.revision
        let content = document.contentSHA256
        let rowsBefore = try await document.namedVersions()
        XCTAssertEqual(Set(rowsBefore.map(\.id)),
                       Set([first.version.id, second.version.id, recovery.summary.id]))

        let failing = PromotionFailingFileManager()
        failing.failPendingPromotion = true
        let failingStore = CADNamedVersionStore(packageURL: url, fileManager: failing)
        do {
            _ = try await failingStore.create(
                name: "Three",
                expectedRevision: revision,
                expectedContentSHA256: content)
            XCTFail("a real FileManager promotion failure must be reported")
        } catch let error as CADNamedVersionError {
            guard case .ioFailure(let detail) = error else {
                return XCTFail("expected ioFailure, got \(error)")
            }
            XCTAssertTrue(detail.contains("injected actual FileManager"),
                          "the failure must be the real FileManager error, got \(detail)")
        }
        XCTAssertEqual(failing.promotionAttempts, 1,
                       "exactly the final pending promotion must be attempted")

        // Current commit and every existing checkpoint are untouched.
        XCTAssertEqual(try packageFileHashes(url), before)
        XCTAssertEqual(document.revision, revision)
        XCTAssertEqual(document.contentSHA256, content)
        XCTAssertEqual(try Data(contentsOf: retained), retainedBytes)
        XCTAssertEqual(try Data(contentsOf: hiddenRetained.appendingPathComponent("payload.bin")),
                       hiddenBytes)
        XCTAssertEqual(Set(try hiddenVersionEntries(in: url)), [".retained-foreign"],
                       "only the owned pending entry may be removed; hidden retained entries stay")

        let rowsAfter = try await document.namedVersions()
        XCTAssertEqual(Set(rowsAfter.map(\.id)),
                       Set([first.version.id, second.version.id, recovery.summary.id]))
        XCTAssertFalse(rowsAfter.contains { $0.name == "Three" })
        for row in rowsAfter {
            let loaded = try store.load(row.id)
            XCTAssertEqual(loaded.record.id, row.id)
            XCTAssertEqual(loaded.manifest.contentSHA256, row.contentSHA256)
        }
        let compare = try await document.compareNamedVersion(first.version.id)
        XCTAssertFalse(compare.identical)

        document.close()
        let reopened = try await FloeCADDocument.open(at: url)
        let reopenedRows = try await reopened.namedVersions()
        XCTAssertEqual(Set(reopenedRows.map(\.id)),
                       Set([first.version.id, second.version.id, recovery.summary.id]))
        XCTAssertEqual(try packageFileHashes(url), before,
                       "reopening a rejected create must not rewrite the package")
        reopened.close()
    }

    /// A promotion failure AFTER the format-floor commit cannot be treated as
    /// a safe precommit refusal: the package identity moved. The open document
    /// must adopt that identity, report no success without a visible version,
    /// retain the verified pending bytes for recovery, and keep later ordinary
    /// edit/save/reopen working.
    func testPromotionFailureAfterFloorCommitAdoptsIdentityAndRetainsCheckpoint() async throws {
        let (document, url) = try await makeDocument("PromotionWindow")
        addTriangle(document, name: "Base")
        try await save(document)
        let revisionBefore = document.revision
        let contentBefore = document.contentSHA256
        let floorBefore = try XCTUnwrap(try manifestObject(url)["schemaVersion"] as? Int)
        XCTAssertLessThan(floorBefore, CADDocumentFormat.namedVersionFormatVersion)

        CADDocumentFaultInjection.beforeNamedVersionPromotion = {
            throw NSError(domain: "FloeCADVersionTest", code: 40,
                          userInfo: [NSLocalizedDescriptionKey:
                            "injected final promotion failure after floor commit"])
        }
        var failure: CADNamedVersionError?
        do {
            _ = try await document.createNamedVersion(name: "Window")
            XCTFail("a checkpoint that never became visible must not be reported as success")
        } catch let error as CADNamedVersionError {
            failure = error
        } catch {
            XCTFail("expected a CADNamedVersionError, got \(error)")
        }
        CADDocumentFaultInjection.beforeNamedVersionPromotion = nil

        let promotionFailure = try XCTUnwrap(failure)
        guard case let .promotionFailed(pendingID, committedRevision,
                                        committedContent, committedModel, _) = promotionFailure else {
            return XCTFail("expected promotionFailed, got \(promotionFailure)")
        }
        // The floor commit is an explicitly reported safe commit: the open
        // document/store/session identity must have adopted it.
        XCTAssertEqual(committedRevision, document.revision)
        XCTAssertEqual(committedContent, document.contentSHA256)
        XCTAssertEqual(committedModel, document.modelSHA256)
        XCTAssertEqual(document.revision, revisionBefore + 1)
        XCTAssertEqual(document.contentSHA256, contentBefore,
                       "the floor commit keeps the exact current document bytes")
        XCTAssertTrue(document.project.hasNamedVersions)
        XCTAssertGreaterThanOrEqual(document.project.formatVersion,
                                    CADDocumentFormat.namedVersionFormatVersion)
        let floorAfter = try XCTUnwrap(try manifestObject(url)["schemaVersion"] as? Int)
        XCTAssertGreaterThanOrEqual(floorAfter, CADDocumentFormat.namedVersionFormatVersion)

        // No visible checkpoint and no success; the verified bytes are retained
        // under the hidden pending path and can be loaded/recovered explicitly.
        let visibleAfterFailure = try await document.namedVersions()
        XCTAssertEqual(visibleAfterFailure.count, 0)
        let pendingDirectory = url.appendingPathComponent(
            "versions/.pending-\(pendingID.uuidString)", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingDirectory.path))
        let store = CADNamedVersionStore(packageURL: url)
        let retained = try store.loadRetainedPendingCheckpoint(pendingID)
        XCTAssertEqual(retained.record.id, pendingID)
        XCTAssertEqual(retained.manifest.contentSHA256, contentBefore)

        // Later ordinary edit/save must use the adopted revision, not fail
        // stale, and the hidden checkpoint must survive the commit rotation.
        addTriangle(document, name: "After", offset: 30)
        try await save(document)
        let savedRevision = document.revision
        XCTAssertGreaterThan(savedRevision, committedRevision)
        let visibleAfterSave = try await document.namedVersions()
        XCTAssertEqual(visibleAfterSave.count, 0,
                       "the retained checkpoint stays hidden across an ordinary save")
        document.close()

        let reopened = try await FloeCADDocument.open(at: url)
        XCTAssertEqual(reopened.revision, savedRevision)
        XCTAssertEqual(reopened.summary().bodyCount, 2)
        XCTAssertGreaterThanOrEqual(reopened.project.formatVersion,
                                    CADDocumentFormat.namedVersionFormatVersion)
        let reopenedStore = CADNamedVersionStore(packageURL: reopened.url)
        let carried = try reopenedStore.loadRetainedPendingCheckpoint(pendingID)
        XCTAssertEqual(carried.manifest.contentSHA256, contentBefore,
                       "an ordinary commit must carry the retained pending bytes")
        let promoted = try reopenedStore.promoteRetainedPendingCheckpoint(pendingID)
        XCTAssertEqual(promoted.record.id, pendingID)
        let rows = try await reopened.namedVersions()
        XCTAssertEqual(rows.map(\.id), [pendingID])
        XCTAssertEqual(rows.first?.contentSHA256, contentBefore)
        reopened.close()
    }

    // MARK: - R4: retained recovery user workflow

    /// The actual closure gap: a promotion failure after the format-floor
    /// commit must be findable after reopen, list as recovery (not as a
    /// version), and recover through the ordinary typed action into a visible
    /// version that compare/restore/edit/save all use.
    func testPromotionFailureRecoverySurvivesReopenAndRecoversThroughTypedAction() async throws {
        let (document, url) = try await makeDocument("RecoveryFlow")
        addTriangle(document, name: "Base")
        try await save(document)
        let revisionBefore = document.revision
        let contentBefore = document.contentSHA256

        CADDocumentFaultInjection.beforeNamedVersionPromotion = {
            throw NSError(domain: "FloeCADVersionTest", code: 41,
                          userInfo: [NSLocalizedDescriptionKey:
                            "injected final promotion failure"])
        }
        var failure: CADNamedVersionError?
        do {
            _ = try await document.createNamedVersion(name: "Recover me")
            XCTFail("an unpublished checkpoint must not be reported as success")
        } catch let error as CADNamedVersionError {
            failure = error
        } catch {
            XCTFail("expected a CADNamedVersionError, got \(error)")
        }
        CADDocumentFaultInjection.beforeNamedVersionPromotion = nil
        let promotionFailure = try XCTUnwrap(failure)
        guard case let .promotionFailed(pendingID, committedRevision,
                                        committedContent, committedModel, _) = promotionFailure else {
            return XCTFail("expected promotionFailed, got \(promotionFailure)")
        }
        XCTAssertEqual(committedRevision, document.revision)
        XCTAssertEqual(committedContent, document.contentSHA256)
        XCTAssertEqual(committedModel, document.modelSHA256)
        XCTAssertEqual(document.revision, revisionBefore + 1)

        let visibleBefore = try await document.namedVersions()
        XCTAssertEqual(visibleBefore.count, 0)
        let recoveries = try await document.namedVersionRecoveries()
        XCTAssertEqual(recoveries.count, 1)
        let recovery = try XCTUnwrap(recoveries.first)
        XCTAssertEqual(recovery.id, pendingID)
        XCTAssertEqual(recovery.name, "Recover me")
        XCTAssertEqual(recovery.contentSHA256, contentBefore)
        XCTAssertTrue(recovery.isUsable)
        XCTAssertTrue(recovery.retainedAfterFormatFloor)
        XCTAssertNil(recovery.issue)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: recoveryMarkerURL(pendingID, in: url).path))

        // The ordinary typed tool exposes the same read-only recovery state.
        let listRaw = try await document.handleNamedVersionAction("list", args: [:])
        let listObject = try jsonObject(listRaw)
        XCTAssertEqual(listObject["ok"] as? Bool, true)
        let listedRecoveries = listObject["recoveries"] as? [[String: Any]]
        XCTAssertEqual(listedRecoveries?.count, 1)
        XCTAssertEqual(listedRecoveries?.first?["id"] as? String,
                       pendingID.uuidString)
        let listedVersions = listObject["versions"] as? [[String: Any]]
        XCTAssertEqual(listedVersions?.count, 0)

        document.close()

        let reopened = try await FloeCADDocument.open(at: url)
        let reopenedRecoveries = try await reopened.namedVersionRecoveries()
        XCTAssertEqual(reopenedRecoveries.map(\.id), [pendingID])
        let reopenedVisible = try await reopened.namedVersions()
        XCTAssertEqual(reopenedVisible.count, 0,
                       "retained bytes are not a visible version after reopen")

        // Recover through the SAME public action surface used by the tool.
        let recoverRaw = try await reopened.handleNamedVersionAction(
            "recover", args: ["version_id": pendingID.uuidString])
        let recoverObject = try jsonObject(recoverRaw)
        XCTAssertEqual(recoverObject["ok"] as? Bool, true)
        let resultObject = try XCTUnwrap(recoverObject["result"] as? [String: Any])
        let versionObject = try XCTUnwrap(resultObject["version"] as? [String: Any])
        XCTAssertEqual(versionObject["id"] as? String, pendingID.uuidString)
        XCTAssertEqual(resultObject["contentSHA256"] as? String, contentBefore)

        let visibleAfter = try await reopened.namedVersions()
        XCTAssertEqual(visibleAfter.map(\.id), [pendingID])
        XCTAssertEqual(visibleAfter.first?.contentSHA256, contentBefore)
        XCTAssertTrue(visibleAfter.first?.isUsable == true)
        let recoveriesAfter = try await reopened.namedVersionRecoveries()
        XCTAssertEqual(recoveriesAfter.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: recoveryDirectory(pendingID, in: url).path))
        let listAfterRaw = try await reopened.handleNamedVersionAction("list", args: [:])
        let listAfter = try jsonObject(listAfterRaw)
        let listAfterVersions = listAfter["versions"] as? [[String: Any]]
        XCTAssertTrue(listAfterVersions?.contains {
            ($0["id"] as? String) == pendingID.uuidString
        } == true, "the typed list must show the recovered visible version")
        let listAfterRecoveries = listAfter["recoveries"] as? [[String: Any]]
        XCTAssertEqual(listAfterRecoveries?.count, 0)

        let comparison = try await reopened.compareNamedVersion(pendingID)
        XCTAssertTrue(comparison.identical)
        XCTAssertTrue(comparison.contentIdentical)

        addTriangle(reopened, name: "After recovery", offset: 40)
        try await save(reopened)
        let editedRevision = reopened.revision
        XCTAssertGreaterThan(editedRevision, committedRevision)
        let restored = try await reopened.restoreNamedVersion(pendingID)
        XCTAssertFalse(restored.alreadyCurrent)
        XCTAssertEqual(reopened.revision, editedRevision + 1)
        XCTAssertEqual(reopened.summary().bodyCount, 1)
        reopened.close()

        let reopenedAgain = try await FloeCADDocument.open(at: url)
        let persisted = try await reopenedAgain.namedVersions()
        XCTAssertTrue(persisted.contains { $0.id == pendingID && $0.isUsable })
        let persistedRecoveries = try await reopenedAgain.namedVersionRecoveries()
        XCTAssertEqual(persistedRecoveries.count, 0)
        reopenedAgain.close()
    }

    /// The same retained/reopen/recover workflow after a REAL FileManager
    /// promotion fault, recovered through the public document service rather
    /// than a private-store promotion call.
    func testRealFileManagerPromotionFaultCreatesRecoverableEntryThroughPublicRecovery() async throws {
        let (document, url) = try await makeDocument("RealFileManagerRecovery")
        addTriangle(document, name: "Base")
        try await save(document)
        let contentBefore = document.contentSHA256

        let failing = PromotionFailingFileManager()
        failing.failPendingPromotion = true
        let store = CADNamedVersionStore(packageURL: url, fileManager: failing)
        do {
            _ = try await store.create(
                name: "FM retained",
                expectedRevision: document.revision,
                expectedContentSHA256: document.contentSHA256)
            XCTFail("a real FileManager promotion failure must be reported")
        } catch let error as CADNamedVersionError {
            guard case .ioFailure(let detail) = error else {
                return XCTFail("expected ioFailure, got \(error)")
            }
            XCTAssertTrue(detail.contains("injected actual FileManager"),
                          "the real FileManager error must be reported, got \(detail)")
        }
        XCTAssertEqual(failing.promotionAttempts, 1)
        let floor = try XCTUnwrap(try manifestObject(url)["schemaVersion"] as? Int)
        XCTAssertGreaterThanOrEqual(floor, CADDocumentFormat.namedVersionFormatVersion)
        document.close()

        let reopened = try await FloeCADDocument.open(at: url)
        let recoveries = try await reopened.namedVersionRecoveries()
        XCTAssertEqual(recoveries.count, 1)
        let recovery = try XCTUnwrap(recoveries.first)
        XCTAssertEqual(recovery.name, "FM retained")
        XCTAssertEqual(recovery.contentSHA256, contentBefore)
        XCTAssertTrue(recovery.isUsable)

        let result = try await reopened.recoverNamedVersion(recovery.id)
        XCTAssertEqual(result.version.id, recovery.id)
        XCTAssertEqual(result.contentSHA256, contentBefore)
        let visible = try await reopened.namedVersions()
        XCTAssertEqual(visible.map(\.id), [recovery.id])
        let remaining = try await reopened.namedVersionRecoveries()
        XCTAssertEqual(remaining.count, 0)

        let comparison = try await reopened.compareNamedVersion(recovery.id)
        XCTAssertTrue(comparison.contentIdentical)
        addTriangle(reopened, name: "After FM recovery", offset: 40)
        try await save(reopened)
        let restored = try await reopened.restoreNamedVersion(recovery.id)
        XCTAssertFalse(restored.alreadyCurrent)
        XCTAssertEqual(reopened.summary().bodyCount, 1)
        reopened.close()

        let reopenedAgain = try await FloeCADDocument.open(at: url)
        let persisted = try await reopenedAgain.namedVersions()
        XCTAssertTrue(persisted.contains { $0.id == recovery.id })
        reopenedAgain.close()
    }

    /// A failed retry must keep the retained bytes, every prior visible
    /// version and the current document exactly unchanged.
    func testFailedRecoveryRetryKeepsRetainedCheckpointAndPriorVersions() async throws {
        let (document, url) = try await makeDocument("RecoveryRetry")
        addTriangle(document, name: "Base")
        try await save(document)
        let pendingID = try await forciblyRetainCheckpoint(document, name: "Retained")
        let other = try await document.createNamedVersion(name: "Other")
        let rowsBefore = try await document.namedVersions()
        XCTAssertEqual(rowsBefore.map(\.id), [other.version.id])

        let revisionBefore = document.revision
        let contentBefore = document.contentSHA256
        let hashesBefore = try packageFileHashes(url)
        let recoveriesBefore = try await document.namedVersionRecoveries()
        XCTAssertEqual(recoveriesBefore.map(\.id), [pendingID])

        CADDocumentFaultInjection.beforeNamedVersionPromotion = {
            throw NSError(domain: "FloeCADVersionTest", code: 78,
                          userInfo: [NSLocalizedDescriptionKey:
                            "injected retry failure"])
        }
        do {
            _ = try await document.recoverNamedVersion(pendingID)
            XCTFail("a failed retry must not report success")
        } catch let error as CADNamedVersionError {
            guard case .ioFailure = error else {
                return XCTFail("expected ioFailure, got \(error)")
            }
        } catch {
            XCTFail("expected a CADNamedVersionError, got \(error)")
        }
        CADDocumentFaultInjection.beforeNamedVersionPromotion = nil

        XCTAssertEqual(try packageFileHashes(url), hashesBefore,
                       "a failed retry must not rewrite the visible package")
        let floorAfterFailedRetry = try XCTUnwrap(
            try manifestObject(url)["schemaVersion"] as? Int)
        XCTAssertGreaterThanOrEqual(floorAfterFailedRetry,
                                    CADDocumentFormat.namedVersionFormatVersion,
                                    "a failed retry must never lower the committed floor")
        XCTAssertEqual(document.revision, revisionBefore)
        XCTAssertEqual(document.contentSHA256, contentBefore)
        let rowsAfterFailure = try await document.namedVersions()
        XCTAssertEqual(rowsAfterFailure.map(\.id), [other.version.id])
        let recoveriesAfterFailure = try await document.namedVersionRecoveries()
        XCTAssertEqual(recoveriesAfterFailure.map(\.id), [pendingID])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: recoveryMarkerURL(pendingID, in: url).path))

        let recovered = try await document.recoverNamedVersion(pendingID)
        XCTAssertEqual(recovered.version.id, pendingID)
        let rowsAfterRecovery = try await document.namedVersions()
        XCTAssertEqual(Set(rowsAfterRecovery.map(\.id)),
                       Set([other.version.id, pendingID]))
        let recoveriesAfter = try await document.namedVersionRecoveries()
        XCTAssertEqual(recoveriesAfter.count, 0)
        document.close()
    }

    /// Corrupt retained metadata is listed truthfully as unusable, recovery is
    /// refused, and deleting only that recovery leaves the current document,
    /// visible versions and external files intact.
    func testCorruptRetainedRecoveryIsListedUnusableAndDeleteLeavesOthersIntact() async throws {
        let (document, url) = try await makeDocument("RecoveryCorrupt")
        addTriangle(document, name: "Base")
        try await save(document)
        let pendingID = try await forciblyRetainCheckpoint(document, name: "Damaged")
        let other = try await document.createNamedVersion(name: "Other")
        let external = url.deletingLastPathComponent().appendingPathComponent("external.step")
        let externalBytes = Data("external part reference".utf8)
        try externalBytes.write(to: external)

        let revision = document.revision
        let content = document.contentSHA256
        let bodyCount = document.summary().bodyCount
        let hashesBefore = try packageFileHashes(url)
        let pendingDirectory = recoveryDirectory(pendingID, in: url)
        try Data("this is not a version record".utf8)
            .write(to: pendingDirectory.appendingPathComponent("version.json"),
                   options: .atomic)

        let recoveries = try await document.namedVersionRecoveries()
        XCTAssertEqual(recoveries.count, 1)
        let row = try XCTUnwrap(recoveries.first)
        XCTAssertEqual(row.id, pendingID)
        XCTAssertEqual(row.name, "Damaged")
        XCTAssertFalse(row.isUsable)
        XCTAssertNotNil(row.issue)

        do {
            _ = try await document.recoverNamedVersion(pendingID)
            XCTFail("a corrupt retained checkpoint must not be recovered")
        } catch let error as CADNamedVersionError {
            guard case .corrupt = error else {
                return XCTFail("expected corrupt, got \(error)")
            }
        } catch {
            XCTFail("expected a CADNamedVersionError, got \(error)")
        }
        XCTAssertEqual(document.revision, revision)
        XCTAssertEqual(document.contentSHA256, content)
        XCTAssertEqual(document.summary().bodyCount, bodyCount)
        let visibleAfterRefusal = try await document.namedVersions()
        XCTAssertEqual(visibleAfterRefusal.map(\.id), [other.version.id])

        let deletion = try await document.discardNamedVersionRecovery(pendingID)
        XCTAssertTrue(deletion.deleted)
        XCTAssertEqual(deletion.name, "Damaged")
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingDirectory.path))
        XCTAssertEqual(try packageFileHashes(url), hashesBefore,
                       "deleting a recovery must not rewrite the visible package")
        let floorAfterDiscard = try XCTUnwrap(
            try manifestObject(url)["schemaVersion"] as? Int)
        XCTAssertGreaterThanOrEqual(floorAfterDiscard,
                                    CADDocumentFormat.namedVersionFormatVersion,
                                    "deleting a recovery must never lower the committed floor")
        XCTAssertEqual(try Data(contentsOf: external), externalBytes)
        let visibleAfterDelete = try await document.namedVersions()
        XCTAssertEqual(visibleAfterDelete.map(\.id), [other.version.id])
        let recoveriesAfterDelete = try await document.namedVersionRecoveries()
        XCTAssertEqual(recoveriesAfterDelete.count, 0)
        document.close()
    }

    /// A malformed recovery marker is still truthful, unusable state that can
    /// be deleted; it is never promoted or presented as a completed version.
    func testMalformedRecoveryMarkerIsListedUnusableAndDeletable() async throws {
        let (document, url) = try await makeDocument("RecoveryMarker")
        addTriangle(document, name: "Base")
        try await save(document)
        let pendingID = try await forciblyRetainCheckpoint(document, name: "Marker")
        let pendingDirectory = recoveryDirectory(pendingID, in: url)
        try Data("this is not a recovery marker".utf8)
            .write(to: recoveryMarkerURL(pendingID, in: url), options: .atomic)

        let recoveries = try await document.namedVersionRecoveries()
        XCTAssertEqual(recoveries.count, 1)
        let row = try XCTUnwrap(recoveries.first)
        XCTAssertEqual(row.id, pendingID)
        XCTAssertFalse(row.isUsable)
        XCTAssertNotNil(row.issue)

        do {
            _ = try await document.recoverNamedVersion(pendingID)
            XCTFail("a malformed recovery marker must not be promoted")
        } catch let error as CADNamedVersionError {
            guard case .recoveryUnavailable = error else {
                return XCTFail("expected recoveryUnavailable, got \(error)")
            }
        } catch {
            XCTFail("expected a CADNamedVersionError, got \(error)")
        }
        let deletion = try await document.discardNamedVersionRecovery(pendingID)
        XCTAssertTrue(deletion.deleted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingDirectory.path))
        let after = try await document.namedVersionRecoveries()
        XCTAssertEqual(after.count, 0)
        document.close()
    }

    /// A visible identity collision refuses recovery and leaves both the
    /// retained checkpoint and the visible package entries untouched.
    func testRecoveryIdentityCollisionRefusesWithoutOverwrite() async throws {
        let (document, url) = try await makeDocument("RecoveryCollision")
        addTriangle(document, name: "Base")
        try await save(document)
        let pendingID = try await forciblyRetainCheckpoint(document, name: "Collision")
        let other = try await document.createNamedVersion(name: "Other")
        let collisionDirectory = versionDirectory(pendingID, in: url)
        try FileManager.default.createDirectory(at: collisionDirectory,
                                                withIntermediateDirectories: true)
        let sentinel = collisionDirectory.appendingPathComponent("keep-me.txt")
        let sentinelBytes = Data("a visible identity occupies this path".utf8)
        try sentinelBytes.write(to: sentinel)
        let recoveriesBefore = try await document.namedVersionRecoveries()
        XCTAssertEqual(recoveriesBefore.map(\.id), [pendingID])

        do {
            _ = try await document.recoverNamedVersion(pendingID)
            XCTFail("an identity collision must not overwrite the visible entry")
        } catch let error as CADNamedVersionError {
            guard case .recoveryCollision = error else {
                return XCTFail("expected recoveryCollision, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: sentinel), sentinelBytes)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: recoveryMarkerURL(pendingID, in: url).path))
        let recoveriesAfter = try await document.namedVersionRecoveries()
        XCTAssertEqual(recoveriesAfter.map(\.id), [pendingID])
        let visible = try await document.namedVersions()
        XCTAssertTrue(visible.contains { $0.id == other.version.id })
        document.close()
    }

    /// Unmarked `.pending-*` bytes are staging, not retained recovery: they are
    /// never listed, promoted or deleted by the recovery surface.
    func testUnmarkedPendingStagingIsNeverListedPromotedOrDeleted() async throws {
        let (document, url) = try await makeDocument("ActiveStaging")
        addTriangle(document, name: "Base")
        try await save(document)
        let stable = try await document.createNamedVersion(name: "Stable")
        let stagingID = UUID()
        try installUnmarkedStagingCopy(of: stable.version.id, as: stagingID, in: url)
        let stagingURL = recoveryDirectory(stagingID, in: url)
        let hashesBefore = try packageFileHashes(url)

        let recoveries = try await document.namedVersionRecoveries()
        XCTAssertEqual(recoveries.count, 0,
                       "unmarked staging must never appear as recoverable work")
        let visible = try await document.namedVersions()
        XCTAssertEqual(visible.map(\.id), [stable.version.id])

        do {
            _ = try await document.recoverNamedVersion(stagingID)
            XCTFail("unmarked staging must not be promoted")
        } catch let error as CADNamedVersionError {
            guard case .recoveryUnavailable = error else {
                return XCTFail("expected recoveryUnavailable, got \(error)")
            }
        } catch {
            XCTFail("expected a CADNamedVersionError, got \(error)")
        }
        do {
            _ = try await document.discardNamedVersionRecovery(stagingID)
            XCTFail("unmarked staging must not be deleted")
        } catch let error as CADNamedVersionError {
            guard case .notFound = error else {
                return XCTFail("expected notFound, got \(error)")
            }
        } catch {
            XCTFail("expected a CADNamedVersionError, got \(error)")
        }
        let store = CADNamedVersionStore(packageURL: url)
        do {
            _ = try store.promoteRetainedPendingCheckpoint(stagingID)
            XCTFail("a direct store promotion must refuse unmarked staging")
        } catch let error as CADNamedVersionError {
            guard case .recoveryUnavailable = error else {
                return XCTFail("expected recoveryUnavailable, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingURL.path))
        XCTAssertEqual(try packageFileHashes(url), hashesBefore,
                       "refusing unmarked staging must not write the package")
        document.close()
    }

    /// A running create holds the package gate, so the recovery listing cannot
    /// observe its live `.pending-*` staging even though the marker exists.
    func testActiveStagingCannotBeListedWhileCreateHoldsPackageGate() async throws {
        let (document, _) = try await makeDocument("ActiveGate")
        addTriangle(document, name: "Base")
        try await save(document)

        let entered = expectation(description: "checkpoint staged")
        let gate = NamedVersionAsyncGate()
        CADNamedVersionWorkHooks.afterCheckpointStaged = {
            entered.fulfill()
            await gate.wait()
        }
        let createTask = Task { try await document.createNamedVersion(name: "Running") }
        await fulfillment(of: [entered], timeout: 10)

        let hiddenNames = try hiddenVersionEntries(in: document.url)
        XCTAssertEqual(hiddenNames.count, 1)
        let hiddenName = try XCTUnwrap(hiddenNames.first)
        let pendingID = try XCTUnwrap(UUID(uuidString:
            String(hiddenName.dropFirst(".pending-".count))))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: recoveryMarkerURL(pendingID, in: document.url).path),
                      "the format-floor create must have written its marker before the commit")

        let listingReachedGate = expectation(description: "recovery listing reached the gate")
        CADNamedVersionWorkHooks.beforeRecoveryListGate = {
            listingReachedGate.fulfill()
        }
        let listingReturned = NamedVersionFlag()
        let listingTask = Task { () -> [CADNamedVersionRecoverySummary] in
            let rows = try await document.namedVersionRecoveries()
            listingReturned.mark()
            return rows
        }
        await fulfillment(of: [listingReachedGate], timeout: 10)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(listingReturned.isMarked,
                       "the recovery listing must wait for the active create's package gate")
        CADNamedVersionWorkHooks.beforeRecoveryListGate = nil

        createTask.cancel()
        gate.release()
        do {
            _ = try await createTask.value
            XCTFail("a cancelled create must not report success")
        } catch let error as CADNamedVersionError {
            guard case .restoreRefused = error else {
                return XCTFail("expected a cancellation refusal, got \(error)")
            }
        } catch is CancellationError {
            // expected
        }
        CADNamedVersionWorkHooks.afterCheckpointStaged = nil
        let listed = try await listingTask.value
        XCTAssertEqual(listed.count, 0, "cancelled staging must never be listed")
        XCTAssertEqual(try hiddenVersionEntries(in: document.url), [])
        document.close()
    }

    // MARK: - R4: bounded compare continuation / exact record access

    /// More than one page of differences must expose the exact tail through
    /// the same compare action, with a truthful total/next offset and identity
    /// pins that refuse a changed current revision.
    func testComparisonPagesExposeEntireTailWithStableIdentity() async throws {
        let (document, _) = try await makeDocument("ComparePages")
        addTriangle(document, name: "Base")
        try await save(document)
        let base = try await document.createNamedVersion(name: "Base")

        var addedIDs: [UUID] = []
        for index in 0..<250 {
            addedIDs.append(addTriangle(document, name: "Part \(index)",
                                       offset: Float(index + 1) * 20))
        }
        try await save(document)

        let first = try await document.compareNamedVersion(base.version.id)
        XCTAssertEqual(first.differences.count, 240)
        XCTAssertTrue(first.truncated)
        XCTAssertEqual(first.totalDifferences, 250)
        let firstNext = try XCTUnwrap(first.nextOffset)
        XCTAssertEqual(firstNext, 240)
        let pins = CADNamedVersionComparisonPins(from: first.from, to: first.to)
        let second = try await document.compareNamedVersion(
            base.version.id, offset: firstNext, pins: pins)
        XCTAssertEqual(second.differences.count, 10)
        XCTAssertFalse(second.truncated)
        XCTAssertNil(second.nextOffset)
        XCTAssertEqual(second.totalDifferences, 250)
        XCTAssertEqual(second.from, first.from)
        XCTAssertEqual(second.to, first.to)
        let allIdentifiers = Set((first.differences + second.differences).map(\.identifier))
        XCTAssertEqual(allIdentifiers, Set(addedIDs.map(\.uuidString)))
        XCTAssertEqual(allIdentifiers.count, 250)

        // The ordinary typed action can fetch the same tail with pinned identity.
        let pinData = try JSONEncoder().encode(pins)
        let pinObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: pinData) as? [String: Any])
        let pageRaw = try await document.handleNamedVersionAction(
            "compare",
            args: ["version_id": base.version.id.uuidString,
                   "offset": firstNext,
                   "identity": pinObject])
        let pageObject = try jsonObject(pageRaw)
        let pageComparison = try XCTUnwrap(pageObject["comparison"] as? [String: Any])
        let pageDifferences = pageComparison["differences"] as? [[String: Any]]
        XCTAssertEqual(pageDifferences?.count, 10)
        XCTAssertEqual(pageComparison["totalDifferences"] as? Int, 250)
        XCTAssertNil(pageComparison["nextOffset"])

        // Later pages require pins; a changed current revision is refused
        // rather than silently mixing two revisions.
        do {
            _ = try await document.handleNamedVersionAction(
                "compare", args: ["version_id": base.version.id.uuidString,
                                  "offset": firstNext])
            XCTFail("a later page without identity pins must be refused")
        } catch let error as CADNamedVersionError {
            guard case .invalidAction = error else {
                return XCTFail("expected invalidAction, got \(error)")
            }
        }
        addTriangle(document, name: "Late", offset: 40_000)
        try await save(document)
        do {
            _ = try await document.compareNamedVersion(
                base.version.id, offset: firstNext, pins: pins)
            XCTFail("a changed current revision must refuse the pinned page")
        } catch let error as CADNamedVersionError {
            guard case .comparisonStale = error else {
                return XCTFail("expected comparisonStale, got \(error)")
            }
        }
        document.close()
    }

    /// A record with more changed fields than the bounded summary detail must
    /// still be fetchable in full through exact saved-record access, with a
    /// whole-value digest and byte-bounded chunk paging that never invents or
    /// drops values.
    func testSelectedRecordDetailExposesAllChangedMaterialFields() async throws {
        let (document, _) = try await makeDocument("CompareRecord")
        addTriangle(document, name: "Base")
        let firstMaterial = CADMaterialDefinition(
            name: "Material A",
            baseColor: SIMD4(0.6, 0.5, 0.4, 1),
            metallic: 0.1, roughness: 0.2, opacity: 1,
            emissive: SIMD3(0, 0, 0), emissiveStrength: 0)
        let materialID = firstMaterial.id
        try setMaterialLibrary(CADMaterialLibrary(entries: [firstMaterial]),
                               on: document)
        try await save(document)
        let version = try await document.createNamedVersion(name: "Before material")

        let changed = CADMaterialDefinition(
            id: materialID,
            name: "Material B",
            baseColor: SIMD4(0.1, 0.2, 0.3, 0.8),
            metallic: 0.9, roughness: 0.8, opacity: 0.7,
            emissive: SIMD3(0.2, 0.3, 0.4), emissiveStrength: 2.5)
        try setMaterialLibrary(CADMaterialLibrary(entries: [changed]),
                               on: document)
        try await save(document)

        let comparison = try await document.compareNamedVersion(version.version.id)
        let materialDifference = try XCTUnwrap(comparison.differences.first {
            $0.section == "materials" && $0.identifier == materialID.raw.uuidString
        })
        XCTAssertLessThanOrEqual(materialDifference.detail.split(separator: ";").count, 10,
                                 "the visible summary must stay bounded")
        XCTAssertFalse(materialDifference.detail.contains("roughness"),
                       "the bounded summary must not claim the omitted material fields")

        var detail = try await document.namedVersionRecordDetail(
            version.version.id, section: "materials",
            identifier: materialID.raw.uuidString, chunkLimit: 1)
        XCTAssertEqual(detail.change, "modified")

        // The ordinary typed action exposes the same exact record path.
        let recordRaw = try await document.handleNamedVersionAction(
            "record",
            args: ["version_id": version.version.id.uuidString,
                   "section": "materials",
                   "identifier": materialID.raw.uuidString,
                   "chunk_limit": 1])
        let recordObject = try jsonObject(recordRaw)
        XCTAssertEqual(recordObject["ok"] as? Bool, true)
        let handleRecord = try XCTUnwrap(recordObject["record"] as? [String: Any])
        XCTAssertEqual(handleRecord["section"] as? String, "materials")
        XCTAssertEqual(handleRecord["identifier"] as? String,
                       materialID.raw.uuidString)
        XCTAssertEqual(handleRecord["change"] as? String, "modified")
        let pins = CADNamedVersionComparisonPins(from: detail.from, to: detail.to)
        XCTAssertTrue(detail.fromRecord.present)
        XCTAssertTrue(detail.toRecord.present)
        XCTAssertNotNil(detail.fromRecord.sha256)
        XCTAssertNotNil(detail.toRecord.sha256)
        XCTAssertGreaterThan(detail.fromRecord.chunkCount, detail.fromRecord.chunks.count)
        XCTAssertGreaterThan(detail.toRecord.chunkCount, detail.toRecord.chunks.count)

        var oldChunks = detail.fromRecord.chunks
        var oldCursor: Int? = detail.fromRecord.nextChunkOffset
        while let cursor = oldCursor {
            let page = try await document.namedVersionRecordDetail(
                version.version.id, section: "materials",
                identifier: materialID.raw.uuidString,
                chunkOffset: cursor, chunkLimit: 1, pins: pins)
            oldChunks += page.fromRecord.chunks
            oldCursor = page.fromRecord.nextChunkOffset
        }
        var newChunks = detail.toRecord.chunks
        var newCursor: Int? = detail.toRecord.nextChunkOffset
        while let cursor = newCursor {
            let page = try await document.namedVersionRecordDetail(
                version.version.id, section: "materials",
                identifier: materialID.raw.uuidString,
                chunkOffset: cursor, chunkLimit: 1, pins: pins)
            newChunks += page.toRecord.chunks
            newCursor = page.toRecord.nextChunkOffset
        }
        let oldText = oldChunks.joined()
        let newText = newChunks.joined()
        XCTAssertEqual(sha256Hex(Data(oldText.utf8)), detail.fromRecord.sha256)
        XCTAssertEqual(sha256Hex(Data(newText.utf8)), detail.toRecord.sha256)

        let expectedOld = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(firstMaterial)) as? [String: Any]
        let expectedNew = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(changed)) as? [String: Any]
        let actualOld = try JSONSerialization.jsonObject(
            with: Data(oldText.utf8)) as? [String: Any]
        let actualNew = try JSONSerialization.jsonObject(
            with: Data(newText.utf8)) as? [String: Any]
        let oldExpectedData = try JSONSerialization.data(
            withJSONObject: try XCTUnwrap(expectedOld), options: [.sortedKeys])
        let oldActualData = try JSONSerialization.data(
            withJSONObject: try XCTUnwrap(actualOld), options: [.sortedKeys])
        let newExpectedData = try JSONSerialization.data(
            withJSONObject: try XCTUnwrap(expectedNew), options: [.sortedKeys])
        let newActualData = try JSONSerialization.data(
            withJSONObject: try XCTUnwrap(actualNew), options: [.sortedKeys])
        XCTAssertEqual(oldActualData, oldExpectedData,
                       "the old record must contain every actual stored field")
        XCTAssertEqual(newActualData, newExpectedData,
                       "the new record must contain every actual stored field")
        XCTAssertEqual((actualNew?["roughness"] as? NSNumber)?.doubleValue, 0.8,
                       "the omitted summary field must be retrievable exactly")

        // Record pages are pinned too: a changed current document is refused.
        addTriangle(document, name: "Late", offset: 60)
        try await save(document)
        do {
            _ = try await document.namedVersionRecordDetail(
                version.version.id, section: "materials",
                identifier: materialID.raw.uuidString, chunkLimit: 1, pins: pins)
            XCTFail("a changed current revision must refuse a pinned record page")
        } catch let error as CADNamedVersionError {
            guard case .comparisonStale = error else {
                return XCTFail("expected comparisonStale, got \(error)")
            }
        }
        document.close()
    }

    /// A stored record whose exact pretty JSON is several megabytes must still
    /// be fully reachable through bounded pages: the scan counts every
    /// 512-byte chunk without retaining an all-record array, a later/tail page
    /// is addressable, an out-of-range page invents nothing, and joining every
    /// page reconstructs the exact whole value whose SHA-256 the first page
    /// reported. Chinese and emoji scalars force many 2-/3-/4-byte boundary
    /// decisions across more than 4096 chunks (far more than one page).
    func testLongUnicodeRecordPagesRemainBoundedAndReconstructExactly() async throws {
        let (document, _) = try await makeDocument("LongRecord")
        // 80,000 repetitions of a 28-byte mixed Chinese/emoji unit: the stored
        // body record is ~2.24 MB before JSON overhead, so more than 4096
        // bounded chunks and far more than a single page.
        let unit = "版本🙂设计🎨汉字é"
        let longName = "开始-" + String(repeating: unit, count: 80_000) + "-结束"
        let bodyID = addTriangle(document, name: longName,
                                 title: "Add long Unicode body")
        try await save(document)
        let version = try await document.createNamedVersion(name: "Long record")

        let first = try await document.namedVersionRecordDetail(
            version.version.id, section: "geometry",
            identifier: bodyID.uuidString, chunkLimit: 8)
        let firstSide = first.fromRecord
        XCTAssertTrue(firstSide.present)
        XCTAssertEqual(firstSide.chunkOffset, 0)
        XCTAssertEqual(firstSide.chunks.count, 8, "one page must stay bounded")
        XCTAssertGreaterThan(firstSide.chunkCount, 4_096,
                             "the fixture must require many bounded pages")
        XCTAssertGreaterThan(firstSide.byteCount, 4_096 * 512,
                             "the whole stored value must exceed 4096 chunks")
        XCTAssertEqual(firstSide.nextChunkOffset, 8)
        XCTAssertEqual(first.toRecord.chunkCount, firstSide.chunkCount)
        XCTAssertEqual(first.toRecord.sha256, firstSide.sha256)
        XCTAssertEqual(first.toRecord.byteCount, firstSide.byteCount)
        let pins = CADNamedVersionComparisonPins(from: first.from, to: first.to)

        // Reconstruct the whole value through bounded 256-chunk pages. Every
        // page reports the same whole-value identity; no chunk exceeds the
        // fixed byte bound or is empty.
        var reconstructed: [String] = []
        var cursor: Int? = 0
        var pageCount = 0
        while let offset = cursor {
            let page = try await document.namedVersionRecordDetail(
                version.version.id, section: "geometry",
                identifier: bodyID.uuidString,
                chunkOffset: offset, chunkLimit: 256, pins: pins)
            let side = page.fromRecord
            XCTAssertEqual(side.chunkCount, firstSide.chunkCount)
            XCTAssertEqual(side.sha256, firstSide.sha256)
            XCTAssertEqual(side.byteCount, firstSide.byteCount)
            XCTAssertEqual(side.chunkOffset, offset)
            for chunk in side.chunks {
                XCTAssertFalse(chunk.isEmpty)
                XCTAssertLessThanOrEqual(chunk.utf8.count, 512,
                                         "a chunk must stay byte-bounded")
            }
            reconstructed.append(contentsOf: side.chunks)
            cursor = side.nextChunkOffset
            pageCount += 1
            if pageCount > 128 {
                XCTFail("record paging did not terminate")
                break
            }
        }
        XCTAssertEqual(reconstructed.count, firstSide.chunkCount)
        XCTAssertEqual(pageCount, (firstSide.chunkCount + 255) / 256,
                       "every page must carry the full 256-chunk bound, not one chunk")
        let wholeText = reconstructed.joined()
        XCTAssertEqual(wholeText.utf8.count, firstSide.byteCount,
                       "every stored UTF-8 byte must be reachable")
        XCTAssertEqual(sha256Hex(Data(wholeText.utf8)), firstSide.sha256,
                       "joining the pages must reconstruct the exact whole value")
        XCTAssertEqual(Array(reconstructed.prefix(8)), firstSide.chunks,
                       "the first bounded page must be the start of the same value")
        let record = try jsonObject(wholeText)
        XCTAssertEqual(record["name"] as? String, longName,
                       "every Chinese/emoji scalar must survive page boundaries")
        XCTAssertEqual(record["bodyID"] as? String, bodyID.uuidString)
        let trimmedRecordText = wholeText.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(trimmedRecordText.hasPrefix("{"))
        XCTAssertTrue(trimmedRecordText.hasSuffix("}"))

        // A later page near the tail is addressable and is the exact suffix.
        let tailOffset = firstSide.chunkCount - 2
        let tail = try await document.namedVersionRecordDetail(
            version.version.id, section: "geometry",
            identifier: bodyID.uuidString,
            chunkOffset: tailOffset, chunkLimit: 8, pins: pins)
        XCTAssertEqual(tail.fromRecord.chunkOffset, tailOffset)
        XCTAssertEqual(tail.fromRecord.chunks.count, 2)
        XCTAssertNil(tail.fromRecord.nextChunkOffset)
        XCTAssertEqual(tail.fromRecord.chunks, Array(reconstructed.suffix(2)))
        let tailText = tail.fromRecord.chunks.joined()
        XCTAssertFalse(tailText.isEmpty)
        XCTAssertTrue(wholeText.hasSuffix(tailText),
                      "the tail page must be the exact end of the stored JSON")

        // Out-of-range pages are truthful: no invented chunk, the whole-value
        // digest/counts remain available and the offset clamps to the end.
        let beyond = try await document.namedVersionRecordDetail(
            version.version.id, section: "geometry",
            identifier: bodyID.uuidString,
            chunkOffset: firstSide.chunkCount + 7, chunkLimit: 8, pins: pins)
        XCTAssertTrue(beyond.fromRecord.chunks.isEmpty)
        XCTAssertNil(beyond.fromRecord.nextChunkOffset)
        XCTAssertEqual(beyond.fromRecord.chunkOffset, firstSide.chunkCount)
        XCTAssertEqual(beyond.fromRecord.chunkCount, firstSide.chunkCount)
        XCTAssertEqual(beyond.fromRecord.sha256, firstSide.sha256)
        XCTAssertEqual(beyond.fromRecord.byteCount, firstSide.byteCount)
        document.close()
    }

    /// A genuine parent Task.cancel while the owned detached checkpoint copy
    /// is suspended must publish nothing: no visible checkpoint, no pending
    /// debris, no loss of previous checkpoints and no current-document change.
    func testRealCancellationDuringCheckpointStagingPublishesNothing() async throws {
        let (document, url) = try await makeDocument("CancelCreate")
        addTriangle(document, name: "Base")
        try await save(document)
        let stable = try await document.createNamedVersion(name: "Stable")
        addTriangle(document, name: "Current", offset: 20)
        try await save(document)
        let revision = document.revision
        let content = document.contentSHA256
        let rowsBefore = try await document.namedVersions()

        let entered = expectation(description: "checkpoint staged")
        let gate = NamedVersionAsyncGate()
        CADNamedVersionWorkHooks.afterCheckpointStaged = {
            entered.fulfill()
            await gate.wait()
        }
        let task = Task { try await document.createNamedVersion(name: "Cancelled") }
        await fulfillment(of: [entered], timeout: 10)
        task.cancel()
        gate.release()
        do {
            _ = try await task.value
            XCTFail("a cancelled create must not report success")
        } catch let error as CADNamedVersionError {
            guard case .restoreRefused = error else {
                return XCTFail("expected a cancellation refusal, got \(error)")
            }
        } catch is CancellationError {
            // A cancellation error is also acceptable; the side effects below
            // are the contract.
        }
        CADNamedVersionWorkHooks.afterCheckpointStaged = nil
        // Bounded settle: any unjoined late worker would get a chance to
        // publish here; the assertions below prove none can.
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(document.revision, revision)
        XCTAssertEqual(document.contentSHA256, content)
        let rowsAfter = try await document.namedVersions()
        XCTAssertEqual(Set(rowsAfter.map(\.id)), Set(rowsBefore.map(\.id)))
        XCTAssertFalse(rowsAfter.contains { $0.name == "Cancelled" })
        XCTAssertEqual(try hiddenVersionEntries(in: url), [],
                       "cancelled staging must remove its owned pending entry")
        let recoveriesAfterCancel = try await document.namedVersionRecoveries()
        XCTAssertEqual(recoveriesAfterCancel.count, 0,
                       "cancelled staging must never become retained recovery work")
        let stableRow = try XCTUnwrap(rowsAfter.first { $0.id == stable.version.id })
        let loaded = try CADNamedVersionStore(packageURL: url).load(stableRow.id)
        XCTAssertEqual(loaded.manifest.contentSHA256, stable.version.contentSHA256)

        // The same document must stay usable afterwards.
        let after = try await document.createNamedVersion(name: "After cancel")
        XCTAssertEqual(after.version.name, "After cancel")
        document.close()
    }

    /// A genuine parent Task.cancel while the detached checkpoint load is
    /// suspended must not create a recovery checkpoint, mutate the live graph
    /// or commit a restore.
    func testRealCancellationDuringCheckpointLoadCreatesNoRecoveryAndRestoresNothing() async throws {
        let (document, _) = try await makeDocument("CancelRestore")
        addTriangle(document, name: "Base")
        try await save(document)
        let base = try await document.createNamedVersion(name: "Base")
        addTriangle(document, name: "Current", offset: 20)
        try await save(document)
        let revision = document.revision
        let content = document.contentSHA256
        let bodyCount = document.summary().bodyCount
        let rowsBefore = try await document.namedVersions()

        let entered = expectation(description: "checkpoint loaded")
        let gate = NamedVersionAsyncGate()
        CADNamedVersionWorkHooks.afterCheckpointLoaded = {
            entered.fulfill()
            await gate.wait()
        }
        let task = Task { try await document.restoreNamedVersion(base.version.id) }
        await fulfillment(of: [entered], timeout: 10)
        task.cancel()
        gate.release()
        do {
            _ = try await task.value
            XCTFail("a cancelled restore must not report success")
        } catch is CancellationError {
            // expected genuine cancellation
        }
        CADNamedVersionWorkHooks.afterCheckpointLoaded = nil
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(document.revision, revision)
        XCTAssertEqual(document.contentSHA256, content)
        XCTAssertEqual(document.summary().bodyCount, bodyCount)
        let rowsAfter = try await document.namedVersions()
        XCTAssertEqual(Set(rowsAfter.map(\.id)), Set(rowsBefore.map(\.id)),
                       "a cancelled precommit restore must not create a recovery checkpoint")
        XCTAssertEqual(try hiddenVersionEntries(in: document.url), [])

        // A normal restore still works after the cancellation.
        let restored = try await document.restoreNamedVersion(base.version.id)
        XCTAssertFalse(restored.alreadyCurrent)
        XCTAssertEqual(document.summary().bodyCount, 1)
        document.close()
    }

    /// Read-only list/compare detached reads must also observe real parent
    /// cancellation and return no partially applied result or write.
    func testRealCancellationDuringVersionReadsWritesNothing() async throws {
        let (document, url) = try await makeDocument("CancelRead")
        addTriangle(document, name: "Base")
        try await save(document)
        let version = try await document.createNamedVersion(name: "Base")
        let revision = document.revision
        let content = document.contentSHA256
        let hashes = try packageFileHashes(url)

        let compareEntered = expectation(description: "version loaded for compare")
        let compareGate = NamedVersionAsyncGate()
        CADNamedVersionWorkHooks.afterCheckpointLoaded = {
            compareEntered.fulfill()
            await compareGate.wait()
        }
        let compareTask = Task { try await document.compareNamedVersion(version.version.id) }
        await fulfillment(of: [compareEntered], timeout: 10)
        compareTask.cancel()
        compareGate.release()
        do {
            _ = try await compareTask.value
            XCTFail("a cancelled compare must not return a result")
        } catch is CancellationError {
            // expected
        }
        CADNamedVersionWorkHooks.afterCheckpointLoaded = nil

        let listEntered = expectation(description: "version list loaded")
        let listGate = NamedVersionAsyncGate()
        CADNamedVersionWorkHooks.afterListLoaded = {
            listEntered.fulfill()
            await listGate.wait()
        }
        let listTask = Task { try await document.namedVersions() }
        await fulfillment(of: [listEntered], timeout: 10)
        listTask.cancel()
        listGate.release()
        do {
            _ = try await listTask.value
            XCTFail("a cancelled list must not return a result")
        } catch is CancellationError {
            // expected
        }
        CADNamedVersionWorkHooks.afterListLoaded = nil

        XCTAssertEqual(document.revision, revision)
        XCTAssertEqual(document.contentSHA256, content)
        XCTAssertEqual(try packageFileHashes(url), hashes,
                       "cancelled read-only operations must not write the package")
        document.close()
    }

    // MARK: - E34 owner-lifetime close regressions

    /// A REAL close from the async `afterCheckpointStaged` seam, before the
    /// first format-floor commit, must refuse the checkpoint. The current
    /// commit and floor stay byte-identical; only this create's owned hidden
    /// pending entry is removed, and a foreign hidden entry survives.
    func testCloseAtStagingHookBeforeFirstFloorCommitLeavesPackageAndFloorUnchanged() async throws {
        let (document, url) = try await makeDocument("CloseBeforeFloor")
        addTriangle(document, name: "Solid")
        try await save(document)
        let revision = document.revision
        let content = document.contentSHA256
        let floorBefore = try XCTUnwrap(try manifestObject(url)["schemaVersion"] as? Int)
        XCTAssertLessThan(floorBefore, CADDocumentFormat.namedVersionFormatVersion)

        let versionsURL = url.appendingPathComponent("versions", isDirectory: true)
        let foreign = versionsURL.appendingPathComponent(".retained-foreign", isDirectory: true)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        let foreignBytes = Data("foreign retained bytes".utf8)
        try foreignBytes.write(to: foreign.appendingPathComponent("payload.bin"))
        let hashesBefore = try packageFileHashes(url)

        let entered = expectation(description: "checkpoint staged")
        let gate = NamedVersionAsyncGate()
        CADNamedVersionWorkHooks.afterCheckpointStaged = {
            entered.fulfill()
            await gate.wait()
        }
        let task = Task { try await document.createNamedVersion(name: "Closed") }
        await fulfillment(of: [entered], timeout: 10)
        let hiddenBeforeClose = try hiddenVersionEntries(in: url)
        XCTAssertTrue(hiddenBeforeClose.contains { $0.hasPrefix(".pending-") },
                      "the real staging copy must exist at the close seam")
        document.close()
        gate.release()
        do {
            _ = try await task.value
            XCTFail("a checkpoint must not be created after the document closed")
        } catch let error as CADNamedVersionError {
            guard case .closed = error else {
                return XCTFail("expected closed, got \(error)")
            }
        } catch {
            XCTFail("expected a CADNamedVersionError, got \(error)")
        }
        CADNamedVersionWorkHooks.afterCheckpointStaged = nil

        XCTAssertTrue(document.isClosed)
        XCTAssertEqual(document.revision, revision)
        XCTAssertEqual(document.contentSHA256, content)
        XCTAssertEqual(try packageFileHashes(url), hashesBefore,
                       "the closed create must not rewrite the current package")
        XCTAssertEqual(try XCTUnwrap(try manifestObject(url)["schemaVersion"] as? Int),
                       floorBefore, "no format-floor commit may land after close")
        XCTAssertEqual(try hiddenVersionEntries(in: url), [".retained-foreign"],
                       "only the owned pending entry is removed; foreign hidden bytes stay")
        XCTAssertEqual(try Data(contentsOf: foreign.appendingPathComponent("payload.bin")),
                       foreignBytes)
        let rows = try CADNamedVersionStore(packageURL: url).list()
        XCTAssertEqual(rows.count, 0)
    }

    /// The same close on an already-floor package with a previous version must
    /// refuse the final promotion too: the previous checkpoint stays
    /// byte-identical and the new name is absent.
    func testCloseAtStagingHookOnAlreadyFloorPackageKeepsPriorVersionExact() async throws {
        let (document, url) = try await makeDocument("CloseAlreadyFloor")
        addTriangle(document, name: "Base")
        try await save(document)
        let first = try await document.createNamedVersion(name: "Prior")
        addTriangle(document, name: "Second", offset: 20)
        try await save(document)
        let floor = try XCTUnwrap(try manifestObject(url)["schemaVersion"] as? Int)
        XCTAssertGreaterThanOrEqual(floor, CADDocumentFormat.namedVersionFormatVersion)
        let revision = document.revision
        let content = document.contentSHA256
        let hashesBefore = try packageFileHashes(url)
        let rowsBefore = try await document.namedVersions()
        XCTAssertEqual(rowsBefore.map(\.id), [first.version.id])

        let entered = expectation(description: "checkpoint staged")
        let gate = NamedVersionAsyncGate()
        CADNamedVersionWorkHooks.afterCheckpointStaged = {
            entered.fulfill()
            await gate.wait()
        }
        let task = Task { try await document.createNamedVersion(name: "Closed") }
        await fulfillment(of: [entered], timeout: 10)
        XCTAssertEqual(try hiddenVersionEntries(in: url).filter { $0.hasPrefix(".pending-") }.count,
                       1, "the real staging copy must exist at the close seam")
        document.close()
        gate.release()
        do {
            _ = try await task.value
            XCTFail("an already-floor checkpoint must not promote after close")
        } catch let error as CADNamedVersionError {
            guard case .closed = error else {
                return XCTFail("expected closed, got \(error)")
            }
        } catch {
            XCTFail("expected a CADNamedVersionError, got \(error)")
        }
        CADNamedVersionWorkHooks.afterCheckpointStaged = nil

        XCTAssertTrue(document.isClosed)
        XCTAssertEqual(document.revision, revision)
        XCTAssertEqual(document.contentSHA256, content)
        XCTAssertEqual(try packageFileHashes(url), hashesBefore,
                       "every previous version and current package byte must stay exact")
        XCTAssertEqual(try XCTUnwrap(try manifestObject(url)["schemaVersion"] as? Int),
                       floor)
        XCTAssertEqual(try hiddenVersionEntries(in: url), [])
        let store = CADNamedVersionStore(packageURL: url)
        let rowsAfter = try store.list()
        XCTAssertEqual(rowsAfter.map(\.id), [first.version.id])
        XCTAssertEqual(rowsAfter.first?.contentSHA256, first.version.contentSHA256)
        XCTAssertFalse(rowsAfter.contains { $0.name == "Closed" })
        let loaded = try store.load(first.version.id)
        XCTAssertEqual(loaded.manifest.contentSHA256, first.version.contentSHA256)

        let reopened = try await FloeCADDocument.open(at: url)
        XCTAssertEqual(reopened.revision, revision)
        let reopenedRows = try await reopened.namedVersions()
        XCTAssertEqual(reopenedRows.map(\.id), [first.version.id])
        reopened.close()
    }

    /// A close while the checkpoint is loading for restore must refuse before
    /// a safety checkpoint or any in-memory graph replacement. The persisted
    /// package stays exactly as it was.
    func testCloseDuringCheckpointLoadRefusesRestoreBeforeRecoveryOrGraphChange() async throws {
        let (document, url) = try await makeDocument("CloseDuringLoad")
        addTriangle(document, name: "Base")
        try await save(document)
        let base = try await document.createNamedVersion(name: "Base")
        addTriangle(document, name: "Current", offset: 20)
        try await save(document)
        let revision = document.revision
        let content = document.contentSHA256
        let bodyCount = document.summary().bodyCount
        let rowsBefore = try await document.namedVersions()
        let hashesBefore = try packageFileHashes(url)

        CADNamedVersionTestHooks.afterCheckpointLoad = { document.close() }
        do {
            _ = try await document.restoreNamedVersion(base.version.id)
            XCTFail("a closed document must not restore a version")
        } catch let error as CADNamedVersionError {
            guard case .closed = error else {
                return XCTFail("expected closed, got \(error)")
            }
        } catch {
            XCTFail("expected a CADNamedVersionError, got \(error)")
        }
        CADNamedVersionTestHooks.afterCheckpointLoad = nil

        XCTAssertTrue(document.isClosed)
        XCTAssertEqual(document.revision, revision)
        XCTAssertEqual(document.contentSHA256, content)
        XCTAssertEqual(document.summary().bodyCount, bodyCount)
        XCTAssertEqual(try packageFileHashes(url), hashesBefore,
                       "a restored-closed load must not write a safety checkpoint")
        XCTAssertEqual(try hiddenVersionEntries(in: url), [])
        let rowsAfter = try CADNamedVersionStore(packageURL: url).list()
        XCTAssertEqual(Set(rowsAfter.map(\.id)), Set(rowsBefore.map(\.id)))
        XCTAssertFalse(rowsAfter.contains { $0.isRecovery },
                       "the refused restore must not leave a safety checkpoint")
    }

    /// A public delete cancelled while it is waiting for `CADPackageGate` must
    /// refuse before moving any checkpoint bytes.
    func testCancelledPublicDeleteWaitingForPackageGateRemovesNoBytes() async throws {
        let (document, url) = try await makeDocument("CancelDeleteGate")
        addTriangle(document, name: "Base")
        try await save(document)
        let version = try await document.createNamedVersion(name: "Keep")
        let revision = document.revision
        let content = document.contentSHA256
        let hashesBefore = try packageFileHashes(url)

        await CADPackageGate.acquireAsync(url)
        let finished = NamedVersionFlag()
        let task = Task { () -> CADNamedVersionDeleteResult in
            defer { finished.mark() }
            return try await document.deleteNamedVersion(version.version.id)
        }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(finished.isMarked,
                       "the delete must still be waiting for package ownership")
        task.cancel()
        CADPackageGate.release(url)
        do {
            _ = try await task.value
            XCTFail("a cancelled delete must not report success")
        } catch is CancellationError {
            // expected: refused before filesystem mutation
        } catch {
            XCTFail("expected cancellation, got \(error)")
        }

        XCTAssertEqual(try packageFileHashes(url), hashesBefore)
        XCTAssertEqual(document.revision, revision)
        XCTAssertEqual(document.contentSHA256, content)
        let rowsAfterCancel = try await document.namedVersions()
        XCTAssertEqual(rowsAfterCancel.map(\.id), [version.version.id])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: versionDirectory(version.version.id, in: url).path))

        // The same public delete still works after the cancellation.
        let deletion = try await document.deleteNamedVersion(version.version.id)
        XCTAssertTrue(deletion.deleted)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: versionDirectory(version.version.id, in: url).path))
        document.close()
    }

    /// A public discard of retained recovery bytes cancelled while waiting for
    /// `CADPackageGate` must leave the complete owned checkpoint untouched.
    func testCancelledPublicDiscardWaitingForPackageGateKeepsRetainedCheckpoint() async throws {
        let (document, url) = try await makeDocument("CancelDiscardGate")
        addTriangle(document, name: "Base")
        try await save(document)
        let pendingID = try await forciblyRetainCheckpoint(document, name: "Retained")
        let store = CADNamedVersionStore(packageURL: url)
        let before = try store.loadRetainedPendingCheckpoint(pendingID)

        await CADPackageGate.acquireAsync(url)
        let finished = NamedVersionFlag()
        let task = Task { () -> CADNamedVersionDeleteResult in
            defer { finished.mark() }
            return try await document.discardNamedVersionRecovery(pendingID)
        }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(finished.isMarked,
                       "the discard must still be waiting for package ownership")
        task.cancel()
        CADPackageGate.release(url)
        do {
            _ = try await task.value
            XCTFail("a cancelled discard must not report success")
        } catch is CancellationError {
            // expected: refused before filesystem mutation
        } catch {
            XCTFail("expected cancellation, got \(error)")
        }

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: recoveryDirectory(pendingID, in: url).path))
        XCTAssertEqual(try hiddenVersionEntries(in: url),
                       [".pending-\(pendingID.uuidString)"])
        let after = try store.loadRetainedPendingCheckpoint(pendingID)
        XCTAssertEqual(after.manifest.contentSHA256, before.manifest.contentSHA256)
        XCTAssertEqual(after.record.name, "Retained")

        let deletion = try await document.discardNamedVersionRecovery(pendingID)
        XCTAssertTrue(deletion.deleted)
        let remainingRecoveries = try await document.namedVersionRecoveries()
        XCTAssertEqual(remainingRecoveries.count, 0)
        document.close()
    }

    /// Closing after the safety checkpoint was committed but before the exact
    /// restore must still remove ONLY that provisional recovery checkpoint.
    /// Nothing else is rewritten and the visible versions stay exact.
    func testCloseAfterSafetyCheckpointStillRemovesOwnedProvisionalRecovery() async throws {
        let (document, url) = try await makeDocument("CloseAfterRecovery")
        addTriangle(document, name: "Base")
        try await save(document)
        let base = try await document.createNamedVersion(name: "Base")
        addTriangle(document, name: "Current", offset: 20)
        try await save(document)
        let revision = document.revision
        let content = document.contentSHA256
        let bodyCount = document.summary().bodyCount
        let rowsBefore = try await document.namedVersions()
        let hashesBefore = try packageFileHashes(url)

        let sawProvisional = NamedVersionFlag()
        let priorVisibleCount = rowsBefore.count
        CADNamedVersionTestHooks.beforeRestoreCommit = {
            let versionsURL = url.appendingPathComponent("versions", isDirectory: true)
            let visible = ((try? FileManager.default.contentsOfDirectory(
                at: versionsURL, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                .filter { UUID(uuidString: $0.lastPathComponent) != nil }
            if visible.count > priorVisibleCount { sawProvisional.mark() }
            document.close()
        }
        do {
            _ = try await document.restoreNamedVersion(base.version.id)
            XCTFail("a closed document must not enter the restore commit")
        } catch let error as CADNamedVersionError {
            guard case .closed = error else {
                return XCTFail("expected closed, got \(error)")
            }
        } catch {
            XCTFail("expected a CADNamedVersionError, got \(error)")
        }
        CADNamedVersionTestHooks.beforeRestoreCommit = nil

        XCTAssertTrue(document.isClosed)
        XCTAssertTrue(sawProvisional.isMarked,
                      "the safety checkpoint must have been created before the close")
        XCTAssertEqual(document.revision, revision)
        XCTAssertEqual(document.contentSHA256, content)
        XCTAssertEqual(document.summary().bodyCount, bodyCount)
        XCTAssertEqual(try packageFileHashes(url), hashesBefore,
                       "cleanup must not rewrite the current package or prior versions")
        XCTAssertEqual(try hiddenVersionEntries(in: url), [])
        let rowsAfter = try CADNamedVersionStore(packageURL: url).list()
        XCTAssertEqual(Set(rowsAfter.map(\.id)), Set(rowsBefore.map(\.id)))
        XCTAssertFalse(rowsAfter.contains { $0.isRecovery },
                       "the closed restore's provisional recovery must be removed")
    }

    /// A close that races an ALREADY ENTERED floor commit waits for that
    /// synchronous atomic phase. The checkpoint and raised floor are the real
    /// committed state; the open document adopts the same identity and never
    /// rolls the commit back or reports a half-complete result.
    func testCloseRacingEnteredFloorCommitFinishesHonestlyAndKeepsCommittedIdentity() async throws {
        let (document, url) = try await makeDocument("CloseRacingCommit")
        addTriangle(document, name: "Base")
        try await save(document)
        let revisionBefore = document.revision
        let contentBefore = document.contentSHA256
        let floorBefore = try XCTUnwrap(try manifestObject(url)["schemaVersion"] as? Int)
        XCTAssertLessThan(floorBefore, CADDocumentFormat.namedVersionFormatVersion)

        let commitEntered = expectation(description: "format-floor commit entered")
        let release = DispatchSemaphore(value: 0)
        CADDocumentFaultInjection.beforeCommit = {
            commitEntered.fulfill()
            release.wait()
        }
        let task = Task { try await document.createNamedVersion(name: "Racing") }
        await fulfillment(of: [commitEntered], timeout: 10)
        // The main actor will block inside close() on the owner lease until the
        // already-entered synchronous commit and promotion finish. Release the
        // commit from a background thread so that wait is bounded.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) {
            release.signal()
        }
        document.close()
        CADDocumentFaultInjection.beforeCommit = nil

        let created = try await task.value
        XCTAssertTrue(document.isClosed)
        XCTAssertEqual(created.revision, revisionBefore + 1)
        XCTAssertEqual(created.contentSHA256, contentBefore)
        XCTAssertEqual(document.revision, created.revision,
                       "the open document adopts the actual committed identity")
        XCTAssertEqual(document.contentSHA256, created.contentSHA256)
        XCTAssertEqual(document.modelSHA256, created.modelSHA256)
        XCTAssertTrue(document.project.hasNamedVersions)
        XCTAssertGreaterThanOrEqual(document.project.formatVersion,
                                    CADDocumentFormat.namedVersionFormatVersion)

        let manifest = try manifestObject(url)
        XCTAssertEqual(manifest["revision"] as? Int, created.revision)
        XCTAssertEqual(manifest["contentSHA256"] as? String, created.contentSHA256)
        XCTAssertGreaterThanOrEqual(manifest["schemaVersion"] as? Int ?? 0,
                                    CADDocumentFormat.namedVersionFormatVersion)
        XCTAssertEqual(try hiddenVersionEntries(in: url), [])
        let store = CADNamedVersionStore(packageURL: url)
        let rows = try store.list()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.name, "Racing")
        XCTAssertEqual(rows.first?.contentSHA256, contentBefore)
        let loaded = try store.load(try XCTUnwrap(rows.first?.id))
        XCTAssertEqual(loaded.manifest.contentSHA256, contentBefore)

        let reopened = try await FloeCADDocument.open(at: url)
        XCTAssertEqual(reopened.revision, created.revision)
        let reopenedVersions = try await reopened.namedVersions()
        XCTAssertEqual(reopenedVersions.count, 1)
        reopened.close()
    }

}
