// SPDX-License-Identifier: MPL-2.0
//
// G04 archive document bridge tests (authored, NOT RUN in this source lane).
//
// These suites pin the contract that Main's unified qualification executes
// against the real compiled core:
//   * the closed wire identity and envelope guards (version, size, owner,
//     path, destination) refuse malformed input before any lease exists;
//   * RAR and unknown formats fail CLOSED with the truthful original reason
//     before the workspace authority is touched (no fake success, no
//     decoder download, no silent downgrade);
//   * the long-running operation registry gives real cancellation (the
//     derived token the engine polls trips) and honest progress snapshots;
//   * the preview staging session is reused across entry selections and is
//     removed exactly once on discard;
//   * the engine's bounded summary line is the extraction receipt.
// Operations that require an installed composition (listing/extract against
// the real workspace lease) are qualified by Main's build; the guards above
// are what keep a malformed or stale request from ever reaching it.

import Foundation
import Testing
import FloeTools
import FloeWorkspace
@testable import FloeAndroidCore

private func g04Request(_ fields: [String: Any]) -> Data {
    var value = fields
    value["version"] = G04ArchiveWire.version
    value["requestID"] = "test-request"
    return try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
}

private func g04Response(_ data: Data) -> [String: Any] {
    (try! JSONSerialization.jsonObject(with: data)) as! [String: Any]
}

private let g04Owner: [String: Any] = [
    "taskID": UUID().uuidString,
    "workspaceID": UUID().uuidString,
    "nativeEpoch": 1,
    "hostGeneration": 1,
]

struct G04ArchiveWireTests {
    @Test func wireIdentityIsClosedAndAdditive() {
        #expect(G04ArchiveWire.version == 25)
        #expect(G04ArchiveWire.schema == "floe.archive/25")
        #expect(BridgeV25.version == 25)
        #expect(G04ArchiveWire.maximumRequestBytes == 65_536)
        #expect(G04ArchiveWire.maximumResponseBytes == 65_536)
        #expect(G04ArchiveWire.maximumPreviewBytes < G04ArchiveWire.maximumResponseBytes)
        #expect(G04ArchiveWire.maximumPreviewFileBytes == 1024 * 1024)
        for operation in [
            "handshake", "g04.archive.listing", "g04.archive.extract",
            "g04.archive.decompress", "g04.archive.previewEntry",
            "g04.archive.previewDiscard", "g04.archive.progress", "g04.archive.cancel",
        ] {
            #expect(G04ArchiveWire.operations.contains(operation))
        }
    }

    @Test func handshakeReportsCapabilitiesTruthfully() {
        let response = g04Response(g04Request(["operation": "handshake"]))
        #expect(response["ok"] as? Bool == true)
        #expect(response["schema"] as? String == "floe.archive/25")
        #expect(response["version"] as? Int == 25)
        let formats = response["nativeFormats"] as? [String] ?? []
        #expect(Set(formats) == ArchiveBrowserService.nativeFormats)
        #expect(formats.contains("zip") && formats.contains("tar") && formats.contains("7z"))
        let single = response["singleFileFormats"] as? [String] ?? []
        #expect(Set(single) == ArchiveBrowserService.singleFileFormats)
        let rar = response["rar"] as? [String: Any]
        #expect(rar?["supported"] as? Bool == false)
        #expect((rar?["reason"] as? String)?.isEmpty == false)
    }
}

struct G04ArchiveEnvelopeTests {
    @Test func wrongVersionFailsClosed() {
        let data = try! JSONSerialization.data(withJSONObject: [
            "version": 24, "operation": "handshake", "requestID": "x",
        ])
        let response = G04ArchiveBridge.handle(requestData: data, fallbackRequestID: "x")
        #expect(response["ok"] as? Bool == false)
        #expect(response["code"] as? String == "invalidRequest")
    }

    @Test func oversizedRequestFailsClosed() {
        let blob = String(repeating: "a", count: G04ArchiveWire.maximumRequestBytes)
        let response = g04Response(g04Request(["operation": "handshake", "echo": blob]))
        #expect(response["ok"] as? Bool == false)
        #expect(response["code"] as? String == "requestTooLarge")
    }

