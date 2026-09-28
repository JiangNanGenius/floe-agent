// FloeExecutionTests — Build 233 Linux image recovery regression.
//
// Covers the production image verification/recovery path (not hand-built
// proxies):
//   * hash open/read failures are typed (stage + POSIX errno) and never
//     mistaken for content/digest failures,
//   * an installed image whose artifact cannot be read derives
//     `.imageRepairRequired`, and re-verification clears it after the file
//     is readable again WITHOUT any download,
//   * a genuine digest mismatch stays a non-transient content failure,
//   * the Runtime v2 composite resolver serves the expanded verified image
//     after the legacy directory has moved away (path/migration coherence).

import Foundation
import XCTest
import Darwin
import ZIPFoundation
import FloeCore
@testable import FloeCore
import FloeTools
@testable import FloeExecution

final class LinuxGuestImageRecoveryTests: XCTestCase {
    private var workRoot: URL!

    override func setUpWithError() throws {
        workRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        LinuxGuestImageDistributionCatalog.clearTestEntries()
        try? FileManager.default.removeItem(at: workRoot)
    }

    // MARK: - Typed hash failures

    func testTypedOpenFailureOnMissingFile() throws {
        let missing = workRoot.appendingPathComponent("absent.img")
        XCTAssertThrowsError(try FloeDigest.sha512Hex(ofFileAt: missing)) { error in
            guard let io = error as? FloeFileIOError else {
                return XCTFail("expected FloeFileIOError, got \(error)")
            }
            XCTAssertEqual(io.stage, .open)
            XCTAssertEqual(io.posixErrno, ENOENT)
            XCTAssertFalse(io.isTransientAccessFailure,
                           "ENOENT is a missing path, not a retryable transient condition")
        }
    }

    func testTransientAccessFailureClassification() {
        let again = FloeFileIOError(stage: .read, posixErrno: EAGAIN, detail: "temporarily unavailable")
        XCTAssertTrue(again.isTransientAccessFailure)
        let busy = FloeFileIOError(stage: .read, posixErrno: EBUSY, detail: "busy")
        XCTAssertTrue(busy.isTransientAccessFailure)
        let denied = FloeFileIOError(stage: .open, posixErrno: EACCES, detail: "permission denied")
        XCTAssertFalse(denied.isTransientAccessFailure,
                       "a permanent permission denial must not be classified transient")
        let unknown = FloeFileIOError(stage: .read, posixErrno: 0, detail: "unknown")
        XCTAssertFalse(unknown.isTransientAccessFailure, "errno 0 never defaults to transient")
    }

    func testIOFailureMessageCarriesStageAndErrno() {
        let issue = LinuxImageVerificationIssue.ioFailure(
            role: "disk",
            error: FloeFileIOError(stage: .open, posixErrno: EACCES, detail: "未能打开该文件")
        )
        let message = issue.message
        XCTAssertTrue(message.contains("cannot hash disk"))
        XCTAssertTrue(message.contains("stage=open"))
        XCTAssertTrue(message.contains("errno=\(EACCES)"))
        XCTAssertTrue(message.contains("未能打开该文件"))
        // A path is never embedded in a digest error message.
        XCTAssertFalse(message.contains(workRoot.path))
    }

    // MARK: - Installed-image recovery

    func testInstalledImageMissingArtifactDerivesImageRepairRequired() async throws {
        let serviceRoot = workRoot.appendingPathComponent("store", isDirectory: true)
        let service = LinuxGuestImageInstallationService(root: serviceRoot, limits: .standard)
        let imageID = "floe-recovery-test-1"
        let imageDir = try makeInstalledImage(id: imageID, service: service)

        // Simulate the device condition: artifact unopenable at verification.
        let diskURL = imageDir.appendingPathComponent("disk.img")
        let movedAside = workRoot.appendingPathComponent("disk.img.aside")
        try FileManager.default.moveItem(at: diskURL, to: movedAside)

        let status = await service.status(id: imageID)
        XCTAssertTrue(status.installed)
        XCTAssertEqual(status.verificationIssue, .artifactMissing(role: "disk"))

        var facts = LinuxGuestInstallFacts()
        facts.storageAvailable = true
        facts.imageInstalled = true
        facts.imageVerificationIssue = status.verificationIssue
        guard case .imageRepairRequired(let transient, _) =
            LinuxGuestInstallStateDerivation.state(from: facts) else {
            return XCTFail("expected imageRepairRequired")
        }
        XCTAssertFalse(transient, "a missing artifact is not a known transient I/O condition")
    }

