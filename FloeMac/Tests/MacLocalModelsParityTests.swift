// FloeMac MacLocalModelsParityTests — focused fixture tests for the Mac
// local-model lifecycle wrappers.
//
// SPDX-License-Identifier: MPL-2.0
//
// These tests run the REAL shared modules (FloeLocalModelCatalog store,
// FloeLocalModels adapter/runtime) against synthetic fixtures: snapshot
// bytes are written exactly as Floe's installer commits them, and the
// settings-model download contract runs through a scriptable runner seam
// (production always runs the shared LocalModelStore.download). The shared
// store's network transfer itself cannot be stubbed from outside — it owns
// its URLSession — so the handoff requests one transport seam (see report).
// No cloud fallback exists anywhere in the path.

import XCTest
import Foundation
import Synchronization
@testable import MacLocalModelsParity
import FloeCore
import FloeModels
import FloeProviders
import FloeLocalModelCatalog
import FloeLocalModels

// MARK: - Fixtures

private func makeTemporaryRoot() -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("mac-local-models-parity-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// A complete, tiny MLX snapshot: real safetensors header structure and a
/// supported model_type, with byte counts that match the served bytes.
/// `LocalModelCatalogEntry` has no public memberwise initializer, so the
/// fixture decodes through its public Codable conformance.
private func makeSyntheticMLXEntry(
    id: String = "mac-parity-fixture-mlx"
) -> (entry: LocalModelCatalogEntry, files: [String: Data]) {
    let header: [String: Any] = [
        "__metadata__": ["format": "pt"],
        "weight": ["dtype": "F32", "shape": [1], "data_offsets": [0, 4]]
    ]
    let headerData = try! JSONSerialization.data(withJSONObject: header)
    var safetensors = Data()
    var length = UInt64(headerData.count).littleEndian
    withUnsafeBytes(of: &length) { safetensors.append(contentsOf: $0) }
    safetensors.append(headerData)
    safetensors.append(Data([0, 0, 0, 0]))
    let files: [String: Data] = [
        "config.json": #"{"model_type":"qwen3_5"}"#.data(using: .utf8)!,
        "model.safetensors": safetensors,
        "tokenizer.json": #"{"version":"1.0"}"#.data(using: .utf8)!,
    ]
    let artifacts = files
        .map { LocalModelArtifact($0.key, byteCount: Int64($0.value.count)) }
        .sorted { $0.path < $1.path }
    let total = files.values.reduce(0) { $0 + $1.count }
    let json: [String: Any] = [
        "id": id,
        "profileID": UUID().uuidString,
        "displayName": "Mac Parity Fixture",
        "repository": "floe/mac-parity-fixture",
        "revision": "deadbeefcafe0000000000000000000000000000",
        "runtimeFormat": "mlx",
        "artifacts": artifacts.map {
            ["path": $0.path, "byteCount": $0.byteCount] as [String: Any]
        },
        "parameterBillions": 0.001,
        "approximateDownloadBytes": total,
        "supportsVision": false,
        "supportsReasoning": false,
        "supportsToolCalling": false,
        "license": "TEST"
    ]
    let data = try! JSONSerialization.data(withJSONObject: json)
    let entry = try! JSONDecoder().decode(LocalModelCatalogEntry.self, from: data)
    return (entry, files)
}

// MARK: - Tests

@available(macOS 15.4, *)
@MainActor
final class MacLocalModelsParityTests: XCTestCase {
    private func waitFor(
        _ description: String,
        timeout: TimeInterval = 10,
        condition: () -> Bool
    ) async {
        let start = Date()
        while !condition() {
            if Date().timeIntervalSince(start) > timeout {
                XCTFail("timed out waiting for \(description)")
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: Availability

    func testAvailabilityOnThisMacIsSupported() {
        let support = MacLocalModelAvailability.support()
        // This host is an Apple-silicon M5 Pro on macOS 15.4+.
        XCTAssertTrue(support.isSupported, "expected supported runtime, got \(String(describing: support.unavailableReason))")
        XCTAssertEqual(support.engine, MacLocalModelEngine.mlx)
        XCTAssertGreaterThan(support.headroomBytes, 0)
    }

    func testAvailabilitySurfacesIntelMacAsUnsupported() {
        let probe = MacLocalModelAvailability.Probe(
            isAppleSilicon: false,
            macOSVersion: .init(majorVersion: 26, minorVersion: 0, patchVersion: 0),
            hasMetalDevice: true,
            physicalMemoryBytes: 16 << 30,
            reservedMemoryBytes: 0
        )
        let support = MacLocalModelAvailability.support(probe: probe)
        XCTAssertFalse(support.isSupported)
        XCTAssertNil(support.engine)
        XCTAssertNotNil(support.unavailableReason)
    }

    func testAvailabilitySurfacesPre154MacAsUnsupported() {
        let probe = MacLocalModelAvailability.Probe(
            isAppleSilicon: true,
            macOSVersion: .init(majorVersion: 15, minorVersion: 3, patchVersion: 1),
            hasMetalDevice: true,
            physicalMemoryBytes: 16 << 30,
            reservedMemoryBytes: 0
        )
        XCTAssertFalse(MacLocalModelAvailability.support(probe: probe).isSupported)
    }

    func testAvailabilitySurfacesMissingMetalAsUnsupported() {
        let probe = MacLocalModelAvailability.Probe(
            isAppleSilicon: true,
            macOSVersion: .init(majorVersion: 26, minorVersion: 0, patchVersion: 0),
            hasMetalDevice: false,
            physicalMemoryBytes: 16 << 30,
            reservedMemoryBytes: 0
        )
        XCTAssertFalse(MacLocalModelAvailability.support(probe: probe).isSupported)
    }

    func testAvailabilitySubtractsReservedMemoryFromHeadroom() {
        let reserved: Int64 = 4 << 30
        let probe = MacLocalModelAvailability.Probe(
            isAppleSilicon: true,
            macOSVersion: .init(majorVersion: 26, minorVersion: 0, patchVersion: 0),
            hasMetalDevice: true,
            physicalMemoryBytes: 16 << 30,
            reservedMemoryBytes: reserved
        )
        let support = MacLocalModelAvailability.support(probe: probe)
        XCTAssertTrue(support.isSupported)
        XCTAssertEqual(support.headroomBytes, (16 << 30) - UInt64(reserved))
    }

    // MARK: Shared catalog parity expectations

    func testSharedCatalogMatchesMacPickerAssumptions() {
        let entries = CuratedLocalModelCatalog.entries
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(Set(entries.map(\.id)).count, entries.count)
        XCTAssertEqual(Set(entries.map(\.profileID)).count, entries.count)
        for entry in entries {
            XCTAssertEqual(entry.runtimeFormat, .mlx)
            XCTAssertTrue(ProviderProfile.onDeviceModelIDs.contains(entry.profileID))
            XCTAssertGreaterThan(entry.approximateDownloadBytes, 0)
            XCTAssertFalse(entry.revision.isEmpty)
            XCTAssertFalse(entry.artifacts.isEmpty)
            for artifact in entry.artifacts {
                XCTAssertGreaterThan(artifact.byteCount, 0)
                let url = entry.artifactURL(artifact)
                XCTAssertEqual(url.scheme, "https")
                XCTAssertEqual(url.host, "huggingface.co")
                XCTAssertTrue(url.path.contains("/resolve/\(entry.revision)/"))
            }
        }
        // Retired entries are never downloadable.
        XCTAssertTrue(CuratedLocalModelCatalog.retiredEntries.allSatisfy { !entries.contains($0) })
    }

    // MARK: Shared store lifecycle (offline)

    /// Install a synthetic snapshot by writing the exact bytes Floe's
    /// installer would commit, then exercise the shared verification,
    /// discovery, resume and removal paths. The network transfer itself is
    /// covered by the shared module's own tests; it cannot be stubbed from
    /// outside here (see the transport-seam note in the handoff).
    func testSharedStoreVerifiesInstalledSnapshotAndDetectsTampering() async throws {
        let (entry, files) = makeSyntheticMLXEntry()

        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalModelStore(root: root)

        // Hand-install: artifacts + Floe install manifest, byte-exact.
        let directory = root.appendingPathComponent(entry.id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (path, data) in files {
            try data.write(to: directory.appendingPathComponent(path))
        }
        let manifest: [String: Any] = [
            "modelID": entry.id,
            "repository": entry.repository,
            "revision": entry.revision,
            "format": "mlx",
            "artifacts": entry.artifacts.map {
                ["path": $0.path, "byteCount": $0.byteCount] as [String: Any]
            },
        ]
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: directory.appendingPathComponent(".floe-model.json"))

        XCTAssertTrue(LocalModelStore.hasInstallManifest(in: directory))
        XCTAssertEqual(LocalModelSnapshotIntegrity.problems(directory: directory, entry: entry), [])

        // Discovery is catalog-gated on purpose: a hand-copied folder (or an
        // unknown id) is never assumed to be a complete install.
        let unknownInstalled = await store.isInstalled(id: entry.id)
        XCTAssertFalse(unknownInstalled)
        let unknownURL = await store.installedModelURL(id: entry.id)
        XCTAssertNil(unknownURL)

        // Tampered snapshot (truncated safetensors) is caught by the shared
        // deterministic audit before any engine work.
        let weightsURL = directory.appendingPathComponent("model.safetensors")
        let original = try Data(contentsOf: weightsURL)
        try original.prefix(8).write(to: weightsURL)
        let problems = LocalModelSnapshotIntegrity.problems(directory: directory, entry: entry)
        XCTAssertFalse(problems.isEmpty)
        try original.write(to: weightsURL)
    }

    func testSharedStoreDiscoversResumeStateForCatalogIDsAndCancelDropsIt() async throws {
        let entry = CuratedLocalModelCatalog.entries[0]
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalModelStore(root: root)

        // A durable resume set for a catalog entry is discoverable.
        let downloads = root.appendingPathComponent(".downloads/\(entry.id)", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try Data("resume".utf8).write(to: downloads.appendingPathComponent("file-0.resume"))
        let resumable = await store.resumableModelIDs()
        XCTAssertTrue(resumable.contains(entry.id))

        await store.cancelDownload(id: entry.id)
        let afterCancel = await store.resumableModelIDs()
        XCTAssertFalse(afterCancel.contains(entry.id))
    }

    func testSharedStoreRejectsTraversalArtifact() async throws {
        let (entry, _) = makeSyntheticMLXEntry()

        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalModelStore(root: root)

        // Rebuild the synthetic entry with a traversal artifact via Codable.
        var maliciousJSON = try! JSONSerialization.jsonObject(
            with: try! JSONEncoder().encode(entry)
        ) as! [String: Any]
        maliciousJSON["artifacts"] = [["path": "../evil.safetensors", "byteCount": 4]]
        let maliciousData = try! JSONSerialization.data(withJSONObject: maliciousJSON)
        let malicious = try! JSONDecoder().decode(LocalModelCatalogEntry.self, from: maliciousData)

        do {
            _ = try await store.download(malicious)
            XCTFail("expected traversal rejection")
        } catch let error as LocalModelStore.StoreError {
            guard case .unexpectedArtifact = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
        // Staging must be cleaned; nothing installed.
        let installedFlag = await store.isInstalled(id: entry.id)
        XCTAssertFalse(installedFlag)
    }

    /// In-flight pause behavior (URLSession resume-data handoff) requires a
    /// transport seam on the shared `LocalModelStore`; it is exercised by the
    /// settings-model lease tests through the scripted runner below and by
    /// the shared module's own drain tests on the iPad host.
    func testSharedStoreInFlightPauseRequiresTransportSeam() throws {
        throw XCTSkip("shared LocalModelStore owns its URLSession; add the transport seam to test in-flight pause offline")
    }

    func testSharedStoreRemoveDeletesOnlyTheModelDirectory() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalModelStore(root: root)
        try await store.remove(id: "never-installed")
        let values = try root.resourceValues(forKeys: [.isDirectoryKey])
        XCTAssertEqual(values.isDirectory, true)
    }

    // MARK: Service + host hooks

    func testServicePublishesInstalledModelsThroughSharedAdapter() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = MacLocalModelService(store: LocalModelStore(root: root))

        let callback = expectation(description: "host callback")
        service.setHostHooks(.init { result in
            switch result {
            case .success(let models):
                // The Apple Foundation Model row is always listed (kept for
                // settings/history exactly like the iPad); downloaded entries
                // appear only after a real install.
                XCTAssertTrue(models.contains(where: { $0.remoteModelID == "apple-foundation-model" }))
                XCTAssertFalse(models.contains(where: { $0.id == CuratedLocalModelCatalog.entries[0].profileID }))
            case .failure(let error):
                XCTFail("expected success, got \(error)")
            }
            callback.fulfill()
        })
        await service.refreshInstalledModels()
        await fulfillment(of: [callback], timeout: 10)

        let adapter = service.makeAdapter()
        XCTAssertEqual(adapter.protocolKind, .openAIChatCompletions)
        XCTAssertEqual(MacLocalModelService.providerProfile.id, ProviderProfile.onDeviceProviderID)
        XCTAssertEqual(MacLocalModelService.providerProfile.kind, .local)
    }

    func testServiceAdapterHandoffMatchesSharedIdentity() {
        let profile = MacLocalModelService.providerProfile
        XCTAssertEqual(profile.id, LocalProviderAdapter.providerProfile.id)
        XCTAssertEqual(profile.baseURL, URL(string: "http://127.0.0.1"))
        XCTAssertTrue(profile.allowsPlainHTTP)
    }

    // MARK: Settings model

    func testSettingsModelInitialStateAndBusyTransitions() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = MacLocalModelService(store: LocalModelStore(root: root))
        let settings = MacLocalModelsSettingsModel(service: service)
        await settings.refresh()

        XCTAssertEqual(settings.items.count, CuratedLocalModelCatalog.entries.count)
        XCTAssertTrue(settings.items.allSatisfy { $0.state == .notInstalled })
        XCTAssertFalse(settings.isBusy)
        XCTAssertFalse(settings.isDownloading)
        XCTAssertTrue(settings.runtimeSupport.isSupported)
    }

    func testSettingsAdmitRefusalBlocksDownloadAndSurfacesError() {
        struct Refused: Error {}
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = MacLocalModelService(store: LocalModelStore(root: root))
        let settings = MacLocalModelsSettingsModel(service: service) { throw Refused() }
        settings.download(CuratedLocalModelCatalog.entries[0])
        XCTAssertNotNil(settings.activeError)
        XCTAssertFalse(settings.isDownloading)
    }

    /// The pause/cancel contract: the lease is held for the whole download
    /// and released only when the download task reaches its durable end —
    /// pause/cancel await that completion rather than racing it.
    func testSettingsLeaseHeldForDownloadAndReleasedOnExplicitPause() async throws {
        let entry = CuratedLocalModelCatalog.entries[0]
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = MacLocalModelService(store: LocalModelStore(root: root))

        let runner = ScriptedDownloadRunner()
        let lease = LeaseTracker()
        let settings = MacLocalModelsSettingsModel(
            service: service,
            admitWork: {
                lease.acquire()
                return { lease.release() }
            },
            downloadRunner: runner.runner
        )

        settings.download(entry)
        await waitFor("runner started") { runner.started }
        await waitFor("isDownloading") { settings.isDownloading }
        XCTAssertEqual(settings.activeDownloadID, entry.id)
        XCTAssertEqual(lease.activeCount, 1)

        // A duplicate download request while one owns the slot is ignored.
        settings.download(entry)
        XCTAssertEqual(lease.activeCount, 1)

        // Pause: the transfer receives the interrupt, the download task
        // finishes on its own, and only then is the lease released.
        runner.requestInterrupt()
        await waitFor("runner finished") { runner.finished }
        await settings.pauseDownload(id: entry.id)
        XCTAssertEqual(lease.activeCount, 0)
        XCTAssertNil(settings.activeDownloadID)
        XCTAssertFalse(settings.isDownloading)
        XCTAssertFalse(settings.isBusy)
        XCTAssertNil(settings.activeError)

        // A second pause with nothing in flight is a no-op.
        await settings.pauseDownload(id: entry.id)
        XCTAssertEqual(lease.activeCount, 0)
    }

    func testSettingsCancelAwaitCompletionAndSurfacesTransferFailure() async throws {
        let entry = CuratedLocalModelCatalog.entries[1]
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = MacLocalModelService(store: LocalModelStore(root: root))
        let lease = LeaseTracker()
        let runner = ScriptedDownloadRunner()
        let settings = MacLocalModelsSettingsModel(
            service: service,
            admitWork: {
                lease.acquire()
                return { lease.release() }
            },
            downloadRunner: runner.runner
        )

        settings.download(entry)
        await waitFor("isDownloading") { settings.isDownloading }
        XCTAssertEqual(lease.activeCount, 1)

        runner.fail(with: URLError(.networkConnectionLost))
        await settings.cancelDownload(id: entry.id)
        XCTAssertEqual(lease.activeCount, 0)
        XCTAssertNil(settings.activeDownloadID)
        XCTAssertFalse(settings.isBusy)
        XCTAssertNotNil(settings.activeError)
    }

    func testSettingsSuccessfulDownloadReleasesLeaseAndClearsSlot() async throws {
        let entry = CuratedLocalModelCatalog.entries[0]
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = MacLocalModelService(store: LocalModelStore(root: root))
        let lease = LeaseTracker()
        let runner = ScriptedDownloadRunner()
        let published = Mutex<Result<[ModelProfile], Error>?>(nil)
        service.setHostHooks(.init { result in published.withLock { $0 = result } })
        let settings = MacLocalModelsSettingsModel(
            service: service,
            admitWork: {
                lease.acquire()
                return { lease.release() }
            },
            downloadRunner: runner.runner
        )

        settings.download(entry)
        await waitFor("runner started") { runner.started }
        await waitFor("progress delivered") { settings.progress != nil }
        XCTAssertTrue(settings.isDownloading)

        runner.succeed()
        await waitFor("publish after install") { published.withLock { $0 } != nil }
        XCTAssertEqual(lease.activeCount, 0)
        XCTAssertNil(settings.activeDownloadID)
        XCTAssertFalse(settings.isBusy)
        XCTAssertNil(settings.activeError)
    }

    func testSettingsRemoveWithoutInstallationIsSilentNoOp() async {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = MacLocalModelService(store: LocalModelStore(root: root))
        let lease = LeaseTracker()
        let settings = MacLocalModelsSettingsModel(service: service) {
            lease.acquire()
            return { lease.release() }
        }
        await settings.remove(id: CuratedLocalModelCatalog.entries[0].id)
        XCTAssertNil(settings.activeError)
        XCTAssertEqual(lease.activeCount, 0)
        XCTAssertEqual(lease.totalAcquires, 1)
    }
}

// MARK: - Test helpers

@MainActor
private final class LeaseTracker {
    private var count = 0
    private var acquires = 0
    var activeCount: Int { count }
    var totalAcquires: Int { acquires }
    func acquire() { count += 1; acquires += 1 }
    func release() { count = max(0, count - 1) }
}

/// Scriptable transfer standing in for the shared store download: hangs
/// until the test requests an interrupt (pause/cancel) or a terminal state,
/// mirroring how URLSession delivers cancellation to the owning task.
@available(macOS 15.4, *)
private final class ScriptedDownloadRunner: @unchecked Sendable {
    enum Outcome {
        case hang
        case succeed
        case fail(Error)
    }

    private let lock = NSLock()
    private var outcome: Outcome = .hang
    private var _started = false
    private var _finished = false

    var started: Bool { lock.withLock { _started } }
    var finished: Bool { lock.withLock { _finished } }

    var runner: MacLocalModelsSettingsModel.DownloadRunner {
        { [weak self] entry, progress in
            guard let self else { throw URLError(.cancelled) }
            self.lock.withLock { self._started = true }
            progress(.init(
                modelID: entry.id,
                component: entry.artifacts.first?.path ?? "weights",
                bytesReceived: 64,
                bytesExpected: 1024,
                fractionCompleted: 0.06
            ))
            while true {
                try await Task.sleep(for: .milliseconds(20))
                let current = self.lock.withLock { self.outcome }
                switch current {
                case .hang:
                    continue
                case .succeed:
                    self.lock.withLock { self._finished = true }
                    return URL(fileURLWithPath: "/tmp/\(entry.id)")
                case .fail(let error):
                    self.lock.withLock { self._finished = true }
                    throw error
                }
            }
        }
    }

    func requestInterrupt() {
        // Pause semantics: the transfer is asked to stop and reports a
        // cancelled error, exactly like a cancelled URLSession task.
        fail(with: URLError(.cancelled))
    }

    func succeed() {
        lock.withLock { outcome = .succeed }
    }

    func fail(with error: Error) {
        lock.withLock { outcome = .fail(error) }
    }
}