    @Test func unknownOperationFailsClosed() {
        let response = g04Response(g04Request(["operation": "g04.archive.wipe"]))
        #expect(response["ok"] as? Bool == false)
        #expect(response["code"] as? String == "unsupportedOperation")
    }

    @Test func missingOwnerFailsBeforeAnyLease() {
        let response = g04Response(g04Request([
            "operation": "g04.archive.listing",
            "relativePath": "docs/a.zip",
        ]))
        #expect(response["ok"] as? Bool == false)
        #expect(response["code"] as? String == "invalidOwner")
    }

    @Test func zeroEpochOwnerFailsClosed() {
        var owner = g04Owner
        owner["nativeEpoch"] = 0
        let response = g04Response(g04Request([
            "operation": "g04.archive.listing",
            "owner": owner,
            "relativePath": "docs/a.zip",
        ]))
        #expect(response["ok"] as? Bool == false)
        #expect(response["code"] as? String == "invalidOwner")
    }

    @Test func absoluteAndTraversalPathsFailBeforeAnyLease() {
        for path in ["/etc/passwd", "~/secrets", "a/../../b.zip", "..", "a/./b/../c.zip"] {
            let response = g04Response(g04Request([
                "operation": "g04.archive.listing",
                "owner": g04Owner,
                "relativePath": path,
            ]))
            #expect(response["ok"] as? Bool == false, path)
            #expect(response["code"] as? String == "invalidPath", path)
        }
    }

    @Test func emptyPathComponentsStayInsideTheWorkspace() {
        // `a//b.zip` is workspace-relative; the guard accepts it and the
        // engine's own path policy (standardization + the workspace guard)
        // stays the single authority for normalization.
        let accepted = try! G04ArchiveBridge.relativePath("a//b.zip", error: .invalidPath)
        #expect(accepted == "a//b.zip")
    }

    @Test func controlCharactersInPathsFailClosed() {
        let response = g04Response(g04Request([
            "operation": "g04.archive.listing",
            "owner": g04Owner,
            "relativePath": "docs/a\u{0}.zip",
        ]))
        #expect(response["ok"] as? Bool == false)
        #expect(response["code"] as? String == "invalidPath")
    }

    @Test func rarReportsTheTruthfulOriginalReasonWithoutTouchingTheAuthority() {
        // No composition is installed in this test host: a request that
        // reached the lease would fail `retired`. The format preflight must
        // refuse first, with the original honest reason.
        let response = g04Response(g04Request([
            "operation": "g04.archive.listing",
            "owner": g04Owner,
            "relativePath": "docs/report.rar",
        ]))
        #expect(response["ok"] as? Bool == false)
        #expect(response["code"] as? String == "unsupportedFormat")
        let detail = response["detail"] as? String ?? ""
        #expect(detail.contains("signed decoder"))
    }

    @Test func unknownExtensionFailsClosedBeforeAnyLease() {
        let response = g04Response(g04Request([
            "operation": "g04.archive.listing",
            "owner": g04Owner,
            "relativePath": "docs/program.exe",
        ]))
        #expect(response["ok"] as? Bool == false)
        #expect(response["code"] as? String == "unsupportedFormat")
    }

    @Test func singleFileExtractionPreflightIsRefused() {
        // `extract` only accepts containers; a gzip payload must be refused
        // before the lease, not staged as a folder.
        let response = g04Response(g04Request([
            "operation": "g04.archive.extract",
            "owner": g04Owner,
            "relativePath": "docs/log.gz",
            "destinationDir": "out",
            "operationID": UUID().uuidString,
        ]))
        #expect(response["ok"] as? Bool == false)
        #expect(response["code"] as? String == "unsupportedFormat")
    }

    @Test func containerDecompressionPreflightIsRefused() {
        let response = g04Response(g04Request([
            "operation": "g04.archive.decompress",
            "owner": g04Owner,
            "relativePath": "docs/bundle.zip",
            "destinationFile": "out/file",
            "operationID": UUID().uuidString,
        ]))
        #expect(response["ok"] as? Bool == false)
        #expect(response["code"] as? String == "unsupportedFormat")
    }

