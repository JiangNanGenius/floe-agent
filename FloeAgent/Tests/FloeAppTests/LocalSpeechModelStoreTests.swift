#if canImport(UIKit)
import XCTest
import CryptoKit
@testable import FloeApp

@MainActor
final class LocalSpeechModelStoreTests: XCTestCase {
    func testRejectedDownloadPreservesInstalledModelAndRetryCanRecover() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "local-speech-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let bytes = Data("verified-model".utf8)
        let model = fixture(bytes)
        let downloader = DownloadFixture(root: root.appendingPathComponent("transfers"), bytes: bytes)
        let store = LocalSpeechModelStore(catalog: LocalSpeechCatalog(schemaVersion: 1, models: [model]), root: root.appendingPathComponent("models"), defaults: UserDefaults(suiteName: suite)!, downloader: downloader)
        await store.beginInstallation(model)
        try await waitForCompletion(store)
        let installed = await store.isInstalled(model)
        XCTAssertTrue(installed)
        await downloader.setCorrupt(true)
        await store.beginInstallation(model)
        try await waitForCompletion(store)
        let failure = await store.state().failureKey
        XCTAssertNotNil(failure)
        let preserved = await store.isInstalled(model)
        XCTAssertTrue(preserved, "A failed replacement must not destroy the good model")
        await downloader.setCorrupt(false)
        await store.beginInstallation(model)
        try await waitForCompletion(store)
        let retryFailure = await store.state().failureKey
        XCTAssertNil(retryFailure)
        try await store.remove(model)
        let removed = await store.isInstalled(model)
        XCTAssertFalse(removed)
    }

    func testCancellationDoesNotInstallIncompleteFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "local-speech-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let bytes = Data("model".utf8), model = fixture(Data("model".utf8))
        let downloader = DownloadFixture(root: root.appendingPathComponent("transfers"), bytes: bytes, delays: true)
        let store = LocalSpeechModelStore(catalog: LocalSpeechCatalog(schemaVersion: 1, models: [model]), root: root.appendingPathComponent("models"), defaults: UserDefaults(suiteName: suite)!, downloader: downloader)
        await store.beginInstallation(model)
        await store.cancelInstallation()
        try await waitForCompletion(store)
        let installed = await store.isInstalled(model)
        XCTAssertFalse(installed)
    }

    func testVoiceMetadataUpdateKeepsVerifiedModelFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "local-speech-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let bytes = Data("verified-model".utf8)
        let model = fixture(bytes)
        let store = LocalSpeechModelStore(catalog: LocalSpeechCatalog(schemaVersion: 1, models: [model]), root: root.appendingPathComponent("models"), defaults: UserDefaults(suiteName: suite)!, downloader: DownloadFixture(root: root.appendingPathComponent("transfers"), bytes: bytes))
        await store.beginInstallation(model)
        try await waitForCompletion(store)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(model)) as? [String: Any])
        object["title"] = "Updated display name"
        object["languages"] = ["zh", "en", "ja"]
        let updated = try JSONDecoder().decode(LocalSpeechModel.self, from: JSONSerialization.data(withJSONObject: object))
        let stillInstalled = await store.isInstalled(updated)
        XCTAssertTrue(stillInstalled, "Voice metadata updates must not require downloading the same model again")
        var files = try XCTUnwrap(object["files"] as? [[String: Any]])
        files[0]["sha256"] = String(repeating: "0", count: 64)
        object["files"] = files
        let changed = try JSONDecoder().decode(LocalSpeechModel.self, from: JSONSerialization.data(withJSONObject: object))
        let differentAssets = await store.isInstalled(changed)
        XCTAssertFalse(differentAssets, "Asset changes still require complete verification and installation")
    }

    func testCatalogRejectsTraversalAndUnpinnedAssetURLs() async {
        var model = fixture(Data("model".utf8))
        model = LocalSpeechModel(id: model.id, title: model.title, engine: model.engine, repository: model.repository, revision: model.revision, license: model.license, languages: model.languages, voices: model.voices, files: [.init(path: "../escape", url: URL(string: "https://huggingface.co/test/model/resolve/main/weights.bin")!, sha256: String(repeating: "1", count: 64), byteCount: 5)], tokenizerRelativePath: nil, minimumMemoryBytes: nil)
        let store = LocalSpeechModelStore(catalog: LocalSpeechCatalog(schemaVersion: 1, models: [model]))
        do { _ = try await store.catalog(); XCTFail("Malformed catalog accepted") }
        catch { XCTAssertEqual(error as? LocalSpeechModelStore.Failure, .corrupt) }
    }

    func testBundledCatalogOffersOnlyTheSmallEnhancedPackWithHiddenLegacyDescriptor() async throws {
        let store = LocalSpeechModelStore.shared
        let all = try await store.catalog()
        let visible = try await store.visibleCatalog()
        XCTAssertEqual(visible.count, 1, "Exactly one pack may be downloaded/picked: the small MOSS-based enhanced model")
        let pack = try XCTUnwrap(visible.first)
        XCTAssertEqual(pack.engine, "mossTTSNano")
        XCTAssertEqual(pack.defaultVoiceID, "default")
        XCTAssertFalse(pack.isHidden)
        XCTAssertLessThan(pack.byteCount, 400_000_000, "Enhanced pack ships at ~369 MB, not the old gigabyte size")
        XCTAssertEqual(pack.voices.map(\.id), [
            "default", "vivian", "serena", "uncle_fu", "dylan", "eric", "ryan", "aiden", "ono_anna", "sohee"
        ])
        for voice in pack.voices where voice.id != "default" {
            let reference = try XCTUnwrap(voice.reference)
            let codes = try LocalSpeechVoiceReference.load(reference: reference, modelDirectory: FileManager.default.temporaryDirectory)
            XCTAssertEqual(codes.count, reference.frames)
            XCTAssertTrue(codes.allSatisfy { $0.count == 16 })
            XCTAssertEqual(voice.languages, ["zh", "en", "ja"])
        }
        let legacy = try XCTUnwrap(all.first { $0.engine == "qwen3TTS" })
        XCTAssertTrue(legacy.isHidden, "The legacy descriptor stays loadable for old installs until the migration finishes")
        XCTAssertEqual(legacy.defaultVoiceID, "vivian")
        XCTAssertEqual(Set(legacy.voices.map(\.id)), Set([
            "vivian", "serena", "uncle_fu", "dylan", "eric", "ryan", "aiden", "ono_anna", "sohee"
        ]))
        XCTAssertEqual(legacy.voices.count, 9)
    }

    func testCatalogRejectsUnsafeModelDirectoryNames() async {
        let original = fixture(Data("model".utf8))
        for id in ["..", "../escape", ".staging", "nested/model"] {
            let model = LocalSpeechModel(id: id, title: original.title, engine: original.engine,
                repository: original.repository, revision: original.revision, license: original.license,
                languages: original.languages, voices: original.voices, files: original.files,
                tokenizerRelativePath: nil, minimumMemoryBytes: nil)
            let store = LocalSpeechModelStore(catalog: .init(schemaVersion: 1, models: [model]))
            do { _ = try await store.catalog(); XCTFail("Unsafe model directory accepted: \(id)") }
            catch { XCTAssertEqual(error as? LocalSpeechModelStore.Failure, .corrupt) }
        }
    }

    func testHiddenLegacyPackCannotBeInstalled() async {
        let legacy = hiddenPack()
        let store = LocalSpeechModelStore(catalog: LocalSpeechCatalog(schemaVersion: 1, models: [legacy, visiblePack()]))
        await store.beginInstallation(legacy)
        let state = await store.state()
        XCTAssertFalse(state.running, "A hidden legacy descriptor must never start a download")
        XCTAssertEqual(state.failureKey, "voice.local.error.legacy")
    }

    // MARK: - Reference voice schema

    func testCatalogValidatesReferenceVoiceEnvelopes() async {
        let base = visiblePack()
        let good = reference(path: "references/qualified.json", source: .bundled)
        // The default voice id must stay in the list (defaultVoiceID binding).
        let ok = patched(base, voices: base.voices + [voice(id: "qualified", reference: good)])
        do { _ = try await LocalSpeechModelStore(catalog: .init(schemaVersion: 1, models: [ok])).catalog() }
        catch { XCTFail("Valid reference envelope rejected: \(error)") }
        let mutations: [(String, LocalSpeechModel.Voice.Reference)] = [
            ("wrong frame width", reference(path: "references/x.json", codesPerFrame: 8)),
            ("wrong codebook", reference(path: "references/x.json", codebookSize: 512)),
            ("zero frames", reference(path: "references/x.json", frames: 0)),
            ("path outside references/", reference(path: "voices/x.json")),
            ("short digest", reference(path: "references/x.json", sha256: "abc")),
            ("downloaded asset without catalog binding", reference(path: "references/x.json", source: .downloaded))
        ]
        for (label, bad) in mutations {
            let model = patched(base, voices: base.voices + [voice(id: "qualified", reference: bad)])
            let store = LocalSpeechModelStore(catalog: .init(schemaVersion: 1, models: [model]))
            do { _ = try await store.catalog(); XCTFail("Invalid reference accepted (\(label))") }
            catch { XCTAssertEqual(error as? LocalSpeechModelStore.Failure, .corrupt, label) }
        }
    }

    func testReferenceFileParsingIsFailClosed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("pack")
        let codes = (0..<7).map { frame in (0..<16).map { Int32(($0 + frame * 16) % 1024) } }
        let json = referenceJSON(codes: codes)
        let file = directory.appendingPathComponent("references/qualified.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try json.write(to: file)
        let reference = reference(path: "references/qualified.json", source: .downloaded, sha256: hex(Data(json)), byteCount: Int64(json.count), frames: 7)
        let parsed = try LocalSpeechVoiceReference.load(reference: reference, modelDirectory: directory)
        XCTAssertEqual(parsed, codes)
        // Tampered bytes (same length): hash gate.
        var tampered = json
        tampered[tampered.index(after: tampered.startIndex)] ^= 1
        try tampered.write(to: file)
        XCTAssertThrowsError(try LocalSpeechVoiceReference.load(reference: reference, modelDirectory: directory)) {
            XCTAssertEqual($0 as? LocalSpeechVoiceReference.LoadError, .corrupt)
        }
        try json.write(to: file)
        // Size gate.
        let short = self.reference(path: "references/qualified.json", source: .downloaded, sha256: hex(Data(json)), byteCount: 4, frames: 7)
        XCTAssertThrowsError(try LocalSpeechVoiceReference.load(reference: short, modelDirectory: directory))
        let wrongFrames = self.reference(path: "references/qualified.json", source: .downloaded, sha256: hex(json), byteCount: Int64(json.count), frames: 6)
        XCTAssertThrowsError(try LocalSpeechVoiceReference.load(reference: wrongFrames, modelDirectory: directory))
        // Out-of-range code gate.
        let outOfRange = referenceJSON(codes: [Array(repeating: Int32(1024), count: 16)])
        try outOfRange.write(to: file)
        let rangeReference = self.reference(path: "references/qualified.json", source: .downloaded, sha256: hex(outOfRange), byteCount: Int64(outOfRange.count), frames: 1)
        XCTAssertThrowsError(try LocalSpeechVoiceReference.load(reference: rangeReference, modelDirectory: directory))
        // Missing file gate.
        try FileManager.default.removeItem(at: file)
        XCTAssertThrowsError(try LocalSpeechVoiceReference.load(reference: reference, modelDirectory: directory)) {
            XCTAssertEqual($0 as? LocalSpeechVoiceReference.LoadError, .missing)
        }
    }

    // MARK: - Durable migration + exact cleanup

    func testMigrationStagesAreDurableAndCleanupRemovesOnlyExactLegacyArtifacts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "local-speech-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = hiddenPack()
        let fresh = visiblePack()
        let modelsRoot = root.appendingPathComponent("models")
        let transfers = root.appendingPathComponent("transfers")
        try seedInstalledPack(legacy, root: modelsRoot, bytes: Data(legacyBytes))
        try seedTransferArtifacts(for: legacy, transfers: transfers)
        // Foreign transfer bytes and an ASR-shaped key must survive: cleanup is
        // strictly limited to the legacy pack's own final/staging/URL-keyed blobs.
        let decoy = transfers.appendingPathComponent(String(repeating: "f", count: 64) + ".download")
        try Data("asr-adjacent".utf8).write(to: decoy)
        let freshArtifacts = LocalSpeechModelStore.transferArtifacts(for: try XCTUnwrap(fresh.files.first?.url), transfersRoot: transfers)
        try Data("keep-me".utf8).write(to: freshArtifacts[1])
        let store = LocalSpeechModelStore(catalog: LocalSpeechCatalog(schemaVersion: 1, models: [legacy, fresh]),
                                          root: modelsRoot, defaults: defaults,
                                          downloader: DownloadFixture(root: transfers, bytes: Data(freshBytes)),
                                          transfersRoot: transfers)
        await store.beginInstallation(fresh, selectionRevision: 7)
        try await waitForCompletion(store)
        var record = await store.migrationRecord
        XCTAssertEqual(record?.stage, .awaitingLoadValidation)
        XCTAssertEqual(record?.newModelID, fresh.id)
        XCTAssertEqual(record?.selectionRevision, 7)
        XCTAssertEqual(record?.legacy.map(\.id), [legacy.id])
        // Process death: the same durable state is visible to a fresh instance.
        let relaunched = LocalSpeechModelStore(catalog: LocalSpeechCatalog(schemaVersion: 1, models: [legacy, fresh]),
                                               root: modelsRoot, defaults: defaults,
                                               downloader: DownloadFixture(root: transfers, bytes: Data(freshBytes)),
                                               transfersRoot: transfers)
        await relaunched.restoreInstallation()
        record = await relaunched.migrationRecord
        XCTAssertEqual(record?.stage, .awaitingLoadValidation, "Migration stages survive process death")
        await store.migrationLoadValidated(legacyStillSelected: false)
        try await waitForMigrationCompletion(store)
        let gone = await store.isInstalled(legacy)
        XCTAssertFalse(gone, "Legacy final pack directory removed after validated migration")
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelsRoot.appendingPathComponent("tts-\(legacy.id)-\(legacy.revision)").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelsRoot.appendingPathComponent(".tts-\(legacy.id)-\(legacy.revision)").path))
        for artifact in legacyArtifacts(legacy, transfers: transfers) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: artifact.path), "Known legacy transfer blob \(artifact.lastPathComponent) removed")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: decoy.path), "Foreign transfer bytes are never touched")
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshArtifacts[1].path), "The new pack's own resumable transfer is preserved")
        let installed = await store.isInstalled(fresh)
        XCTAssertTrue(installed)
    }

    func testLeaseBlockedLegacyCleanupRetriesOnReleaseAndLaunch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "local-speech-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = hiddenPack()
        let fresh = visiblePack()
        let modelsRoot = root.appendingPathComponent("models")
        try seedInstalledPack(legacy, root: modelsRoot, bytes: Data(legacyBytes))
        let store = LocalSpeechModelStore(catalog: LocalSpeechCatalog(schemaVersion: 1, models: [legacy, fresh]),
                                          root: modelsRoot, defaults: defaults,
                                          downloader: DownloadFixture(root: root.appendingPathComponent("transfers"), bytes: Data(freshBytes)),
                                          transfersRoot: root.appendingPathComponent("transfers"))
        await store.beginInstallation(fresh, selectionRevision: 1)
        try await waitForCompletion(store)
        let lease: LocalSpeechModelStore.Lease
        do { lease = try await store.acquire(legacy.id) }
        catch LocalSpeechModelStore.Failure.memory, LocalSpeechModelStore.Failure.thermal {
            throw XCTSkip("Lease path requires device-like memory/thermal headroom")
        }
        await store.migrationLoadValidated(legacyStillSelected: true)
        var record = await store.migrationRecord
        XCTAssertEqual(record?.stage, .awaitingLegacyRelease)
        // A still-in-use legacy pack blocks cleanup even after release is signed.
        await store.migrationLegacyReleased()
        record = await store.migrationRecord
        XCTAssertEqual(record?.stage, .cleanupPending)
        let actualAt272 = await store.isInstalled(legacy)
        XCTAssertTrue(actualAt272)
        // Retry on lease release.
        await store.release(lease.id)
        try await waitForMigrationCompletion(store)
        let actualAt276 = await store.isInstalled(legacy)
        XCTAssertFalse(actualAt276)
        // Retry on launch: a cleanupPending stage persisted by the previous
        // process completes during restoreInstallation once the process (and
        // with it every lease) is gone.
        let suite2 = "local-speech-tests.\(UUID().uuidString)"
        let defaults2 = UserDefaults(suiteName: suite2)!
        defer { defaults2.removePersistentDomain(forName: suite2) }
        let modelsRoot2 = root.appendingPathComponent("models2")
        try seedInstalledPack(legacy, root: modelsRoot2, bytes: Data(legacyBytes))
        let pre = LocalSpeechModelStore(catalog: LocalSpeechCatalog(schemaVersion: 1, models: [legacy, fresh]),
                                        root: modelsRoot2, defaults: defaults2,
                                        downloader: DownloadFixture(root: root.appendingPathComponent("transfers2"), bytes: Data(freshBytes)),
                                        transfersRoot: root.appendingPathComponent("transfers2"))
        await pre.beginInstallation(fresh, selectionRevision: 1)
        try await waitForCompletion(pre)
        let held: LocalSpeechModelStore.Lease
        do { held = try await pre.acquire(legacy.id) }
        catch LocalSpeechModelStore.Failure.memory, LocalSpeechModelStore.Failure.thermal { throw XCTSkip("Lease path requires device-like memory/thermal headroom") }
        await pre.migrationLoadValidated(legacyStillSelected: true)
        await pre.migrationLegacyReleased()
        let again = await pre.migrationRecord
        XCTAssertEqual(again?.stage, .cleanupPending)
        let actualAt298 = await pre.isInstalled(legacy)
        XCTAssertTrue(actualAt298, "Lease-blocked cleanup defers, it never deletes under an active lease")
        _ = held
        // "Process death": the lease disappears with the old instance; a fresh
        // store reconciles at launch and finishes the removal.
        let launch = LocalSpeechModelStore(catalog: LocalSpeechCatalog(schemaVersion: 1, models: [legacy, fresh]),
                                           root: modelsRoot2, defaults: defaults2,
                                           downloader: DownloadFixture(root: root.appendingPathComponent("transfers3"), bytes: Data(freshBytes)),
                                           transfersRoot: root.appendingPathComponent("transfers3"))
        await launch.restoreInstallation()
        try await waitForMigrationCompletion(launch)
        let actualAt308 = await launch.isInstalled(legacy)
        XCTAssertFalse(actualAt308)
    }

    func testOldPendingTransferResumeIsDisabledAtLaunch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "local-speech-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = hiddenPack()
        let transfers = root.appendingPathComponent("transfers")
        try seedTransferArtifacts(for: legacy, transfers: transfers)
        let decoy = transfers.appendingPathComponent(String(repeating: "e", count: 64) + ".resume")
        try Data("foreign-resume".utf8).write(to: decoy)
        defaults.set(legacy.id, forKey: "voice.local.pendingInstallation")
        let store = LocalSpeechModelStore(catalog: LocalSpeechCatalog(schemaVersion: 1, models: [legacy]),
                                          root: root.appendingPathComponent("models"), defaults: defaults,
                                          downloader: DownloadFixture(root: transfers, bytes: Data(legacyBytes)),
                                          transfersRoot: transfers)
        await store.restoreInstallation()
        let state = await store.state()
        XCTAssertFalse(state.running, "A pending legacy install must not resume")
        XCTAssertNil(defaults.string(forKey: "voice.local.pendingInstallation"))
        for artifact in legacyArtifacts(legacy, transfers: transfers) where artifact.pathExtension == "resume" {
            XCTAssertFalse(FileManager.default.fileExists(atPath: artifact.path), "Legacy resume blobs dropped")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: decoy.path), "Only the legacy keys are removed")
    }

    func testCancelDuringMigrationKeepsLegacyPackAndPendingRecordDropped() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "local-speech-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = hiddenPack()
        let fresh = visiblePack()
        let modelsRoot = root.appendingPathComponent("models")
        try seedInstalledPack(legacy, root: modelsRoot, bytes: Data(legacyBytes))
        let store = LocalSpeechModelStore(catalog: LocalSpeechCatalog(schemaVersion: 1, models: [legacy, fresh]),
                                          root: modelsRoot, defaults: defaults,
                                          downloader: DownloadFixture(root: root.appendingPathComponent("transfers"), bytes: Data(freshBytes), delays: true),
                                          transfersRoot: root.appendingPathComponent("transfers"))
        await store.beginInstallation(fresh, selectionRevision: 2)
        var record = await store.migrationRecord
        XCTAssertEqual(record?.stage, .pendingInstall)
        await store.cancelInstallation()
        try await waitForCompletion(store)
        record = await store.migrationRecord
        XCTAssertNil(record, "Cancelling before completion aborts the migration intent")
        let actualAt358 = await store.isInstalled(legacy)
        XCTAssertTrue(actualAt358, "A cancelled new install preserves the old usable pack")
        let actualAt359 = await store.isInstalled(fresh)
        XCTAssertFalse(actualAt359)
    }

    func testProgressSnapshotReportsPhaseAndRealNetworkSpeedOnly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "local-speech-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = visiblePack()
        let store = LocalSpeechModelStore(catalog: LocalSpeechCatalog(schemaVersion: 1, models: [model]),
                                          root: root.appendingPathComponent("models"), defaults: defaults,
                                          downloader: TimedDownloadFixture(root: root.appendingPathComponent("transfers"), bytes: Data(freshBytes)),
                                          transfersRoot: root.appendingPathComponent("transfers"))
        await store.beginInstallation(model)
        var sawSpeed = false
        for _ in 0..<80 {
            let state = await store.state()
            if state.bytesPerSecond > 0 { sawSpeed = true }
            if !state.running { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try await waitForCompletion(store)
        XCTAssertTrue(sawSpeed, "Smoothed speed reflects real network callbacks")
        let final = await store.state()
        XCTAssertFalse(final.running)
        XCTAssertEqual(final.bytesPerSecond, 0, "Speed clears outside the live download")
        XCTAssertEqual(final.completed, final.total)
        XCTAssertEqual(final.downloadPercent, 100, accuracy: 0.001)
        XCTAssertEqual(final.phase, .committing, "100% download is reported as committing, and only isInstalled means installed")
    }

    func testRetirementFenceBlocksAcquireWhileCleanupSuspends() async throws {
        // Regression for actor reentrancy: cleanup awaits `retire` before the
        // synchronous deletion pass. A legacy acquire that lands mid-cleanup
        // must fail busy instead of mounting a lease under deletion.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "local-speech-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = hiddenPack()
        let fresh = visiblePack()
        let modelsRoot = root.appendingPathComponent("models")
        try seedInstalledPack(legacy, root: modelsRoot, bytes: Data(legacyBytes))
        let store = LocalSpeechModelStore(catalog: LocalSpeechCatalog(schemaVersion: 1, models: [legacy, fresh]),
                                          root: modelsRoot, defaults: defaults,
                                          downloader: GatedRetireFixture(root: root.appendingPathComponent("transfers"), bytes: Data(freshBytes)),
                                          transfersRoot: root.appendingPathComponent("transfers"))
        await store.beginInstallation(fresh, selectionRevision: 1)
        try await waitForCompletion(store)
        let cleanup = Task { await store.migrationLoadValidated(legacyStillSelected: false) }
        try await Task.sleep(for: .milliseconds(80))
        do {
            _ = try await store.acquire(legacy.id)
            XCTFail("Legacy pack leased while retirement cleanup was suspended")
        } catch let failure as LocalSpeechModelStore.Failure {
            XCTAssertEqual(failure, .busy)
        }
        await cleanup.value
        let record = await store.migrationRecord
        XCTAssertNil(record)
        let actualAt421 = await store.isInstalled(legacy)
        XCTAssertFalse(actualAt421)
    }

    func testFailedLegacyRemovalStaysRetryableAndKeepsOldPackUsable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "local-speech-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = hiddenPack()
        let fresh = visiblePack()
        let modelsRoot = root.appendingPathComponent("models")
        try seedInstalledPack(legacy, root: modelsRoot, bytes: Data(legacyBytes))
        let fault = CleanupFault()
        let store = LocalSpeechModelStore(catalog: LocalSpeechCatalog(schemaVersion: 1, models: [legacy, fresh]),
                                          root: modelsRoot, defaults: defaults,
                                          downloader: DownloadFixture(root: root.appendingPathComponent("transfers"), bytes: Data(freshBytes)),
                                          transfersRoot: root.appendingPathComponent("transfers"),
                                          remover: { url in
                                              if fault.isArmed, url.lastPathComponent.contains(legacy.id), !url.lastPathComponent.hasPrefix(".") {
                                                  throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError)
                                              }
                                              try FileManager.default.removeItem(at: url)
                                          })
        await store.beginInstallation(fresh, selectionRevision: 1)
        try await waitForCompletion(store)
        await store.migrationLoadValidated(legacyStillSelected: false)
        let status = await store.migrationStatus()
        XCTAssertEqual(status.record?.stage, .cleanupPending, "A cleanup failure must not report finished")
        XCTAssertEqual(status.cleanupFailureKey, "voice.local.error.remove")
        let actualAt451 = await store.isInstalled(legacy)
        XCTAssertTrue(actualAt451, "The failed-cleanup pack stays usable while retry is pending")
        // Retry after the fault clears completes and clears the actionable key.
        fault.disarm()
        await store.retryLegacyCleanup()
        let done = await store.migrationStatus()
        XCTAssertNil(done.record)
        XCTAssertNil(done.cleanupFailureKey)
        let actualAt458 = await store.isInstalled(legacy)
        XCTAssertFalse(actualAt458)
    }

    // MARK: - Smoothed speed estimator (definite-bug regression)

    func testSpeedEstimatorHoldsBaselineAcrossFrequentCallbacks() {
        // The original bug reset the baseline on EVERY callback, so 0.1 s
        // intervals (dt < 0.5 s) never reached the sample gate and speed stayed
        // blank. The estimator must hold the baseline until a full 0.5 s window
        // accumulates, then roll it. Synthetic clock values keep this fully
        // deterministic and independent of real downloads.
        var estimator = SpeedEstimator()
        XCTAssertNil(estimator.sample(now: 0.0, bytes: 0), "first sample only seeds the baseline")
        // Sub-window callbacks must hold the baseline and report nothing.
        XCTAssertNil(estimator.sample(now: 0.1, bytes: 10_000_000))
        XCTAssertNil(estimator.sample(now: 0.2, bytes: 20_000_000))
        XCTAssertNil(estimator.sample(now: 0.3, bytes: 30_000_000))
        XCTAssertNil(estimator.sample(now: 0.4, bytes: 40_000_000))
        // The sample that reaches the 0.5 s window yields ~100 MB/s.
        XCTAssertEqual(estimator.sample(now: 0.5, bytes: 50_000_000) ?? 0, 100_000_000, accuracy: 1)
        // Baseline rolled: the next window needs a fresh 0.5 s of elapsed time.
        XCTAssertNil(estimator.sample(now: 0.6, bytes: 58_000_000))
        XCTAssertNil(estimator.sample(now: 0.9, bytes: 90_000_000))
        XCTAssertEqual(estimator.sample(now: 1.0, bytes: 100_000_000) ?? 0, 100_000_000, accuracy: 1)
        // A stalled window (no new bytes) honestly decays the speed.
        XCTAssertNil(estimator.sample(now: 1.2, bytes: 100_000_000))
        XCTAssertEqual(estimator.sample(now: 1.5, bytes: 100_000_000) ?? 0, 60_000_000, accuracy: 1)
        XCTAssertEqual(estimator.currentRate(now: 1.5), 60_000_000, accuracy: 1)
        // A stalled transfer may stop emitting callbacks entirely. Polling
        // the shared snapshot must expire the last rate without inventing data.
        XCTAssertEqual(estimator.currentRate(now: 3.1), 0)
        estimator.reset()
        XCTAssertEqual(estimator.currentRate(now: 3.1), 0)
    }

    func testFrequentCallbackProgressReportsSpeed() async throws {
        // End-to-end counterpart using genuinely frequent (~60 ms) callbacks
        // that each fire well under the 0.5 s window — the case the old code
        // silently dropped.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "local-speech-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = visiblePack()
        let store = LocalSpeechModelStore(catalog: LocalSpeechCatalog(schemaVersion: 1, models: [model]),
                                          root: root.appendingPathComponent("models"), defaults: defaults,
                                          downloader: FrequentCallbackDownloadFixture(root: root.appendingPathComponent("transfers"), bytes: Data(freshBytes)),
                                          transfersRoot: root.appendingPathComponent("transfers"))
        await store.beginInstallation(model)
        var sawSpeed = false
        for _ in 0..<40 {
            let state = await store.state()
            if state.running, state.bytesPerSecond > 0 { sawSpeed = true; break }
            if !state.running { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try await waitForCompletion(store)
        XCTAssertTrue(sawSpeed, "60ms-interval callbacks must still yield a smoothed speed")
        let actualAt511 = await store.state().bytesPerSecond
        XCTAssertEqual(actualAt511, 0, "speed clears once the download phase ends")
    }

    // MARK: - Fixtures

    private let legacyBytes = Data("legacy-qwen-weights".utf8)
    private let freshBytes = Data("fresh-moss-weights".utf8)

    private func fixture(_ bytes: Data) -> LocalSpeechModel {
        let revision = String(repeating: "1", count: 40)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return LocalSpeechModel(id: "test-tts", title: "Synthetic test", engine: "mossTTSNano", repository: "test/model", revision: revision, license: "Apache-2.0", languages: ["zh", "en"], voices: [.init(id: "default", name: "Test", languages: ["zh", "en"])], files: [.init(path: "weights.bin", url: URL(string: "https://huggingface.co/test/model/resolve/\(revision)/weights.bin")!, sha256: hash, byteCount: Int64(bytes.count))], tokenizerRelativePath: nil, minimumMemoryBytes: nil)
    }

    private func hiddenPack() -> LocalSpeechModel {
        let revision = String(repeating: "2", count: 40)
        return LocalSpeechModel(id: "legacy-pack", title: "Legacy", engine: "qwen3TTS", repository: "test/legacy", revision: revision, license: "Apache-2.0", languages: ["zh"], voices: [.init(id: "vivian", name: "Vivian", languages: ["zh"])], files: [.init(path: "weights.bin", url: URL(string: "https://huggingface.co/test/legacy/resolve/\(revision)/weights.bin")!, sha256: hex(Data(legacyBytes)), byteCount: Int64(legacyBytes.count))], tokenizerRelativePath: nil, minimumMemoryBytes: nil, defaultVoiceID: "vivian", visibility: "hidden")
    }

    private func visiblePack() -> LocalSpeechModel {
        let revision = String(repeating: "3", count: 40)
        return LocalSpeechModel(id: "enhanced-pack", title: "Enhanced", engine: "mossTTSNano", repository: "test/enhanced", revision: revision, license: "Apache-2.0", languages: ["zh", "en"], voices: [.init(id: "default", name: "Default", languages: ["zh", "en"])], files: [.init(path: "weights.bin", url: URL(string: "https://huggingface.co/test/enhanced/resolve/\(revision)/weights.bin")!, sha256: hex(Data(freshBytes)), byteCount: Int64(freshBytes.count))], tokenizerRelativePath: nil, minimumMemoryBytes: nil, defaultVoiceID: "default", visibility: "visible")
    }

    private func reference(path: String, source: LocalSpeechModel.Voice.Reference.Source = .bundled,
                           sha256: String = String(repeating: "a", count: 64), byteCount: Int64 = 512,
                           frames: Int = 2, codesPerFrame: Int = 16, codebookSize: Int = 1024) -> LocalSpeechModel.Voice.Reference {
        .init(source: source, path: path, sha256: sha256, byteCount: byteCount, frames: frames, codesPerFrame: codesPerFrame, codebookSize: codebookSize)
    }

    private func voice(id: String, reference: LocalSpeechModel.Voice.Reference?) -> LocalSpeechModel.Voice {
        .init(id: id, name: "Qualified", languages: ["zh"], reference: reference)
    }

    private func patched(_ model: LocalSpeechModel, voices: [LocalSpeechModel.Voice]) -> LocalSpeechModel {
        LocalSpeechModel(id: model.id, title: model.title, engine: model.engine, repository: model.repository, revision: model.revision, license: model.license, languages: model.languages, voices: voices, files: model.files, tokenizerRelativePath: model.tokenizerRelativePath, minimumMemoryBytes: model.minimumMemoryBytes, defaultVoiceID: model.defaultVoiceID, visibility: model.visibility)
    }

    private func referenceJSON(codes: [[Int32]]) -> Data {
        let payload: [String: Any] = [
            "schemaVersion": 1, "engine": "mossTTSNano", "codesPerFrame": 16, "codebookSize": 1024,
            "frames": codes.count, "codes": codes.map { $0.map(Int.init) },
            "provenance": ["generator": "synthetic-test"]
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    private func seedInstalledPack(_ model: LocalSpeechModel, root: URL, bytes: Data) throws {
        let directory = root.appendingPathComponent("tts-\(model.id)-\(model.revision)")
        for asset in model.files {
            let target = directory.appendingPathComponent(asset.path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: target)
        }
        try JSONEncoder().encode(model).write(to: directory.appendingPathComponent("installed.json"))
    }

    private func seedTransferArtifacts(for model: LocalSpeechModel, transfers: URL) throws {
        try FileManager.default.createDirectory(at: transfers, withIntermediateDirectories: true)
        for artifact in legacyArtifacts(model, transfers: transfers) {
            try Data("partial-transfer".utf8).write(to: artifact)
        }
    }

    private func legacyArtifacts(_ model: LocalSpeechModel, transfers: URL) -> [URL] {
        model.files.flatMap { LocalSpeechModelStore.transferArtifacts(for: $0.url, transfersRoot: transfers) }
    }

    private func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func waitForCompletion(_ store: LocalSpeechModelStore) async throws {
        for _ in 0..<500 {
            if !(await store.state().running) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Synthetic installation did not settle")
    }

    private func waitForMigrationCompletion(_ store: LocalSpeechModelStore) async throws {
        for _ in 0..<300 {
            if await store.migrationRecord == nil { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Migration cleanup did not settle")
    }
}

/// Fires cumulative progress on a sub-window (60 ms) cadence, like a real
/// background URLSession writing data in small bursts.
private actor FrequentCallbackDownloadFixture: LocalSpeechDownloading {
    let root: URL
    let bytes: Data
    init(root: URL, bytes: Data) { self.root = root; self.bytes = bytes }
    func download(_ url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("frequent-download")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        let steps = 14
        for step in 1...steps {
            try await Task.sleep(for: .milliseconds(60))
            progress(Int64(bytes.count * step / steps))
        }
        try bytes.write(to: file)
        return file
    }
}

/// A fixture whose `retire` suspends, exposing the actor-reentrancy window.
private actor GatedRetireFixture: LocalSpeechDownloading {
    let root: URL
    let bytes: Data
    init(root: URL, bytes: Data) { self.root = root; self.bytes = bytes }
    func download(_ url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("gated-download")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        try bytes.write(to: file)
        progress(Int64(bytes.count))
        return file
    }
    func retire(_ url: URL) async {
        try? await Task.sleep(for: .milliseconds(220))
    }
}

private final class CleanupFault: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = true
    var isArmed: Bool { lock.withLock { armed } }
    func disarm() { lock.withLock { armed = false } }
}

private actor DownloadFixture: LocalSpeechDownloading {
    let root: URL
    let bytes: Data
    let delays: Bool
    private var corrupt = false
    init(root: URL, bytes: Data, delays: Bool = false) { self.root = root; self.bytes = bytes; self.delays = delays }
    func setCorrupt(_ value: Bool) { corrupt = value }
    func download(_ url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        if delays { try await Task.sleep(for: .seconds(30)) }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("cached-download")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        var result = bytes
        if corrupt { result[0] ^= 1 }
        try result.write(to: file)
        progress(Int64(result.count))
        return file
    }
}

/// Reports cumulative progress on real time intervals so the smoothed speed
/// estimator can only ever observe genuine "network" throughput.
private actor TimedDownloadFixture: LocalSpeechDownloading {
    let root: URL
    let bytes: Data
    init(root: URL, bytes: Data) { self.root = root; self.bytes = bytes }
    func download(_ url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("timed-download")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        for step in 1...4 {
            try await Task.sleep(for: .milliseconds(560))
            progress(Int64(bytes.count * step / 4))
        }
        try bytes.write(to: file)
        return file
    }
}
#endif