    func testReverifyClearsAfterArtifactRestoredWithoutDownload() async throws {
        let serviceRoot = workRoot.appendingPathComponent("store", isDirectory: true)
        let service = LinuxGuestImageInstallationService(root: serviceRoot, limits: .standard)
        let imageID = "floe-recovery-test-2"
        let imageDir = try makeInstalledImage(id: imageID, service: service)

        let diskURL = imageDir.appendingPathComponent("disk.img")
        let movedAside = workRoot.appendingPathComponent("disk-2.img.aside")
        try FileManager.default.moveItem(at: diskURL, to: movedAside)
        let failing = await service.status(id: imageID)
        XCTAssertNotNil(failing.verificationIssue)

        // Restore the file: re-verification clears with zero bytes downloaded.
        try FileManager.default.moveItem(at: movedAside, to: diskURL)
        let restored = await service.reverify(id: imageID)
        XCTAssertTrue(restored.installed)
        XCTAssertNil(restored.verificationIssue)

        var facts = LinuxGuestInstallFacts()
        facts.storageAvailable = true
        facts.imageInstalled = true
        XCTAssertEqual(LinuxGuestInstallStateDerivation.state(from: facts),
                       .installedStopped(environmentID: nil))
    }

    func testDigestMismatchDerivesNonTransientRepair() async throws {
        let serviceRoot = workRoot.appendingPathComponent("store", isDirectory: true)
        let service = LinuxGuestImageInstallationService(root: serviceRoot, limits: .standard)
        let imageID = "floe-recovery-test-3"
        let imageDir = try makeInstalledImage(id: imageID, service: service)

        // Tamper with the bytes after the manifest recorded their digest.
        let diskURL = imageDir.appendingPathComponent("disk.img")
        let handle = try FileHandle(forUpdating: diskURL)
        try handle.seek(toOffset: 4096)
        try handle.write(contentsOf: Data(repeating: 0xCD, count: 4096))
        try handle.close()

        let status = await service.status(id: imageID)
        XCTAssertEqual(status.verificationIssue, .digestMismatch(role: "disk"))
        XCTAssertFalse(status.verificationIssue?.isIOFailure ?? true,
                       "a digest mismatch is content truth, never an I/O failure")

        var facts = LinuxGuestInstallFacts()
        facts.storageAvailable = true
        facts.imageInstalled = true
        facts.imageVerificationIssue = status.verificationIssue
        guard case .imageRepairRequired(let transient, _) =
            LinuxGuestInstallStateDerivation.state(from: facts) else {
            return XCTFail("expected imageRepairRequired")
        }
        XCTAssertFalse(transient)
    }

    // MARK: - Migration / composite resolver coherence

    func testCompositeResolverUsesExpandedAfterLegacyMovedAway() async throws {
        let imageID = "floe-recovery-test-4"
        let legacyRoot = workRoot.appendingPathComponent("legacy-images", isDirectory: true)
        let expandedRoot = workRoot.appendingPathComponent("expanded-images", isDirectory: true)

        let legacyService = LinuxGuestImageInstallationService(root: workRoot, limits: .standard)
        let legacyImageDir = legacyService.imagesDirectory
        let legacyData = try makeInstalledImage(id: imageID, in: legacyImageDir)

        // The same verified content at the expanded root (post-migration shape).
        let legacyImageContents = legacyImageDir.appendingPathComponent(imageID, isDirectory: true)
        let expandedImageDir = expandedRoot.appendingPathComponent(imageID, isDirectory: true)
        try FileManager.default.createDirectory(at: expandedImageDir, withIntermediateDirectories: true)
        try copyDirectoryContents(from: legacyImageContents, to: expandedImageDir)

        let gate = VerifiedGate()
        let resolver = RuntimeV2CompositeImageResolver(
            expandedImagesRoot: expandedRoot,
            legacy: FileLinuxGuestImageResolver(root: legacyRoot),
            verifiedGate: { _ in await gate.value }
        )

        // Legacy directory moves aside exactly like a completed migration.
        let movedLegacy = workRoot.appendingPathComponent("legacy-images-aside", isDirectory: true)
        try FileManager.default.createDirectory(at: movedLegacy, withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: legacyImageDir.appendingPathComponent(imageID, isDirectory: true),
            to: movedLegacy.appendingPathComponent(imageID, isDirectory: true)
        )

        // The composite resolver must serve the expanded image and verify it,
        // instead of hashing the now-missing legacy path.
        let failure = await resolver.linuxGuestImageVerificationFailure(id: imageID)
        XCTAssertNil(failure, "post-migration verification must use the expanded path")
        let image = await resolver.linuxGuestImage(id: imageID)
        XCTAssertEqual(image?.id, imageID)

        // If the gate says not verified, the resolver must not invent truth.
        await gate.set(false)
        let unresolved = await resolver.linuxGuestImage(id: imageID)
        XCTAssertNil(unresolved, "an unverified image cannot be served from expanded storage")
    }

