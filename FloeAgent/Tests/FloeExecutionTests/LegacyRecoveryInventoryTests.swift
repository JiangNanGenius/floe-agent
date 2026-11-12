import Foundation
import Testing
import FloeCore
@testable import FloeExecution

#if canImport(Darwin)
import Darwin
@Suite struct LegacyRecoveryInventoryTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let baseA = String(repeating: "a", count: 128)
    private static let baseB = String(repeating: "b", count: 128)

    private final class Fixture {
        let root: URL
        init(parent: URL? = nil) throws {
            let candidate = (parent ?? FileManager.default.temporaryDirectory)
                .appendingPathComponent("legacy-inventory-fixture-" + UUID().uuidString, isDirectory: true)
            // A UUID leaf does not exist yet. Create our owned directory first,
            // then ask POSIX for its actual existing canonical path; resolving
            // a Foundation URL before creation is not this contract.
            try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
            do { root = try Self.canonicalExistingDirectory(candidate) }
            catch {
                try? FileManager.default.removeItem(at: candidate)
                throw error
            }
            for relative in ["recovery/quarantine", "runtime/vm", "environments", "foreign"] {
                try FileManager.default.createDirectory(at: root.appendingPathComponent(relative),
                    withIntermediateDirectories: true)
            }
        }
        static func canonicalExistingDirectory(_ url: URL) throws -> URL {
            guard let resolved = url.path.withCString({ realpath($0, nil) }) else {
                let code = errno
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            defer { free(resolved) }
            return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
        func json(_ value: [String: Any], at url: URL) throws {
            try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url)
        }
        struct Entry {
            let environment: String
            let runtime: String
            let relative: String
            let directory: URL
            let disk: URL
            let runtimeMetadata: URL
            let environmentMetadata: URL
            let marker: URL
            let generation: URL
        }
        func entry(environment: String = "env-a", runtime: String = "rt-env-a",
                   holdPath: String? = nil, bootDigest: String = LegacyRecoveryInventoryTests.baseA,
                   environmentDigest: String = LegacyRecoveryInventoryTests.baseA) throws -> Entry {
            let relative = "recovery/quarantine/runtime-vm-" + runtime + "-" + UUID().uuidString
            let directory = root.appendingPathComponent(relative, isDirectory: true)
            let environmentDirectory = root.appendingPathComponent("environments/" + environment, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: environmentDirectory.appendingPathComponent("data"),
                withIntermediateDirectories: true)
            let disk = directory.appendingPathComponent("disk.img")
            try Data(repeating: 0xA5, count: 4096).write(to: disk)
            let handle = try FileHandle(forWritingTo: disk)
            try handle.truncate(atOffset: 1_048_576)
            try handle.close()
            let runtimeMetadata = directory.appendingPathComponent("runtime.json")
            try json(["version": 1, "runtimeID": runtime, "environmentID": environment,
                "baseImageID": "synthetic-base", "bootBaseDiskDigest": bootDigest,
                "credential": "DO-NOT-EXPORT-CREDENTIAL"], at: runtimeMetadata)
            let environmentMetadata = environmentDirectory.appendingPathComponent("metadata.json")
            try json(["version": 1, "environmentID": environment, "baseImageID": "synthetic-base",
                "baseRootfsSHA512": environmentDigest, "name": "DO-NOT-EXPORT-NAME"], at: environmentMetadata)
            let marker = environmentDirectory.appendingPathComponent("repair-hold.json")
            try json(["version": 2, "environmentID": environment, "runtimeID": runtime,
                "holdID": UUID().uuidString, "preservedPath": holdPath ?? relative,
                "reason": "DO-NOT-EXPORT-REASON"], at: marker)
            let generation = environmentDirectory.appendingPathComponent("repair-hold.generation")
            try Data("7\n".utf8).write(to: generation)
            try Data("DO-NOT-READ-USER-DATA".utf8).write(
                to: environmentDirectory.appendingPathComponent("data/untouched.txt"))
            return Entry(environment: environment, runtime: runtime, relative: relative, directory: directory,
                disk: disk, runtimeMetadata: runtimeMetadata, environmentMetadata: environmentMetadata,
                marker: marker, generation: generation)
        }
        func references(complete: Bool = true, referenced: Set<String> = [], active: Set<String> = [],
                        capturedAt: Date = LegacyRecoveryInventoryTests.now) -> LegacyRecoveryReferenceSnapshot {
            .init(capturedAt: capturedAt, isComplete: complete,
                referencedEnvironmentIDs: referenced, activeEnvironmentIDs: active)
        }
        func scan(references: LegacyRecoveryReferenceSnapshot?, limits: LegacyRecoveryInventoryLimits = .init(),
                  seams: LegacyRecoveryInventorySeams = LegacyRecoveryInventoryTests.seams()) -> LegacyRecoveryInventoryReport {
            LegacyRecoveryInventory.scan(.init(legacyRoot: root, currentReferences: references, limits: limits), seams: seams)
        }
    }

    private static func seams() -> LegacyRecoveryInventorySeams {
        .init(monotonicNow: { 0 }, wallNow: { LegacyRecoveryInventoryTests.now },
            isCancelled: { false }, cloneAttributes: { _ in .unsupported })
    }

    @Test func exactIdentityAndBoundedMetadataAreObservedWithoutDiskContent() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let entry = try fixture.entry()
        let originalMarker = try Data(contentsOf: entry.marker)
        let report = fixture.scan(references: fixture.references())
        let record = try #require(report.records.first,
            "root diagnostic: \(String(describing: report.rootDiagnostic)); stop reasons: \(report.stopReasons)")
        #expect(report.diskContentBytesRead == 0)
        #expect(report.sidecarBytesRead > 0)
        #expect(record.reviewSnapshot.diskIdentity?.logicalBytes == 1_048_576)
        #expect((record.reviewSnapshot.diskIdentity?.inode ?? 0) > 0)
        #expect(record.reviewSnapshot.diskIdentity?.linkCount == 1)
        #expect(record.reviewSnapshot.observedRepairGeneration == 7)
        #expect(record.reviewSnapshot.repairGeneration.sha256 != nil)
        #expect(record.holdPathState == .exactPhysicalLocation)
        #expect(record.hasRecognizedPhysicalEvidence)
        #expect(record.mustPreserveRepairEvidence)
        #expect(record.isReviewableForBytePreservingMaintenance)
        #expect(!record.authorizesMutation)
        #expect(!record.permitsRecaptureAgainstCurrentBase)
        #expect(record.privateBytes == nil)
        #expect(report.summary.privateUnknownCount == 1)
        #expect(try Data(contentsOf: entry.marker) == originalMarker)
        let encoded = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        #expect(!encoded.contains("DO-NOT-EXPORT"))
        #expect(!encoded.contains("DO-NOT-READ"))
        let ordinary = String(decoding: try JSONEncoder().encode(report.summary), as: UTF8.self)
        #expect(!ordinary.contains(entry.environment))
        #expect(!ordinary.contains(entry.runtime))
        #expect(!ordinary.contains("relativeDirectory"))
    }

    @Test func mismatchedRuntimeIdentityIsNeverEligible() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let entry = try fixture.entry()
        try fixture.json(["version": 1, "runtimeID": "rt-other", "environmentID": entry.environment,
            "baseImageID": "synthetic-base", "bootBaseDiskDigest": Self.baseA], at: entry.runtimeMetadata)
        let record = try #require(fixture.scan(references: fixture.references()).records.first)
        #expect(!record.runtimeIdentityMatchesDirectory)
        #expect(record.planningBlockers.contains(.runtimeIdentityMismatch))
        #expect(record.mustPreserveRepairEvidence)
        #expect(!record.authorizesMutation)
    }

    @Test func mismatchedEnvironmentAndMarkerIdentitiesStayVisible() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let entry = try fixture.entry()
        try fixture.json(["version": 1, "environmentID": "env-other", "baseImageID": "synthetic-base",
            "baseRootfsSHA512": Self.baseA], at: entry.environmentMetadata)
        try fixture.json(["version": 2, "environmentID": "env-other", "runtimeID": entry.runtime,
            "holdID": UUID().uuidString, "preservedPath": entry.relative], at: entry.marker)
        let record = try #require(fixture.scan(references: fixture.references()).records.first)
        #expect(record.planningBlockers.contains(.environmentIdentityMismatch))
        #expect(record.planningBlockers.contains(.repairIdentityMismatch))
        #expect(record.hasRecognizedPhysicalEvidence)
        #expect(!record.isReviewableForBytePreservingMaintenance)
    }

    @Test func staleMarkerStillShowsMatchingQuarantineEvidenceWithoutRewriting() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let entry = try fixture.entry(holdPath: "runtime/vm/rt-env-a")
        let marker = try Data(contentsOf: entry.marker)
        let report = fixture.scan(references: fixture.references())
        let record = try #require(report.records.first)
        #expect(record.hasRecognizedPhysicalEvidence)
        #expect(record.repairIdentityMatches == true)
        #expect(record.recordedPreservedDirectory == "runtime/vm/rt-env-a")
        #expect(record.holdPathState == .differentLocationMissingDisk)
        #expect(record.mustPreserveRepairEvidence)
        #expect(!record.repairAcknowledgementsInspected)
        #expect(report.summary.differentHoldLocationCount == 1)
        #expect(try Data(contentsOf: entry.marker) == marker)
        #expect(!record.authorizesMutation)
    }

    @Test func baseDriftCannotBecomePermissionToRecapture() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        _ = try fixture.entry(bootDigest: Self.baseA, environmentDigest: Self.baseB)
        let report = fixture.scan(references: fixture.references())
        let record = try #require(report.records.first)
        #expect(record.baseComparison == .differs)
        #expect(record.recordedBootBaseDigest == Self.baseA)
        #expect(record.environmentBaseDigest == Self.baseB)
        #expect(report.summary.baseDriftCount == 1)
        #expect(record.mustPreserveRepairEvidence)
        #expect(!record.permitsRecaptureAgainstCurrentBase)
        #expect(!record.authorizesMutation)
    }

    @Test func pinnedTemplateDoesNotMistakeContentDigestForRootfsDigest() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let entry = try fixture.entry()
        try fixture.json(["version": 1, "runtimeID": entry.runtime, "environmentID": entry.environment,
            "baseImageID": "synthetic-base", "bootBaseDiskDigest": Self.baseB,
            "templateID": "template-a", "templateVersion": 1, "templateDigest": Self.baseA], at: entry.runtimeMetadata)
        try fixture.json(["version": 1, "environmentID": entry.environment, "baseImageID": "synthetic-base",
            "baseRootfsSHA512": Self.baseA, "templateID": "template-a", "templateVersion": 1,
            "templateDigest": Self.baseA], at: entry.environmentMetadata)
        let record = try #require(fixture.scan(references: fixture.references()).records.first)
        #expect(record.recordedTemplateID == "template-a")
        #expect(record.baseComparison == .unknown)
        #expect(!record.permitsRecaptureAgainstCurrentBase)
    }

    @Test func traversalMarkerIsRejectedWhilePhysicalEvidenceIsPreserved() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        _ = try fixture.entry(holdPath: "../../foreign")
        let record = try #require(fixture.scan(references: fixture.references()).records.first)
        #expect(record.holdPathState == .unsafe)
        #expect(record.planningBlockers.contains(.unsafeRepairPath))
        #expect(record.hasRecognizedPhysicalEvidence)
        #expect(record.mustPreserveRepairEvidence)
    }

    @Test func symlinkDiskIsNotFollowed() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let entry = try fixture.entry()
        let foreign = fixture.root.appendingPathComponent("foreign/private.img")
        let canary = Data("FOREIGN-CONTENT".utf8)
        try canary.write(to: foreign)
        try FileManager.default.removeItem(at: entry.disk)
        try FileManager.default.createSymbolicLink(at: entry.disk, withDestinationURL: foreign)
        let report = fixture.scan(references: fixture.references())
        let record = try #require(report.records.first)
        #expect(record.diskState == .symlinkOrUnsafePath)
        #expect(record.reviewSnapshot.diskIdentity == nil)
        #expect(!record.hasRecognizedPhysicalEvidence)
        #expect(report.diskContentBytesRead == 0)
        #expect(try Data(contentsOf: foreign) == canary)
    }

    @Test func symlinkRuntimeSidecarIsNotDecoded() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let entry = try fixture.entry()
        let foreign = fixture.root.appendingPathComponent("foreign/runtime.json")
        try fixture.json(["credential": "FOREIGN-CREDENTIAL"], at: foreign)
        try FileManager.default.removeItem(at: entry.runtimeMetadata)
        try FileManager.default.createSymbolicLink(at: entry.runtimeMetadata, withDestinationURL: foreign)
        let report = fixture.scan(references: fixture.references())
        let record = try #require(report.records.first)
        #expect(record.reviewSnapshot.runtimeMetadata.state == .symlinkOrUnsafePath)
        #expect(record.environmentID == nil)
        #expect(!String(decoding: try JSONEncoder().encode(report), as: UTF8.self).contains("FOREIGN-CREDENTIAL"))
    }

    @Test func symlinkRecoveryDirectoryIsNotTraversed() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let entry = try fixture.entry()
        let target = fixture.root.appendingPathComponent("foreign/real-entry", isDirectory: true)
        try FileManager.default.moveItem(at: entry.directory, to: target)
        try FileManager.default.createSymbolicLink(at: entry.directory, withDestinationURL: target)
        let record = try #require(fixture.scan(references: fixture.references()).records.first)
        #expect(record.planningBlockers.contains(.unsupportedDirectory))
        #expect(record.reviewSnapshot.diskIdentity == nil)
        #expect(!record.isReviewableForBytePreservingMaintenance)
    }

    @Test func oversizedSidecarIsStatOnlyAndNeverRead() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let entry = try fixture.entry()
        try Data(repeating: 0x41, count: 65_537).write(to: entry.runtimeMetadata)
        let report = fixture.scan(references: fixture.references())
        let record = try #require(report.records.first)
        #expect(record.reviewSnapshot.runtimeMetadata.state == .tooLarge)
        #expect(report.sidecarBytesRead == 0)
        #expect(record.environmentID == nil)
        #expect(record.planningBlockers.contains(.runtimeMetadataUnavailable))
    }

    @Test func entryAndSidecarByteBudgetsAreExplicitlyPartial() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        for index in 0..<3 { _ = try fixture.entry(environment: "env-\(index)", runtime: "rt-env-\(index)") }
        let entries = fixture.scan(references: fixture.references(), limits: .init(maximumDirectoryEntries: 1))
        #expect(entries.summary.isPartial)
        #expect(entries.directoryEntriesVisited <= 1)
        #expect(entries.stopReasons.contains("entryBudget"))
        #expect(entries.records.allSatisfy { $0.planningBlockers.contains(.inventoryIncomplete) })
        let bytes = fixture.scan(references: fixture.references(), limits: .init(maximumTotalSidecarBytes: 64))
        #expect(bytes.summary.isPartial)
        #expect(bytes.sidecarBytesRead <= 64)
        #expect(bytes.stopReasons.contains("sidecarByteBudget"))
    }

    @Test func recordAndReadAttemptCapsAlsoWithholdPlanningEligibility() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        for index in 0..<3 { _ = try fixture.entry(environment: "env-\(index)", runtime: "rt-env-\(index)") }
        let records = fixture.scan(references: fixture.references(), limits: .init(maximumRecords: 1))
        #expect(records.records.count <= 1)
        #expect(records.stopReasons.contains("recordBudget"))
        #expect(records.records.allSatisfy { !$0.isReviewableForBytePreservingMaintenance })
        let reads = fixture.scan(references: fixture.references(), limits: .init(maximumSidecarReads: 1))
        #expect(reads.sidecarReadsAttempted <= 1)
        #expect(reads.stopReasons.contains("sidecarReadBudget"))
        #expect(reads.records.allSatisfy { !$0.isReviewableForBytePreservingMaintenance })
    }

    private final class Ticks: @unchecked Sendable {
        let lock = NSLock()
        var value = 0.0
        func next() -> Double {
            lock.lock(); defer { lock.unlock() }
            value += 0.01; return value
        }
    }
    @Test func timeAndCancellationBudgetsDoNotReportEmptySuccess() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        _ = try fixture.entry()
        let ticks = Ticks()
        var timedSeams = Self.seams(); timedSeams.monotonicNow = { ticks.next() }
        let timed = fixture.scan(references: fixture.references(), limits: .init(maximumDuration: 0.001), seams: timedSeams)
        #expect(timed.summary.isPartial)
        #expect(timed.stopReasons.contains("timeBudget"))
        var cancelled = Self.seams(); cancelled.isCancelled = { true }
        let stopped = fixture.scan(references: fixture.references(), seams: cancelled)
        #expect(stopped.summary.isPartial)
        #expect(stopped.stopReasons.contains("cancelled"))
    }

    @Test func absentIncompleteExpiredAndFutureReferenceSnapshotsStayUnknown() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        _ = try fixture.entry()
        let snapshots: [LegacyRecoveryReferenceSnapshot?] = [
            nil, fixture.references(complete: false),
            fixture.references(capturedAt: Self.now.addingTimeInterval(-120)),
            fixture.references(capturedAt: Self.now.addingTimeInterval(120))
        ]
        for snapshot in snapshots {
            let record = try #require(fixture.scan(references: snapshot).records.first)
            #expect(record.currentReferenceState == .unknown)
            #expect(record.planningBlockers.contains(.currentReferencesUnknown))
            #expect(!record.isReviewableForBytePreservingMaintenance)
            #expect(record.mustPreserveRepairEvidence)
        }
    }

    @Test func positiveActiveAndCurrentReferencesAlwaysProtect() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let entry = try fixture.entry()
        let active = try #require(fixture.scan(references: fixture.references(
            complete: false, active: [entry.environment.uppercased()])).records.first)
        #expect(active.currentReferenceState == .active)
        #expect(active.planningBlockers.contains(.currentReferenceActive))
        let referenced = try #require(fixture.scan(references: fixture.references(
            referenced: [entry.environment])).records.first)
        #expect(referenced.currentReferenceState == .referenced)
        #expect(referenced.planningBlockers.contains(.currentReferenceExists))
        #expect(!active.isReviewableForBytePreservingMaintenance)
        #expect(!referenced.isReviewableForBytePreservingMaintenance)
    }

    @Test func hardlinkIsObservedAndBlocksByteReplacementPlanning() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let entry = try fixture.entry()
        try FileManager.default.linkItem(at: entry.disk, to: fixture.root.appendingPathComponent("foreign/alias.img"))
        let report = fixture.scan(references: fixture.references())
        let record = try #require(report.records.first)
        #expect(record.reviewSnapshot.diskIdentity?.linkCount == 2)
        #expect(record.planningBlockers.contains(.linkedDisk))
        #expect(report.summary.linkedDiskCount == 1)
        #expect(!record.isReviewableForBytePreservingMaintenance)
    }

    @Test func malformedGenerationRemainsAnUnknownGuard() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let entry = try fixture.entry()
        try Data("not-a-generation".utf8).write(to: entry.generation)
        let record = try #require(fixture.scan(references: fixture.references()).records.first)
        #expect(record.reviewSnapshot.repairGeneration.state == .malformed)
        #expect(record.reviewSnapshot.observedRepairGeneration == nil)
        #expect(record.planningBlockers.contains(.generationUnmeasured))
    }

    @Test func replacingPathDuringMetadataQueryIsDetected() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let entry = try fixture.entry()
        let path = entry.disk
        var seams = Self.seams()
        seams.cloneAttributes = { _ in
            // Test-only mutation: replace the path while the reader still owns
            // the old FD. An fstat-only check would miss this inode swap.
            try? Data(repeating: 0xCC, count: 4096).write(to: path, options: .atomic)
            return .attributes(StorageCloneAttributes(privateBytes: 4096, cloneID: 1,
                extendedFlags: 0, cloneRefCount: 1))
        }
        let record = try #require(fixture.scan(references: fixture.references(), seams: seams).records.first)
        #expect(record.diskState == .changedDuringRead)
        #expect(record.privateBytes == nil)
        #expect(record.planningBlockers.contains(.diskChanged))
        #expect(!record.isReviewableForBytePreservingMaintenance)
    }

    @Test func descriptorCloneQueryAgreesWithExistingPathReaderOnSameFixtureInode() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let entry = try fixture.entry()
        let descriptor = open(entry.disk.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        #expect(descriptor >= 0)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        let byDescriptor = StorageCloneAttributesReader.read(descriptor: descriptor)
        let byPath = StorageCloneAttributesReader.read(path: entry.disk.path)
        switch (byDescriptor, byPath) {
        case (.attributes(let first), .attributes(let second)): #expect(first == second)
        case (.unsupported, .unsupported): break // Both measured APIs report unavailable support.
        default: Issue.record("Descriptor/path clone metadata did not agree on the same fixture inode")
        }
    }

    @Test func fixtureCreatesItsOwnedLeafBeforePOSIXCanonicalization() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: fixture.root.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        let canonical = try Fixture.canonicalExistingDirectory(fixture.root)
        #expect(canonical.path == fixture.root.path)
        _ = try fixture.entry()
        let report = fixture.scan(references: fixture.references())
        #expect(report.rootDiagnostic == nil)
        #expect(report.rootIdentity != nil)
        #expect(report.records.count == 1)
    }

    @Test func trustedRootAncestorAliasIsCanonicalizedBeforeNoFollowWalk() throws {
        let parent = try Fixture(); defer { parent.cleanup() }
        let target = parent.root.appendingPathComponent("foreign", isDirectory: true)
        let alias = parent.root.appendingPathComponent("trusted-parent-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let child = try Fixture(parent: alias); defer { child.cleanup() }
        _ = try child.entry()
        // The service explicitly authorizes this existing root. The alias is
        // ABOVE that root, not a sidecar-controlled child of the root.
        let authorizedAlias = alias.appendingPathComponent(child.root.lastPathComponent, isDirectory: true)
        let report = LegacyRecoveryInventory.scan(.init(legacyRoot: authorizedAlias,
            currentReferences: child.references()), seams: Self.seams())
        #expect(report.rootDiagnostic == nil)
        #expect(report.rootIdentity != nil)
        #expect(report.records.count == 1)
        #expect(report.records.first?.hasRecognizedPhysicalEvidence == true)
    }

    @Test func missingTrustedRootReportsFirstPOSIXCanonicalizationError() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let missing = fixture.root.appendingPathComponent("missing-do-not-create", isDirectory: true)
        let report = LegacyRecoveryInventory.scan(.init(legacyRoot: missing,
            currentReferences: fixture.references()), seams: Self.seams())
        #expect(report.stopReasons.contains("rootUnavailable"))
        #expect(report.rootDiagnostic?.stage == .posixCanonicalization)
        #expect(report.rootDiagnostic?.posixErrno == ENOENT)
        #expect(report.rootIdentity == nil)
        #expect(report.records.isEmpty)
        #expect(report.summary.isPartial)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test func embeddedNULRootIsRejectedBeforeCStringTruncation() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        _ = try fixture.entry()
        let raw = fixture.root.path + "\0not-the-authorized-root"
        #expect(raw.utf8.contains(0))
        let invalid = URL(fileURLWithPath: raw, isDirectory: true)
        // Foundation may normalize the NUL before the reader receives a URL.
        // In either representation it must not truncate to the valid root.
        #expect(invalid.path != fixture.root.path)
        let report = LegacyRecoveryInventory.scan(.init(legacyRoot: invalid,
            currentReferences: fixture.references()), seams: Self.seams())
        #expect(report.stopReasons.contains("rootUnavailable"))
        if invalid.path.utf8.contains(0) {
            #expect(report.rootDiagnostic?.stage == .inputValidation)
            #expect(report.rootDiagnostic?.posixErrno == EINVAL)
        } else {
            #expect(report.rootDiagnostic?.stage == .posixCanonicalization)
            #expect(report.rootDiagnostic?.posixErrno == ENOENT)
        }
        #expect(report.records.isEmpty)
        #expect(report.summary.isPartial)
    }

    @Test func fileInsteadOfRootReportsFirstComponentOpenError() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let file = fixture.root.appendingPathComponent("foreign/not-a-directory")
        try Data([0x01]).write(to: file)
        let report = LegacyRecoveryInventory.scan(.init(legacyRoot: file,
            currentReferences: fixture.references()), seams: Self.seams())
        #expect(report.stopReasons.contains("rootUnavailable"))
        #expect(report.rootDiagnostic?.stage == .componentOpen)
        #expect(report.rootDiagnostic?.posixErrno == ENOTDIR)
        #expect(report.rootDiagnostic?.componentIndex != nil)
        #expect(report.records.isEmpty)
        #expect(report.summary.isPartial)
    }

    @Test func controlledQuarantineParentSymlinkIsStillRefused() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        _ = try fixture.entry()
        let controlled = fixture.root.appendingPathComponent("recovery/quarantine", isDirectory: true)
        let moved = fixture.root.appendingPathComponent("foreign/quarantine", isDirectory: true)
        try FileManager.default.moveItem(at: controlled, to: moved)
        try FileManager.default.createSymbolicLink(at: controlled, withDestinationURL: moved)
        let report = fixture.scan(references: fixture.references())
        #expect(report.rootIdentity != nil)
        #expect(report.rootDiagnostic == nil)
        #expect(report.stopReasons.contains("supportedParentUnavailable"))
        #expect(report.summary.isPartial)
        #expect(report.records.isEmpty)
        #expect(report.diskContentBytesRead == 0)
    }
}
#endif
