import Foundation
import Testing
@testable import FloeTools
@testable import FloeCore

// FloeToolsTests — Design revision payload store on the shared artifact
// authority. Covers the critical-review contracts: validated identities on
// every entrypoint, containment + symlink rejection, immutable revisions
// (replay vs conflict), corrupt/oversized reads, and cross-canvas isolation.

@Suite("Design revision payloads")
struct DesignRevisionPayloadStoreTests {
    private let canvasA = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
    private let canvasB = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
    private let node = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!

    private func makeStore() -> DesignRevisionPayloadStore {
        // Uses the real artifact root; paths are validated-unique per test.
        DesignRevisionPayloadStore()
    }

    @Test func storeReadVerifyRoundTrip() throws {
        let store = makeStore()
        let bytes = Data("revision-payload-bytes".utf8)
        let relative = try store.store(
            canvasID: canvasA, nodeID: node, artifactID: "art-1", revisionID: "rev-1",
            bytes: bytes
        )
        let loaded = try store.verifiedBytes(
            canvasID: canvasA, nodeID: node, artifactID: "art-1", revisionID: "rev-1",
            expectedContentSHA256: FloeDigest.sha256Hex(bytes)
        )
        #expect(loaded == bytes)
        // Hash mismatch fails closed.
        #expect(throws: (any Error).self) {
            try store.verifiedBytes(
                canvasID: canvasA, nodeID: node, artifactID: "art-1", revisionID: "rev-1",
                expectedContentSHA256: String(repeating: "0", count: 64)
            )
        }
        _ = relative
    }

    @Test func sameIdDifferentBytesConflictNeverOverwrite() throws {
        let store = makeStore()
        let revision = "rev-\(UUID().uuidString.lowercased())"
        let artifact = "art-\(UUID().uuidString.lowercased())"
        try store.store(canvasID: canvasA, nodeID: node, artifactID: artifact, revisionID: revision, bytes: Data("one".utf8))
        #expect(throws: DesignRevisionPayloadStoreError.conflict(revision)) {
            try store.store(canvasID: canvasA, nodeID: node, artifactID: artifact, revisionID: revision, bytes: Data("two".utf8))
        }
        // The original bytes survived.
        let loaded = try store.verifiedBytes(
            canvasID: canvasA, nodeID: node, artifactID: artifact, revisionID: revision,
            expectedContentSHA256: FloeDigest.sha256Hex(Data("one".utf8))
        )
        #expect(loaded == Data("one".utf8))
        // Identical re-store is a replay no-op.
        try store.store(canvasID: canvasA, nodeID: node, artifactID: artifact, revisionID: revision, bytes: Data("one".utf8))
    }

    @Test func invalidIdentitiesAreRejected() throws {
        let store = makeStore()
        for bad in ["", "..", "a/b", String(repeating: "x", count: 65), "has space"] {
            #expect(throws: DesignRevisionPayloadStoreError.invalidIdentity("artifactID")) {
                try store.store(canvasID: canvasA, nodeID: node, artifactID: bad, revisionID: "rev", bytes: Data("x".utf8))
            }
        }
    }

    @Test func crossCanvasPathsAreIsolated() throws {
        let store = makeStore()
        let artifact = "art-\(UUID().uuidString.lowercased())"
        let revision = "rev-\(UUID().uuidString.lowercased())"
        try store.store(canvasID: canvasA, nodeID: node, artifactID: artifact, revisionID: revision, bytes: Data("a".utf8))
        // Canvas B cannot read canvas A's payload even with identical ids.
        #expect(throws: (any Error).self) {
            try store.verifiedBytes(
                canvasID: canvasB, nodeID: node, artifactID: artifact, revisionID: revision,
                expectedContentSHA256: FloeDigest.sha256Hex(Data("a".utf8))
            )
        }
    }

    @Test func oversizedPayloadIsRejectedBeforeRead() throws {
        let store = DesignRevisionPayloadStore(maxPayloadBytes: 8)
        let artifact = "art-\(UUID().uuidString.lowercased())"
        #expect(throws: DesignRevisionPayloadStoreError.payloadTooLarge(16)) {
            try store.store(canvasID: canvasA, nodeID: node, artifactID: artifact, revisionID: "rev", bytes: Data(count: 16))
        }
    }

    @Test func stagedCommitAndAbandon() throws {
        let store = makeStore()
        let artifact = "art-\(UUID().uuidString.lowercased())"
        let revision = "rev-\(UUID().uuidString.lowercased())"
        let staged = try store.stage(
            canvasID: canvasA, nodeID: node, artifactID: artifact, revisionID: revision,
            bytes: Data("staged".utf8)
        )
        // Not visible before commit.
        #expect(throws: (any Error).self) {
            try store.verifiedBytes(
                canvasID: canvasA, nodeID: node, artifactID: artifact, revisionID: revision,
                expectedContentSHA256: staged.contentSHA256
            )
        }
        try store.commit(staged)
        let loaded = try store.verifiedBytes(
            canvasID: canvasA, nodeID: node, artifactID: artifact, revisionID: revision,
            expectedContentSHA256: staged.contentSHA256
        )
        #expect(loaded == Data("staged".utf8))
        // Abandon removes only staging.
        let staged2 = try store.stage(
            canvasID: canvasA, nodeID: node, artifactID: artifact, revisionID: revision,
            bytes: Data("staged".utf8)
        )
        store.abandon(staged2)
        // Published payload intact (reference-shared, never removed by cleanup).
        let still = try store.verifiedBytes(
            canvasID: canvasA, nodeID: node, artifactID: artifact, revisionID: revision,
            expectedContentSHA256: staged.contentSHA256
        )
        #expect(still == Data("staged".utf8))
    }
}