    @Test func malformedOperationIDFailsClosed() {
        let response = g04Response(g04Request([
            "operation": "g04.archive.progress",
            "operationID": "not-a-uuid",
        ]))
        #expect(response["ok"] as? Bool == false)
        #expect(response["code"] as? String == "invalidOperationID")
    }

    @Test func progressForUnknownOperationFailsClosed() {
        let response = g04Response(g04Request([
            "operation": "g04.archive.progress",
            "operationID": UUID().uuidString,
        ]))
        #expect(response["ok"] as? Bool == false)
        #expect(response["code"] as? String == "invalidOperationID")
    }
}

struct G04ArchiveOperationRegistryTests {
    @Test func cancellationTripsTheDerivedTokenTheEnginePolls() {
        let registry = G04ArchiveOperationRegistry()
        let owner = try! G04ArchiveOwner(
            taskID: UUID(), workspaceID: UUID(), nativeEpoch: 1, hostGeneration: 1)
        let parent = CancellationToken()
        let id = UUID()
        let token = registry.begin(owner: owner, operationID: id, parent: parent)
        #expect(!token.isCancelled)
        #expect(registry.snapshot(id)?.cancelled == false)
        #expect(registry.cancel(id))
        #expect(token.isCancelled)
        #expect(registry.snapshot(id)?.cancelled == true)
        // The parent lease token stays live: UI cancel must not tear the
        // workspace lease itself, only this operation.
        #expect(!parent.isCancelled)
        registry.end(id)
        #expect(registry.snapshot(id) == nil)
        #expect(!registry.cancel(id))
    }

    @Test func parentCancellationPropagatesToTheOperationToken() {
        let registry = G04ArchiveOperationRegistry()
        let owner = try! G04ArchiveOwner(
            taskID: UUID(), workspaceID: UUID(), nativeEpoch: 1, hostGeneration: 1)
        let parent = CancellationToken()
        let id = UUID()
        let token = registry.begin(owner: owner, operationID: id, parent: parent)
        parent.cancel()
        #expect(token.isCancelled)
    }

    @Test func progressSnapshotsStayBoundedAndHonest() {
        let registry = G04ArchiveOperationRegistry()
        let owner = try! G04ArchiveOwner(
            taskID: UUID(), workspaceID: UUID(), nativeEpoch: 1, hostGeneration: 1)
        let id = UUID()
        _ = registry.begin(owner: owner, operationID: id, parent: CancellationToken())
        registry.update(id, progress: ArchiveProgress(
            phase: .writing, completedBytes: 1024, totalBytes: 4096, completedEntries: 3))
        let snapshot = registry.snapshot(id)
        #expect(snapshot?.phase == "writing")
        #expect(snapshot?.completedBytes == 1024)
        #expect(snapshot?.totalBytes == 4096)
        #expect(snapshot?.completedEntries == 3)
        #expect(snapshot?.cancelled == false)
    }

    @Test func cancellationBeforeLeaseAcquisitionIsRetainedUntilActualSettlement() {
        let registry = G04ArchiveOperationRegistry()
        let owner = try! G04ArchiveOwner(taskID: UUID(), workspaceID: UUID(), nativeEpoch: 1, hostGeneration: 1)
        let id = UUID()
        let parent = CancellationToken()
        #expect(registry.reserve(owner: owner, operationID: id))
        #expect(!registry.reserve(owner: owner, operationID: id))
        #expect(registry.cancel(id))
        let engine = registry.begin(owner: owner, operationID: id, parent: parent)
        #expect(engine.isCancelled)
        #expect(!parent.isCancelled)
        #expect(registry.snapshot(id)?.cancelled == true)
        registry.end(id)
        #expect(registry.snapshot(id) == nil)
    }

