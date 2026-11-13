// FloeCoreTests — synthetic native coverage for the bounded sparse rewrite.
//
// These tests intentionally use real regular files on the host/test volume in
// an isolated temporary directory. They do not touch a runtime environment,
// a device, a database, a real recovery disk or a model-facing path.
//
// Coverage:
//   * nonzero blocks, unallocated holes, explicitly written zero blocks,
//     zero tail and an unaligned EOF preserve every logical byte;
//   * clone+punch verifies full SHA-512, birthtime and complete readable ACL;
//     copying and every attempted fallback are explicitly refused;
//   * hard links, symlinks (file and parent component) and source mutation
//     are rejected without deleting the source;
//   * preflight ENOSPC, injected punch failure, cancellation before the
//     swap and unsupported swap all leave the original inode intact;
//   * every durable crash point recovers to the original or fully verified
//     staged bytes, and unknown stage/source identities are preserved;
//   * corrupt journals fail closed and never delete a stage.

import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#endif
@testable import FloeCore

final class StorageSparseDiskRewriteTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageSparseDiskRewriteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - Core byte/metadata integrity

    func testClonePunchPreservesEveryLogicalByteAndMetadata() throws {
        let directory = try makeRoot("clone-punch")
        let name = "disk.img"
        let url = try makeSource(in: directory, name: name)
        let before = try Data(contentsOf: url)
        let inodeBefore = try sourceIdentity(in: directory, name: name).inode
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o640, .modificationDate: fixedDate],
            ofItemAtPath: url.path
        )

        let request = try makeRequest(root: directory, name: name, mode: .cloneAndPunch)
        let report = try perform(request)

        XCTAssertEqual(report.modeUsed, .cloneAndPunch)
        XCTAssertEqual(report.logicalBytes, Int64(before.count))
        XCTAssertEqual(report.sourceDigestSHA512, report.stageDigestSHA512)
        XCTAssertEqual(report.nonzeroBytes + report.zeroBytes, report.logicalBytes)
        XCTAssertGreaterThan(report.nonzeroBytes, 0)
        XCTAssertGreaterThan(report.zeroBytes, 0)
        XCTAssertLessThan(
            report.stageAllocatedBytesAtVerification,
            report.sourceAllocatedBytesBefore
        )
        XCTAssertTrue(report.stageRetired)
        XCTAssertEqual(report.journalPhase, "retired")
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertNotEqual(try sourceIdentity(in: directory, name: name).inode, inodeBefore)
        XCTAssertTrue(try stageNames(in: directory).isEmpty)

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1, 0o640)
        if let modified = attributes[.modificationDate] as? Date {
            XCTAssertEqual(modified.timeIntervalSince1970, fixedDate.timeIntervalSince1970, accuracy: 0.001)
        } else {
            XCTFail("the rewritten disk has no modification date")
        }

        let journal = try readJournal(directory: directory, jobID: request.jobID)
        XCTAssertEqual(journal.phase, .retired)
        XCTAssertTrue(journal.stageRetired)
        XCTAssertEqual(journal.sourceDigestSHA512, Optional(report.sourceDigestSHA512))
    }

    func testMetadataAndXattrPreserved() throws {
        let directory = try makeRoot("metadata")
        let name = "disk.img"
        let url = try makeSource(in: directory, name: name)
        let xattrName = "com.example.floe.sparse-test"
        let xattrValue = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        try setTestXattr(url, name: xattrName, value: xattrValue)
        let fixedDate = Date(timeIntervalSince1970: 1_690_000_000)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600, .modificationDate: fixedDate, .creationDate: fixedDate.addingTimeInterval(-100)],
            ofItemAtPath: url.path
        )
        let flagSet = url.path.withCString { chflags($0, UInt32(UF_NODUMP)) } == 0
        let inspectionBefore = try StorageSparseDiskRewrite.inspectSource(
            rootURL: directory,
            relativePath: name
        )

        let metadataBefore = try metadata(at: url)
        let request = try makeRequest(root: directory, name: name, mode: .cloneAndPunch)
        let report = try perform(request)
        let metadataAfter = try metadata(at: url)
        XCTAssertEqual(metadataAfter.birthSeconds, metadataBefore.birthSeconds)
        XCTAssertEqual(metadataAfter.birthNanoseconds, metadataBefore.birthNanoseconds)
        XCTAssertEqual(metadataAfter.aclExternalRepresentation, metadataBefore.aclExternalRepresentation)
        XCTAssertEqual(
            try StorageSparseDiskPOSIX.metadataFingerprint(metadataAfter),
            try StorageSparseDiskPOSIX.metadataFingerprint(metadataBefore)
        )
        XCTAssertEqual(report.protectionClassPreserved, inspectionBefore.protectionClass != nil)
        XCTAssertEqual(report.protectionClassVerification,
                       inspectionBefore.protectionClass == nil ? .notVerified : .verified)

        let restoredXattr = try XCTUnwrap(getTestXattr(url, name: xattrName))
        XCTAssertEqual(restoredXattr, xattrValue)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1, 0o600)
        if let modified = attributes[.modificationDate] as? Date {
            XCTAssertEqual(modified.timeIntervalSince1970, fixedDate.timeIntervalSince1970, accuracy: 0.001)
        }
        if flagSet {
            XCTAssertNotEqual(try sourceIdentity(in: directory, name: name).fileFlags & UInt32(UF_NODUMP), 0)
        }
        #if os(iOS)
        if let protectionClassBefore = inspectionBefore.protectionClass {
            let inspectionAfter = try StorageSparseDiskRewrite.inspectSource(
                rootURL: directory,
                relativePath: name
            )
            XCTAssertEqual(inspectionAfter.protectionClass, protectionClassBefore)
        }
        #endif
    }

    func testStageBirthtimeRestorationIsReadBack() throws {
        let directory = try makeRoot("stage-birthtime")
        let sourceURL = try makeSource(in: directory)
        let before = try Data(contentsOf: sourceURL)
        let sourceFD = sourceURL.path.withCString { open($0, O_RDONLY | O_NOFOLLOW) }
        guard sourceFD >= 0 else { throw POSIXError(.EIO) }
        defer { _ = Darwin.close(sourceFD) }
        let parentFD = try StorageSparseDiskPOSIX.openDirectory(directory)
        defer { _ = Darwin.close(parentFD) }
        let snapshot = try StorageSparseDiskPOSIX.captureMetadata(fd: sourceFD)
        guard StorageSparseDiskPOSIX.cloneFile(
            sourceFD: sourceFD, directoryFD: parentFD, name: "stage.img"
        ) == 0 else { throw POSIXError(.ENOTSUP) }
        let stageURL = directory.appendingPathComponent("stage.img")
        try FileManager.default.setAttributes(
            [.creationDate: Date(timeIntervalSince1970: Double(snapshot.birthSeconds - 300))],
            ofItemAtPath: stageURL.path
        )
        let stageFD = try StorageSparseDiskPOSIX.openStageForRewrite(parentFD: parentFD, name: "stage.img")
        defer { _ = Darwin.close(stageFD) }
        let deliberatelyChanged = try StorageSparseDiskPOSIX.captureMetadata(fd: stageFD)
        XCTAssertNotEqual(deliberatelyChanged.birthSeconds, snapshot.birthSeconds)
        try StorageSparseDiskPOSIX.applyMetadata(sourceFD: sourceFD, stageFD: stageFD, snapshot: snapshot)
        try StorageSparseDiskPOSIX.fsyncFD(stageFD)
        let restored = try StorageSparseDiskPOSIX.captureMetadata(fd: stageFD)
        XCTAssertEqual(restored.birthSeconds, snapshot.birthSeconds)
        XCTAssertEqual(restored.birthNanoseconds, snapshot.birthNanoseconds)
        XCTAssertEqual(restored.aclExternalRepresentation, snapshot.aclExternalRepresentation)
        XCTAssertEqual(
            try StorageSparseDiskPOSIX.metadataFingerprint(restored),
            try StorageSparseDiskPOSIX.metadataFingerprint(snapshot)
        )
        XCTAssertEqual(try Data(contentsOf: stageURL), before)
        XCTAssertEqual(try Data(contentsOf: sourceURL), before)
    }

    func testAutomaticModeIsAlwaysLossless() throws {
        let directory = try makeRoot("automatic")
        let name = "disk.img"
        let url = try makeSource(in: directory, name: name)
        let before = try Data(contentsOf: url)

        let request = try makeRequest(root: directory, name: name, mode: .automatic)
        let report = try perform(request)

        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(report.sourceDigestSHA512, report.stageDigestSHA512)
        XCTAssertEqual(report.modeUsed, .cloneAndPunch)
        XCTAssertGreaterThan(report.punchedBytes, 0)
        XCTAssertNil(report.fallbackReason)
    }

    func testUnsupportedPunchRefusesCopyEvenWhenFallbackFlagIsTrue() throws {
        for mode in [StorageSparseDiskRewriteMode.automatic, .cloneAndPunch] {
            let directory = try makeRoot("punch-unsupported-" + mode.rawValue)
            let name = "disk.img"
            let url = try makeSource(in: directory, name: name)
            let before = try Data(contentsOf: url)
            let original = try sourceIdentity(in: directory, name: name)
            var hooks = StorageSparseDiskRewrite.TestHooks()
            hooks.forcePunchUnsupported = true
            let request = try makeRequest(
                root: directory, name: name, mode: mode, allowSparseCopyFallback: true
            )
            XCTAssertThrowsError(try perform(request, hooks: hooks)) { error in
                guard case StorageSparseDiskRewriteError.punchUnsupported = error else {
                    return XCTFail("expected punchUnsupported, got \(error)")
                }
            }
            XCTAssertEqual(try Data(contentsOf: url), before)
            XCTAssertEqual(try sourceIdentity(in: directory, name: name).inode, original.inode)
            XCTAssertTrue(try stageNames(in: directory).isEmpty)
        }
    }

    // MARK: - Admission rejection

    func testHardLinkIsRejected() throws {
        let directory = try makeRoot("hardlink")
        let name = "disk.img"
        let url = try makeSource(in: directory, name: name)
        let alias = directory.appendingPathComponent("alias.img")
        let linkResult = url.path.withCString { sourcePath in
            alias.path.withCString { aliasPath in
                link(sourcePath, aliasPath)
            }
        }
        XCTAssertEqual(linkResult, 0)

        XCTAssertThrowsError(
            try StorageSparseDiskRewrite.inspectSource(rootURL: directory, relativePath: name)
        ) { error in
            guard case StorageSparseDiskRewriteError.hardLinked(let count) = error else {
                return XCTFail("expected a hard-link rejection, got \(error)")
            }
            XCTAssertEqual(count, 2)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: alias.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testSymlinkFileAndParentAreRejected() throws {
        let directory = try makeRoot("symlink")
        let name = "disk.img"
        let url = try makeSource(in: directory, name: name)
        let fileLink = directory.appendingPathComponent("file-link.img")
        try FileManager.default.createSymbolicLink(atPath: fileLink.path, withDestinationPath: url.path)
        XCTAssertThrowsError(
            try StorageSparseDiskRewrite.inspectSource(rootURL: directory, relativePath: "file-link.img")
        ) { error in
            guard case StorageSparseDiskRewriteError.symbolicLink = error else {
                return XCTFail("expected a symlink rejection, got \(error)")
            }
        }

        let outside = try makeRoot("outside")
        let outsideFile = try makeSource(in: outside, name: "outside.img")
        let directoryLink = directory.appendingPathComponent("dir-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(atPath: directoryLink.path, withDestinationPath: outside.path)
        XCTAssertThrowsError(
            try StorageSparseDiskRewrite.inspectSource(
                rootURL: directory,
                relativePath: "dir-link/outside.img"
            )
        ) { error in
            guard case StorageSparseDiskRewriteError.symbolicLink = error else {
                return XCTFail("expected a symlink parent rejection, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideFile.path))
    }

    func testSourceMutationDuringCountingIsRejected() throws {
        let directory = try makeRoot("mutation")
        let name = "disk.img"
        let url = try makeSource(in: directory, name: name)
        let original = try Data(contentsOf: url)

        var hooks = StorageSparseDiskRewrite.TestHooks()
        hooks.afterCounting = {
            let fd = url.path.withCString { open($0, O_WRONLY) }
            guard fd >= 0 else {
                XCTFail("mutation fixture could not open its source")
                return
            }
            defer { _ = Darwin.close(fd) }
            var byte: UInt8 = 0xFF
            let written = withUnsafeBytes(of: &byte) { raw in
                pwrite(fd, raw.baseAddress, raw.count, 0)
            }
            XCTAssertEqual(written, 1, "mutation fixture must change its source")
            XCTAssertEqual(fsync(fd), 0)
        }
        let request = try makeRequest(root: directory, name: name, mode: .cloneAndPunch)
        XCTAssertThrowsError(try perform(request, hooks: hooks)) { error in
            guard let typed = error as? StorageSparseDiskRewriteError else {
                return XCTFail("expected sourceChanged, got \(error)")
            }
            if case .sourceChanged = typed {
                return
            }
            XCTFail("expected sourceChanged, got \(typed.code)")
        }
        XCTAssertNotEqual(try Data(contentsOf: url), original)
        XCTAssertTrue(try stageNames(in: directory).isEmpty)
    }

    // MARK: - Failure and cancellation

    func testPreflightENOSPCDoesNotCreateAStage() throws {
        let directory = try makeRoot("enospc-preflight")
        let name = "disk.img"
        let url = try makeSource(in: directory, name: name)
        let before = try Data(contentsOf: url)

        var hooks = StorageSparseDiskRewrite.TestHooks()
        hooks.availableBytesOverride = { _ in 1 }
        let request = try makeRequest(root: directory, name: name, mode: .cloneAndPunch)
        XCTAssertThrowsError(try perform(request, hooks: hooks)) { error in
            guard case StorageSparseDiskRewriteError.insufficientSpace(_, _, _) = error else {
                return XCTFail("expected insufficientSpace, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertTrue(try stageNames(in: directory).isEmpty)
    }

    func testInjectedPunchFailureLeavesSourceIntact() throws {
        let directory = try makeRoot("punch-failure")
        let name = "disk.img"
        let url = try makeSource(in: directory, name: name)
        let before = try Data(contentsOf: url)

        var hooks = StorageSparseDiskRewrite.TestHooks()
        hooks.beforePunch = { _, _ in
            throw StorageSparseDiskRewriteError.injectedFailure("punch")
        }
        let request = try makeRequest(root: directory, name: name, mode: .cloneAndPunch)
        XCTAssertThrowsError(try perform(request, hooks: hooks)) { error in
            guard case StorageSparseDiskRewriteError.injectedFailure("punch") = error else {
                return XCTFail("expected injectedFailure, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertTrue(try stageNames(in: directory).isEmpty)
    }

    func testCancellationBeforeSwapRemovesOnlyTheStage() throws {
        let directory = try makeRoot("cancel-before")
        let name = "disk.img"
        let url = try makeSource(in: directory, name: name)
        let before = try Data(contentsOf: url)
        let flag = TestFlag()
        let request = try makeRequest(root: directory, name: name, mode: .cloneAndPunch)

        XCTAssertThrowsError(
            try perform(
                request,
                isCancelled: { flag.isSet },
                progress: { progress in
                    if progress.phase == .verifying && progress.processedBytes == progress.totalBytes {
                        flag.set()
                    }
                }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError, "expected cancellation, got \(error)")
        }
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertTrue(try stageNames(in: directory).isEmpty)
    }

    func testCancellationAfterSwapRequiresAndCompletesRecovery() throws {
        let directory = try makeRoot("cancel-after")
        let name = "disk.img"
        let url = try makeSource(in: directory, name: name)
        let before = try Data(contentsOf: url)
        let flag = TestFlag()
        let request = try makeRequest(root: directory, name: name, mode: .cloneAndPunch)

        XCTAssertThrowsError(
            try perform(
                request,
                isCancelled: { flag.isSet },
                progress: { progress in
                    if progress.phase == .committing {
                        flag.set()
                    }
                }
            )
        ) { error in
            guard case StorageSparseDiskRewriteError.cancelledAfterSwap(let jobID) = error else {
                return XCTFail("expected cancelledAfterSwap, got \(error)")
            }
            XCTAssertEqual(jobID, request.jobID)
        }

        let recovery = try recover(directory: directory, name: name, jobID: request.jobID)
        XCTAssertTrue(
            recovery.resolution == .committed || recovery.resolution == .alreadyCommitted,
            "unexpected recovery resolution \(recovery.resolution)"
        )
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertTrue(try stageNames(in: directory).isEmpty)
    }

    func testUnsupportedSwapFailsClosed() throws {
        let directory = try makeRoot("swap-unsupported")
        let name = "disk.img"
        let url = try makeSource(in: directory, name: name)
        let before = try Data(contentsOf: url)

        var hooks = StorageSparseDiskRewrite.TestHooks()
        hooks.forceSwapUnsupported = true
        let request = try makeRequest(root: directory, name: name, mode: .cloneAndPunch)
        XCTAssertThrowsError(try perform(request, hooks: hooks)) { error in
            guard case StorageSparseDiskRewriteError.swapUnsupported = error else {
                return XCTFail("expected swapUnsupported, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertTrue(try stageNames(in: directory).isEmpty)
    }

    func testMinimumReclaimGateKeepsTheOriginal() throws {
        let directory = try makeRoot("minimum-reclaim")
        let name = "disk.img"
        let url = try makeAllZeroSource(in: directory, name: name, size: 4 * 65_536)
        let before = try Data(contentsOf: url)

        let request = try makeRequest(
            root: directory,
            name: name,
            mode: .cloneAndPunch,
            minimumReclaimBytes: 1_000_000
        )
        XCTAssertThrowsError(try perform(request)) { error in
            guard case StorageSparseDiskRewriteError.insufficientReclaim(_, _) = error else {
                return XCTFail("expected insufficientReclaim, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertTrue(try stageNames(in: directory).isEmpty)
    }

    func testRenamedRootRecoveryRequiresDurablePhysicalBindingAndPreservesBytes() throws {
        let points: [StorageSparseDiskRewrite.CrashPoint] = [.afterVerified, .afterSwap]
        for point in points {
            let old = try makeRoot("rename-" + point.rawValue)
            let file = try makeSource(in: old, name: "disk.img")
            let bytes = try Data(contentsOf: file)
            let fd = try StorageSparseDiskPOSIX.openDirectory(old)
            let physical = try StorageSparseDiskPOSIX.identity(of: fd); close(fd)
            let request = try makeRequest(root: old, name: "disk.img", mode: .cloneAndPunch)
            var hooks = StorageSparseDiskRewrite.TestHooks()
            hooks.crashAt = { if $0 == point { throw StorageSparseDiskRewriteError.crashInjected("relocation") } }
            XCTAssertThrowsError(try perform(request, hooks: hooks))
            let journalRoot = try readJournal(directory: old, jobID: request.jobID).rootPath
            let moved = old.deletingLastPathComponent().appendingPathComponent(old.lastPathComponent + "-moved")
            try FileManager.default.moveItem(at: old, to: moved)
            let beforeRecovery = try Data(contentsOf: moved.appendingPathComponent("journal/" + request.jobID + ".json"))
            XCTAssertThrowsError(try StorageSparseDiskRewrite.recover(rootURL: moved, relativePath: "disk.img",
                journalDirectoryURL: moved.appendingPathComponent("journal"), jobID: request.jobID, fence: fence()))
            XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent("journal/" + request.jobID + ".json")), beforeRecovery)
            let result = try StorageSparseDiskRewrite.recover(rootURL: moved, relativePath: "disk.img",
                journalDirectoryURL: moved.appendingPathComponent("journal"), jobID: request.jobID, fence: fence(),
                recordedRootBinding: .init(recordedRootPath: journalRoot, device: physical.device, inode: physical.inode))
            XCTAssertTrue(result.sourceIdentityVerified); XCTAssertNotEqual(result.resolution, .needsInspection)
            XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent("disk.img")), bytes)
            XCTAssertTrue(try stageNames(in: moved).isEmpty)
            XCTAssertEqual(try readJournal(directory: moved, jobID: request.jobID).rootPath, journalRoot)
        }
    }

    func testCopiedRootRejectsOldBindingWithoutMutatingSourceStageOrJournal() throws {
        let old = try makeRoot("copy-root")
        _ = try makeSource(in: old, name: "disk.img")
        let fd = try StorageSparseDiskPOSIX.openDirectory(old)
        let physical = try StorageSparseDiskPOSIX.identity(of: fd); close(fd)
        let request = try makeRequest(root: old, name: "disk.img", mode: .cloneAndPunch)
        var hooks = StorageSparseDiskRewrite.TestHooks()
        hooks.crashAt = { if $0 == .afterVerified { throw StorageSparseDiskRewriteError.crashInjected("copy") } }
        XCTAssertThrowsError(try perform(request, hooks: hooks))
        let record = try readJournal(directory: old, jobID: request.jobID)
        let copied = try makeRoot("copy-destination")
        try FileManager.default.removeItem(at: copied)
        try FileManager.default.copyItem(at: old, to: copied)
        let names = ["disk.img", try XCTUnwrap(record.stageName), "journal/" + request.jobID + ".json"]
        let before = try names.map { try Data(contentsOf: copied.appendingPathComponent($0)) }
        XCTAssertThrowsError(try StorageSparseDiskRewrite.recover(rootURL: copied, relativePath: "disk.img",
            journalDirectoryURL: copied.appendingPathComponent("journal"), jobID: request.jobID, fence: fence(),
            recordedRootBinding: .init(recordedRootPath: record.rootPath, device: physical.device, inode: physical.inode)))
        for (index,name) in names.enumerated() {
            XCTAssertEqual(try Data(contentsOf: copied.appendingPathComponent(name)), before[index])
        }
    }

    // MARK: - Crash recovery

    func testCrashRecoveryAtEveryDurablePhase() throws {
        for point in StorageSparseDiskRewrite.CrashPoint.all {
            let directory = try makeRoot("crash-\(point.rawValue)")
            let name = "disk.img"
            let url = try makeSource(in: directory, name: name)
            let before = try Data(contentsOf: url)
            let request = try makeRequest(root: directory, name: name, mode: .cloneAndPunch)

            var hooks = StorageSparseDiskRewrite.TestHooks()
            hooks.crashAt = { actual in
                if actual == point {
                    throw StorageSparseDiskRewriteError.crashInjected(actual.rawValue)
                }
            }
            XCTAssertThrowsError(try perform(request, hooks: hooks)) { error in
                guard case StorageSparseDiskRewriteError.crashInjected(let name) = error else {
                    return XCTFail("expected crashInjected at \(point.rawValue), got \(error)")
                }
                XCTAssertEqual(name, point.rawValue)
            }

            let recovery = try recover(directory: directory, name: name, jobID: request.jobID)
            XCTAssertNotEqual(
                recovery.resolution,
                .needsInspection,
                "crash point \(point.rawValue) needs inspection: \(recovery.detail)"
            )
            XCTAssertEqual(try Data(contentsOf: url), before, "crash point \(point.rawValue)")
            XCTAssertTrue(
                try stageNames(in: directory).isEmpty,
                "crash point \(point.rawValue) left a stage"
            )
        }
    }

    func testRecoveryPreservesAStageWithUnknownIdentity() throws {
        let directory = try makeRoot("unknown-stage")
        let name = "disk.img"
        _ = try makeSource(in: directory, name: name)
        let request = try makeRequest(root: directory, name: name, mode: .cloneAndPunch)

        var hooks = StorageSparseDiskRewrite.TestHooks()
        hooks.crashAt = { point in
            if point == .afterIntent {
                throw StorageSparseDiskRewriteError.crashInjected(point.rawValue)
            }
        }
        XCTAssertThrowsError(try perform(request, hooks: hooks))
        let journal = try readJournal(directory: directory, jobID: request.jobID)
        let stageName = try XCTUnwrap(journal.stageName)
        let stageURL = directory.appendingPathComponent(stageName)
        try Data([0xAA, 0xBB, 0xCC]).write(to: stageURL)

        let recovery = try recover(directory: directory, name: name, jobID: request.jobID)
        XCTAssertEqual(recovery.resolution, .needsInspection)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stageURL.path))
    }

    func testRecoveryPreservesAnUnknownSourceReplacement() throws {
        let directory = try makeRoot("unknown-source")
        let name = "disk.img"
        let url = try makeSource(in: directory, name: name)
        let request = try makeRequest(root: directory, name: name, mode: .cloneAndPunch)

        var hooks = StorageSparseDiskRewrite.TestHooks()
        hooks.crashAt = { point in
            if point == .afterVerified {
                throw StorageSparseDiskRewriteError.crashInjected(point.rawValue)
            }
        }
        XCTAssertThrowsError(try perform(request, hooks: hooks))
        let journal = try readJournal(directory: directory, jobID: request.jobID)
        let stageName = try XCTUnwrap(journal.stageName)
        let stageURL = directory.appendingPathComponent(stageName)
        let savedURL = directory.appendingPathComponent("source-saved.img")
        try FileManager.default.moveItem(at: url, to: savedURL)
        try Data(repeating: 0x7F, count: 32).write(to: url)

        let recovery = try recover(directory: directory, name: name, jobID: request.jobID)
        XCTAssertEqual(recovery.resolution, .needsInspection)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stageURL.path))
    }

    func testCorruptJournalFailsClosedWithoutDeletingTheStage() throws {
        let directory = try makeRoot("corrupt-journal")
        let name = "disk.img"
        _ = try makeSource(in: directory, name: name)
        let request = try makeRequest(root: directory, name: name, mode: .cloneAndPunch)

        var hooks = StorageSparseDiskRewrite.TestHooks()
        hooks.crashAt = { point in
            if point == .afterStageCreated {
                throw StorageSparseDiskRewriteError.crashInjected(point.rawValue)
            }
        }
        XCTAssertThrowsError(try perform(request, hooks: hooks))
        let journalURL = directory.appendingPathComponent("journal/\(request.jobID).json")
        try Data("not a journal".utf8).write(to: journalURL)

        XCTAssertThrowsError(
            try recover(directory: directory, name: name, jobID: request.jobID)
        ) { error in
            guard case StorageSparseDiskRewriteError.journalCorrupt = error else {
                return XCTFail("expected journalCorrupt, got \(error)")
            }
        }
        XCTAssertFalse(try stageNames(in: directory).isEmpty)
    }

    func testSparseCopyWithProductionDefaultProbeIsRejectedBeforeStaging() throws {
        let directory = try makeRoot("default-probe-refused")
        let name = "disk.img"
        let url = directory.appendingPathComponent(name)
        let fd = url.path.withCString { open($0, O_RDWR | O_CREAT | O_EXCL, mode_t(0o600)) }
        guard fd >= 0 else { throw POSIXError(.EIO) }
        do {
            for index in 0..<16 {
                try write(Data(repeating: 0x41, count: 4_096), to: fd, at: Int64(index * 65_536))
            }
            guard ftruncate(fd, 16 * 65_536) == 0, fsync(fd) == 0 else { throw POSIXError(.EIO) }
        } catch {
            _ = Darwin.close(fd)
            throw error
        }
        _ = Darwin.close(fd)
        let before = try Data(contentsOf: url)
        let inspection = try StorageSparseDiskRewrite.inspectSource(rootURL: directory, relativePath: name)
        let request = StorageSparseDiskRewriteRequest(
            rootURL: directory, relativePath: name, expectedSource: inspection.identity,
            journalDirectoryURL: directory.appendingPathComponent("journal"),
            jobID: "default-probe", maintenanceLeaseID: "lease-test",
            holdGeneration: 7, jobGeneration: 9, mode: .sparseCopy,
            minimumReclaimBytes: 0, allowSparseCopyFallback: true
        )
        XCTAssertEqual(request.zeroProbeBytes, 65_536)
        XCTAssertThrowsError(try perform(request)) { error in
            guard case StorageSparseDiskRewriteError.unsupportedMode = error else {
                return XCTFail("expected disabled sparse copy, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: url), before)
        let after = try StorageSparseDiskRewrite.inspectSource(rootURL: directory, relativePath: name)
        XCTAssertTrue(after.identity.matchesFully(inspection.identity))
        XCTAssertEqual(after.allocatedBytes, inspection.allocatedBytes)
        XCTAssertTrue(try stageNames(in: directory).isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(
            at: directory.appendingPathComponent("journal"), includingPropertiesForKeys: nil
        ).isEmpty)
    }

    func testCloneFailureRefusesCopyForEverySupportedMode() throws {
        for mode in [StorageSparseDiskRewriteMode.automatic, .cloneAndPunch] {
            for fallback in [false, true] {
                let directory = try makeRoot("clone-unsupported-\(mode.rawValue)-\(fallback)")
                let url = try makeSource(in: directory)
                let before = try Data(contentsOf: url)
                let original = try sourceIdentity(in: directory, name: "disk.img")
                var hooks = StorageSparseDiskRewrite.TestHooks()
                hooks.forceCloneFailure = true
                let request = try makeRequest(
                    root: directory, name: "disk.img", mode: mode, allowSparseCopyFallback: fallback
                )
                XCTAssertThrowsError(try perform(request, hooks: hooks)) { error in
                    guard case StorageSparseDiskRewriteError.cloneUnavailable = error else {
                        return XCTFail("expected cloneUnavailable, got \(error)")
                    }
                }
                XCTAssertEqual(try Data(contentsOf: url), before)
                XCTAssertEqual(try sourceIdentity(in: directory, name: "disk.img").inode, original.inode)
                XCTAssertTrue(try stageNames(in: directory).isEmpty)
            }
        }
    }

    func testUnknownMetadataReadFailsBeforeStageAndSourceReplacement() throws {
        for field in ["acl", "protection-class"] {
            let directory = try makeRoot("unknown-metadata-" + field)
            let url = try makeSource(in: directory)
            let before = try Data(contentsOf: url)
            let original = try sourceIdentity(in: directory, name: "disk.img")
            var hooks = StorageSparseDiskRewrite.TestHooks()
            hooks.metadataReadFault = { current in
                if current == field {
                    throw StorageSparseDiskRewriteError.metadataUnavailable(field: field)
                }
            }
            let request = try makeRequest(root: directory, name: "disk.img", allowSparseCopyFallback: true)
            XCTAssertThrowsError(try perform(request, hooks: hooks)) { error in
                guard case StorageSparseDiskRewriteError.metadataUnavailable = error else {
                    return XCTFail("expected metadata refusal, got \(error)")
                }
            }
            XCTAssertEqual(try Data(contentsOf: url), before)
            XCTAssertTrue(try sourceIdentity(in: directory, name: "disk.img").matchesFully(original))
            XCTAssertTrue(try stageNames(in: directory).isEmpty)
        }
    }

    func testUnknownProtectionIsNotReportedAsPreserved() throws {
        XCTAssertThrowsError(try StorageSparseDiskPOSIX.requireKnownProtectionClass(nil)) { error in
            guard case StorageSparseDiskRewriteError.metadataUnavailable(let field) = error else {
                return XCTFail("expected unknown protection refusal, got \(error)")
            }
            XCTAssertEqual(field, "protection-class")
        }
        let directory = try makeRoot("protection-status")
        _ = try makeSource(in: directory)
        let inspection = try StorageSparseDiskRewrite.inspectSource(rootURL: directory, relativePath: "disk.img")
        let report = try perform(makeRequest(root: directory, name: "disk.img"))
        XCTAssertEqual(report.protectionClassPreserved, inspection.protectionClass != nil)
        XCTAssertEqual(report.protectionClassVerification,
                       inspection.protectionClass == nil ? .notVerified : .verified)
    }

    func testRetainedCloneCannotEnableCopyFallback() throws {
        let directory = try makeRoot("retained-clone")
        let base = try makeSource(in: directory, name: "base.img")
        let baseFD = base.path.withCString { open($0, O_RDONLY | O_NOFOLLOW) }
        guard baseFD >= 0 else { throw POSIXError(.EIO) }
        let parentFD = try StorageSparseDiskPOSIX.openDirectory(directory)
        let cloned = StorageSparseDiskPOSIX.cloneFile(sourceFD: baseFD, directoryFD: parentFD, name: "disk.img")
        _ = Darwin.close(baseFD)
        _ = Darwin.close(parentFD)
        guard cloned == 0 else { throw POSIXError(.ENOTSUP) }
        let disk = directory.appendingPathComponent("disk.img")
        let before = try Data(contentsOf: disk)
        let original = try sourceIdentity(in: directory, name: "disk.img")
        var hooks = StorageSparseDiskRewrite.TestHooks()
        hooks.forcePunchUnsupported = true
        let request = try makeRequest(
            root: directory, name: "disk.img", minimumReclaimBytes: 0,
            allowSparseCopyFallback: true
        )
        XCTAssertThrowsError(try perform(request, hooks: hooks)) { error in
            guard case StorageSparseDiskRewriteError.punchUnsupported = error else {
                return XCTFail("retained COW source must not fall back to copying: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: disk), before)
        XCTAssertEqual(try Data(contentsOf: base), before)
        XCTAssertEqual(try sourceIdentity(in: directory, name: "disk.img").inode, original.inode)
        XCTAssertTrue(try stageNames(in: directory).isEmpty)
    }

    func testSignedGainRejectsGrowthAndZeroEvenWithoutCallerMinimum() throws {
        let minima: [Int64?] = [nil, 0, 1]
        let stages: [Int64] = [4_096, 65_536]
        for minimum in minima {
            for stage in stages {
                XCTAssertThrowsError(try StorageSparseDiskRewriteEngine.requirePositiveGain(
                    sourceAllocated: 4_096, stageAllocated: stage, minimumReclaimBytes: minimum
                )) { error in
                    guard case StorageSparseDiskRewriteError.insufficientReclaim(let measured, let required) = error else {
                        return XCTFail("expected signed reclaim rejection, got \(error)")
                    }
                    XCTAssertEqual(measured, 4_096 - stage)
                    XCTAssertEqual(required, 1)
                }
            }
        }
        XCTAssertNoThrow(try StorageSparseDiskRewriteEngine.requirePositiveGain(
            sourceAllocated: 65_536, stageAllocated: 4_096, minimumReclaimBytes: nil
        ))
    }

    func testRecoveryPersistenceFailuresRequireRecoveryAndConverge() throws {
        for scenario in ["abort", "retire", "rollback"] {
            for fault in ["directory", "journal"] {
                let directory = try makeRoot("persist-\(scenario)-\(fault)")
                let url = try makeSource(in: directory)
                let before = try Data(contentsOf: url)
                let original = try sourceIdentity(in: directory, name: "disk.img")
                let request = try makeRequest(root: directory, name: "disk.img")
                var rewriteHooks = StorageSparseDiskRewrite.TestHooks()
                let stop: StorageSparseDiskRewrite.CrashPoint = scenario == "abort" ? .afterStageCreated : .afterSwappedJournal
                rewriteHooks.crashAt = { point in
                    if point == stop { throw StorageSparseDiskRewriteError.crashInjected(point.rawValue) }
                }
                XCTAssertThrowsError(try perform(request, hooks: rewriteHooks))
                if scenario == "rollback" {
                    let record = try readJournal(directory: directory, jobID: request.jobID)
                    try corruptDataPreservingStableIdentity(at: url, expected: XCTUnwrap(record.stage))
                }
                let target: StorageSparseDiskRewriteRecovery.PersistencePoint
                switch scenario {
                case "abort": target = .abortStage
                case "retire": target = .retired
                default: target = .rollbackComplete
                }
                var recoveryHooks = StorageSparseDiskRewriteRecovery.TestHooks()
                if fault == "directory" {
                    recoveryHooks.beforeDirectorySync = { point in
                        if point == target { throw StorageSparseDiskRewriteError.fsyncFailed(errno: EIO) }
                    }
                } else {
                    recoveryHooks.beforeJournalUpdate = { point in
                        if point == target { throw StorageSparseDiskRewriteError.journalWriteFailed(errno: EIO) }
                    }
                }
                XCTAssertThrowsError(try recover(
                    directory: directory, name: "disk.img", jobID: request.jobID, hooks: recoveryHooks
                )) { error in
                    guard case StorageSparseDiskRewriteError.recoveryRequired(let job, _) = error else {
                        return XCTFail("expected recoveryRequired after persistence failure, got \(error)")
                    }
                    XCTAssertEqual(job, request.jobID)
                }
                XCTAssertEqual(try Data(contentsOf: url), before)
                let resolved = try recover(directory: directory, name: "disk.img", jobID: request.jobID)
                XCTAssertNotEqual(resolved.resolution, .needsInspection)
                XCTAssertTrue(resolved.sourceIdentityVerified)
                XCTAssertEqual(try Data(contentsOf: url), before)
                XCTAssertTrue(try stageNames(in: directory).isEmpty)
                let record = try readJournal(directory: directory, jobID: request.jobID)
                XCTAssertEqual(record.phase, scenario == "retire" ? .retired : .aborted)
                if scenario != "retire" {
                    XCTAssertEqual(try sourceIdentity(in: directory, name: "disk.img").inode, original.inode)
                }
            }
        }
    }

    func testRecoveryRejectsLegacySchemaWithoutDeletingAnything() throws {
        let directory = try makeRoot("old-schema")
        let url = try makeSource(in: directory)
        let before = try Data(contentsOf: url)
        let request = try makeRequest(root: directory, name: "disk.img")
        var hooks = StorageSparseDiskRewrite.TestHooks()
        hooks.crashAt = { point in
            if point == .afterStageCreated { throw StorageSparseDiskRewriteError.crashInjected(point.rawValue) }
        }
        XCTAssertThrowsError(try perform(request, hooks: hooks))
        let record = try readJournal(directory: directory, jobID: request.jobID)
        let stage = directory.appendingPathComponent(try XCTUnwrap(record.stageName))
        let journalURL = directory.appendingPathComponent("journal/\(request.jobID).json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: journalURL)) as? [String: Any])
        object["schemaVersion"] = 1
        try JSONSerialization.data(withJSONObject: object).write(to: journalURL)
        XCTAssertThrowsError(try recover(directory: directory, name: "disk.img", jobID: request.jobID)) { error in
            guard case StorageSparseDiskRewriteError.journalCorrupt = error else {
                return XCTFail("expected legacy schema refusal, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: stage.path))
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testRecoveryPreservesHardlinkedOrSymlinkedStage() throws {
        for kind in ["hardlink", "symlink"] {
            let directory = try makeRoot("stage-" + kind)
            let url = try makeSource(in: directory)
            let before = try Data(contentsOf: url)
            let request = try makeRequest(root: directory, name: "disk.img")
            var hooks = StorageSparseDiskRewrite.TestHooks()
            hooks.crashAt = { point in
                if point == .afterStageCreated { throw StorageSparseDiskRewriteError.crashInjected(point.rawValue) }
            }
            XCTAssertThrowsError(try perform(request, hooks: hooks))
            let record = try readJournal(directory: directory, jobID: request.jobID)
            let stage = directory.appendingPathComponent(try XCTUnwrap(record.stageName))
            let other = directory.appendingPathComponent("other.img")
            if kind == "hardlink" {
                try FileManager.default.linkItem(at: stage, to: other)
            } else {
                try Data([0xA1, 0xB2]).write(to: other)
                try FileManager.default.removeItem(at: stage)
                try FileManager.default.createSymbolicLink(at: stage, withDestinationURL: other)
            }
            let otherBefore = try Data(contentsOf: other)
            let result = try recover(directory: directory, name: "disk.img", jobID: request.jobID)
            XCTAssertEqual(result.resolution, .needsInspection)
            XCTAssertTrue(FileManager.default.fileExists(atPath: stage.path))
            XCTAssertEqual(try Data(contentsOf: other), otherBefore)
            XCTAssertEqual(try Data(contentsOf: url), before)
        }
    }

    func testAbortOnlyCtimeDigestRejectsAbsentMalformedAndChangedContent() throws {
        for fault in ["missing", "malformed", "content"] {
            let directory = try makeRoot("ctime-digest-" + fault)
            let url = try makeSource(in: directory)
            let request = try prepareAbortOnlyJob(directory: directory, stagePresent: true)
            var original = try readJournal(directory: directory, jobID: request.jobID)
            let journalURL = directory.appendingPathComponent("journal/" + request.jobID + ".json")
            if fault == "content" {
                try corruptDataPreservingStableIdentity(at: url, expected: original.source)
            } else {
                original.sourceDigestSHA512 = fault == "missing" ? nil : String(repeating: "g", count: 128)
                try JSONEncoder().encode(original).write(to: journalURL)
                try Self.changeOnlySourceCtime(url)
            }
            let current = try sourceIdentity(in: directory, name: "disk.img")
            XCTAssertTrue(current.matchesStable(original.source))
            XCTAssertFalse(current.matchesFully(original.source))
            let stage = directory.appendingPathComponent(try XCTUnwrap(original.stageName))
            let sourceBytes = try Data(contentsOf: url), stageBytes = try Data(contentsOf: stage)
            let journalBytes = try Data(contentsOf: journalURL)
            let result = try StorageSparseDiskRewrite.recover(rootURL: directory, relativePath: "disk.img",
                journalDirectoryURL: directory.appendingPathComponent("journal"), jobID: request.jobID,
                fence: fence(), policy: .abortUnchangedSourceOnly)
            XCTAssertEqual(result.resolution, .needsInspection)
            XCTAssertEqual(result.detail, fault == "content"
                ? "source-preserving-abort-source-digest" : "source-preserving-abort-digest-unavailable")
            XCTAssertFalse(result.sourceContentDigestVerified); XCTAssertFalse(result.stageRemoved)
            XCTAssertEqual(try Data(contentsOf: url), sourceBytes)
            XCTAssertEqual(try Data(contentsOf: stage), stageBytes)
            XCTAssertEqual(try Data(contentsOf: journalURL), journalBytes)
        }
    }

    func testAbortOnlyCtimeDigestRefusesChangesDuringReadAndFinalFence() throws {
        for boundary in ["during-read", "after-read", "journal-after-read"] {
            let directory = try makeRoot("ctime-race-" + boundary)
            let url = try makeSource(in: directory)
            let request = try prepareAbortOnlyJob(directory: directory, stagePresent: true)
            let original = try readJournal(directory: directory, jobID: request.jobID)
            try Self.changeOnlySourceCtime(url)
            let stage = directory.appendingPathComponent(try XCTUnwrap(original.stageName))
            let sourceBytes = try Data(contentsOf: url), stageBytes = try Data(contentsOf: stage)
            let journalURL = directory.appendingPathComponent("journal/" + request.jobID + ".json")
            let journalBytes = try Data(contentsOf: journalURL)
            var altered = original; altered.lastError = "synthetic-concurrent-journal-writer"
            let alteredBytes = try JSONEncoder().encode(altered)
            let calls = TestCounter()
            let callbackFailed = TestFlag()
            let testFence = StorageSparseDiskMaintenanceFence(leaseID: "lease-test", generation: 9) {
                if calls.increment() == 3 && boundary != "during-read" {
                    if boundary == "journal-after-read" { try alteredBytes.write(to: journalURL) }
                    else { try Self.changeOnlySourceCtime(url) }
                }
            }
            let result = try StorageSparseDiskRewrite.recover(rootURL: directory, relativePath: "disk.img",
                journalDirectoryURL: directory.appendingPathComponent("journal"), jobID: request.jobID,
                fence: testFence, policy: .abortUnchangedSourceOnly, progress: { value in
                    if boundary == "during-read" && value.processedBytes == 0 {
                        do { try Self.changeOnlySourceCtime(url) } catch { callbackFailed.set() }
                    }
                })
            XCTAssertFalse(callbackFailed.isSet)
            XCTAssertEqual(result.resolution, .needsInspection)
            XCTAssertEqual(result.detail, boundary == "journal-after-read"
                ? "source-preserving-abort-journal-changed" : "source-preserving-abort-source-changed")
            XCTAssertFalse(result.stageRemoved); XCTAssertFalse(result.sourceContentDigestVerified)
            XCTAssertEqual(try Data(contentsOf: url), sourceBytes)
            XCTAssertEqual(try Data(contentsOf: stage), stageBytes)
            XCTAssertEqual(try Data(contentsOf: journalURL), boundary == "journal-after-read" ? alteredBytes : journalBytes)
        }
    }

    func testAbortOnlyFullIdentityFastPathSkipsHashAndFinishesOwnedMutation() throws {
        for stagePresent in [false, true] {
            let directory = try makeRoot("abort-fast-\(stagePresent)")
            let url = try makeSource(in: directory)
            let sourceBytes = try Data(contentsOf: url)
            let request = try prepareAbortOnlyJob(directory: directory, stagePresent: stagePresent)
            let original = try readJournal(directory: directory, jobID: request.jobID)
            let hashProgress = TestFlag(), cancelled = TestFlag()
            var hooks = StorageSparseDiskRewriteRecovery.TestHooks()
            hooks.beforeJournalUpdate = { point in
                if point == .abortStage || point == .abortWithoutStage { cancelled.set() }
            }
            let result = try StorageSparseDiskRewriteRecovery.recover(rootURL: directory,
                relativePath: "disk.img", journalDirectoryURL: directory.appendingPathComponent("journal"),
                jobID: request.jobID, fence: fence(), policy: .abortUnchangedSourceOnly,
                isCancelled: { cancelled.isSet }, progress: { _ in hashProgress.set() }, hooks: hooks)
            XCTAssertTrue(cancelled.isSet, "Cancellation arrives only after the first owned mutation")
            XCTAssertFalse(hashProgress.isSet, "Unchanged full identity must keep the no-content-read fast path")
            XCTAssertEqual(result.resolution, .abortedBeforeSwap); XCTAssertEqual(result.phase, "aborted")
            XCTAssertFalse(result.sourceContentDigestVerified); XCTAssertEqual(result.stageRemoved, stagePresent)
            let final = try readJournal(directory: directory, jobID: request.jobID)
            XCTAssertEqual(final.source, original.source)
            XCTAssertEqual(final.sourceDigestSHA512, original.sourceDigestSHA512)
            XCTAssertEqual(try Data(contentsOf: url), sourceBytes)
            XCTAssertTrue(try sourceIdentity(in: directory, name: "disk.img").matchesFully(original.source))
            XCTAssertTrue(try stageNames(in: directory).isEmpty)
        }
    }

    // MARK: - Helpers

    private final class TestCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    }

    private static func changeOnlySourceCtime(_ url: URL) throws {
        let fd = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW) }
        guard fd >= 0 else { throw POSIXError(.EIO) }; defer { _ = Darwin.close(fd) }
        let before = try StorageSparseDiskPOSIX.identity(of: fd)
        let permissions = mode_t(before.mode & 0o7777)
        guard fchmod(fd, permissions ^ mode_t(0o100)) == 0, fchmod(fd, permissions) == 0 else {
            throw POSIXError(.EIO)
        }
        let after = try StorageSparseDiskPOSIX.identity(of: fd)
        guard after.matchesStable(before), !after.matchesFully(before) else {
            throw StorageSparseDiskRewriteError.injectedFailure("synthetic-ctime-change-not-established")
        }
    }

    private func prepareAbortOnlyJob(directory: URL, stagePresent: Bool) throws -> StorageSparseDiskRewriteRequest {
        let request = try makeRequest(root: directory, name: "disk.img", mode: .cloneAndPunch)
        var hooks = StorageSparseDiskRewrite.TestHooks()
        hooks.crashAt = { point in
            if stagePresent && point == .afterStaging {
                throw StorageSparseDiskRewriteError.crashInjected("synthetic-ctime-stage-left")
            }
            if !stagePresent && point == .afterVerified {
                throw StorageSparseDiskRewriteError.injectedFailure("synthetic-ctime-stage-cleaned")
            }
        }
        XCTAssertThrowsError(try perform(request, hooks: hooks)) { error in
            XCTAssertEqual(error as? StorageSparseDiskRewriteError, stagePresent
                ? .crashInjected("synthetic-ctime-stage-left") : .injectedFailure("synthetic-ctime-stage-cleaned"))
        }
        let record = try readJournal(directory: directory, jobID: request.jobID)
        XCTAssertEqual(record.phase, stagePresent ? .staging : .failed)
        XCTAssertEqual(record.sourceDigestSHA512?.utf8.count, 128)
        XCTAssertEqual(try stageNames(in: directory).isEmpty, !stagePresent)
        return request
    }

    private final class TestFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }

        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private func makeRoot(_ name: String) throws -> URL {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("journal", isDirectory: true),
            withIntermediateDirectories: true
        )
        return directory
    }

    @discardableResult
    private func makeSource(in directory: URL, name: String = "disk.img") throws -> URL {
        let block = 65_536
        let size = Int64(block) * 9 + 12_345
        let url = directory.appendingPathComponent(name)
        let fd = url.path.withCString {
            open($0, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o640))
        }
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = Darwin.close(fd) }
        try write(Data(repeating: 0x11, count: block), to: fd, at: 0)
        try write(Data(repeating: 0x00, count: block), to: fd, at: Int64(block) * 2)
        try write(Data(repeating: 0x22, count: block), to: fd, at: Int64(block) * 3)
        try write(Data(repeating: 0x33, count: block), to: fd, at: Int64(block) * 6)
        guard ftruncate(fd, off_t(size)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard fsync(fd) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard fchmod(fd, mode_t(0o640)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return url
    }

    @discardableResult
    private func makeAllZeroSource(in directory: URL, name: String, size: Int64) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let fd = url.path.withCString {
            open($0, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o640))
        }
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = Darwin.close(fd) }
        guard ftruncate(fd, off_t(size)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard fsync(fd) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return url
    }

    private func write(_ data: Data, to fd: Int32, at offset: Int64) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let result = pwrite(
                    fd,
                    base.advanced(by: written),
                    raw.count - written,
                    off_t(offset) + off_t(written)
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                if result == 0 {
                    throw POSIXError(.EIO)
                }
                written += result
            }
        }
    }

    private func sourceIdentity(in directory: URL, name: String) throws -> StorageSparseDiskIdentity {
        try StorageSparseDiskRewrite.inspectSource(rootURL: directory, relativePath: name).identity
    }

    private func makeRequest(
        root: URL,
        name: String,
        mode: StorageSparseDiskRewriteMode = .automatic,
        minimumReclaimBytes: Int64? = nil,
        allowSparseCopyFallback: Bool = false
    ) throws -> StorageSparseDiskRewriteRequest {
        let identity = try sourceIdentity(in: root, name: name)
        return StorageSparseDiskRewriteRequest(
            rootURL: root,
            relativePath: name,
            expectedSource: identity,
            journalDirectoryURL: root.appendingPathComponent("journal", isDirectory: true),
            jobID: "job-\(UUID().uuidString)",
            maintenanceLeaseID: "lease-test",
            holdGeneration: 7,
            jobGeneration: 9,
            mode: mode,
            chunkBytes: 65_536,
            zeroProbeBytes: 4_096,
            safetyMarginBytes: 1_048_576,
            minimumReclaimBytes: minimumReclaimBytes,
            allowSparseCopyFallback: allowSparseCopyFallback
        )
    }

    private func fence() -> StorageSparseDiskMaintenanceFence {
        StorageSparseDiskMaintenanceFence(leaseID: "lease-test", generation: 9) {}
    }

    @discardableResult
    private func perform(
        _ request: StorageSparseDiskRewriteRequest,
        hooks: StorageSparseDiskRewrite.TestHooks = StorageSparseDiskRewrite.TestHooks(),
        isCancelled: @escaping @Sendable () -> Bool = { false },
        progress: (@Sendable (StorageSparseDiskRewriteProgress) -> Void)? = nil
    ) throws -> StorageSparseDiskRewriteReport {
        try StorageSparseDiskRewrite._rewrite(
            request,
            fence: fence(),
            hooks: hooks,
            isCancelled: isCancelled,
            progress: progress
        )
    }

    private func recover(
        directory: URL,
        name: String,
        jobID: String,
        hooks: StorageSparseDiskRewriteRecovery.TestHooks? = nil
    ) throws -> StorageSparseDiskRecoveryReport {
        if let hooks {
            return try StorageSparseDiskRewriteRecovery.recover(
                rootURL: directory, relativePath: name,
                journalDirectoryURL: directory.appendingPathComponent("journal", isDirectory: true),
                jobID: jobID, fence: fence(), isCancelled: { false }, hooks: hooks
            )
        }
        return try StorageSparseDiskRewrite.recover(
            rootURL: directory,
            relativePath: name,
            journalDirectoryURL: directory.appendingPathComponent("journal", isDirectory: true),
            jobID: jobID,
            fence: fence(),
            isCancelled: { false }
        )
    }

    private func metadata(at url: URL) throws -> StorageSparseDiskMetadataSnapshot {
        let fd = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW) }
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { _ = Darwin.close(fd) }
        return try StorageSparseDiskPOSIX.captureMetadata(fd: fd)
    }

    private func corruptDataPreservingStableIdentity(
        at url: URL, expected: StorageSparseDiskIdentity
    ) throws {
        let fd = url.path.withCString { open($0, O_RDWR | O_NOFOLLOW) }
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { _ = Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw POSIXError(.EIO) }
        try write(Data([0x7F]), to: fd, at: 0)
        var times = [
            info.st_atimespec,
            timespec(tv_sec: time_t(expected.modificationSeconds),
                     tv_nsec: Int(expected.modificationNanoseconds)),
        ]
        let result = times.withUnsafeBufferPointer { futimens(fd, $0.baseAddress) }
        guard result == 0, fsync(fd) == 0 else { throw POSIXError(.EIO) }
        guard try StorageSparseDiskPOSIX.identity(of: fd).matchesStable(expected) else {
            throw StorageSparseDiskRewriteError.injectedFailure("corruption-fixture-identity")
        }
    }

    private func readJournal(
        directory: URL,
        jobID: String
    ) throws -> StorageSparseDiskRewriteJournalRecord {
        let data = try Data(
            contentsOf: directory.appendingPathComponent("journal/\(jobID).json")
        )
        return try JSONDecoder().decode(StorageSparseDiskRewriteJournalRecord.self, from: data)
    }

    private func stageNames(in directory: URL) throws -> [String] {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        return names.filter { name in
            name.hasPrefix(".") && name.contains(".sparse-") && name.hasSuffix(".stage")
        }
    }

    private func setTestXattr(_ url: URL, name: String, value: Data) throws {
        let result: Int32 = url.path.withCString { path in
            name.withCString { namePointer in
                value.withUnsafeBytes { raw in
                    setxattr(path, namePointer, raw.baseAddress, raw.count, 0, 0)
                }
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func getTestXattr(_ url: URL, name: String) throws -> Data? {
        let size: Int = url.path.withCString { path in
            name.withCString { namePointer in
                getxattr(path, namePointer, nil, 0, 0, 0)
            }
        }
        if size < 0 {
            if errno == ENOATTR { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if size == 0 { return Data() }
        var data = Data(count: size)
        let actual: Int = url.path.withCString { path in
            name.withCString { namePointer in
                data.withUnsafeMutableBytes { raw in
                    getxattr(path, namePointer, raw.baseAddress, raw.count, 0, 0)
                }
            }
        }
        guard actual == size else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return data
    }
}