    // MARK: - Two-phase reconnect barrier

    /// Builds a qualified image with a distinct content id so a test can tell
    /// which resolver the registry used. The lookup key stays the
    /// environment's descriptor image id ("env-image"): a reconnect never
    /// changes an environment's descriptor.
    private func qualifiedImage(contentID: String) -> LinuxGuestImage {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-b233-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bios = directory.appendingPathComponent("bbl64.bin")
        let contents = Data("bios-\(contentID)".utf8)
        FileManager.default.createFile(atPath: bios.path, contents: contents)
        return LinuxGuestImage(
            id: contentID,
            biosPath: bios.path,
            qualified: true,
            qualificationEvidence: "b233 reconnect check \(UUID().uuidString)",
            qualificationRun: "run-b233-reconnect",
            artifacts: [
                LinuxGuestImageArtifact(
                    role: .bios, path: bios.path,
                    sha512: FloeDigest.sha512Hex(contents),
                    bytes: Int64(contents.count)
                )
            ]
        )
    }

    @discardableResult
    private func makeBarrierRegistry(
        resolver: FakeImageResolver
    ) -> (TinyEMULinuxGuestRegistry, FakeSessionLedger) {
        let ledger = FakeSessionLedger()
        let registry = TinyEMULinuxGuestRegistry(
            environments: FakeEnvironmentProvider(descriptors: [
                "env-1": LinuxGuestEnvironmentDescriptor(id: "env-1", ownerID: "owner", imageID: "env-image")
            ]),
            images: resolver,
            limits: .standard,
            factory: FakeSessionFactory(ledger: ledger, handler: { _, _ in [] }),
            runtimeV2: nil
        )
        return (registry, ledger)
    }

    private func resolver(returning contentID: String) -> FakeImageResolver {
        FakeImageResolver(images: ["env-image": qualifiedImage(contentID: contentID)])
    }

    func testBeginReconnectSwapsResolverAndHoldsBarrier() async throws {
        let (registry, ledger) = makeBarrierRegistry(resolver: resolver(returning: "old-content"))
        let service = TinyEMULinuxCommandService(registry: registry)
        let began = await service.beginLinuxBackendReconnect(
            images: resolver(returning: "new-content"), runtimeV2: nil
        )
        XCTAssertTrue(began)
        // While the barrier is held every guest start is refused guestBusy.
        do {
            _ = try await service.startGuest(environmentID: "env-1", taskID: nil)
            XCTFail("a start must be refused while the reconnect barrier is held")
        } catch let error as LinuxGuestError {
            guard case .guestBusy = error else { throw error }
        }
        // Commit admits starts again, now through the new resolver.
        await service.commitLinuxBackendReconnect()
        let didStart = try await service.startGuest(environmentID: "env-1", taskID: nil)
        XCTAssertTrue(didStart)
        XCTAssertEqual(ledger.image(for: "env-1")?.id, "new-content")
    }

    func testAbortReconnectRestoresOldResolver() async throws {
        let (registry, ledger) = makeBarrierRegistry(resolver: resolver(returning: "old-content"))
        let service = TinyEMULinuxCommandService(registry: registry)
        let began = await service.beginLinuxBackendReconnect(
            images: resolver(returning: "new-content"), runtimeV2: nil
        )
        XCTAssertTrue(began)
        await service.abortLinuxBackendReconnect()

        // A start after abort must boot via the OLD resolver.
        let didStart = try await service.startGuest(environmentID: "env-1", taskID: nil)
        XCTAssertTrue(didStart)
        XCTAssertEqual(ledger.image(for: "env-1")?.id, "old-content",
                       "abort must restore the old resolver before starts resume")
    }

    func testReconnectRefusedWhileGuestActiveLeavesResolverUnchanged() async throws {
        let (registry, ledger) = makeBarrierRegistry(resolver: resolver(returning: "old-content"))
        let service = TinyEMULinuxCommandService(registry: registry)
        // Boot the old resolver first.
        let didStart = try await service.startGuest(environmentID: "env-1", taskID: nil)
        XCTAssertTrue(didStart)

        // A second resolver must be refused while the guest is active.
        let began = await service.beginLinuxBackendReconnect(
            images: resolver(returning: "new-content"), runtimeV2: nil
        )
        XCTAssertFalse(began, "a reconnect must be refused while a guest is active")
        // The resolver stays the old one and starts keep working normally.
        let secondStart = try await service.startGuest(environmentID: "env-1", taskID: nil)
        XCTAssertTrue(secondStart)
        XCTAssertEqual(ledger.image(for: "env-1")?.id, "old-content")
    }

