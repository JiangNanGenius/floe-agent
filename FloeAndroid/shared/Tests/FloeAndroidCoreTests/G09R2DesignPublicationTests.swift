// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 creative result-publication + first-material App-port tests
// (authored source; executed by Main's combined gate).
//
// They exercise the REAL creative publication port over the existing
// `CreativeAssetStore`/Materials authority, the shared adopt/replay/reconcile
// semantics, the retained-asset and staged-import first-result paths, the
// bounded inventory/pending pages and the Root-stop fence. No compiler, device,
// provider or paid call is used here.
import XCTest
import Foundation
@testable import FloeAndroidCore
import FloeCore
import FloeModels
import FloePersistence
import FloeAndroidWorkbench

final class G09R2DesignPublicationTests: XCTestCase {
    private var roots: [URL] = []
    private var databases: [DatabaseManager] = []
    private static let epochLock = NSLock()
    nonisolated(unsafe) private static var epochCounter: UInt64 = 22_000

    override func tearDown() async throws {
        for database in databases { try? await database.close() }
        databases.removeAll()
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        try await super.tearDown()
    }

    private static func nextEpoch() -> UInt64 {
        epochLock.lock(); defer { epochLock.unlock() }
        epochCounter += 1
        return epochCounter
    }

    private struct Fixture {
        let design: G09R2DesignService
        let root: RuntimeStorageRoot
        let rootURL: URL
        let database: DatabaseManager
        let conversationStore: SQLiteConversationStore
        let assetStore: CreativeAssetStore
        let assets: G09CreativeAssetHost
        let epoch: UInt64
    }

    private func makeFixture() async throws -> Fixture {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "floe-design-publication-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        roots.append(url)
        let manager = try DatabaseManager.inMemory()
        try await manager.migrate()
        databases.append(manager)
        let conversationStore = SQLiteConversationStore(database: manager)
        let workspaceStore = SQLiteWorkspaceStore(database: manager)
        let root = try XCTUnwrap(
            RuntimeStorageRoot(validatingAbsoluteDirectory: url.path))
        let assetStore = CreativeAssetStore(
            database: manager, reachabilityGuard: nil,
            deferPhysicalReclamation: true)
        let assets = G09CreativeAssetHost(root: root, store: assetStore)
        let canvas = G09CanvasProjectRepository(root: root)
        let epoch = Self.nextEpoch()
        let design = G09R2DesignService(
            epoch: epoch,
            root: root,
            canvasRepository: canvas,
            assets: assets,
            workspaceStore: workspaceStore,
            conversationStore: conversationStore,
            database: manager)
        return Fixture(
            design: design, root: root, rootURL: url, database: manager,
            conversationStore: conversationStore, assetStore: assetStore,
            assets: assets, epoch: epoch)
    }

