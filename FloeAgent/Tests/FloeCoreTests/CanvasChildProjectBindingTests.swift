// FloeCoreTests — canvas child-project binding (Build265).
import Foundation
import Testing
@testable import FloeCore

@Suite("Canvas child project binding")
struct CanvasChildProjectBindingTests {
    private func node(metadata: [String: String] = [:]) -> CanvasNode {
        var node = CanvasNode.placeholder(kind: .image, position: CanvasPoint(x: 10, y: 20), zIndex: 1)
        node.metadata = metadata
        return node
    }

    @Test("binding round-trips through node metadata and the project codec")
    func roundTrip() throws {
        let projectID = UUID()
        let assetID = UUID()
        var subject = node()
        subject.childProjectBinding = CanvasChildProjectBinding(
            projectID: projectID, appliedRevision: 7, draftRevision: 9,
            renderedAssetID: assetID, sourceNodeID: UUID(), sourceAssetHash: "abc")

        let binding = try #require(subject.childProjectBinding)
        #expect(binding.projectID == projectID)
        #expect(binding.appliedRevision == 7)
        #expect(binding.draftRevision == 9)

        let document = CanvasDocument(name: "Doc", nodes: [subject])
        let project = CanvasProject(id: UUID(), name: "Canvas", documents: [document], selectedDocumentID: document.id)
        let data = try CanvasProjectCodec.encode(project)
        let decoded = try CanvasProjectCodec.decode(data)
        let restored = try #require(decoded.documents.first?.nodes.first)
        #expect(restored.childProjectBinding == binding)
    }

    @Test("legacy nodes decode without a binding and are not rewritten")
    func legacyNode() throws {
        let json = """
        {"id":"\(UUID().uuidString)","kind":"image","text":"old","position":{"x":0,"y":0},"size":{"width":10,"height":10}}
        """
        let decoded = try JSONDecoder().decode(CanvasNode.self, from: Data(json.utf8))
        #expect(decoded.childProjectBinding == nil)
        #expect(decoded.metadata.isEmpty)
    }

    @Test("unknown newer metadata keys survive a round-trip untouched")
    func unknownMetadataPreserved() throws {
        var subject = node(metadata: ["future.feature": "opaque-value", "derivedFromNodeID": "x"])
        subject.childProjectBinding = CanvasChildProjectBinding(projectID: UUID(), appliedRevision: 1)
        let encoded = try JSONEncoder().encode(subject)
        let decoded = try JSONDecoder().decode(CanvasNode.self, from: encoded)
        #expect(decoded.metadata["future.feature"] == "opaque-value")
        #expect(decoded.metadata["derivedFromNodeID"] == "x")
        #expect(decoded.childProjectBinding?.appliedRevision == 1)
    }

    @Test("unknown newer schema is preserved raw and reported, never treated as unbound")
    func unknownSchemaVersion() throws {
        let raw = #"{"schemaVersion":99,"projectID":"\#(UUID().uuidString)","appliedRevision":4}"#
        var subject = node(metadata: [CanvasNode.childProjectMetadataKey: raw])
        guard case .unknownVersion(let preserved) = subject.childProjectBindingState else {
            Issue.record("expected unknownVersion, got \(subject.childProjectBindingState)")
            return
        }
        #expect(preserved == raw)
        #expect(subject.childProjectBinding == nil)
        #expect(subject.childProjectBindingState.isRecoverable)
        // Re-encoding the node keeps the unknown binding byte-identical.
        let decoded = try JSONDecoder().decode(CanvasNode.self, from: JSONEncoder().encode(subject))
        #expect(decoded.metadata[CanvasNode.childProjectMetadataKey] == raw)
    }

    @Test("malformed binding metadata is preserved and surfaced")
    func malformedBinding() {
        let raw = "not-json"
        let subject = node(metadata: [CanvasNode.childProjectMetadataKey: raw])
        guard case .malformed(let preserved) = subject.childProjectBindingState else {
            Issue.record("expected malformed, got \(subject.childProjectBindingState)")
            return
        }
        #expect(preserved == raw)
        #expect(subject.childProjectBindingState.isRecoverable)
    }

    @Test("bindings without a version field are treated as version 1")
    func legacyBindingVersion() throws {
        let raw = #"{"projectID":"\#(UUID().uuidString)","appliedRevision":2}"#
        let subject = node(metadata: [CanvasNode.childProjectMetadataKey: raw])
        guard case .valid(let binding) = subject.childProjectBindingState else {
            Issue.record("expected valid, got \(subject.childProjectBindingState)")
            return
        }
        #expect(binding.schemaVersion == 1)
        #expect(binding.appliedRevision == 2)
    }