    // MARK: - Queued-admission interleaving

    func testBeginReconnectRefusedWhenQueuedAdmissionAppears() async throws {
        // A v2 substrate reporting one queued admission. begin installs its
        // barrier, sees the queue, aborts (old resolver restored) and fails.
        let queueRoot = workRoot.appendingPathComponent("queue-fixed", isDirectory: true)
        try FileManager.default.createDirectory(at: queueRoot, withIntermediateDirectories: true)
        let queuedV2 = QueuedRuntimeV2Recorder(root: queueRoot, parks: false, fixedQueued: 1)
        let pair = try makeQueuedRegistry(recorder: queuedV2, queueRoot: queueRoot, oldContent: "old-content")
        let registry = pair.0; let ledger = pair.1
        let service = TinyEMULinuxCommandService(registry: registry)
        // Reconnect supplies a NEW resolver (its image also lives in a known
        // expanded dir; reuse queueRoot for the new image too).
        let newImage = try relativeQualifiedImage(contentID: "new-content", in: queueRoot)
        let began = await service.beginLinuxBackendReconnect(
            images: FakeImageResolver(images: ["env-image": newImage]), runtimeV2: queuedV2
        )
        XCTAssertFalse(began, "a queued admission must refuse the reconnect")

        // The old resolver was restored by the abort: a start boots it.
        let didStart = try await service.startGuest(environmentID: "env-1", taskID: nil)
        XCTAssertTrue(didStart)
        XCTAssertEqual(ledger.image(for: "env-1")?.id, "old-content")
    }

    func testNoStartInterleavesWhileQueuedCheckSuspends() async throws {
        // Park queuedStarts at a continuation: while suspended the barrier
        // must already hold, so a concurrent start is refused guestBusy
        // instead of sneaking in via actor reentrancy.
        let queueRoot = workRoot.appendingPathComponent("queue-parked", isDirectory: true)
        try FileManager.default.createDirectory(at: queueRoot, withIntermediateDirectories: true)
        let parkedV2 = QueuedRuntimeV2Recorder(root: queueRoot, parks: true, fixedQueued: 0)
        let pair = try makeQueuedRegistry(recorder: parkedV2, queueRoot: queueRoot, oldContent: "old-content")
        let registry = pair.0
        let service = TinyEMULinuxCommandService(registry: registry)
        let newImage = try relativeQualifiedImage(contentID: "new-content", in: queueRoot)

        let beginTask = Task {
            await service.beginLinuxBackendReconnect(
                images: FakeImageResolver(images: ["env-image": newImage]), runtimeV2: parkedV2
            )
        }
        await parkedV2.waitUntilProbed()

        // During the suspended queued check a concurrent start must be refused.
        do {
            _ = try await service.startGuest(environmentID: "env-1", taskID: nil)
            XCTFail("a start must be refused while the queued-check barrier is held")
        } catch let error as LinuxGuestError {
            guard case .guestBusy = error else { throw error }
        }

        // Empty queue: begin completes successfully.
        await parkedV2.resume(queued: 0)
        let began = await beginTask.value
        XCTAssertTrue(began)
        await service.abortLinuxBackendReconnect()
    }

    /// The card's owner continuation fires exactly once for a real success
    /// transition of THIS image's job, never for unrelated revisions,
    /// cancellation or failure.
    func testCompletionGateReportsOnlyGenuineVerifiedTransitions() {
        var gate = LinuxGuestInstallCompletionGate()
        // An unrelated job revision (this image's job never ran): no signal.
        XCTAssertFalse(gate.observe(running: false, failed: false, verified: true))
        // Started, then finished unverified or failed: no signal.
        XCTAssertFalse(gate.observe(running: true, failed: false, verified: false))
        XCTAssertFalse(gate.observe(running: false, failed: false, verified: false))
        XCTAssertFalse(gate.observe(running: true, failed: false, verified: false))
        XCTAssertFalse(gate.observe(running: false, failed: true, verified: false))
        // Started again, finished verified: exactly one signal.
        XCTAssertFalse(gate.observe(running: true, failed: false, verified: false))
        XCTAssertTrue(gate.observe(running: false, failed: false, verified: true))
        XCTAssertFalse(gate.observe(running: false, failed: false, verified: true))
        // A later unrelated revision cannot re-fire it.
        XCTAssertFalse(gate.observe(running: false, failed: false, verified: true))
    }

    // MARK: - Trusted-install cancellation + coalescing