    // A real 1x1 RGBA PNG (the base first result).
    private static let pngBytes = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
        0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41,
        0x54, 0x78, 0xDA, 0x63, 0xF8, 0xCF, 0xC0, 0xF0,
        0x1F, 0x00, 0x05, 0x00, 0x01, 0xFF, 0x56, 0xC7,
        0x2F, 0x0D, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45,
        0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    ])

    /// A DIFFERENT real 1x1 PNG (same signature/IHDR family, different bytes).
    private static let adoptedPngBytes: Data = {
        Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
        )!
    }()

    // MARK: - Fixtures / helpers

    private func creativeTarget(
        sourceID: String = UUID().uuidString.lowercased(),
        originConversationID: String? = nil
    ) -> DesignTarget {
        DesignTarget(
            kind: .creativeDocument,
            ownerID: "creative-library",
            sourceID: sourceID,
            originConversationID: originConversationID,
            requestedOutputKind: .image)
    }

    private func creativeBinding(
        _ target: DesignTarget,
        sessionToken: String = "creative-publication-session"
    ) -> G09R2DesignBindingDTO {
        G09R2DesignBindingDTO(
            target: target,
            storage: G09StorageLayerDTO(kind: .appOwned),
            sessionToken: sessionToken)
    }

    private func stage(
        _ fixture: Fixture,
        sessionToken: String,
        data: Data,
        format: String
    ) throws -> G09R2StagedDesignPayloadDTO {
        let directory = fixture.root.artifactStoreURL
            .appendingPathComponent("CreativeIncoming", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let token = "\(sessionToken).\(UUID().uuidString.lowercased())"
        try data.write(to: directory.appendingPathComponent(token))
        return G09R2StagedDesignPayloadDTO(
            token: token,
            format: format,
            byteCount: Int64(data.count),
            sha256: FloeDigest.sha256Hex(data))
    }

    private func ingest(
        _ fixture: Fixture,
        bytes: Data,
        format: String = "png",
        fileName: String = "result.png"
    ) async throws -> CreativeAssetRecord {
        let staging = fixture.rootURL.appendingPathComponent(
            "ingest-\(UUID().uuidString).\(format)")
        try bytes.write(to: staging)
        defer { try? FileManager.default.removeItem(at: staging) }
        let reference = try await fixture.assets.ingestForSourceCreate(
            staging: staging,
            fileName: fileName,
            mimeType: format == "png" ? "image/png" : nil,
            byteCount: Int64(bytes.count),
            sha256: FloeDigest.sha256Hex(bytes),
            candidateID: UUID())
        let record = try await fixture.assetStore.asset(id: reference.id)
        return try XCTUnwrap(record)
    }

    private func materialURL(
        _ fixture: Fixture, record: CreativeAssetRecord
    ) throws -> URL {
        let relative = try XCTUnwrap(record.localRelativePath)
        let clean = try XCTUnwrap(
            G09CreativeAssetHost.canonicalAssetRelativePath(relative))
        return fixture.root.artifactStoreURL
            .appendingPathComponent("Materials", isDirectory: true)
            .appendingPathComponent(clean)
    }

    private func bindCreative(
        _ fixture: Fixture,
        target: DesignTarget,
        binding: G09R2DesignBindingDTO,
        firstBytes: Data? = nil
    ) async throws -> G09R2DesignStateDTO {
        let bound = try await fixture.design.bind(G09R2DesignBindRequest(
            binding: binding, expectedRevision: 0,
            opID: "bind-\(UUID().uuidString)"))
        guard let firstBytes else { return bound }
        let asset = try await ingest(fixture, bytes: firstBytes)
        let staged = try stage(
            fixture, sessionToken: binding.sessionToken,
            data: firstBytes, format: "png")
        return try await fixture.design.bindCreativeFirstResult(
            G09R2DesignCreativeBindRequest(
                binding: binding,
                expectedRevision: bound.envelope.revision,
                opID: "first-\(UUID().uuidString)",
                boundResultID: asset.id.uuidString.lowercased(),
                payload: staged,
                displayName: "first.png"),
            trustedUI: true)
    }

    private func adoptDifferentRevision(
        _ fixture: Fixture,
        binding: G09R2DesignBindingDTO,
        adoptedBytes: Data,
        proposeOpID: String,
        adoptOpID: String
    ) async throws -> G09R2DesignDecisionResultDTO {
        let state = try await fixture.design.state(binding)
        let artifact = try XCTUnwrap(state.envelope.project.artifacts.first)
        let base = try XCTUnwrap(artifact.currentRevision)
        let staged = try stage(
            fixture, sessionToken: binding.sessionToken,
            data: adoptedBytes, format: "png")
        let proposal = try await fixture.design.propose(
            G09R2DesignProposeRequest(
                binding: binding,
                expectedRevision: state.envelope.revision,
                opID: proposeOpID,
                artifactID: artifact.id,
                baseRevisionID: base.id,
                payload: staged,
                summary: "Publication candidate",
                diff: [],
                feedbackIDs: [],
                workIntent: nil),
            trustedUI: true)
        return try await fixture.design.adopt(G09R2DesignAdoptRequest(
            binding: binding,
            expectedRevision: proposal.state.envelope.revision,
            opID: adoptOpID,
            candidateID: proposal.candidate.id,
            mode: .updateOriginal),
            trustedUI: true)
    }

    // MARK: - Publication

    func testCreativeAdoptionPublishesVerifiedAssetAndPreservesOriginal()
        async throws {
        let fixture = try await makeFixture()
        let target = creativeTarget()
        let binding = creativeBinding(target)
        let first = try await ingest(fixture, bytes: Self.pngBytes)
        _ = try await bindCreative(
            fixture, target: target, binding: binding,
            firstBytes: Self.pngBytes)
        let assetCountBefore = try await fixture.assetStore.allAssets().count

        let adopted = try await adoptDifferentRevision(
            fixture, binding: binding,
            adoptedBytes: Self.adoptedPngBytes,
            proposeOpID: "publication-propose-1",
            adoptOpID: "publication-adopt-1")
        XCTAssertEqual(adopted.publication.state, .published)
        let identifier = try XCTUnwrap(adopted.publication.identifier)
        let receiptDigest = try XCTUnwrap(adopted.publication.contentSHA256)
        XCTAssertEqual(receiptDigest, FloeDigest.sha256Hex(Self.adoptedPngBytes))
        XCTAssertEqual(adopted.publication.destination, "creative:creative-library")
        XCTAssertNil(adopted.publication.reason)

        let assetID = try XCTUnwrap(UUID(uuidString: identifier))
        let recordValue = try await fixture.assetStore.asset(id: assetID)
        let record = try XCTUnwrap(recordValue)
        XCTAssertEqual(
            record.contentHash,
            FloeDigest.sha256Hex(Self.adoptedPngBytes))
        let relative = try XCTUnwrap(record.localRelativePath)
        XCTAssertTrue(relative.hasPrefix(assetID.uuidString + "-design-"))
        let url = try materialURL(fixture, record: record)
        XCTAssertEqual(try Data(contentsOf: url), Self.adoptedPngBytes)

        // The original first-result asset row and bytes are untouched.
        let originalValue = try await fixture.assetStore.asset(id: first.id)
        let original = try XCTUnwrap(originalValue)
        XCTAssertEqual(original.contentHash, FloeDigest.sha256Hex(Self.pngBytes))
        XCTAssertEqual(
            try Data(contentsOf: materialURL(fixture, record: original)),
            Self.pngBytes)
        let countAfterAdoption =
            try await fixture.assetStore.allAssets().count
        XCTAssertEqual(countAfterAdoption, assetCountBefore + 1)

        // Replay of the SAME adopt returns the SAME canonical asset/receipt
        // and never duplicates the library row.
        let replay = try await fixture.design.adopt(G09R2DesignAdoptRequest(
            binding: binding,
            expectedRevision: adopted.state.envelope.revision,
            opID: "publication-adopt-1",
            candidateID: adopted.candidateID,
            mode: .updateOriginal),
            trustedUI: true)
        XCTAssertTrue(replay.idempotent)
        XCTAssertEqual(replay.publication.state, .published)
        XCTAssertEqual(replay.publication.identifier, identifier)
        XCTAssertEqual(replay.publication.contentSHA256, receiptDigest)
        let countAfterReplay = try await fixture.assetStore.allAssets().count
        XCTAssertEqual(countAfterReplay, assetCountBefore + 1)
    }

    func testCreativePublicationRepairsMissingCanonicalBytesIdempotently()
        async throws {
        let fixture = try await makeFixture()
        let target = creativeTarget()
        let binding = creativeBinding(target)
        _ = try await bindCreative(
            fixture, target: target, binding: binding,
            firstBytes: Self.pngBytes)
        let adopted = try await adoptDifferentRevision(
            fixture, binding: binding,
            adoptedBytes: Self.adoptedPngBytes,
            proposeOpID: "repair-propose-1",
            adoptOpID: "repair-adopt-1")
        let identifier = try XCTUnwrap(adopted.publication.identifier)
        let assetID = try XCTUnwrap(UUID(uuidString: identifier))
        let recordValue = try await fixture.assetStore.asset(id: assetID)
        let record = try XCTUnwrap(recordValue)
        let url = try materialURL(fixture, record: record)
        let count = try await fixture.assetStore.allAssets().count

        // Simulate a crash between the durable row and the file write: the
        // replay must repair the SAME canonical asset, never mint a new row.
        try FileManager.default.removeItem(at: url)
        let replay = try await fixture.design.adopt(G09R2DesignAdoptRequest(
            binding: binding,
            expectedRevision: adopted.state.envelope.revision,
            opID: "repair-adopt-1",
            candidateID: adopted.candidateID,
            mode: .updateOriginal),
            trustedUI: true)
        XCTAssertEqual(replay.publication.state, .published)
        XCTAssertEqual(replay.publication.identifier, identifier)
        XCTAssertEqual(try Data(contentsOf: url), Self.adoptedPngBytes)
        let countAfterRepair = try await fixture.assetStore.allAssets().count
        XCTAssertEqual(countAfterRepair, count)
    }

    func testCreativePublicationFailureStaysPendingAndRetriesSameIntent()
        async throws {
        let fixture = try await makeFixture()
        let target = creativeTarget()
        let binding = creativeBinding(target)
        _ = try await bindCreative(
            fixture, target: target, binding: binding,
            firstBytes: Self.pngBytes)
        let state = try await fixture.design.state(binding)
        let artifact = try XCTUnwrap(state.envelope.project.artifacts.first)
        let base = try XCTUnwrap(artifact.currentRevision)
        let staged = try stage(
            fixture, sessionToken: binding.sessionToken,
            data: Self.adoptedPngBytes, format: "png")
        let proposal = try await fixture.design.propose(
            G09R2DesignProposeRequest(
                binding: binding,
                expectedRevision: state.envelope.revision,
                opID: "failure-propose-1",
                artifactID: artifact.id,
                baseRevisionID: base.id,
                payload: staged,
                summary: "Failing publication",
                diff: [],
                feedbackIDs: [],
                workIntent: nil),
            trustedUI: true)
        let materials = fixture.root.artifactStoreURL
            .appendingPathComponent("Materials", isDirectory: true)
        let countBefore = try await fixture.assetStore.allAssets().count
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: materials.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: materials.path)
        }
        let adopted = try await fixture.design.adopt(G09R2DesignAdoptRequest(
            binding: binding,
            expectedRevision: proposal.state.envelope.revision,
            opID: "failure-adopt-1",
            candidateID: proposal.candidate.id,
            mode: .updateOriginal),
            trustedUI: true)
        // The owner CAS committed, but the result is NOT claimed as published.
        XCTAssertEqual(adopted.publication.state, .pending)
        XCTAssertNil(adopted.publication.identifier)
        XCTAssertNotNil(adopted.publication.reason)
        let countAfterFailure = try await fixture.assetStore.allAssets().count
        XCTAssertEqual(countAfterFailure, countBefore)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: materials.path)
        let retry = try await fixture.design.adopt(G09R2DesignAdoptRequest(
            binding: binding,
            expectedRevision: adopted.state.envelope.revision,
            opID: "failure-adopt-1",
            candidateID: proposal.candidate.id,
            mode: .updateOriginal),
            trustedUI: true)
        XCTAssertEqual(retry.publication.state, .published)
        let identifier = try XCTUnwrap(retry.publication.identifier)
        let retriedAsset = try await fixture.assetStore.asset(
            id: UUID(uuidString: identifier)!)
        XCTAssertNotNil(retriedAsset)
        let countAfterRetry = try await fixture.assetStore.allAssets().count
        XCTAssertEqual(countAfterRetry, countBefore + 1)
    }

    func testCreativePublicationCanonicalMergeAndCrossOwnerBinding()
        async throws {
        let fixture = try await makeFixture()
        let target = creativeTarget()
        let binding = creativeBinding(target)
        let original = try await ingest(fixture, bytes: Self.pngBytes)
        _ = try await bindCreative(
            fixture, target: target, binding: binding,
            firstBytes: Self.pngBytes)
        let digest = FloeDigest.sha256Hex(Self.pngBytes)
        let port = G09R2DesignCreativePublicationPort(assets: fixture.assets)
        let count = try await fixture.assetStore.allAssets().count
        let publication = DesignResultPublication(
            target: target,
            targetStableKey: target.stableKey,
            operationID: "merge-op",
            candidateID: "merge-candidate",
            mode: .updateOriginal,
            artifactID: "merge-artifact",
            revisionID: "merge-revision",
            payloadRelativePath: "merge.payload",
            contentSHA256: digest,
            format: "png",
            displayName: "Merged.png",
            originConversationID: nil,
            ownerRevision: 1,
            bytes: Self.pngBytes)
        // Identical bytes are the SAME canonical content-addressed asset: the
        // publication returns the original row instead of a duplicate.
        let receipt = try await port.publish(publication)
        XCTAssertEqual(
            receipt.identifier,
            original.id.uuidString.lowercased())
        XCTAssertEqual(receipt.destination, "creative:creative-library")
        let countAfterMerge = try await fixture.assetStore.allAssets().count
        XCTAssertEqual(countAfterMerge, count)

        // A frozen target that disagrees with the live identity is refused
        // before any write (no cross-owner replay/alias).
        let mismatched = DesignResultPublication(
            target: target,
            targetStableKey: String(repeating: "f", count: 64),
            operationID: publication.operationID,
            candidateID: publication.candidateID,
            mode: publication.mode,
            artifactID: publication.artifactID,
            revisionID: publication.revisionID,
            payloadRelativePath: publication.payloadRelativePath,
            contentSHA256: digest,
            format: "png",
            displayName: publication.displayName,
            originConversationID: nil,
            ownerRevision: 1,
            bytes: Self.pngBytes)
        do {
            _ = try await port.publish(mismatched)
            XCTFail("a mismatched frozen target must be refused")
        } catch is G09R2DesignPublicationError {
            // expected
        }

        // Unsupported/malformed payload or format is typed and writes nothing.
        let badFormat = DesignResultPublication(
            target: target, targetStableKey: target.stableKey,
            operationID: "bad-format", candidateID: "c",
            mode: .updateOriginal, artifactID: "a", revisionID: "r",
            payloadRelativePath: "p", contentSHA256: digest,
            format: "bin", displayName: "Bad", originConversationID: nil,
            ownerRevision: 1, bytes: Self.pngBytes)
        do {
            _ = try await port.publish(badFormat)
            XCTFail("an unsupported creative format must be refused")
        } catch is G09R2DesignPublicationError {
            // expected
        }
        let wrongDigest = DesignResultPublication(
            target: target, targetStableKey: target.stableKey,
            operationID: "wrong-digest", candidateID: "c",
            mode: .updateOriginal, artifactID: "a", revisionID: "r",
            payloadRelativePath: "p",
            contentSHA256: String(repeating: "0", count: 64),
            format: "png", displayName: "Wrong", originConversationID: nil,
            ownerRevision: 1, bytes: Self.pngBytes)
        do {
            _ = try await port.publish(wrongDigest)
            XCTFail("payload bytes that do not match the digest must be refused")
        } catch is G09R2DesignPublicationError {
            // expected
        }
        let countAfterRefusals =
            try await fixture.assetStore.allAssets().count
        XCTAssertEqual(countAfterRefusals, count)

        // Distinct owner/destination/publicationKey bindings derive distinct
        // deterministic identities; a replay of the SAME binding is stable.
        let other = DesignTarget(
            kind: .creativeDocument,
            ownerID: "creative-library",
            sourceID: UUID().uuidString.lowercased(),
            requestedOutputKind: .image)
        let otherPublication = DesignResultPublication(
            target: other, targetStableKey: other.stableKey,
            operationID: "merge-op", candidateID: "merge-candidate",
            mode: .updateOriginal, artifactID: "merge-artifact",
            revisionID: "merge-revision", payloadRelativePath: "merge.payload",
            contentSHA256: digest, format: "png", displayName: "Merged.png",
            originConversationID: nil, ownerRevision: 1, bytes: Self.pngBytes)
        let keyA = G09R2DesignCreativePublicationPort.bindingKey(
            publication, targetKey: target.stableKey,
            destination: G09R2DesignCreativePublicationPort
                .destination(for: publication))
        let keyB = G09R2DesignCreativePublicationPort.bindingKey(
            otherPublication, targetKey: other.stableKey,
            destination: G09R2DesignCreativePublicationPort
                .destination(for: otherPublication))
        XCTAssertNotEqual(keyA, keyB)
        let idA = G09R2DesignCreativePublicationPort.deterministicUUID(
            "floe.design.publication.asset|\(keyA)")
        let idAReplay = G09R2DesignCreativePublicationPort.deterministicUUID(
            "floe.design.publication.asset|\(keyA)")
        let idB = G09R2DesignCreativePublicationPort.deterministicUUID(
            "floe.design.publication.asset|\(keyB)")
        XCTAssertEqual(idA, idAReplay)
        XCTAssertNotEqual(idA, idB)
    }

    func testCreativePublicationRootStopRefusesLateAdoption() async throws {
        let fixture = try await makeFixture()
        let target = creativeTarget()
        let binding = creativeBinding(target)
        _ = try await bindCreative(
            fixture, target: target, binding: binding,
            firstBytes: Self.pngBytes)
        let state = try await fixture.design.state(binding)
        let artifact = try XCTUnwrap(state.envelope.project.artifacts.first)
        let base = try XCTUnwrap(artifact.currentRevision)
        let staged = try stage(
            fixture, sessionToken: binding.sessionToken,
            data: Self.adoptedPngBytes, format: "png")
        let proposal = try await fixture.design.propose(
            G09R2DesignProposeRequest(
                binding: binding,
                expectedRevision: state.envelope.revision,
                opID: "stop-propose-1",
                artifactID: artifact.id,
                baseRevisionID: base.id,
                payload: staged,
                summary: "Stop",
                diff: [],
                feedbackIDs: [],
                workIntent: nil),
            trustedUI: true)
        let count = try await fixture.assetStore.allAssets().count
        let drained = await fixture.design.requestRootStop(
            epoch: fixture.epoch)
        XCTAssertTrue(drained)
        do {
            _ = try await fixture.design.adopt(G09R2DesignAdoptRequest(
                binding: binding,
                expectedRevision: proposal.state.envelope.revision,
                opID: "stop-adopt-1",
                candidateID: proposal.candidate.id,
                mode: .updateOriginal),
            trustedUI: true)
            XCTFail("an adoption after Root stop must be refused")
        } catch let error as G09CreativeError {
            XCTAssertEqual(error, .staleGeneration)
        }
        let countAfterStop = try await fixture.assetStore.allAssets().count
        XCTAssertEqual(countAfterStop, count)
        do {
            _ = try await fixture.design.creativeAssets(trustedUI: true)
            XCTFail("inventory after Root stop must be refused")
        } catch let error as G09CreativeError {
            XCTAssertEqual(error, .staleGeneration)
        }
    }

    // MARK: - Retained asset / staged import

    func testRetainedAssetBindReadsVerifiedBytesWithoutPayloadToken()
        async throws {
        let fixture = try await makeFixture()
        let target = creativeTarget()
        let binding = creativeBinding(target)
        let asset = try await ingest(fixture, bytes: Self.pngBytes)
        let bound = try await fixture.design.bind(G09R2DesignBindRequest(
            binding: binding, expectedRevision: 0, opID: "retained-bind"))
        let first = try await fixture.design.bindCreativeRetainedFirstResult(
            G09R2DesignCreativeRetainedBindRequest(
                binding: binding,
                expectedRevision: bound.envelope.revision,
                opID: "retained-first",
                boundResultID: asset.id.uuidString.lowercased()),
            trustedUI: true)
        XCTAssertEqual(first.envelope.project.creativeRequest?.state,
                       .firstResultBound)
        XCTAssertEqual(
            first.envelope.project.creativeRequest?.boundResultID,
            asset.id.uuidString.lowercased())
        XCTAssertEqual(first.envelope.creativeFirstResultProvenance,
                       .trustedUIManualImport)
        let revision = try XCTUnwrap(
            first.envelope.project.artifacts.first?.currentRevision)
        XCTAssertEqual(revision.contentSHA256,
                       FloeDigest.sha256Hex(Self.pngBytes))

        // A tampered retained file is refused before any envelope change.
        try Data("tampered".utf8).write(
            to: materialURL(fixture, record: asset))
        let otherTarget = creativeTarget()
        let otherBinding = creativeBinding(
            otherTarget, sessionToken: "retained-tamper-session")
        let otherBound = try await fixture.design.bind(
            G09R2DesignBindRequest(
                binding: otherBinding, expectedRevision: 0,
                opID: "retained-tamper-bind"))
        do {
            _ = try await fixture.design
                .bindCreativeRetainedFirstResult(
                    G09R2DesignCreativeRetainedBindRequest(
                        binding: otherBinding,
                        expectedRevision: otherBound.envelope.revision,
                        opID: "retained-tamper-first",
                        boundResultID: asset.id.uuidString.lowercased()),
                    trustedUI: true)
            XCTFail("tampered retained bytes must be refused")
        } catch let error as G09CreativeError {
            XCTAssertEqual(error, .assetDigestMismatch)
        }
        let untouched = try await fixture.design.state(otherBinding)
        XCTAssertEqual(
            untouched.envelope.project.creativeRequest?.state,
            .awaitingFirstResult)
        XCTAssertTrue(untouched.envelope.project.artifacts.isEmpty)
    }

    func testStagedImportCreatesRealCanonicalAssetAndReusesContentMerge()
        async throws {
        let fixture = try await makeFixture()
        let target = creativeTarget()
        let binding = creativeBinding(target)
        let bound = try await fixture.design.bind(G09R2DesignBindRequest(
            binding: binding, expectedRevision: 0, opID: "import-bind"))
        let staged = try stage(
            fixture, sessionToken: binding.sessionToken,
            data: Self.adoptedPngBytes, format: "png")
        let receipt = try await fixture.design.importCreativeFirstResult(
            G09R2DesignCreativeImportBindRequest(
                binding: binding,
                expectedRevision: bound.envelope.revision,
                opID: "import-first",
                payload: staged,
                displayName: "Manual material"),
            trustedUI: true)
        XCTAssertTrue(receipt.imported)
        let assetID = try XCTUnwrap(UUID(uuidString: receipt.asset.assetID))
        let recordValue = try await fixture.assetStore.asset(id: assetID)
        let record = try XCTUnwrap(recordValue)
        XCTAssertEqual(
            record.contentHash,
            FloeDigest.sha256Hex(Self.adoptedPngBytes))
        XCTAssertEqual(
            try Data(contentsOf: materialURL(fixture, record: record)),
            Self.adoptedPngBytes)
        XCTAssertEqual(
            receipt.state.envelope.project.creativeRequest?.boundResultID,
            assetID.uuidString.lowercased())

        // A second target importing the SAME bytes resolves the SAME canonical
        // row (`imported == false`), never a duplicate library asset.
        let otherTarget = creativeTarget()
        let otherBinding = creativeBinding(
            otherTarget, sessionToken: "import-merge-session")
        let otherBound = try await fixture.design.bind(G09R2DesignBindRequest(
            binding: otherBinding, expectedRevision: 0,
            opID: "import-merge-bind"))
        let otherStaged = try stage(
            fixture, sessionToken: otherBinding.sessionToken,
            data: Self.adoptedPngBytes, format: "png")
        let merged = try await fixture.design.importCreativeFirstResult(
            G09R2DesignCreativeImportBindRequest(
                binding: otherBinding,
                expectedRevision: otherBound.envelope.revision,
                opID: "import-merge-first",
                payload: otherStaged),
            trustedUI: true)
        XCTAssertFalse(merged.imported)
        XCTAssertEqual(
            merged.asset.assetID, assetID.uuidString.lowercased())
    }

    // MARK: - Bounded inventory / pending reopen

    func testCreativeAssetPageIsBoundedAndPendingRequestReopens()
        async throws {
        let fixture = try await makeFixture()
        for index in 0..<30 {
            _ = try await ingest(
                fixture,
                bytes: Data("inventory-\(index)".utf8),
                format: "png",
                fileName: "inventory-\(index).png")
        }
        let first = try await fixture.design.creativeAssets(
            limit: 200, cursor: nil, trustedUI: true)
        XCTAssertEqual(first.assets.count, 24)
        XCTAssertNotNil(first.nextCursor)
        let second = try await fixture.design.creativeAssets(
            limit: 200, cursor: first.nextCursor, trustedUI: true)
        XCTAssertLessThanOrEqual(second.assets.count, 24)
        XCTAssertFalse(second.assets.isEmpty)
        XCTAssertTrue(
            Set(first.assets.map(\.assetID))
                .isDisjoint(with: Set(second.assets.map(\.assetID))))
        let clamped = try await fixture.design.creativeAssets(
            limit: 0, cursor: nil, trustedUI: true)
        XCTAssertEqual(clamped.assets.count, 1)
        do {
            _ = try await fixture.design.creativeAssets(
                limit: 24, cursor: nil, trustedUI: false)
            XCTFail("the inventory is host-bridge only")
        } catch let error as G09CreativeError {
            XCTAssertEqual(error, .sessionRequired)
        }

        let target = creativeTarget()
        let binding = creativeBinding(target)
        let bound = try await fixture.design.bind(G09R2DesignBindRequest(
            binding: binding, expectedRevision: 0, opID: "pending-bind"))
        let pending = try await fixture.design.creativePendingRequests(
            limit: 24, cursor: nil, trustedUI: true)
        let entry = try XCTUnwrap(
            pending.requests.first { $0.targetKey == target.stableKey })
        XCTAssertEqual(entry.ownerRevision, bound.envelope.revision)
        XCTAssertEqual(entry.state, .awaitingFirstResult)
        XCTAssertEqual(entry.requestedOutputKind, .image)
        XCTAssertEqual(entry.target.kind, .creativeDocument)
        XCTAssertEqual(entry.target.sourceID, target.sourceID)

        // Reopen the returned exact target with a fresh editor session: the
        // SAME owner envelope/request is returned, no id pasting/guessing.
        let reopened = try await fixture.design.bind(G09R2DesignBindRequest(
            binding: G09R2DesignBindingDTO(
                target: entry.target,
                storage: G09StorageLayerDTO(kind: .appOwned),
                sessionToken: "reopen-session"),
            expectedRevision: entry.ownerRevision,
            opID: "pending-reopen"))
        XCTAssertEqual(reopened.envelope.revision, bound.envelope.revision)
        XCTAssertEqual(reopened.envelope.project.creativeRequest?.state,
                       .awaitingFirstResult)
        XCTAssertEqual(reopened.envelope.target.stableKey, target.stableKey)
    }

    // MARK: - Size / path refusals

    func testRetainedBindRefusesOversizeAndEscapingAssetPaths()
        async throws {
        let fixture = try await makeFixture()
        let oversize = try await ingest(fixture, bytes: Self.pngBytes)
        let oversizeURL = try materialURL(fixture, record: oversize)
        let handle = try FileHandle(forWritingTo: oversizeURL)
        try handle.truncate(
            atOffset: UInt64(G09R2CreativeLimits.designSourceBytes) + 1)
        try handle.close()

        let target = creativeTarget()
        let binding = creativeBinding(target)
        let bound = try await fixture.design.bind(G09R2DesignBindRequest(
            binding: binding, expectedRevision: 0, opID: "oversize-bind"))
        do {
            _ = try await fixture.design.bindCreativeRetainedFirstResult(
                G09R2DesignCreativeRetainedBindRequest(
                    binding: binding,
                    expectedRevision: bound.envelope.revision,
                    opID: "oversize-first",
                    boundResultID: oversize.id.uuidString.lowercased()),
                trustedUI: true)
            XCTFail("an asset over the design source cap must be refused")
        } catch let error as G09CreativeError {
            XCTAssertEqual(error, .assetTooLarge)
        }

        // A row whose recorded path escapes Materials is never selectable and
        // cannot be bound; no path from a caller or row becomes authority.
        let escapingID = UUID()
        let escapingBytes = Data("escaping asset".utf8)
        try await fixture.assetStore.save(CreativeAssetRecord(
            id: escapingID,
            contentHash: FloeDigest.sha256Hex(escapingBytes),
            kind: .image,
            displayName: "escape.png",
            mimeType: "image/png",
            localRelativePath: "../escape.png",
            byteCount: Int64(escapingBytes.count),
            referenceCount: 0))
        let escapingTarget = creativeTarget()
        let escapingBinding = creativeBinding(
            escapingTarget, sessionToken: "escaping-session")
        let escapingBound = try await fixture.design.bind(
            G09R2DesignBindRequest(
                binding: escapingBinding, expectedRevision: 0,
                opID: "escaping-bind"))
        do {
            _ = try await fixture.design.bindCreativeRetainedFirstResult(
                G09R2DesignCreativeRetainedBindRequest(
                    binding: escapingBinding,
                    expectedRevision: escapingBound.envelope.revision,
                    opID: "escaping-first",
                    boundResultID: escapingID.uuidString.lowercased()),
                trustedUI: true)
            XCTFail("an escaping Materials path must be refused")
        } catch let error as G09CreativeError {
            XCTAssertEqual(error, .assetReferenceInvalid)
        }
        let listed = try await fixture.design.creativeAssets(
            limit: 24, cursor: nil, trustedUI: true)
        let escapedEntry = listed.assets.first {
            $0.assetID == escapingID.uuidString.lowercased()
        }
        XCTAssertEqual(escapedEntry?.selectable, false)
    }
}