    @Test("setting nil removes the key instead of writing an empty binding")
    func clearingBinding() {
        var subject = node()
        subject.childProjectBinding = CanvasChildProjectBinding(projectID: UUID(), appliedRevision: 1)
        #expect(subject.metadata[CanvasNode.childProjectMetadataKey] != nil)
        subject.childProjectBinding = nil
        #expect(subject.metadata[CanvasNode.childProjectMetadataKey] == nil)
        #expect(subject.childProjectBinding == nil)
    }

    @Test("higher-version pending marker is preserved raw, read-only, never forkable")
    func higherVersionPendingPreserved() throws {
        let raw = try #require(PendingWrapper(
            status: "pending",
            pending: CanvasChildProjectPending(schemaVersion: 42, parentProjectID: UUID()),
            reason: nil).json)
        var subject = node(metadata: [CanvasNode.childProjectPendingMetadataKey: raw])
        guard case .unknownVersion(let preserved) = subject.childProjectBindingState else {
            Issue.record("expected unknownVersion, got \(subject.childProjectBindingState)")
            return
        }
        #expect(preserved == raw)
        #expect(subject.childProjectBinding == nil)
        #expect(subject.childProjectBindingState.isNotEditable)
        #expect(subject.childProjectBindingState.isRecoverable)
        // It must not be treated as pending: no fork request is collected.
        let document = CanvasDocument(name: "Doc", nodes: [subject])
        #expect(CanvasCopyForkPlanner.pendingRequests(in: document).isEmpty)
        // A copied node carries the same unknown marker forward untouched.
        var copy = subject
        copy.id = UUID()
        #expect(copy.childProjectBindingState.isNotEditable)
        // Attempting to write a pending state over it must not clobber the raw marker.
        copy.setChildProjectPending(.pending(CanvasChildProjectPending(parentProjectID: UUID())))
        #expect(copy.childProjectBindingState.isNotEditable)
        // Re-encoding preserves the original raw bytes.
        let decoded = try JSONDecoder().decode(CanvasNode.self, from: JSONEncoder().encode(subject))
        #expect(decoded.metadata[CanvasNode.childProjectPendingMetadataKey] == raw)
    }

    @Test("unrecognized pending status is preserved raw and never retried or forked")
    func unrecognizedStatusPreserved() throws {
        let raw = try #require(PendingWrapper(
            status: "blocked-by-policy",
            pending: CanvasChildProjectPending(parentProjectID: UUID()),
            reason: "needs review").json)
        let subject = node(metadata: [CanvasNode.childProjectPendingMetadataKey: raw])
        guard case .unrecognizedStatus(let preserved) = subject.childProjectBindingState else {
            Issue.record("expected unrecognizedStatus, got \(subject.childProjectBindingState)")
            return
        }
        #expect(preserved == raw)
        #expect(subject.childProjectBinding == nil)
        #expect(subject.childProjectBindingState.isNotEditable)
        #expect(subject.childProjectBindingState.isRecoverable)
        // Not pending: fork planner ignores it; retry UI switches do nothing.
        let document = CanvasDocument(name: "Doc", nodes: [subject])
        #expect(CanvasCopyForkPlanner.pendingRequests(in: document).isEmpty)
        // Higher-version failure metadata is likewise unknown, not failed.
        let futureFailed = try #require(PendingWrapper(
            status: "failed",
            pending: CanvasChildProjectPending(schemaVersion: 7, parentProjectID: UUID()),
            reason: "x").json)
        let failedNode = node(metadata: [CanvasNode.childProjectPendingMetadataKey: futureFailed])
        guard case .unknownVersion = failedNode.childProjectBindingState else {
            Issue.record("expected unknownVersion for future failed marker")
            return
        }
        #expect(failedNode.childProjectBindingState.isNotEditable)
    }

    @Test("current-version pending and failed markers still decode for retry")
    func currentVersionPendingStillWorks() throws {
        var subject = node()
        let pending = CanvasChildProjectPending(parentProjectID: UUID())
        subject.setChildProjectPending(.pending(pending))
        guard case .pending(let decoded) = subject.childProjectBindingState else {
            Issue.record("expected pending, got \(subject.childProjectBindingState)")
            return
        }
        #expect(decoded.parentProjectID == pending.parentProjectID)
        let document = CanvasDocument(name: "Doc", nodes: [subject])
        #expect(CanvasCopyForkPlanner.pendingRequests(in: document).count == 1)

        subject.setChildProjectPending(.failed(pending, reason: "disk full"))
        guard case .failed(let failed, let reason) = subject.childProjectBindingState else {
            Issue.record("expected failed")
            return
        }
        #expect(failed.parentProjectID == pending.parentProjectID)
        #expect(reason == "disk full")
    }
}