    @Test func cancelAllScopesByOwner() {
        let registry = G04ArchiveOperationRegistry()
        let ownerA = try! G04ArchiveOwner(
            taskID: UUID(), workspaceID: UUID(), nativeEpoch: 1, hostGeneration: 1)
        let ownerB = try! G04ArchiveOwner(
            taskID: UUID(), workspaceID: UUID(), nativeEpoch: 1, hostGeneration: 1)
        let a = UUID(), b = UUID()
        _ = registry.begin(owner: ownerA, operationID: a, parent: CancellationToken())
        _ = registry.begin(owner: ownerB, operationID: b, parent: CancellationToken())
        #expect(registry.cancelAll(for: ownerA) == 1)
        #expect(registry.snapshot(a)?.cancelled == true)
        #expect(registry.snapshot(b)?.cancelled == false)
        // Both records still own work until end(), including the already-cancelled A.
        #expect(registry.cancelAll() == 2)
    }
}

struct G04ArchivePreviewRegistryTests {
    @Test func stagingIsReusedAcrossSelectionsAndRemovedExactlyOnce() {
        let registry = G04ArchivePreviewRegistry()
        let owner = try! G04ArchiveOwner(
            taskID: UUID(), workspaceID: UUID(), nativeEpoch: 1, hostGeneration: 1)
        let preview = UUID()
        registry.session(preview, owner: owner, relativePath: "docs/a.zip")
        // A second registration (recomposition/rotation restore) keeps the
        // original session instead of resetting staged state.
        registry.session(preview, owner: owner, relativePath: "docs/a.zip")
        #expect(registry.stagedDirectory(preview) == nil)
        registry.markStaged(preview, directory: ".floe-archive-preview/xyz")
        #expect(registry.stagedDirectory(preview) == ".floe-archive-preview/xyz")
        let foreign = try! G04ArchiveOwner(
            taskID: UUID(), workspaceID: UUID(), nativeEpoch: 1, hostGeneration: 1)
        #expect(!registry.session(preview, owner: foreign, relativePath: "docs/a.zip"))
        #expect(!registry.session(preview, owner: owner, relativePath: "docs/b.zip"))
        #expect(registry.takeForDiscard(preview, owner: foreign) == nil)
        #expect(registry.stagedDirectory(preview) == ".floe-archive-preview/xyz")
        let taken = registry.takeForDiscard(preview, owner: owner)
        #expect(taken?.directory == ".floe-archive-preview/xyz")
        #expect(taken?.owner == owner)
        #expect(registry.takeForDiscard(preview, owner: owner) == nil)
    }
}

struct G04ArchiveReceiptTests {
    @Test func engineSummaryLineBecomesTheTypedReceipt() {
        let fields = G04ArchiveBridge.extractSummaryFields(
            "status=ok action=extract format=zip source=docs/a.zip destination=out " +
            "entries=12 skipped=1 uncompressedBytes=98765",
            destination: "out")
        #expect(fields["destination"] as? String == "out")
        #expect(fields["entries"] as? Int == 12)
        #expect(fields["skipped"] as? Int == 1)
        #expect(fields["uncompressedBytes"] as? Int64 == 98765)
        #expect((fields["summary"] as? String)?.contains("status=ok") == true)
    }

    @Test func malformedSummaryFieldsDefaultToZeroWithoutCrashing() {
        let fields = G04ArchiveBridge.extractSummaryFields("status=ok action=extract", destination: "out")
        #expect(fields["entries"] as? Int == 0)
        #expect(fields["skipped"] as? Int == 0)
        #expect(fields["uncompressedBytes"] as? Int64 == 0)
        #expect(fields["destination"] as? String == "out")
    }
}

struct G04ArchiveOwnerTests {
    @Test func ownerRoundTripsThroughTheWire() {
        let owner = try! G04ArchiveOwner(
            taskID: UUID(), workspaceID: UUID(), nativeEpoch: 7, hostGeneration: 3)
        let parsed = try! G04ArchiveOwner.parse([
            "taskID": owner.taskID.uuidString,
            "workspaceID": owner.workspaceID.uuidString,
            "nativeEpoch": 7,
            "hostGeneration": 3,
        ])
        #expect(parsed == owner)
        #expect(parsed.workspaceOwner.epoch == 7)
        #expect(parsed.workspaceOwner.taskID == owner.taskID)
        #expect(parsed.workspaceOwner.workspaceID == owner.workspaceID)
    }
}