    /// Owner cancellation (the shared-job token) is observed after the
    /// download and before import/promotion: the install reports `.cancelled`
    /// and nothing is promoted; staging is removed.
    func testOwnerCancellationStopsTrustedInstallWithoutPromotion() async throws {
        let id = "floe-cancel-fixture-1"
        let archiveURL = try makePinnedZipFixture(id: id)
        let root = workRoot.appendingPathComponent("cancel-store-1", isDirectory: true)
        let imagesRoot = root.appendingPathComponent("LinuxGuest/images", isDirectory: true)
        let service = LinuxGuestImageInstallationService(root: root)
        let gate = GatedArchiveDownloader(archive: archiveURL)
        let token = CancellationToken()
        let install = Task {
            try await service.installTrustedImage(id: id, downloader: gate, isCancelled: { token.isCancelled })
        }
        await gate.waitUntilStarted()
        token.cancel()
        await gate.release()
        do {
            _ = try await install.value
            XCTFail("a cancelled owner install must not report success")
        } catch let error as LinuxGuestImageInstallError {
            guard case .cancelled = error else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: imagesRoot.appendingPathComponent(id).path),
            "a cancelled install must never promote a candidate"
        )
        assertNoStagingLeftovers(in: imagesRoot)
    }

    /// Cancelling the direct caller's task is linked to the owner's shared
    /// operation: the download task is cancelled and the install aborts
    /// without promotion. (A coalesced subscriber gets no such link — see the
    /// next test.)
    func testDirectOwnerCancellationStopsInFlightInstall() async throws {
        let id = "floe-cancel-fixture-2"
        let archiveURL = try makePinnedZipFixture(id: id)
        let root = workRoot.appendingPathComponent("cancel-store-2", isDirectory: true)
        let imagesRoot = root.appendingPathComponent("LinuxGuest/images", isDirectory: true)
        let service = LinuxGuestImageInstallationService(root: root)
        let gate = GatedArchiveDownloader(archive: archiveURL)
        let install = Task { try await service.installTrustedImage(id: id, downloader: gate) }
        await gate.waitUntilStarted()
        install.cancel()
        await gate.release()
        do {
            _ = try await install.value
            XCTFail("a caller-cancelled install must not report success")
        } catch let error as LinuxGuestImageInstallError {
            guard case .cancelled = error else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: imagesRoot.appendingPathComponent(id).path))
        assertNoStagingLeftovers(in: imagesRoot)
    }

    /// A coalesced subscriber's cancellation must not cancel the shared
    /// install the owner is waiting for: one download, one promotion, both
    /// callers observe the same result.
    func testCoalescedSubscriberCancellationDoesNotCancelSharedInstall() async throws {
        let id = "floe-cancel-fixture-3"
        let archiveURL = try makePinnedZipFixture(id: id)
        let root = workRoot.appendingPathComponent("cancel-store-3", isDirectory: true)
        let service = LinuxGuestImageInstallationService(root: root)
        let gate = GatedArchiveDownloader(archive: archiveURL)
        let owner = Task { try await service.installTrustedImage(id: id, downloader: gate) }
        await gate.waitUntilStarted()
        let subscriber = Task { try await service.installTrustedImage(id: id, downloader: gate) }
        // Let the subscriber join the in-flight install before cancelling it.
        try await Task.sleep(for: .milliseconds(150))
        subscriber.cancel()
        await gate.release()
        let image = try await owner.value
        XCTAssertEqual(image.id, id)
        let startCount = await gate.startCount
        XCTAssertEqual(startCount, 1, "two callers must share one download")
        _ = try? await subscriber.value
        let destination = root.appendingPathComponent("LinuxGuest/images/\(id)", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("manifest.json").path),
                      "the owner's shared install must complete despite the subscriber cancelling")
        assertNoStagingLeftovers(in: root.appendingPathComponent("LinuxGuest/images", isDirectory: true))
    }

    // MARK: - Diagnostic path redaction

    /// The typed hash error keeps stage/domain/code/errno but never exports
    /// the host path in its user-facing detail.
    func testFileIODescriptionRedactsHostPathsButKeepsClassification() throws {
        let directory = workRoot.appendingPathComponent("private-container-name", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("disk.img").path
        let underlying = NSError(
            domain: NSCocoaErrorDomain,
            code: 260,
            userInfo: [
                NSFilePathErrorKey: path,
                NSLocalizedDescriptionKey: "The file at \(path) could not be opened."
            ]
        )
        let error = FloeFileIOError(stage: .open, underlying: underlying, path: path)
        XCTAssertFalse(error.detail.contains(directory.path), "the detail must not carry the host path")
        XCTAssertFalse(error.detail.contains(directory.lastPathComponent))
        XCTAssertTrue(error.detail.contains("<path>"), "the path is replaced, not dropped silently: \(error.detail)")
        XCTAssertEqual(error.stage, .open)
        XCTAssertEqual(error.domain, NSCocoaErrorDomain)
        XCTAssertEqual(error.code, 260)

        // The real streaming path is sanitized too.
        let missing = directory.appendingPathComponent("absent.img")
        do {
            _ = try FloeDigest.sha512Hex(ofFileAt: missing)
            XCTFail("hashing a missing file must throw")
        } catch let io as FloeFileIOError {
            XCTAssertFalse(io.detail.contains(directory.path))
            XCTAssertFalse(io.errorDescription?.contains(directory.path) ?? false)
            XCTAssertEqual(io.posixErrno, ENOENT)
        }
    }

    // MARK: - Derived install state

    /// A failed repair's newest message stays visible next to the underlying
    /// verification issue instead of being hidden by the older reason.
    func testDerivationSurfacesRepairFailureAlongsideVerificationIssue() {
        var facts = LinuxGuestInstallFacts()
        facts.storageAvailable = true
        facts.imageInstalled = true
        facts.imageVerificationIssue = .artifactMissing(role: "rootfs")
        facts.downloadFailureMessage = "image download failed: the primary source and every mirror were unavailable"
        guard case .imageRepairRequired(let transient, let message) =
            LinuxGuestInstallStateDerivation.state(from: facts) else {
            return XCTFail("expected imageRepairRequired")
        }
        XCTAssertFalse(transient)
        XCTAssertTrue(message.contains("every mirror were unavailable"))
        XCTAssertTrue(message.contains("rootfs"), "the underlying verification reason must stay visible")
    }

    // MARK: - Fixtures

    /// RuntimeV2 integration double with a scriptable (and parkable) queued
    /// count; every other requirement answers a benign stub, mirroring the
    /// accepted recorder pattern.
    private actor QueuedRuntimeV2Recorder: LinuxGuestRuntimeV2Integrating {
        private let root: URL
        private var parked: CheckedContinuation<Int, Never>?
        private var probed = false
        /// When true, queuedStarts parks until `resume`; otherwise it
        /// answers `fixedQueued` immediately.
        private let parks: Bool
        private let fixedQueued: Int

        init(root: URL, parks: Bool, fixedQueued: Int) {
            self.root = root
            self.parks = parks
            self.fixedQueued = fixedQueued
        }

        func waitUntilProbed() async {
            while true {
                if probed { return }
                try? await Task.sleep(for: .milliseconds(2))
            }
        }

        func resume(queued: Int) {
            let continuation = parked
            parked = nil
            continuation?.resume(returning: queued)
        }

        func queuedStarts() async -> Int {
            guard parks else { return fixedQueued }
            return await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
                self.parked = continuation
                self.probed = true
            }
        }

        func acquireSlot(environmentID: String, runtimeID: String, requestedMB: Int) async throws -> RuntimeV2Admission {
            RuntimeV2Admission(runtimeID: runtimeID, ramMB: requestedMB, downgraded: false)
        }

        func acquireShape(
            environmentID: String, runtimeID: String,
            request: GuestResourceRequest, imageSMPCapable: Bool,
            downgrade: GuestShapeDowngradePolicy
        ) async throws -> LinuxGuestShapeAdmission {
            LinuxGuestShapeAdmission(
                runtimeID: runtimeID,
                ramMB: request.memory.mb,
                vcpus: request.vcpus.count,
                downgraded: false
            )
        }

        func planReshape(environmentID: String, ramMB: Int, vcpus: Int, currentVCPUs: Int) async throws {}
        func confirmReshape(environmentID: String, ramMB: Int, vcpus: Int) async {}
        func planRetier(environmentID: String, ramMB: Int) async throws {}
        func confirmTier(environmentID: String, ramMB: Int) async {}

        func prepareWorkingDisk(
            environmentID: String, runtimeID: String, imageID: String,
            legacyWritableDirectory: URL?, targetCapacityBytes: Int64
        ) async throws -> RuntimeV2WorkingDisk {
            let url = root.appendingPathComponent("disk-\(runtimeID).img")
            FileManager.default.createFile(atPath: url.path, contents: Data(count: 1024))
            return RuntimeV2WorkingDisk(diskURL: url, capacityBytes: 1024)
        }

        func environmentDataDirectory(environmentID: String) async throws -> URL {
            let url = root.appendingPathComponent("data/\(environmentID)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        func completeStop(environmentID: String, runtimeID: String, imageID: String, clean: Bool) async {}
        func releaseSlot(environmentID: String, runtimeID: String) async {}
        func expandedImageDirectory(imageID: String) async throws -> URL { root }
        func isImageVerified(imageID: String) async -> Bool { true }
        func isImageVerifiedWithoutMigration(imageID: String) async -> Bool { true }
        func recordedRunnerCapabilities(environmentID: String) async -> String? { nil }
        func recordRunnerCapabilities(_ capabilities: String, environmentID: String) async {}
        func workingDiskCapacityBytes(environmentID: String, runtimeID: String) async -> Int64? { 1024 }
    }

    /// Builds a qualified image whose bios lives inside `directory`, with a
    /// RELATIVE path — the required shape when a Runtime v2 substrate answers
    /// an expanded-image directory (containment check). Lookup key stays the
    /// environment's descriptor id "env-image"; only the image's own id
    /// distinguishes which resolver served it.
    private func relativeQualifiedImage(contentID: String, in directory: URL) throws -> LinuxGuestImage {
        let bios = directory.appendingPathComponent("bbl-\(contentID).bin")
        let contents = Data("bios-\(contentID)".utf8)
        try contents.write(to: bios, options: .atomic)
        return LinuxGuestImage(
            id: contentID,
            biosPath: bios.lastPathComponent,
            qualified: true,
            qualificationEvidence: "b233 queued check \(UUID().uuidString)",
            qualificationRun: "run-b233-queued",
            artifacts: [
                LinuxGuestImageArtifact(
                    role: .bios, path: bios.lastPathComponent,
                    sha512: FloeDigest.sha512Hex(contents),
                    bytes: Int64(contents.count)
                )
            ]
        )
    }

    /// Console handler answering the boot CAPS handshake with a protocol-3
    /// runner and then a successful command reply (same shape as the accepted
    /// transient-ownership fixtures), so the start reaches "running".
    private static func capsPayload(_ token: String) -> Data {
        Data("\u{1e}FLOE-CAPS \(token) runner=2.0.0 protocol=3 maxCommands=8 maxSessions=4\u{1e}\u{1e}FLOE-END \(token) 0\u{1e}".utf8)
    }

    private static func replyPayload(_ token: String) -> Data {
        var data = Data()
        data.append(Data("\u{1e}FLOE-BEGIN \(token)\u{1e}\u{1e}FLOE-OUT \(token)\u{1e}".utf8))
        data.append(Data("ok".utf8))
        data.append(Data("\u{1e}FLOE-END \(token) 0\u{1e}".utf8))
        return data
    }

    fileprivate static let bootHandler: @Sendable (String, String) -> [Data] = { _, token in
        token.hasPrefix("hello-")
            ? [capsPayload(token)]
            : [replyPayload(token)]
    }

    private func makeQueuedRegistry(
        recorder: QueuedRuntimeV2Recorder,
        queueRoot: URL,
        oldContent: String
    ) throws -> (TinyEMULinuxGuestRegistry, FakeSessionLedger) {
        let ledger = FakeSessionLedger()
        let oldImage = try relativeQualifiedImage(contentID: oldContent, in: queueRoot)
        let registry = TinyEMULinuxGuestRegistry(
            environments: FakeEnvironmentProvider(descriptors: [
                "env-1": LinuxGuestEnvironmentDescriptor(id: "env-1", ownerID: "owner", imageID: "env-image")
            ]),
            images: FakeImageResolver(images: ["env-image": oldImage]),
            limits: .standard,
            factory: FakeSessionFactory(ledger: ledger, handler: Self.bootHandler),
            runtimeV2: recorder
        )
        return (registry, ledger)
    }

    private actor VerifiedGate {
        var value = true
        func set(_ value: Bool) { self.value = value }
    }

    @discardableResult
    private func makeInstalledImage(
        id: String,
        service: LinuxGuestImageInstallationService
    ) throws -> URL {
        try makeInstalledImage(id: id, in: service.imagesDirectory)
    }

    /// Writes a small, fully-verifiable image directly into `imagesRoot/<id>`:
    /// manifest plus bios/kernel/disk artifacts with matching digest records.
    @discardableResult
    private func makeInstalledImage(id: String, in imagesRoot: URL) throws -> URL {
        let imageDir = imagesRoot.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: imageDir, withIntermediateDirectories: true)

        let bios = Data("fake-bbl".utf8)
        let kernel = Data("fake-kernel".utf8)
        var disk = Data(count: 16 * 1024)
        for index in stride(from: 0, to: 4096, by: 1) { disk[index] = UInt8(index % 199) }

        try bios.write(to: imageDir.appendingPathComponent("bbl64.bin"))
        try kernel.write(to: imageDir.appendingPathComponent("kernel-riscv64.bin"))
        try disk.write(to: imageDir.appendingPathComponent("disk.img"))

        let image = LinuxGuestImage(
            id: id,
            biosPath: "bbl64.bin",
            kernelPath: "kernel-riscv64.bin",
            diskPath: "disk.img",
            diskReadWrite: true,
            cmdline: "console=hvc0",
            qualified: true,
            qualificationEvidence: "recovery fixture",
            qualificationRun: "run-recovery-fixture",
            artifacts: [
                .init(role: .bios, path: "bbl64.bin",
                      sha512: try FloeDigest.sha512Hex(ofFileAt: imageDir.appendingPathComponent("bbl64.bin")),
                      bytes: Int64(bios.count)),
                .init(role: .kernel, path: "kernel-riscv64.bin",
                      sha512: try FloeDigest.sha512Hex(ofFileAt: imageDir.appendingPathComponent("kernel-riscv64.bin")),
                      bytes: Int64(kernel.count)),
                .init(role: .disk, path: "disk.img",
                      sha512: try FloeDigest.sha512Hex(ofFileAt: imageDir.appendingPathComponent("disk.img")),
                      bytes: Int64(disk.count))
            ]
        )
        try JSONEncoder().encode(image).write(
            to: imageDir.appendingPathComponent("manifest.json"), options: .atomic
        )
        return imageDir
    }

    private func copyDirectoryContents(from source: URL, to destination: URL) throws {
        for entry in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
            try FileManager.default.copyItem(
                at: entry,
                to: destination.appendingPathComponent(entry.lastPathComponent)
            )
        }
    }

    // MARK: - Trusted-install fixtures

    /// Builds a real (tiny) catalog-pinned archive for the cancellation tests
    /// and registers it as a test entry, the same trust shape the production
    /// catalog uses.
    private func makePinnedZipFixture(id: String) throws -> URL {
        let source = workRoot.appendingPathComponent("fixture-\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let bios = Data("cancel-fixture-bios".utf8)
        try bios.write(to: source.appendingPathComponent("bbl64.bin"))
        let manifest = LinuxGuestImage(
            id: id,
            biosPath: "bbl64.bin",
            qualified: true,
            qualificationEvidence: "cancel fixture",
            qualificationRun: "run-cancel-fixture",
            artifacts: [
                .init(role: .bios, path: "bbl64.bin",
                      sha512: FloeDigest.sha512Hex(bios), bytes: Int64(bios.count))
            ]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let manifestData = try encoder.encode(manifest)
        let archiveURL = workRoot.appendingPathComponent("\(id).zip")
        let archive = try Archive(url: archiveURL, accessMode: .create)
        try archive.addEntry(with: "manifest.json", type: .file, uncompressedSize: Int64(manifestData.count)) { position, size in
            let start = Int(position)
            return manifestData.subdata(in: start..<min(start + size, manifestData.count))
        }
        try archive.addEntry(with: "bbl64.bin", type: .file, uncompressedSize: Int64(bios.count)) { position, size in
            let start = Int(position)
            return bios.subdata(in: start..<min(start + size, bios.count))
        }
        LinuxGuestImageDistributionCatalog.registerTestEntry(LinuxGuestTrustedImage(
            id: id,
            archiveURL: URL(string: "https://example.invalid/cancel-fixture/\(id).zip")!,
            mirrors: [],
            archiveSHA512: try FloeDigest.sha512Hex(ofFileAt: archiveURL),
            provenance: LinuxGuestImageProvenance(
                sourceURL: "https://example.invalid/cancel-fixture",
                buildConfigurationURL: nil,
                license: "test fixture",
                distributionAllowed: true
            )
        ))
        return archiveURL
    }

    private func assertNoStagingLeftovers(in imagesRoot: URL) {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: imagesRoot.path)) ?? []
        XCTAssertFalse(
            entries.contains { $0.hasPrefix(".download-") || $0.hasPrefix(".import-") || $0.hasPrefix(".staging-") },
            "staging leftovers after cancellation: \(entries)"
        )
    }
}

/// Download seam that blocks until released, then copies the fixture archive.
/// Used to hold an install in the download stage while a test cancels it.
private actor GatedArchiveDownloader: LinuxGuestImageDownloading {
    private let archive: URL
    private var started = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false

    init(archive: URL) {
        self.archive = archive
    }

    var startCount: Int { started }

    func waitUntilStarted() async {
        while started == 0 {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    func release() {
        released = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    func download(
        _ url: URL,
        to destination: URL,
        maxBytes: Int64,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws(LinuxGuestImageTransferError) {
        started += 1
        if !released {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiters.append(continuation)
            }
        }
        do {
            try FileManager.default.copyItem(at: archive, to: destination)
        } catch {
            throw .localRejection(detail: "fixture copy failed")
        }
        if Task.isCancelled { throw .cancelled }
    }
}
