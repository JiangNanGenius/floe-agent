import Foundation
import XCTest
import Darwin
@testable import FloeCore
@testable import FloeExecution

final class LinuxGuestUpgradeResidueTests: XCTestCase {
    private var work: URL!
    private var center: StorageCleanupLeaseCenter!
    private var artifact: URL { work.appendingPathComponent("artifact", isDirectory: true) }
    private var images: URL { artifact.appendingPathComponent("LinuxGuest/images", isDirectory: true) }

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent("image-residue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        center = StorageCleanupLeaseCenter()
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: work) }
    private func catalog() throws -> LinuxGuestTrustedImage {
        try XCTUnwrap(LinuxGuestImageDistributionCatalog.entry(id: LinuxGuestImageDistributionCatalog.defaultImageID))
    }
    private func owner(build: String = "old", limits: LinuxGuestImageStagingOwner.Limits = .init(),
                       leases: StorageCleanupLeaseCenter? = nil) -> LinuxGuestImageStagingOwner {
        LinuxGuestImageStagingOwner(root: artifact, center: leases ?? center, session: UUID().uuidString,
                                   build: build, limits: limits)
    }
    private func abandon(_ stage: LinuxImageOwnedStage) async {
        if stage.closeNativeOwner() { await center.release(path: stage.url.path) }
    }
    private func payload(_ stage: LinuxImageOwnedStage) throws -> URL {
        let url = stage.payloadURL.appendingPathComponent("piece.bin")
        try Data(repeating: 0x57, count: 4_096).write(to: url)
        return url
    }
    private func record(_ stage: LinuxImageOwnedStage) throws -> LinuxImageStageRecord {
        try JSONDecoder().decode(LinuxImageStageRecord.self,
                                 from: Data(contentsOf: stage.url.appendingPathComponent(LinuxImageStageIO.journalName)))
    }

    private func payloadEntryIdentity(_ name: String, stage: LinuxImageOwnedStage) throws -> LinuxImageStageIdentity {
        let directory = stage.payloadURL.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard directory >= 0 else { throw LinuxImageStageError.io(errno) }
        defer { _ = Darwin.close(directory) }
        return try XCTUnwrap(LinuxImageStageIO.observe(name, in: directory))
    }

    func testHistoricalTransferScratchAndRetiredGuestAreUnlinkedOnce() async throws {
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        var sentinels: [URL: Data] = [:]
        var retired: [URL] = []
        for index in 0..<5 {
            let url = images.appendingPathComponent(".download-\(UUID().uuidString).zip")
            let bytes = Data(repeating: UInt8(index + 1), count: 4_096)
            try bytes.write(to: url); retired.append(url)
        }
        for index in 0..<3 {
            let directory = images.appendingPathComponent(".import-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("disk.img")
            let bytes = Data([UInt8(index)]); try bytes.write(to: url); retired.append(directory)
        }
        let obsolete = images.appendingPathComponent("floe-debian13-riscv64-test")
        try FileManager.default.createDirectory(at: obsolete, withIntermediateDirectories: true)
        try Data(#"{"id":"floe-debian13-riscv64-test"}"#.utf8).write(to: obsolete.appendingPathComponent("manifest.json"))
        try Data([1, 2, 3]).write(to: obsolete.appendingPathComponent("disk.img"))
        retired.append(obsolete)
        let unrelated = images.appendingPathComponent("custom-riscv64-examples")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let metadata = Data(#"{"id":"custom-riscv64-examples"}"#.utf8)
        let manifest = unrelated.appendingPathComponent("manifest.json")
        try metadata.write(to: manifest)
        sentinels[manifest] = metadata
        for path in ["LinuxGuest/images/.trash-old/disk.img", "LinuxGuest/images/installed/disk.img",
                     "Floe/Runtime/v2/recovery/repair/disk.img", "environments/retained/user.bin",
                     "LinuxGuest/ResidentARM64/LinuxGuest/disks/resident-arm64/disk.img"] {
            let url = artifact.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let bytes = Data(path.utf8); try bytes.write(to: url); sentinels[url] = bytes
        }
        let result = await owner().cleanup(build: "new")
        XCTAssertEqual(result.deletedJobs, retired.count)
        XCTAssertEqual(result.retainedLegacyEntries, 1)
        XCTAssertEqual(result.unmeasuredLegacyDirectories, 1)
        for url in retired { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path)) }
        for (url, bytes) in sentinels { XCTAssertEqual(try Data(contentsOf: url), bytes) }
        let repeated = await owner().cleanup(build: "new")
        XCTAssertEqual(repeated.deletedJobs, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: images.appendingPathComponent(LinuxImageStageIO.namespace).path))
    }

    func testNewStageIsDurablyBoundBeforePayloadAndReusedForVerifiedPieceResume() async throws {
        let service = owner()
        let first = try await service.beginDownload(catalog: catalog())
        let bytesURL = try payload(first)
        let archive = first.payloadURL.appendingPathComponent("archive.zip")
        try Data([0xA0]).write(to: archive)
        let before = try Data(contentsOf: bytesURL)
        let journal = try record(first)
        XCTAssertEqual(journal.producer, "FloeExecution.LinuxImageTransfer/1")
        XCTAssertEqual(journal.directoryName, first.directoryName)
        XCTAssertEqual(journal.state, .active)
        XCTAssertNotNil(journal.archiveSHA512)
        let firstIsLeased = await center.isLeased(path: first.url.path)
        XCTAssertTrue(firstIsLeased)
        await service.finish(first, retryable: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
        let second = try await service.beginDownload(catalog: catalog())
        XCTAssertEqual(second.payloadURL, first.payloadURL)
        XCTAssertEqual(try Data(contentsOf: bytesURL), before)
        await service.finish(second, retryable: true)
        let sameBuild = await owner().cleanup(build: "old")
        XCTAssertEqual(sameBuild.deletedJobs, 0)
        XCTAssertEqual(sameBuild.retainedCurrentResume, 1)
        XCTAssertEqual(try Data(contentsOf: bytesURL), before)
    }

    func testUpgradeReclaimsOnlyOwnedObsoleteCatalogTransfer() async throws {
        let producer = owner()
        let stage = try await producer.beginDownload(catalog: catalog())
        _ = try payload(stage)
        await producer.finish(stage, retryable: true)
        let result = await owner().cleanup(build: "new")
        XCTAssertEqual(result.deletedJobs, 1)
        XCTAssertTrue(result.isUpgradePass)
        XCTAssertGreaterThan(result.deletedEntries, 0)
        XCTAssertGreaterThanOrEqual(result.summedDeletedAllocatedBytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.url.path))
    }

    func testActivePathAndDescendantLeasesPreventDeletion() async throws {
        let producer = owner()
        let stage = try await producer.beginImport(catalog: catalog())
        let url = try payload(stage)
        let bytes = try Data(contentsOf: url)
        let active = await owner().cleanup(build: "new")
        XCTAssertEqual(active.deletedJobs, 0)
        XCTAssertEqual(active.skippedBusy, 1)
        await abandon(stage)
        let consumerLease = await center.acquire(path: url.path)
        XCTAssertTrue(consumerLease)
        let consumer = await owner().cleanup(build: "new")
        XCTAssertEqual(consumer.skippedBusy, 1)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        await center.release(path: url.path)
        let idle = await owner().cleanup(build: "new")
        XCTAssertEqual(idle.deletedJobs, 1)
    }

    func testNativeOwnerLockPreventsCrossServiceDeletion() async throws {
        let stage = try await owner().beginImport(catalog: catalog())
        let url = try payload(stage)
        let bytes = try Data(contentsOf: url)
        // Independent centers model another process. The native owner remains
        // live even though that center cannot see the original in-memory lease.
        let otherCenter = StorageCleanupLeaseCenter()
        let result = await owner(leases: otherCenter).cleanup(build: "new")
        XCTAssertEqual(result.skippedBusy, 1)
        XCTAssertEqual(result.deletedJobs, 0)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        await abandon(stage)
    }

    func testDeletionClaimBlocksProducerReacquisition() async throws {
        let producer = owner()
        let stage = try await producer.beginDownload(catalog: catalog())
        let url = try payload(stage)
        await producer.finish(stage, retryable: true)
        let offeredClaim = await center.claimForDeletion(path: stage.url.path)
        let claim = try XCTUnwrap(offeredClaim)
        do {
            let unexpected = try await producer.beginDownload(catalog: catalog())
            await producer.finish(unexpected, retryable: true)
            XCTFail("writer must not bypass a live deletion claim")
        } catch LinuxImageStageError.busy { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        await center.releaseClaim(claim.id)
    }

    func testInterruptedLocalImportIsNotMadeRegenerableByAnUpgrade() async throws {
        let stage = try await owner().beginImport()
        let url = try payload(stage)
        let bytes = try Data(contentsOf: url)
        await abandon(stage)
        let result = await owner().cleanup(build: "new")
        XCTAssertEqual(result.retainedLocalRecovery, 1)
        XCTAssertEqual(result.deletedJobs, 0)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertNil(try record(stage).imageID)
        XCTAssertNil(try record(stage).archiveSHA512)
    }

    func testExactPublishedCandidateAllowsOnlyPrivateWrapperCleanup() async throws {
        let producer = owner()
        let stage = try await producer.beginImport()
        _ = try payload(stage)
        let destination = images.appendingPathComponent("kept-image")
        try await producer.markPromotion(stage, candidate: stage.payloadURL, imageID: "kept-image")
        try FileManager.default.moveItem(at: stage.payloadURL, to: destination)
        let bytes = try Data(contentsOf: destination.appendingPathComponent("piece.bin"))
        await abandon(stage)
        let result = await owner().cleanup(build: "new")
        XCTAssertEqual(result.deletedJobs, 1)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("piece.bin")), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.url.path))
    }

    func testReplacedPublishedInodeCannotAuthorizeCleanup() async throws {
        let producer = owner()
        let stage = try await producer.beginImport()
        _ = try payload(stage)
        let destination = images.appendingPathComponent("kept-image")
        try await producer.markPromotion(stage, candidate: stage.payloadURL, imageID: "kept-image")
        try FileManager.default.moveItem(at: stage.payloadURL, to: destination)
        try FileManager.default.moveItem(at: destination, to: images.appendingPathComponent("saved-image"))
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        await abandon(stage)
        let result = await owner().cleanup(build: "new")
        XCTAssertEqual(result.deletedJobs, 0)
        XCTAssertEqual(result.retainedLocalRecovery, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stage.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: images.appendingPathComponent("saved-image/piece.bin").path))
    }

    func testCorruptOwnershipAndReplacedJobInodeAreRetained() async throws {
        for scenario in ["corrupt", "replaced"] {
            let serviceRoot = artifact.appendingPathComponent(scenario)
            let producer = LinuxGuestImageStagingOwner(root: serviceRoot, center: center, build: "old")
            let stage = try await producer.beginImport(catalog: catalog())
            let url = try payload(stage)
            await abandon(stage)
            if scenario == "corrupt" {
                try Data("invalid owner".utf8).write(to: stage.url.appendingPathComponent(LinuxImageStageIO.journalName))
            } else {
                let saved = work.appendingPathComponent("saved-job")
                try FileManager.default.moveItem(at: stage.url, to: saved)
                try FileManager.default.copyItem(at: saved, to: stage.url)
            }
            let before = try Data(contentsOf: url)
            let result = await LinuxGuestImageStagingOwner(root: serviceRoot, center: center).cleanup(build: "new")
            XCTAssertEqual(result.deletedJobs, 0)
            XCTAssertGreaterThanOrEqual(result.retainedUnknownOwnership, 1)
            XCTAssertEqual(try Data(contentsOf: url), before)
        }
    }

    func testSymlinkAndHardlinkTreesAreNeverFollowedOrPartiallyPurged() async throws {
        for scenario in ["symlink", "hardlink"] {
            let serviceRoot = artifact.appendingPathComponent(scenario)
            // An abandoned job from a previous process has a DIFFERENT session.
            // Closing its lock alone does not change its durable active record.
            let producerSession = UUID().uuidString
            let cleanupSession = UUID().uuidString
            XCTAssertNotEqual(producerSession, cleanupSession)
            let producer = LinuxGuestImageStagingOwner(root: serviceRoot, center: center,
                                                       session: producerSession, build: "old")
            let stage = try await producer.beginImport(catalog: catalog())
            let journal = try record(stage)
            XCTAssertEqual(journal.session, producerSession)
            XCTAssertEqual(journal.kind, .catalogImport)
            XCTAssertEqual(journal.state, .active)
            let keep = try payload(stage)
            let outside = work.appendingPathComponent("outside-" + scenario)
            try Data([0xA1, 0xB2]).write(to: outside)
            // Sort after piece.bin: even a safe entry encountered BEFORE the
            // unsafe link must survive the complete preflight without unlink.
            let linkName = "zz-foreign"
            let link = stage.payloadURL.appendingPathComponent(linkName)
            if scenario == "symlink" {
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            } else {
                try FileManager.default.linkItem(at: outside, to: link)
            }
            let identity = try payloadEntryIdentity(linkName, stage: stage)
            if scenario == "symlink" {
                XCTAssertEqual(identity.mode & UInt16(S_IFMT), UInt16(S_IFLNK))
            } else {
                XCTAssertTrue(identity.isRegular)
                XCTAssertEqual(identity.links, 2)
            }
            await abandon(stage)
            let stillLeased = await center.isLeased(path: stage.url.path)
            XCTAssertFalse(stillLeased)
            let before = try Data(contentsOf: keep)
            let cleaner = LinuxGuestImageStagingOwner(root: serviceRoot, center: center,
                                                      session: cleanupSession, build: "new")
            let result = await cleaner.cleanup(build: "new")
            let context = "scenario=\(scenario), report=\(String(describing: result))"
            XCTAssertEqual(result.deletedJobs, 0, context)
            XCTAssertEqual(result.deletedEntries, 0, context)
            XCTAssertEqual(result.retainedLocalRecovery, 0, context)
            XCTAssertEqual(result.skippedBusy, 0, context)
            XCTAssertGreaterThanOrEqual(result.retainedUnknownOwnership, 1, context)
            XCTAssertEqual(try Data(contentsOf: keep), before)
            XCTAssertEqual(try Data(contentsOf: outside), Data([0xA1, 0xB2]))
            XCTAssertEqual(try payloadEntryIdentity(linkName, stage: stage), identity, context)
        }
    }

    func testSameSessionUnfinishedCatalogImportRemainsProtectedBeforeTreeInspection() async throws {
        let serviceRoot = artifact.appendingPathComponent("same-session")
        let session = UUID().uuidString
        let producer = LinuxGuestImageStagingOwner(root: serviceRoot, center: center,
                                                   session: session, build: "old")
        let stage = try await producer.beginImport(catalog: catalog())
        let keep = try payload(stage)
        await abandon(stage)
        let before = try Data(contentsOf: keep)
        let journalURL = stage.url.appendingPathComponent(LinuxImageStageIO.journalName)
        let journalBefore = try Data(contentsOf: journalURL)
        let cleaner = LinuxGuestImageStagingOwner(root: serviceRoot, center: center,
                                                  session: session, build: "new")
        let result = await cleaner.cleanup(build: "new")
        XCTAssertEqual(result.deletedJobs, 0)
        XCTAssertEqual(result.deletedEntries, 0)
        XCTAssertEqual(result.retainedLocalRecovery, 1)
        XCTAssertEqual(result.retainedUnknownOwnership, 0)
        XCTAssertEqual(result.skippedBusy, 0)
        XCTAssertEqual(try Data(contentsOf: keep), before)
        XCTAssertEqual(try Data(contentsOf: journalURL), journalBefore)
    }

    func testNamespaceSymlinkIsNotTraversed() async throws {
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let outside = work.appendingPathComponent("outside-directory")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let file = outside.appendingPathComponent("keep.bin")
        try Data([0x12]).write(to: file)
        try FileManager.default.createSymbolicLink(at: images.appendingPathComponent(LinuxImageStageIO.namespace), withDestinationURL: outside)
        let result = await owner().cleanup(build: "new")
        XCTAssertEqual(result.deletedJobs, 0)
        XCTAssertGreaterThan(result.failedJobs, 0)
        XCTAssertEqual(try Data(contentsOf: file), Data([0x12]))
    }

    func testCancellationAndBoundsLeaveRecoverableOwnership() async throws {
        let stage = try await owner().beginImport(catalog: catalog())
        let url = try payload(stage)
        let bytes = try Data(contentsOf: url)
        await abandon(stage)
        let cancelled = await owner().cleanup(build: "new", isCancelled: { true })
        XCTAssertTrue(cancelled.wasCancelled)
        XCTAssertEqual(cancelled.deletedEntries, 0)
        var bounds = LinuxGuestImageStagingOwner.Limits()
        bounds.maxEntriesPerJob = 2
        let bounded = await owner(limits: bounds).cleanup(build: "new")
        XCTAssertTrue(bounded.budgetReached)
        XCTAssertEqual(bounded.deletedEntries, 0)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stage.url.appendingPathComponent(LinuxImageStageIO.journalName).path))
        let resumed = await owner().cleanup(build: "new")
        XCTAssertEqual(resumed.deletedJobs, 1)
    }

    func testImageRemovalCannotTargetPrivateTransferNamespace() async throws {
        let stage = try await owner().beginImport()
        let file = try payload(stage)
        let before = try Data(contentsOf: file)
        let installer = LinuxGuestImageInstallationService(root: artifact)
        do {
            try await installer.removeImage(id: LinuxImageStageIO.namespace)
            XCTFail("private transfer namespace is not an installed image")
        } catch LinuxGuestImageInstallError.notFound { }
        XCTAssertEqual(try Data(contentsOf: file), before)
        await abandon(stage)
    }

    func testIncompleteLocalImportIsRetainedWhenRedundancyIsUnknown() async throws {
        let producer = owner()
        let stage = try await producer.beginImport()
        let url = try payload(stage)
        let before = try Data(contentsOf: url)
        await producer.finish(stage)
        XCTAssertEqual(try Data(contentsOf: url), before)
        let offered = await producer.latestReport
        let result = try XCTUnwrap(offered)
        XCTAssertEqual(result.deletedJobs, 0)
        XCTAssertEqual(result.retainedLocalRecovery, 1)
    }

    func testExplicitlyFinishedPrivateStageIsReclaimed() async throws {
        let producer = owner()
        let stage = try await producer.beginImport(catalog: catalog())
        _ = try payload(stage)
        await producer.finish(stage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.url.path))
        let offeredResult = await producer.latestReport
        let result = try XCTUnwrap(offeredResult)
        XCTAssertEqual(result.deletedJobs, 1)
        XCTAssertGreaterThan(result.deletedEntries, 0)
    }
}
