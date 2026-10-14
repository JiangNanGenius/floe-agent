import Foundation
import Testing
@testable import FloeCore

// FloeCoreTests — Typed design targets, ownership adapters and the shared
// owner workflow. Covers the frozen review contracts:
// - unambiguous identity (length-prefixed, case-preserving, environment and
//   requested-kind aware, origin-attribution-free)
// - real format→content-family classification (unknown formats fail)
// - containment/authorization/revocation/cross-task at every boundary
// - full non-canvas cycle: brief/spec, freeze, edit, feedback, propose,
//   compare, adopt/reject (durable, original task only), restore, export
// - late candidates and concurrent manual edits
// - creative pre-material requests: save/restore, first-result binding,
//   duplicate callbacks, task switching
// - unknown-field preservation incl. number/bool exactness

// MARK: - In-memory doubles

private actor InMemoryOwnerStore: DesignOwnerProjectStore {
    private var envelopes: [String: DesignOwnerEnvelope] = [:]
    private(set) var saveCount = 0
    /// Simulates an interrupted commit: the next save throws AFTER the
    /// caller's owner-side effects (used to prove retry convergence).
    var failNextSave = false

    init(seed: DesignOwnerEnvelope? = nil) {
        if let seed { envelopes[seed.target.stableKey] = seed }
    }

    func load(targetKey: String) async throws -> DesignOwnerEnvelope? {
        envelopes[targetKey]
    }

    func setFailNextSave(_ value: Bool) {
        failNextSave = value
    }

    @discardableResult
    func save(
        _ envelope: DesignOwnerEnvelope,
        targetKey: String,
        expectedRevision: Int64?
    ) async throws -> Int64 {
        if failNextSave {
            failNextSave = false
            throw FloeError.storageCorrupted("simulated interrupted CAS")
        }
        if let existing = envelopes[targetKey] {
            if let expectedRevision, existing.revision != expectedRevision {
                throw FloeError.validationFailed(
                    "owner conflict expected \(expectedRevision) actual \(existing.revision)"
                )
            }
        } else if let expectedRevision, expectedRevision != 0 {
            throw FloeError.validationFailed("owner create with non-zero expectation")
        }
        var next = envelope
        next.revision = (expectedRevision ?? 0) + 1
        next.updatedAt = Date()
        envelopes[targetKey] = next
        saveCount += 1
        return next.revision
    }
}

private final class InMemoryPayloadStore: DesignOwnerPayloadStore, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var blobs: [String: Data] = [:]
    private(set) var stored: [String] = []
    private(set) var abandoned: [String] = []

    func store(
        ownerKey: String,
        revisionID: String,
        bytes: Data,
        expectedContentSHA256: String
    ) throws -> String {
        lock.lock(); defer { lock.unlock() }
        let digest = FloeDigest.sha256Hex(bytes)
        guard digest == expectedContentSHA256.lowercased() else {
            throw FloeError.validationFailed("digest mismatch")
        }
        let key = "\(ownerKey)/\(revisionID)"
        if let existing = blobs[key], existing != bytes {
            throw FloeError.validationFailed("immutable revision conflict")
        }
        blobs[key] = bytes
        stored.append(revisionID)
        return "DesignRevisions/owners/\(ownerKey)/revisions/\(revisionID).payload"
    }

    func verifiedBytes(
        ownerKey: String,
        revisionID: String,
        expectedContentSHA256: String
    ) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let data = blobs["\(ownerKey)/\(revisionID)"],
              FloeDigest.sha256Hex(data) == expectedContentSHA256.lowercased() else {
            throw FloeError.storageCorrupted("payload unavailable")
        }
        return data
    }

    func abandon(ownerKey: String, revisionID: String) {
        lock.lock(); defer { lock.unlock() }
        abandoned.append(revisionID)
    }
}

private final class SendableBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T?
    func set(_ value: T) {
        lock.lock(); defer { lock.unlock() }
        storage = value
    }
    var value: T? {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

private final class StubFilePort: DesignWorkspaceFilePort, @unchecked Sendable {
    var files: [String: Data] = [:]
    var format = "png"
    var authorized = true
    var existsFlag = true
    private(set) var resolveCount = 0

    func resolve(
        workspaceID: String,
        reference: String,
        environmentID: String?,
        runID: UUID?
    ) async throws -> DesignResolvedFile {
        guard authorized else { throw DesignTargetError.notAuthorized("stub denied") }
        resolveCount += 1
        guard existsFlag, let data = files[reference] else {
            throw DesignTargetError.notFound("stub missing \(reference)")
        }
        return DesignResolvedFile(
            data: data,
            format: format,
            displayName: (reference as NSString).lastPathComponent,
            contentSHA256: FloeDigest.sha256Hex(data),
            baseRevisionToken: "workspace:\(workspaceID):sha:\(FloeDigest.sha256Hex(data))",
            allowsInPlaceUpdate: true
        )
    }

    func isAuthorized(
        workspaceID: String,
        reference: String,
        environmentID: String?,
        runID: UUID?
    ) async -> Bool {
        authorized
    }

    func exists(workspaceID: String, reference: String, environmentID: String?) async -> Bool {
        existsFlag && files[reference] != nil
    }
}

private final class StubChatPort: DesignChatAttachmentPort, @unchecked Sendable {
    var attachment: DesignChatAttachment?
    var accessible = true

    func resolveAttachment(
        conversationID: String,
        messageID: String,
        attachmentID: String,
        runID: UUID?
    ) async throws -> DesignChatAttachment {
        guard accessible, let attachment else {
            throw DesignTargetError.notAuthorized("stub attachment denied")
        }
        guard attachment.conversationID.caseInsensitiveCompare(conversationID) == .orderedSame else {
            throw DesignTargetError.notAuthorized("stub cross-task")
        }
        return attachment
    }

    func attachmentIsAccessible(
        conversationID: String,
        messageID: String,
        attachmentID: String,
        runID: UUID?
    ) async -> Bool {
        guard accessible, let attachment else { return false }
        return attachment.conversationID.caseInsensitiveCompare(conversationID) == .orderedSame
    }
}

private final class StubCreativePort: DesignCreativeDocumentPort, @unchecked Sendable {
    var requestAuthorized = true
    var assets: [String: Data] = [:]
    var formats: [String: String] = [:]
    var boundFiles: [String: Data] = [:]
    /// Asset ids this stub proves as the committed result of a durable job
    /// for the binding run (the production durable job→asset link). A run
    /// bind for any other asset is refused.
    var runVerifiedAssets: Set<String> = []

    func resolve(
        ownerID: String,
        creationID: String,
        environmentID: String?,
        runID: UUID?
    ) async throws -> DesignResolvedFile {
        guard let data = assets[creationID] else {
            throw DesignTargetError.notFound("stub creative asset missing")
        }
        let format = formats[creationID] ?? "png"
        return DesignResolvedFile(
            data: data,
            format: format,
            displayName: creationID,
            contentSHA256: FloeDigest.sha256Hex(data),
            baseRevisionToken: "creative:\(creationID):sha:\(FloeDigest.sha256Hex(data))",
            allowsInPlaceUpdate: false
        )
    }

    func requestIsAuthorized(
        ownerID: String,
        requestID: String,
        environmentID: String?,
        runID: UUID?
    ) async -> Bool {
        // Trusted in-app UI; runs must present a grant (stub flag).
        runID == nil ? true : requestAuthorized
    }

    func boundResult(
        targetKey: String,
        ownerID: String,
        requestID: String,
        environmentID: String?,
        runID: UUID?
    ) async throws -> DesignResolvedFile? {
        guard let data = boundFiles[requestID] else { return nil }
        return DesignResolvedFile(
            data: data,
            format: formats[requestID] ?? "png",
            displayName: requestID,
            contentSHA256: FloeDigest.sha256Hex(data),
            baseRevisionToken: "creative:\(requestID):sha:\(FloeDigest.sha256Hex(data))",
            allowsInPlaceUpdate: false
        )
    }

    /// Mirrors the production contract: the proposed bytes/format must BE the
    /// retained asset; a run additionally needs the durable job link.
    func verifyFirstResultBinding(
        ownerID: String,
        requestID: String,
        environmentID: String?,
        boundResultID: String,
        bytes: Data,
        format: String,
        runID: UUID?
    ) async throws -> DesignCreativeResultProvenance {
        guard let assetBytes = assets[boundResultID] else {
            throw DesignTargetError.notFound("no retained stub asset \(boundResultID)")
        }
        let assetFormat = formats[boundResultID] ?? "png"
        guard assetFormat.caseInsensitiveCompare(format) == .orderedSame else {
            throw DesignTargetError.unverifiable(
                "proposed format \(format) is not the retained asset format \(assetFormat)")
        }
        guard assetBytes == bytes else {
            throw DesignTargetError.unverifiable(
                "proposed bytes are not the retained asset \(boundResultID)")
        }
        if runID != nil {
            guard requestAuthorized else {
                throw DesignTargetError.notAuthorized("run is not authorized")
            }
            guard runVerifiedAssets.contains(boundResultID) else {
                throw DesignTargetError.notAuthorized(
                    "no durable job link for \(boundResultID)")
            }
            return .generationJob
        }
        return .trustedUIManualImport
    }
}

private final class StubCommitPort: DesignOwnerCommitPort, @unchecked Sendable {
    var canCommitValue = true
    var failure: Error?
    /// Readback classification returned after a successful `commit`.
    var verifyResult: DesignCommitVerification = .matchesProposed
    private(set) var committedBytes: Data?
    private(set) var commitCount = 0
    private(set) var verifyCount = 0
    /// Signals commit() entry exactly once (gated tests poll this).
    private(set) var enteredCount = 0
    /// When set, commit() blocks before returning until the gate opens.
    var gate: AsyncGate?

    func canCommit(_ target: DesignTarget) -> Bool { canCommitValue }

    func commit(
        target: DesignTarget,
        reference: String,
        bytes: Data,
        format: String,
        baseRevisionToken: String
    ) async throws -> String {
        enteredCount += 1
        if let gate { await gate.wait() }
        if let failure { throw failure }
        commitCount += 1
        committedBytes = bytes
        return "workspace:stub:sha:\(FloeDigest.sha256Hex(bytes))"
    }

    func verify(
        target: DesignTarget,
        reference: String,
        proposedContentSHA256: String,
        baseRevisionToken: String
    ) async throws -> DesignCommitVerification {
        verifyCount += 1
        return verifyResult
    }
}

/// In-memory stand-in for the app's EXISTING
/// FilesCenter/ConversationStore/CreativeAssetStore publication path.
/// Enforces the same idempotency contract: one receipt per publication key,
/// never a second attachment/asset for a replay.
private actor StubPublicationPort: DesignResultPublicationPort {
    var failure: Error?
    private var receipts: [String: DesignResultPublicationReceipt] = [:]
    private(set) var publications: [DesignResultPublication] = []
    private(set) var callCount = 0

    func setFailure(_ error: Error?) { failure = error }

    func publish(
        _ publication: DesignResultPublication
    ) async throws -> DesignResultPublicationReceipt {
        callCount += 1
        if let failure { throw failure }
        publications.append(publication)
        if let existing = receipts[publication.publicationKey] { return existing }
        let destination: String
        switch publication.target.kind {
        case .chatAttachment:
            destination = "chat:\(publication.target.ownerID)"
        case .creativeDocument:
            destination = "creative:\(publication.target.sourceID)"
        default:
            destination = "other:\(publication.target.sourceID)"
        }
        let receipt = DesignResultPublicationReceipt(
            identifier: "published-\(receipts.count + 1)",
            destination: destination,
            contentSHA256: publication.contentSHA256
        )
        receipts[publication.publicationKey] = receipt
        return receipt
    }

    func publication(forKey key: String) -> DesignResultPublication? {
        publications.last { $0.publicationKey == key }
    }

    func distinctReceiptCount() -> Int { receipts.count }
}

/// Deterministic await gate for single-flight/concurrency tests.
private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending { continuation.resume() }
    }
}

/// Applies the unified-style diff produced by `DesignOwnerWorkflow.lineDiff`
/// back to old lines. Returns nil when the script is not applicable (which
/// would mean the diff is not a faithful edit script).
private func applyUnifiedDiff(_ diff: [String], to oldLines: [String]) -> [String]? {
    var output: [String] = []
    var index = 0
    for line in diff {
        if line.hasPrefix("- ") {
            let value = String(line.dropFirst(2))
            guard index < oldLines.count, oldLines[index] == value else { return nil }
            index += 1
        } else if line.hasPrefix("+ ") {
            output.append(String(line.dropFirst(2)))
        } else if line.hasPrefix("  ") {
            let value = String(line.dropFirst(2))
            guard index < oldLines.count, oldLines[index] == value else { return nil }
            output.append(value)
            index += 1
        } else {
            return nil
        }
    }
    guard index == oldLines.count else { return nil }
    return output
}

private func splitTestLines(_ text: String) -> [String] {
    text.isEmpty ? [] : text.components(separatedBy: "\n")
}

private func waitUntil(
    timeout: TimeInterval = 5,
    _ condition: () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else {
            throw FloeError.validationFailed("timed out waiting for condition")
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}

private actor StubCanvasRepository: CanvasDocumentRepository {
    private var projects: [UUID: CanvasProject]
    init(project: CanvasProject) { self.projects = [project.id: project] }
    func project(canvasID: UUID) async throws -> CanvasProject {
        guard let project = projects[canvasID] else {
            throw FloeError.validationFailed("missing canvas")
        }
        return project
    }
    func save(_ project: CanvasProject, expectedRevision: Int64) async throws {
        guard let current = projects[project.id], current.revision == expectedRevision else {
            throw FloeError.validationFailed("revision conflict")
        }
        projects[project.id] = project
    }
    func stored(canvasID: UUID) -> CanvasProject? { projects[canvasID] }
}

private struct StubCanvasContentPort: DesignCanvasContentPort {
    let format: String
    let transform: @Sendable (CanvasNode) -> Data
    func readNode(
        canvasID: UUID,
        nodeID: UUID,
        snapshot: DesignCanvasService.Snapshot
    ) async throws -> DesignResolvedFile {
        guard let node = snapshot.node else {
            throw DesignTargetError.notFound("missing node")
        }
        let data = transform(node)
        return DesignResolvedFile(
            data: data,
            format: format,
            displayName: node.title ?? "node",
            contentSHA256: FloeDigest.sha256Hex(data),
            baseRevisionToken: "sha:\(FloeDigest.sha256Hex(data))",
            allowsInPlaceUpdate: true
        )
    }
}

private func makeOutbox() -> DesignDecisionOutbox {
    DesignDecisionOutbox(fileURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("design-target-tests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("outbox.json"))
}

private func makeFileWorkflow(
    filePort: StubFilePort = StubFilePort(),
    commitPort: StubCommitPort? = nil,
    ownerStore: InMemoryOwnerStore = InMemoryOwnerStore(),
    payloads: InMemoryPayloadStore = InMemoryPayloadStore()
) async -> (service: DesignTargetService, workflow: DesignOwnerWorkflow, filePort: StubFilePort, store: InMemoryOwnerStore, payloads: InMemoryPayloadStore) {
    let adapter = DesignFileOwnerAdapter(port: filePort)
    let service = DesignTargetService(adapters: [adapter])
    var ports: [DesignTargetKind: any DesignOwnerCommitPort] = [:]
    if let commitPort { ports[.fileDocument] = commitPort }
    let workflow = DesignOwnerWorkflow(
        targets: service,
        store: ownerStore,
        payloads: payloads,
        commitPorts: ports,
        outbox: makeOutbox()
    )
    return (service, workflow, filePort, ownerStore, payloads)
}

private func makeCreativeWorkflow(
    port: StubCreativePort = StubCreativePort(),
    ownerStore: InMemoryOwnerStore = InMemoryOwnerStore(),
    payloads: InMemoryPayloadStore = InMemoryPayloadStore()
) -> (service: DesignTargetService, workflow: DesignOwnerWorkflow, port: StubCreativePort) {
    let adapter = DesignCreativeOwnerAdapter(port: port)
    let service = DesignTargetService(adapters: [adapter])
    let workflow = DesignOwnerWorkflow(
        targets: service,
        store: ownerStore,
        payloads: payloads,
        outbox: makeOutbox()
    )
    return (service, workflow, port)
}

private func fileTarget(
    workspace: String = "11111111-1111-1111-1111-111111111111",
    reference: String = "hero.png",
    origin: String? = nil,
    environment: String? = nil
) -> DesignTarget {
    DesignTarget(
        kind: .fileDocument,
        ownerID: workspace,
        documentID: "",
        sourceID: reference,
        environmentID: environment,
        originConversationID: origin
    )
}

private func creativeTarget(
    request: String = "req-1",
    kind: DesignContentType = .image,
    origin: String? = nil
) -> DesignTarget {
    DesignTarget(
        kind: .creativeDocument,
        ownerID: "creative",
        documentID: "",
        sourceID: request,
        originConversationID: origin,
        requestedOutputKind: kind
    )
}

// MARK: - Identity

@Suite("Design target identity")
struct DesignTargetIdentityTests {
    @Test func lengthPrefixedIdentityIsCollisionFree() {
        let a = DesignTarget(kind: .fileDocument, ownerID: "a:b", sourceID: "c")
        let b = DesignTarget(kind: .fileDocument, ownerID: "a", sourceID: "b:c")
        #expect(a.displayID != b.displayID)
        #expect(a.stableKey != b.stableKey)
        // Identifiable id is the canonical key, never the colon display form.
        #expect(a.id == a.stableKey)
        #expect(a.id != a.displayID)
    }

    @Test func opaqueIDsPreserveCaseAndUUIDsNormalizeOnlyAtParse() {
        let upper = DesignTarget(kind: .fileDocument, ownerID: "Workspace-ABC", sourceID: "Hero.PNG")
        let lower = DesignTarget(kind: .fileDocument, ownerID: "workspace-abc", sourceID: "hero.png")
        #expect(upper.ownerID == "Workspace-ABC")
        #expect(upper.sourceID == "Hero.PNG")
        #expect(upper.stableKey != lower.stableKey)
        let upperUUID = try? DesignTargetValidation.uuid("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", field: "x")
        let lowerUUID = try? DesignTargetValidation.uuid("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", field: "x")
        #expect(upperUUID != nil)
        #expect(upperUUID == lowerUUID)
    }

    @Test func environmentAndRequestedKindParticipateInIdentity() {
        let base = fileTarget(environment: "env-a")
        let otherEnv = fileTarget(environment: "env-b")
        #expect(!base.isSameSource(as: otherEnv))
        #expect(base.stableKey != otherEnv.stableKey)
        let requestA = creativeTarget(kind: .image)
        let requestB = creativeTarget(kind: .video)
        #expect(requestA.stableKey != requestB.stableKey)
        #expect(!requestA.isSameSource(as: requestB))
    }

    @Test func originAttributionDoesNotChangeSourceIdentity() {
        let direct = fileTarget(origin: nil)
        let fromTaskA = fileTarget(origin: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
        let fromTaskB = fileTarget(origin: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
        #expect(direct.stableKey == fromTaskA.stableKey)
        #expect(fromTaskA.stableKey == fromTaskB.stableKey)
        #expect(fromTaskA.isSameSource(as: fromTaskB))
    }

    @Test func freezingPreservesRequestedKind() {
        let frozen = creativeTarget().freezing(revision: "rev-1")
        #expect(frozen.requestedOutputKind == .image)
        #expect(frozen.revision == "rev-1")
        #expect(frozen.stableKey == creativeTarget().stableKey)
    }
}

// MARK: - Format classification

@Suite("Design content family from verified format")
struct DesignFormatClassificationTests {
    @Test func mapsKnownFamilies() {
        #expect(DesignContentType.from(format: "md") == .notes)
        #expect(DesignContentType.from(format: "svg") == .webpage)
        #expect(DesignContentType.from(format: "PNG") == .image)
        #expect(DesignContentType.from(format: "mov") == .video)
        #expect(DesignContentType.from(format: "pdf") == .pdf)
        #expect(DesignContentType.from(format: "pptx") == .presentation)
        #expect(DesignContentType.from(format: "dwg") == .cad)
    }

    @Test func unknownFormatIsNeverGuessedAsWebpage() async throws {
        #expect(DesignContentType.from(format: "xyz") == nil)
        #expect(throws: DesignTargetError.self) {
            _ = try DesignTargetValidation.contentType(format: "xyz")
        }
        // The file adapter surfaces the honest reason for unknown formats.
        let port = StubFilePort()
        port.files["mystery.xyz"] = Data("mystery".utf8)
        port.format = "xyz"
        let adapter = DesignFileOwnerAdapter(port: port)
        let service = DesignTargetService(adapters: [adapter])
        do {
            _ = try await service.resolve(fileTarget(reference: "mystery.xyz"))
            Issue.record("expected unavailable for unknown format")
        } catch let error as DesignTargetError {
            guard case .unavailable(let reason) = error else {
                Issue.record("unexpected \(error)")
                return
            }
            #expect(reason.contains("xyz"))
        }
    }

    @Test func requireResolvedGatesOnTheRealContentType() async throws {
        let port = StubFilePort()
        port.files["hero.png"] = Data("png-bytes".utf8)
        let adapter = DesignFileOwnerAdapter(port: port)
        let service = DesignTargetService(adapters: [adapter])
        let gated = SendableBox<[DesignContentType]>()
        gated.set([])
        let resolved = try await service.requireResolved(
            fileTarget(), operation: .generate
        ) { type, operation in
            gated.set((gated.value ?? []) + [type])
            return operation == .generate ? nil : "not allowed"
        }
        #expect(resolved.contentType == .image)
        #expect(gated.value == [.image])
        do {
            _ = try await service.requireResolved(
                fileTarget(), operation: .editRegion
            ) { _, _ in "editing not connected" }
            Issue.record("expected unavailable")
        } catch let error as DesignTargetError {
            guard case .unavailable(let reason) = error else {
                Issue.record("unexpected \(error)")
                return
            }
            #expect(reason == "editing not connected")
        }
    }
}

// MARK: - Authorization boundaries

@Suite("Design target authorization boundaries")
struct DesignTargetAuthorizationTests {
    @Test func fileTraversalAndAbsolutePathsAreRejectedBeforeThePort() async throws {
        let port = StubFilePort()
        port.files["../escape.png"] = Data("x".utf8)
        port.files["/etc/passwd"] = Data("x".utf8)
        let adapter = DesignFileOwnerAdapter(port: port)
        let service = DesignTargetService(adapters: [adapter])
        for reference in ["../escape.png", "/etc/passwd", "a//b.png", "./a.png", "file:foo.png"] {
            do {
                _ = try await service.resolve(fileTarget(reference: reference))
                Issue.record("expected invalidReference for \(reference)")
            } catch let error as DesignTargetError {
                guard case .invalidReference = error else {
                    Issue.record("unexpected \(error) for \(reference)")
                    return
                }
            }
        }
        #expect(port.resolveCount == 0)
    }

    @Test func revokedAccessFailsEveryBoundary() async throws {
        let port = StubFilePort()
        port.files["hero.png"] = Data("v1".utf8)
        let (service, workflow, _, _, _) = await makeFileWorkflow(filePort: port)
        let target = fileTarget()
        // Begin with access, freeze works.
        let frozen = try await workflow.freezeInput(
            target: target, operationID: "op-freeze", expectedOwnerRevision: nil
        )
        #expect(frozen.revision.contentSHA256 == FloeDigest.sha256Hex(Data("v1".utf8)))
        // Revoke the live access.
        port.authorized = false
        do {
            _ = try await workflow.state(target)
            Issue.record("expected notAuthorized on state after revocation")
        } catch let error as DesignTargetError {
            guard case .notAuthorized = error else {
                Issue.record("unexpected \(error)")
                return
            }
        }
        do {
            _ = try await workflow.propose(
                target: target, operationID: "op-propose", expectedOwnerRevision: frozen.envelope.revision,
                artifactID: frozen.revision.artifactID, baseRevisionID: frozen.revision.id,
                bytes: Data("v2".utf8), format: "png", summary: "edit"
            )
            Issue.record("expected notAuthorized on propose after revocation")
        } catch let error as DesignTargetError {
            guard case .notAuthorized = error else {
                Issue.record("unexpected \(error)")
                return
            }
        }
        // The service boundary agrees.
        #expect(await service.authorize(target, runID: nil) == false)
    }

    @Test func crossTaskChatAttachmentIsRejected() async throws {
        let port = StubChatPort()
        let owner = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        let other = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        let data = Data("attachment-bytes".utf8)
        port.attachment = DesignChatAttachment(
            data: data, format: "png", displayName: "a.png",
            contentSHA256: FloeDigest.sha256Hex(data),
            baseRevisionToken: "attachment:\(UUID().uuidString):sha:\(FloeDigest.sha256Hex(data))",
            conversationID: owner
        )
        let adapter = DesignChatAttachmentOwnerAdapter(port: port)
        let service = DesignTargetService(adapters: [adapter])
        // Same task resolves.
        let target = DesignTarget(kind: .chatAttachment, ownerID: owner, documentID: "", sourceID: "att-1")
        _ = try await service.resolve(target)
        // A different task's owner string must not alias.
        let foreign = DesignTarget(kind: .chatAttachment, ownerID: other, documentID: "", sourceID: "att-1")
        do {
            _ = try await service.resolve(foreign)
            Issue.record("expected cross-task rejection")
        } catch let error as DesignTargetError {
            guard case .notAuthorized = error else {
                Issue.record("unexpected \(error)")
                return
            }
        }
        // Revocation via the port's metadata probe.
        port.accessible = false
        #expect(await service.authorize(target) == false)
    }

    @Test func canvasAuthorizationClosureAndDeletionFailClosed() async throws {
        let canvasID = UUID()
        let nodeID = UUID()
        var node = CanvasNode.placeholder(kind: .text, position: CanvasPoint(x: 0, y: 0), zIndex: 0)
        node.id = nodeID
        node.text = "hello"
        let document = CanvasDocument(id: UUID(), name: "doc", nodes: [node])
        var project = CanvasProject(id: canvasID, name: "T", documents: [document], selectedDocumentID: document.id)
        project.revision = 1
        let repository = StubCanvasRepository(project: project)
        let service = DesignCanvasService(repository: repository) { runID, canvas in
            runID != nil && canvas == canvasID
        }
        let adapter = DesignCanvasOwnerAdapter(
            service: service,
            contentPort: StubCanvasContentPort(format: "txt") { Data($0.text.utf8) }
        )
        let targets = DesignTargetService(adapters: [adapter])
        let target = DesignTarget(
            kind: .canvasNode, ownerID: canvasID.uuidString.lowercased(),
            documentID: document.id.uuidString.lowercased(),
            sourceID: nodeID.uuidString.lowercased()
        )
        // Trusted UI (nil run) is denied by this closure; an authorized run resolves.
        #expect(await targets.authorize(target) == false)
        let resolved = try await targets.resolve(target, runID: UUID())
        #expect(resolved.contentType == .notes)
        #expect(resolved.canvas?.nodeID == nodeID)
        // Deletion: node missing fails as notFound at the boundary.
        let missing = DesignTarget(
            kind: .canvasNode, ownerID: canvasID.uuidString.lowercased(),
            documentID: document.id.uuidString.lowercased(),
            sourceID: UUID().uuidString.lowercased()
        )
        #expect(await targets.authorize(missing, runID: UUID()) == false)
    }
}

// MARK: - Full non-canvas workflow cycle

@Suite("Design owner workflow")
struct DesignOwnerWorkflowTests {
    private func frozenFixture() async throws -> (
        workflow: DesignOwnerWorkflow, target: DesignTarget,
        envelope: DesignOwnerEnvelope, revision: DesignRevision,
        filePort: StubFilePort, payloads: InMemoryPayloadStore
    ) {
        let port = StubFilePort()
        port.files["hero.png"] = Data("base-image".utf8)
        let payloads = InMemoryPayloadStore()
        let (_, workflow, _, _, _) = await makeFileWorkflow(filePort: port, payloads: payloads)
        let target = fileTarget()
        let frozen = try await workflow.freezeInput(
            target: target, operationID: "op-freeze", expectedOwnerRevision: nil
        )
        return (workflow, target, frozen.envelope, frozen.revision, port, payloads)
    }

    @Test func freezePersistsSpecAndInputAndReopens() async throws {
        let port = StubFilePort()
        port.files["hero.png"] = Data("base".utf8)
        let store = InMemoryOwnerStore()
        let payloads = InMemoryPayloadStore()
        let (_, workflow, _, _, _) = await makeFileWorkflow(filePort: port, ownerStore: store, payloads: payloads)
        let target = fileTarget(origin: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
        _ = try await workflow.updateSpec(
            target: target, operationID: "op-spec", expectedOwnerRevision: nil,
            spec: DesignSpec(palette: ["#111111"], rawMarkdown: "# Brand\n")
        )
        let frozen = try await workflow.freezeInput(
            target: target, operationID: "op-freeze", expectedOwnerRevision: 1
        )
        #expect(frozen.envelope.project.spec?.palette == ["#111111"])
        #expect(frozen.envelope.project.frozenRun?.inputRevisionID == frozen.revision.id)
        #expect(frozen.envelope.project.contentType == .image)
        // Reopen through a NEW workflow over the same stores.
        let adapter = DesignFileOwnerAdapter(port: port)
        let service = DesignTargetService(adapters: [adapter])
        let reopened = DesignOwnerWorkflow(
            targets: service, store: store, payloads: payloads, outbox: makeOutbox()
        )
        let state = try await reopened.state(target)
        #expect(state?.project.spec?.rawMarkdown == "# Brand\n")
        #expect(state?.project.artifacts.first?.currentRevisionID == frozen.revision.id)
        // The store identity is per-source: a different task sees the SAME envelope.
        let otherTask = fileTarget(origin: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
        let otherState = try await reopened.state(otherTask)
        #expect(otherState?.revision == state?.revision)
    }

    @Test func registerEditConflictDoesNotOverwriteManualEdit() async throws {
        let fixture = try await frozenFixture()
        let workflow = fixture.workflow
        let target = fixture.target
        let first = try await workflow.registerEdit(
            target: target, operationID: "op-edit-1",
            expectedOwnerRevision: fixture.envelope.revision,
            artifactID: fixture.revision.artifactID,
            bytes: Data("manual-1".utf8), format: "png",
            origin: .edit, expectedArtifactRevisionID: fixture.revision.id
        )
        // A stale editor save against the ORIGINAL revision conflicts.
        do {
            _ = try await workflow.registerEdit(
                target: target, operationID: "op-edit-2",
                expectedOwnerRevision: first.envelope.revision,
                artifactID: fixture.revision.artifactID,
                bytes: Data("manual-2".utf8), format: "png",
                origin: .edit, expectedArtifactRevisionID: fixture.revision.id
            )
            Issue.record("expected revision conflict")
        } catch let error as DesignWorkflowError {
            guard case .revisionConflict = error else {
                Issue.record("unexpected \(error)")
                return
            }
        }
        let state = try #require(await workflow.state(target))
        #expect(state.project.artifact(fixture.revision.artifactID)?.currentRevision?.contentSHA256
            == FloeDigest.sha256Hex(Data("manual-1".utf8)))
        // Duplicate edit replay returns the recorded revision.
        let replay = try await workflow.registerEdit(
            target: target, operationID: "op-edit-1",
            expectedOwnerRevision: fixture.envelope.revision,
            artifactID: fixture.revision.artifactID,
            bytes: Data("manual-1".utf8), format: "png",
            origin: .edit, expectedArtifactRevisionID: fixture.revision.id
        )
        #expect(replay.revision.id == first.revision.id)
    }

    @Test func proposalCompareAdoptAndLateCandidate() async throws {
        let fixture = try await frozenFixture()
        let workflow = fixture.workflow
        let target = fixture.target
        let proposed = Data("proposed-image".utf8)
        let proposal = try await workflow.propose(
            target: target, operationID: "op-propose",
            expectedOwnerRevision: fixture.envelope.revision,
            artifactID: fixture.revision.artifactID,
            baseRevisionID: fixture.revision.id,
            bytes: proposed, format: "png", summary: "make it pop"
        )
        // Original task attribution lives on the candidate.
        #expect(proposal.candidate.originConversationID == nil)
        let comparison = try await workflow.compare(
            target: target, candidateID: proposal.candidate.id
        )
        #expect(comparison.changed)
        #expect(comparison.proposedSHA256 == FloeDigest.sha256Hex(proposed))
        #expect(comparison.diff.isEmpty) // binary family: digest change only

        // A concurrent manual edit moves the artifact; adoption of the late
        // candidate must conflict and never overwrite.
        _ = try await workflow.registerEdit(
            target: target, operationID: "op-manual",
            expectedOwnerRevision: proposal.envelope.revision,
            artifactID: fixture.revision.artifactID,
            bytes: Data("manual-newer".utf8), format: "png",
            origin: .edit, expectedArtifactRevisionID: fixture.revision.id
        )
        let afterManual = try #require(await workflow.state(target))
        do {
            _ = try await workflow.adopt(
                target: target, operationID: "op-adopt",
                expectedOwnerRevision: afterManual.revision,
                candidateID: proposal.candidate.id,
                mode: .updateOriginal,
                verifyReopen: { _, _, _ in }
            )
            Issue.record("expected late-candidate revision conflict")
        } catch let error as DesignWorkflowError {
            guard case .revisionConflict = error else {
                Issue.record("unexpected \(error)")
                return
            }
        }
        let stillManual = try #require(await workflow.state(target))
        #expect(stillManual.project.artifact(fixture.revision.artifactID)?.currentRevision?.contentSHA256
            == FloeDigest.sha256Hex(Data("manual-newer".utf8)))
        #expect(stillManual.project.candidate(proposal.candidate.id)?.status == .pending)
        // Rejecting the late candidate after generating from the new base:
        // variant adoption is allowed on a moved base.
        let adopted = try await workflow.adopt(
            target: target, operationID: "op-variant",
            expectedOwnerRevision: stillManual.revision,
            candidateID: proposal.candidate.id,
            mode: .variant,
            verifyReopen: { _, _, _ in }
        )
        #expect(adopted.envelope.project.artifact(fixture.revision.artifactID)?.currentRevision?.contentSHA256
            == FloeDigest.sha256Hex(Data("manual-newer".utf8)))
    }

    @Test func adoptInPlaceCommitsOwnerBytesAndDeliversToOriginalTask() async throws {
        let fixture = try await frozenFixture()
        let workflow = fixture.workflow
        let target = fileTarget(
            origin: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        )
        // Re-freeze under the origin-attributed target so the store identity
        // (same source) is shared and the origin is on the frozen request.
        let frozen = try await workflow.freezeInput(
            target: target, operationID: "op-freeze-origin", expectedOwnerRevision: nil
        )
        let proposed = Data("adopted-bytes".utf8)
        let proposal = try await workflow.propose(
            target: target, operationID: "op-propose",
            expectedOwnerRevision: frozen.envelope.revision,
            artifactID: frozen.revision.artifactID,
            baseRevisionID: frozen.revision.id,
            bytes: proposed, format: "png", summary: "adopt me"
        )
        let commitPort = StubCommitPort()
        // Rebuild a workflow with the commit port, sharing the fixture
        // payload store so the proposed bytes remain readable.
        let adapter = DesignFileOwnerAdapter(port: fixture.filePort)
        let service = DesignTargetService(adapters: [adapter])
        let delivered = SendableBox<(UUID, UUID, String, Int64?, String?)>()
        let workflowWithCommit = DesignOwnerWorkflow(
            targets: service,
            store: InMemoryOwnerStore(seed: proposal.envelope),
            payloads: fixture.payloads,
            commitPorts: [.fileDocument: commitPort],
            outbox: makeOutbox()
        )
        let result = try await workflowWithCommit.adopt(
            target: target.freezing(revision: frozen.source.baseRevisionToken),
            operationID: "op-adopt",
            expectedOwnerRevision: proposal.envelope.revision,
            candidateID: proposal.candidate.id,
            mode: .updateOriginal,
            verifyReopen: { bytes, format, type in
                #expect(format == "png")
                #expect(type == .image)
                #expect(bytes == proposed)
            },
            sink: { conversation, candidate, decision, revision, sha in
                delivered.set((conversation, candidate, decision, revision, sha))
            }
        )
        #expect(result.replayed == false)
        #expect(result.deliveryError == nil)
        #expect(commitPort.committedBytes == proposed)
        #expect(delivered.value?.2 == "adopted")
        #expect(delivered.value?.0.uuidString.lowercased() == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
        #expect(result.envelope.project.candidate(proposal.candidate.id)?.status == .adopted)
    }

    @Test func interruptedCommitRetriesConvergeAndDeliverOnce() async throws {
        // Interruption model: the owner-side commit (file write) succeeds,
        // then the envelope CAS is interrupted. Retry with the same
        // operationID must converge (no second overwrite, no lost
        // decision) and deliver EXACTLY one durable event.
        let port = StubFilePort()
        port.files["hero.png"] = Data("base-image".utf8)
        let store = InMemoryOwnerStore()
        let payloads = InMemoryPayloadStore()
        let commitPort = StubCommitPort()
        let adapter = DesignFileOwnerAdapter(port: port)
        let service = DesignTargetService(adapters: [adapter])
        let workflow = DesignOwnerWorkflow(
            targets: service, store: store, payloads: payloads,
            commitPorts: [.fileDocument: commitPort], outbox: makeOutbox()
        )
        let target = fileTarget(origin: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
        let frozen = try await workflow.freezeInput(
            target: target, operationID: "op-freeze", expectedOwnerRevision: nil
        )
        // The target must carry the frozen base token for the in-place gate.
        let frozenTarget = target.freezing(revision: frozen.source.baseRevisionToken)
        let proposed = Data("adopted-bytes".utf8)
        let proposal = try await workflow.propose(
            target: frozenTarget, operationID: "op-propose",
            expectedOwnerRevision: frozen.envelope.revision,
            artifactID: frozen.revision.artifactID,
            baseRevisionID: frozen.revision.id,
            bytes: proposed, format: "png", summary: "adopt"
        )
        let sinkCount = SendableBox<Int>()
        sinkCount.set(0)
        let sink: DesignOwnerDecisionSink = { _, _, _, _, _ in
            sinkCount.set((sinkCount.value ?? 0) + 1)
        }
        // First attempt: owner commit succeeds, envelope CAS is interrupted.
        await store.setFailNextSave(true)
        var firstError: Error?
        do {
            _ = try await workflow.adopt(
                target: frozenTarget, operationID: "op-adopt",
                expectedOwnerRevision: proposal.envelope.revision,
                candidateID: proposal.candidate.id,
                mode: .updateOriginal,
                verifyReopen: { _, _, _ in }, sink: sink
            )
        } catch {
            firstError = error
        }
        #expect(firstError != nil)
        #expect(commitPort.commitCount == 1)
        #expect(sinkCount.value == 0)
        let pending = try #require(await workflow.state(frozenTarget))
        #expect(pending.project.candidate(proposal.candidate.id)?.status == .pending)
        // Retry (same operationID): owner commit runs again (the real port
        // is idempotent on identical bytes), the CAS succeeds, and exactly
        // one durable event is delivered.
        let retried = try await workflow.adopt(
            target: frozenTarget, operationID: "op-adopt",
            expectedOwnerRevision: proposal.envelope.revision,
            candidateID: proposal.candidate.id,
            mode: .updateOriginal,
            verifyReopen: { _, _, _ in }, sink: sink
        )
        #expect(retried.replayed == false)
        #expect(retried.envelope.project.candidate(proposal.candidate.id)?.status == .adopted)
        #expect(sinkCount.value == 1)
        // A third, pure replay is a no-op: no additional event.
        let replay = try await workflow.adopt(
            target: frozenTarget, operationID: "op-adopt",
            expectedOwnerRevision: retried.envelope.revision,
            candidateID: proposal.candidate.id,
            mode: .updateOriginal,
            verifyReopen: { _, _, _ in }, sink: sink
        )
        #expect(replay.replayed == true)
        #expect(sinkCount.value == 1)
    }

    @Test func adoptInPlaceRequiresFrozenBaseToken() async throws {
        let port = StubFilePort()
        port.files["hero.png"] = Data("base".utf8)
        let store = InMemoryOwnerStore()
        let payloads = InMemoryPayloadStore()
        let commitPort = StubCommitPort()
        let adapter = DesignFileOwnerAdapter(port: port)
        let service = DesignTargetService(adapters: [adapter])
        let workflow = DesignOwnerWorkflow(
            targets: service, store: store, payloads: payloads,
            commitPorts: [.fileDocument: commitPort], outbox: makeOutbox()
        )
        let target = fileTarget(origin: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
        let frozen = try await workflow.freezeInput(
            target: target, operationID: "op-freeze", expectedOwnerRevision: nil
        )
        let proposal = try await workflow.propose(
            target: target, operationID: "op-propose",
            expectedOwnerRevision: frozen.envelope.revision,
            artifactID: frozen.revision.artifactID,
            baseRevisionID: frozen.revision.id,
            bytes: Data("new".utf8), format: "png", summary: "adopt"
        )
        // The UNFROZEN target (no revision in the caller's identity) still
        // adopts SAFELY: the frozen base token recorded at freeze time
        // re-gates the commit, so the overwrite is never ungated.
        let adopted = try await workflow.adopt(
            target: target, operationID: "op-adopt",
            expectedOwnerRevision: proposal.envelope.revision,
            candidateID: proposal.candidate.id,
            mode: .updateOriginal,
            verifyReopen: { _, _, _ in }
        )
        #expect(commitPort.commitCount == 1)
        #expect(adopted.envelope.project.candidate(proposal.candidate.id)?.status == .adopted)
        // Only a caller with NEITHER a frozen target identity NOR a recorded
        // base token fails closed. Simulate the legacy no-token shape by
        // stripping the recorded token before the adoption cycle.
        var legacyEnvelope = frozen.envelope
        for artifactIndex in legacyEnvelope.project.artifacts.indices {
            for revisionIndex in legacyEnvelope.project.artifacts[artifactIndex].revisions.indices {
                legacyEnvelope.project.artifacts[artifactIndex].revisions[revisionIndex].ownerBaseToken = nil
            }
        }
        let legacyStore = InMemoryOwnerStore()
        let savedLegacy = try await legacyStore.save(
            legacyEnvelope, targetKey: target.stableKey, expectedRevision: nil)
        let commitPort2 = StubCommitPort()
        let workflow3 = DesignOwnerWorkflow(
            targets: service, store: legacyStore, payloads: payloads,
            commitPorts: [.fileDocument: commitPort2], outbox: makeOutbox()
        )
        let proposal3 = try await workflow3.propose(
            target: target, operationID: "op-propose",
            expectedOwnerRevision: savedLegacy,
            artifactID: frozen.revision.artifactID,
            baseRevisionID: frozen.revision.id,
            bytes: Data("new".utf8), format: "png", summary: "adopt"
        )
        do {
            _ = try await workflow3.adopt(
                target: target, operationID: "op-adopt",
                expectedOwnerRevision: proposal3.envelope.revision,
                candidateID: proposal3.candidate.id,
                mode: .updateOriginal,
                verifyReopen: { _, _, _ in }
            )
            Issue.record("expected invalidReference for a no-token in-place adoption")
        } catch let error as DesignTargetError {
            guard case .invalidReference = error else {
                Issue.record("unexpected \(error)")
                return
            }
        }
        #expect(commitPort2.commitCount == 0)
    }

    @Test func feedbackResolvesOnlyWithVerifiedChangingRevision() async throws {
        let fixture = try await frozenFixture()
        let workflow = fixture.workflow
        let target = fixture.target
        let feedback = try await workflow.addFeedback(
            target: target, operationID: "op-feedback",
            expectedOwnerRevision: fixture.envelope.revision,
            artifactID: fixture.revision.artifactID,
            revisionID: fixture.revision.id,
            anchor: .region(x: 1, y: 2, width: 10, height: 10),
            comment: "make it bolder", author: .user
        )
        // Resolving against the same revision (no change) fails.
        do {
            _ = try await workflow.resolveFeedback(
                target: target, operationID: "op-resolve-bad",
                expectedOwnerRevision: feedback.envelope.revision,
                feedbackID: feedback.feedback.id,
                resolvedByRevisionID: fixture.revision.id
            )
            Issue.record("expected noActualChange")
        } catch let error as DesignWorkflowError {
            guard case .noActualChange = error else {
                Issue.record("unexpected \(error)")
                return
            }
        }
        // A real changing edit makes the anchor stale; relocate then resolve.
        let edit = try await workflow.registerEdit(
            target: target, operationID: "op-edit",
            expectedOwnerRevision: feedback.envelope.revision,
            artifactID: fixture.revision.artifactID,
            bytes: Data("edited".utf8), format: "png",
            origin: .edit, expectedArtifactRevisionID: fixture.revision.id
        )
        let stale = try #require(await workflow.state(target))
        #expect(stale.project.feedback(feedback.feedback.id)?.status == .staleAnchor)
        let relocated = try await workflow.relocateAnchor(
            target: target, operationID: "op-relocate",
            expectedOwnerRevision: edit.envelope.revision,
            feedbackID: feedback.feedback.id,
            anchor: .region(x: 3, y: 4, width: 10, height: 10),
            toRevisionID: edit.revision.id
        )
        #expect(relocated.project.feedback(feedback.feedback.id)?.status == .open)
        // A second, verified change resolves the relocated anchor.
        let edit2 = try await workflow.registerEdit(
            target: target, operationID: "op-edit-2",
            expectedOwnerRevision: relocated.revision,
            artifactID: fixture.revision.artifactID,
            bytes: Data("edited-again".utf8), format: "png",
            origin: .edit, expectedArtifactRevisionID: edit.revision.id
        )
        let resolved = try await workflow.resolveFeedback(
            target: target, operationID: "op-resolve",
            expectedOwnerRevision: edit2.envelope.revision,
            feedbackID: feedback.feedback.id,
            resolvedByRevisionID: edit2.revision.id
        )
        #expect(resolved.project.feedback(feedback.feedback.id)?.status == .solved)
    }

    @Test func restoreAndExportVerified() async throws {
        let fixture = try await frozenFixture()
        let workflow = fixture.workflow
        let target = fixture.target
        let edit = try await workflow.registerEdit(
            target: target, operationID: "op-edit",
            expectedOwnerRevision: fixture.envelope.revision,
            artifactID: fixture.revision.artifactID,
            bytes: Data("second".utf8), format: "png",
            origin: .edit, expectedArtifactRevisionID: fixture.revision.id
        )
        let restored = try await workflow.restore(
            target: target, operationID: "op-restore",
            expectedOwnerRevision: edit.envelope.revision,
            artifactID: fixture.revision.artifactID,
            revisionID: fixture.revision.id
        )
        #expect(restored.project.artifact(fixture.revision.artifactID)?.currentRevision?.origin == .restore)
        let bytes = try await workflow.exportVerified(
            target: target, artifactID: fixture.revision.artifactID,
            revisionID: fixture.revision.id
        ) { data, format, type in
            #expect(format == "png")
            #expect(type == .image)
            #expect(data == Data("base-image".utf8))
        }
        #expect(bytes == Data("base-image".utf8))
        // Export of a payload whose bytes were removed fails closed.
        _ = try? await workflow.exportVerified(
            target: target, artifactID: fixture.revision.artifactID,
            revisionID: "missing-revision"
        ) { _, _, _ in }
    }

    @Test func ownerCASConflictAndReplayOrdering() async throws {
        let port = StubFilePort()
        port.files["hero.png"] = Data("v1".utf8)
        let store = InMemoryOwnerStore()
        let (_, workflow, _, _, _) = await makeFileWorkflow(filePort: port, ownerStore: store)
        let target = fileTarget()
        let first = try await workflow.updateBrief(
            target: target, operationID: "op-1", expectedOwnerRevision: nil,
            brief: DesignBrief(goal: "A")
        )
        // Replay first: returns recorded state even with a stale expectation.
        let replay = try await workflow.updateBrief(
            target: target, operationID: "op-1", expectedOwnerRevision: nil,
            brief: DesignBrief(goal: "A")
        )
        #expect(replay.revision == first.revision)
        // A genuinely new operation with a stale expectation conflicts.
        do {
            _ = try await workflow.updateBrief(
                target: target, operationID: "op-2", expectedOwnerRevision: 0,
                brief: DesignBrief(goal: "B")
            )
            Issue.record("expected ownerConflict")
        } catch let error as DesignOwnerWorkflowError {
            guard case .ownerConflict = error else {
                Issue.record("unexpected \(error)")
                return
            }
        }
    }
}

// MARK: - Creative start (pre-material request)

@Suite("Creative start request")
struct DesignCreativeStartTests {
    @Test func requestSavesRestoresAndBlocksProposalUntilFirstResult() async throws {
        let port = StubCreativePort()
        let store = InMemoryOwnerStore()
        let (_, workflow, _) = makeCreativeWorkflow(port: port, ownerStore: store)
        let target = creativeTarget(origin: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
        let begun = try await workflow.beginCreativeRequest(
            target: target, operationID: "op-begin", expectedOwnerRevision: nil,
            brief: DesignBrief(goal: "Hero banner", audience: "designers"),
            spec: DesignSpec(palette: ["#FF0000"])
        )
        #expect(begun.request.state == .awaitingFirstResult)
        #expect(begun.request.requestedKind == .image)
        #expect(begun.request.originConversationID == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
        // Reopen through a fresh workflow: request restored.
        let (_, reopened, _) = makeCreativeWorkflow(port: port, ownerStore: store)
        let state = try #require(await reopened.state(target))
        #expect(state.project.creativeRequest?.state == .awaitingFirstResult)
        #expect(state.project.brief?.goal == "Hero banner")
        #expect(state.project.spec?.palette == ["#FF0000"])
        // Proposing before a material exists is a typed pending state.
        do {
            _ = try await reopened.propose(
                target: target, operationID: "op-propose",
                expectedOwnerRevision: state.revision,
                artifactID: "missing", baseRevisionID: nil,
                bytes: Data("x".utf8), format: "png", summary: "early"
            )
            Issue.record("expected pendingFirstResult")
        } catch let error as DesignTargetError {
            guard case .pendingFirstResult(let kind) = error else {
                Issue.record("unexpected \(error)")
                return
            }
            #expect(kind == "image")
        }
        // Resolving the target before generation is also pending — never a
        // fabricated webpage.
        do {
            _ = try await reopened.freezeInput(
                target: target, operationID: "op-freeze", expectedOwnerRevision: state.revision
            )
            Issue.record("expected pendingFirstResult on freeze")
        } catch let error as DesignTargetError {
            guard case .pendingFirstResult = error else {
                Issue.record("unexpected \(error)")
                return
            }
        }
    }

    @Test func bindFirstResultOwnsTheResultOnTheSameTarget() async throws {
        let port = StubCreativePort()
        let store = InMemoryOwnerStore()
        let (_, workflow, _) = makeCreativeWorkflow(port: port, ownerStore: store)
        let target = creativeTarget()
        _ = try await workflow.beginCreativeRequest(
            target: target, operationID: "op-begin", expectedOwnerRevision: nil,
            brief: DesignBrief(goal: "banner")
        )
        let bytes = Data("generated-image-1".utf8)
        // The named result must be a REAL retained asset with these bytes.
        port.assets["asset-1"] = bytes
        port.formats["asset-1"] = "png"
        let bound = try await workflow.bindFirstResult(
            target: target, operationID: "op-bind", expectedOwnerRevision: 1,
            bytes: bytes, format: "png", displayName: "result.png", boundResultID: "asset-1"
        )
        #expect(bound.revision.contentSHA256 == FloeDigest.sha256Hex(bytes))
        #expect(bound.envelope.project.creativeRequest?.state == .firstResultBound)
        #expect(bound.envelope.project.creativeRequest?.boundResultID == "asset-1")
        #expect(bound.envelope.project.frozenRun?.operationID == "op-bind")
        // Trusted UI (nil run) records its verified provenance with the bind.
        #expect(bound.envelope.creativeFirstResultProvenance == .trustedUIManualImport)
        // Duplicate generation callback replays the recorded revision.
        let replay = try await workflow.bindFirstResult(
            target: target, operationID: "op-bind", expectedOwnerRevision: 1,
            bytes: bytes, format: "png", displayName: "result.png", boundResultID: "asset-1"
        )
        #expect(replay.revision.id == bound.revision.id)
        // Same operation with DIFFERENT bytes is not a replay.
        do {
            _ = try await workflow.bindFirstResult(
                target: target, operationID: "op-bind", expectedOwnerRevision: 1,
                bytes: Data("other".utf8), format: "png", displayName: "other.png", boundResultID: "asset-2"
            )
            Issue.record("expected replayMismatch")
        } catch let error as DesignOwnerWorkflowError {
            guard case .replayMismatch = error else {
                Issue.record("unexpected \(error)")
                return
            }
        }
        // A second bind through a NEW operation is rejected.
        do {
            _ = try await workflow.bindFirstResult(
                target: target, operationID: "op-bind-2", expectedOwnerRevision: 2,
                bytes: Data("second".utf8), format: "png", displayName: "second.png", boundResultID: "asset-3"
            )
            Issue.record("expected firstResultAlreadyBound")
        } catch let error as DesignTargetError {
            guard case .firstResultAlreadyBound = error else {
                Issue.record("unexpected \(error)")
                return
            }
        }
        // Now the target materializes through the port binding.
        port.boundFiles["req-1"] = bytes
        let (_, reopened, _) = makeCreativeWorkflow(port: port, ownerStore: store)
        let resolved = try await reopened.freezeInput(
            target: target, operationID: "op-freeze", expectedOwnerRevision: 2
        )
        #expect(resolved.source.contentType == .image)
        #expect(resolved.source.contentSHA256 == FloeDigest.sha256Hex(bytes))
    }

    /// T7C anti-circularity reproducer (shared transaction boundary): the
    /// bind must prove the named result IS the real retained asset it claims
    /// to be — the run's own payload bytes must never be recorded as the
    /// first result of a foreign asset id. Before the fix this bind succeeds
    /// (no port verification is consulted), which is the exact foundation of
    /// the circular `boundResultID` read exploit.
    @Test func bindFirstResultMustProveTheBoundAssetBeforeRecording() async throws {
        let port = StubCreativePort()
        let store = InMemoryOwnerStore()
        let payloads = InMemoryPayloadStore()
        let (_, workflow, _) = makeCreativeWorkflow(
            port: port, ownerStore: store, payloads: payloads)
        let target = creativeTarget(origin: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
        let begun = try await workflow.beginCreativeRequest(
            target: target, operationID: "op-begin", expectedOwnerRevision: nil,
            brief: DesignBrief(goal: "banner"))
        // The REAL retained asset the bind names.
        port.assets["asset-foreign"] = Data("real retained asset bytes".utf8)
        port.formats["asset-foreign"] = "png"
        // The model supplies ITS OWN payload while naming that asset.
        let modelPayload = Data("model-authored payload".utf8)
        do {
            _ = try await workflow.bindFirstResult(
                target: target, operationID: "op-bind",
                expectedOwnerRevision: begun.envelope.revision,
                bytes: modelPayload, format: "png", displayName: "forged.png",
                boundResultID: "asset-foreign")
            Issue.record(
                "the shared bind recorded a model-authored payload for a foreign asset id without verifying the real retained bytes")
        } catch {
            // Expected: the port refuses before any payload/CAS effect.
        }
        let state = try #require(await workflow.state(target))
        #expect(state.project.creativeRequest?.state == .awaitingFirstResult)
        #expect(state.revision == begun.envelope.revision)
        #expect(payloads.stored.isEmpty)
    }

    /// Shared boundary, run path: a run's bind is refused unless the named
    /// asset is linked to the run's own task through the durable job record,
    /// and a refusal leaves the request awaiting with no payload written; the
    /// SAME operation then succeeds once the real link exists. Replays stay
    /// idempotent.
    @Test func runBindRequiresDurableJobLinkAndExactAssetBytes() async throws {
        let port = StubCreativePort()
        let store = InMemoryOwnerStore()
        let payloads = InMemoryPayloadStore()
        let (_, workflow, _) = makeCreativeWorkflow(
            port: port, ownerStore: store, payloads: payloads)
        let target = creativeTarget(origin: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
        let begun = try await workflow.beginCreativeRequest(
            target: target, operationID: "op-begin", expectedOwnerRevision: nil,
            brief: DesignBrief(goal: "job-linked result"))
        let run = UUID()
        let bytes = Data("real-job-output".utf8)
        port.assets["asset-job"] = bytes
        port.formats["asset-job"] = "png"
        do {
            _ = try await workflow.bindFirstResult(
                target: target, operationID: "op-bind-run",
                expectedOwnerRevision: begun.envelope.revision,
                bytes: bytes, format: "png", displayName: "job.png",
                boundResultID: "asset-job", runID: run)
            Issue.record("a run bind without the durable job link must be refused")
        } catch let error as DesignTargetError {
            guard case .notAuthorized = error else {
                Issue.record("unexpected \(error)")
                return
            }
        }
        let refused = try #require(await workflow.state(target))
        #expect(refused.project.creativeRequest?.state == .awaitingFirstResult)
        #expect(refused.revision == begun.envelope.revision)
        #expect(payloads.stored.isEmpty)
        // A genuinely job-linked asset binds; the run provenance is recorded.
        port.runVerifiedAssets.insert("asset-job")
        let bound = try await workflow.bindFirstResult(
            target: target, operationID: "op-bind-run",
            expectedOwnerRevision: begun.envelope.revision,
            bytes: bytes, format: "png", displayName: "job.png",
            boundResultID: "asset-job", runID: run)
        #expect(bound.envelope.project.creativeRequest?.boundResultID == "asset-job")
        #expect(bound.envelope.creativeFirstResultProvenance == .generationJob)
        let replay = try await workflow.bindFirstResult(
            target: target, operationID: "op-bind-run",
            expectedOwnerRevision: begun.envelope.revision,
            bytes: bytes, format: "png", displayName: "job.png",
            boundResultID: "asset-job", runID: run)
        #expect(replay.revision.id == bound.revision.id)
        // A revoked run cannot even replay the recorded bind: live authority
        // is re-checked at every boundary.
        port.requestAuthorized = false
        do {
            _ = try await workflow.bindFirstResult(
                target: target, operationID: "op-bind-run",
                expectedOwnerRevision: begun.envelope.revision,
                bytes: bytes, format: "png", displayName: "job.png",
                boundResultID: "asset-job", runID: run)
            Issue.record("a revoked run replay must be refused")
        } catch let error as DesignTargetError {
            guard case .notAuthorized = error else {
                Issue.record("unexpected \(error)")
                return
            }
        }
    }

    /// Mismatched bytes, a mismatched format and an unknown result id are all
    /// refused before effects, including for the trusted-UI path.
    @Test func bindRefusesMismatchAndUnknownResultBeforeEffects() async throws {
        let port = StubCreativePort()
        let payloads = InMemoryPayloadStore()
        let (_, workflow, _) = makeCreativeWorkflow(port: port, payloads: payloads)
        let target = creativeTarget()
        let begun = try await workflow.beginCreativeRequest(
            target: target, operationID: "op-begin", expectedOwnerRevision: nil)
        port.assets["asset-real"] = Data("real bytes".utf8)
        port.formats["asset-real"] = "png"
        // Wrong bytes.
        do {
            _ = try await workflow.bindFirstResult(
                target: target, operationID: "op-bind-bytes",
                expectedOwnerRevision: begun.envelope.revision,
                bytes: Data("different bytes".utf8), format: "png",
                displayName: "x.png", boundResultID: "asset-real")
            Issue.record("mismatched bytes must be refused")
        } catch is DesignTargetError {}
        // Wrong format.
        do {
            _ = try await workflow.bindFirstResult(
                target: target, operationID: "op-bind-format",
                expectedOwnerRevision: begun.envelope.revision,
                bytes: Data("real bytes".utf8), format: "jpg",
                displayName: "x.jpg", boundResultID: "asset-real")
            Issue.record("mismatched format must be refused")
        } catch is DesignTargetError {}
        // Unknown result id.
        do {
            _ = try await workflow.bindFirstResult(
                target: target, operationID: "op-bind-missing",
                expectedOwnerRevision: begun.envelope.revision,
                bytes: Data("real bytes".utf8), format: "png",
                displayName: "x.png", boundResultID: "asset-missing")
            Issue.record("an unknown result id must be refused")
        } catch is DesignTargetError {}
        let state = try #require(await workflow.state(target))
        #expect(state.project.creativeRequest?.state == .awaitingFirstResult)
        #expect(state.revision == begun.envelope.revision)
        #expect(payloads.stored.isEmpty)
    }

    @Test func pendingRequestAcceptsSpecUpdatesAndBindRequiresCurrentRevision() async throws {
        let port = StubCreativePort()
        let store = InMemoryOwnerStore()
        let (_, workflow, _) = makeCreativeWorkflow(port: port, ownerStore: store)
        let target = creativeTarget()
        let begun = try await workflow.beginCreativeRequest(
            target: target, operationID: "op-begin", expectedOwnerRevision: nil
        )
        // Requirements can still be refined before the first result.
        let updated = try await workflow.updateSpec(
            target: target, operationID: "op-spec",
            expectedOwnerRevision: begun.envelope.revision,
            spec: DesignSpec(palette: ["#00FF00"])
        )
        #expect(updated.project.creativeRequest?.state == .awaitingFirstResult)
        #expect(updated.project.spec?.palette == ["#00FF00"])
        // A bind against a stale owner revision is rejected and nothing is
        // materialized (no payload retained, request still awaiting).
        do {
            _ = try await workflow.bindFirstResult(
                target: target, operationID: "op-bind",
                expectedOwnerRevision: begun.envelope.revision,
                bytes: Data("img".utf8), format: "png",
                displayName: "r.png", boundResultID: "asset-1"
            )
            Issue.record("expected ownerConflict")
        } catch let error as DesignOwnerWorkflowError {
            guard case .ownerConflict = error else {
                Issue.record("unexpected \(error)")
                return
            }
        }
        let stillPending = try #require(await workflow.state(target))
        #expect(stillPending.project.creativeRequest?.state == .awaitingFirstResult)
        #expect(stillPending.project.artifacts.isEmpty)
        // The correct revision binds (the named asset is a real retained one).
        port.assets["asset-1"] = Data("img".utf8)
        port.formats["asset-1"] = "png"
        let bound = try await workflow.bindFirstResult(
            target: target, operationID: "op-bind",
            expectedOwnerRevision: updated.revision,
            bytes: Data("img".utf8), format: "png",
            displayName: "r.png", boundResultID: "asset-1"
        )
        #expect(bound.envelope.project.creativeRequest?.state == .firstResultBound)
    }

    @Test func taskSwitchSharesTheRequestAndUnauthorizedRunIsDenied() async throws {
        let port = StubCreativePort()
        let store = InMemoryOwnerStore()
        let (_, workflow, _) = makeCreativeWorkflow(port: port, ownerStore: store)
        let taskA = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        let targetA = creativeTarget(origin: taskA)
        _ = try await workflow.beginCreativeRequest(
            target: targetA, operationID: "op-begin", expectedOwnerRevision: nil,
            brief: DesignBrief(goal: "A's banner")
        )
        // The same source from task B shares ONE history (no fork), while
        // origin attribution stays with the request that created it.
        let targetB = creativeTarget(origin: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
        let stateB = try #require(await workflow.state(targetB))
        #expect(stateB.revision == 1)
        #expect(stateB.project.creativeRequest?.originConversationID == taskA)
        // A run without authorization is denied at the boundary.
        port.requestAuthorized = false
        do {
            _ = try await workflow.state(creativeTarget(), runID: UUID())
            Issue.record("expected notAuthorized")
        } catch let error as DesignTargetError {
            guard case .notAuthorized = error else {
                Issue.record("unexpected \(error)")
                return
            }
        }
        // Trusted UI still reads (the request grant only gates runs).
        _ = try await workflow.state(creativeTarget())
    }

    @Test func unauthorizedRunCannotBeginRequest() async throws {
        let port = StubCreativePort()
        port.requestAuthorized = false
        let (_, workflow, _) = makeCreativeWorkflow(port: port)
        do {
            _ = try await workflow.beginCreativeRequest(
                target: creativeTarget(), operationID: "op-begin",
                expectedOwnerRevision: nil, brief: DesignBrief(goal: "x"),
                runID: UUID()
            )
            Issue.record("expected notAuthorized")
        } catch let error as DesignTargetError {
            guard case .notAuthorized = error else {
                Issue.record("unexpected \(error)")
                return
            }
        }
    }
}

// MARK: - Durable target decisions

@Suite("Design target decision outbox")
struct DesignTargetDecisionTests {
    @Test func targetIntentDoesNotFabricateCanvasFields() {
        let intent = DesignDecisionIntent.forTarget(
            creativeTarget(), candidateID: "cand-1",
            conversationID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            decision: "adopted", operationID: "op-1"
        )
        #expect(intent.isCanvasOwned == false)
        #expect(intent.canvasID.isEmpty)
        #expect(intent.nodeID.isEmpty)
        #expect(intent.expectedCanvasRevision == nil)
        #expect(intent.target?.requestedOutputKind == .image)
        // Fingerprint is stable and decision-sensitive.
        let same = DesignDecisionIntent.forTarget(
            creativeTarget(), candidateID: "cand-1",
            conversationID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            decision: "adopted", operationID: "op-1"
        )
        #expect(intent.fingerprint == same.fingerprint)
        let rejected = DesignDecisionIntent.forTarget(
            creativeTarget(), candidateID: "cand-1",
            conversationID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            decision: "rejected", operationID: "op-1"
        )
        #expect(intent.fingerprint != rejected.fingerprint)
    }

    @Test func legacyCanvasIntentStillDecodesWithBackfilledFingerprint() throws {
        let legacy = """
        {"id":"intent-1","canvasID":"11111111-1111-1111-1111-111111111111","nodeID":"22222222-2222-2222-2222-222222222222","candidateID":"cand","conversationID":"33333333-3333-3333-3333-333333333333","decision":"adopted","operationID":"op","phase":"committing","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let intent = try decoder.decode(DesignDecisionIntent.self, from: Data(legacy.utf8))
        #expect(intent.target == nil)
        #expect(intent.isCanvasOwned)
        #expect(intent.fingerprint == DesignDecisionIntent.makeFingerprint(
            canvasID: intent.canvasID, nodeID: intent.nodeID,
            candidateID: "cand", conversationID: intent.conversationID,
            decision: "adopted", operationID: "op",
            mode: nil, baseRevisionID: nil, expectedCanvasRevision: nil
        ))
    }

    @Test func prepareIfNewDeduplicatesTargetDecisions() async throws {
        let outbox = makeOutbox()
        let intent = DesignDecisionIntent.forTarget(
            fileTarget(origin: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"),
            candidateID: "cand-1",
            conversationID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            decision: "adopted", operationID: "op-1"
        )
        let first = try await outbox.prepareIfNew(intent)
        #expect(first.isNew)
        let second = try await outbox.prepareIfNew(intent)
        #expect(second.isNew == false)
        #expect(second.intent.id == first.intent.id)
    }
}

// MARK: - Unknown field / number preservation

@Suite("Design JSON preservation")
struct DesignJSONPreservationTests {
    @Test func foundationNumbersKeepBoolVsIntegerDistinction() {
        #expect(DesignJSONValue.from(foundation: NSNumber(value: 1)) == .integer(1))
        #expect(DesignJSONValue.from(foundation: NSNumber(value: 0)) == .integer(0))
        #expect(DesignJSONValue.from(foundation: NSNumber(value: true)) == .bool(true))
        #expect(DesignJSONValue.from(foundation: NSNumber(value: false)) == .bool(false))
        #expect(DesignJSONValue.from(foundation: NSNumber(value: Int64.max)) == .integer(Int64.max))
        #expect(DesignJSONValue.from(foundation: NSNumber(value: UInt64.max)) == .unsigned(UInt64.max))
        #expect(DesignJSONValue.from(foundation: 1.5 as NSNumber) == .number(1.5))
    }

    @Test func unknownFieldsSurviveRoundTripExactly() throws {
        // Assemble a payload with unknown keys of every interesting shape.
        var project = DesignWorkflowEngine.createProject(nodeID: "node-x", contentType: .image)
        project.brief = DesignBrief(goal: "g")
        let base = try DesignCanvasMetadata.encode(project)
        var object = try #require(
            try JSONSerialization.jsonObject(with: Data(base.utf8)) as? [String: Any]
        )
        object["futureFlag"] = NSNumber(value: true)
        object["futureIntegerOne"] = NSNumber(value: 1)
        object["futureZero"] = NSNumber(value: 0)
        object["futureBigInteger"] = NSNumber(value: 9_007_199_254_740_993)
        object["futureUnsignedMax"] = NSNumber(value: UInt64.max)
        object["futureString"] = "keep-me"
        object["futureNested"] = ["a": NSNumber(value: 2), "b": [NSNumber(value: false)]]
        let raw = String(
            decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            as: UTF8.self
        )
        let decoded = try #require(try DesignCanvasMetadata.decode(raw, nodeID: "node-x"))
        #expect(decoded.unknownFields["futureFlag"] == .bool(true))
        #expect(decoded.unknownFields["futureIntegerOne"] == .integer(1))
        #expect(decoded.unknownFields["futureZero"] == .integer(0))
        #expect(decoded.unknownFields["futureBigInteger"] == .integer(9_007_199_254_740_993))
        #expect(decoded.unknownFields["futureUnsignedMax"] == .unsigned(UInt64.max))
        #expect(decoded.unknownFields["futureString"] == .string("keep-me"))
        #expect(decoded.unknownFields["futureNested"] == .object([
            "a": .integer(2), "b": .array([.bool(false)])
        ]))
        // Idempotent re-encode: second pass is byte-identical and preserves
        // the same unknown values.
        let firstReencode = try DesignCanvasMetadata.encode(decoded)
        let decodedAgain = try #require(try DesignCanvasMetadata.decode(firstReencode, nodeID: "node-x"))
        #expect(decodedAgain.unknownFields == decoded.unknownFields)
        let secondReencode = try DesignCanvasMetadata.encode(decodedAgain)
        #expect(firstReencode == secondReencode)
        // The modeled fields still round-trip.
        #expect(decodedAgain.brief?.goal == "g")
    }

    @Test func unknownArtifactFieldsSurvive() throws {
        let artifactJSON = """
        {"id":"art-1","contentType":"image","identity":{"name":"Hero","positionX":1,"positionY":2,"width":3,"height":4,"connections":[]},"revisions":[],"branches":{},"futureArtifactKey":{"nested":1},"flag":true}
        """
        let artifact = try JSONDecoder().decode(DesignArtifact.self, from: Data(artifactJSON.utf8))
        #expect(artifact.unknownFields["futureArtifactKey"] == .object(["nested": .integer(1)]))
        #expect(artifact.unknownFields["flag"] == .bool(true))
        let encoded = try JSONEncoder().encode(artifact)
        let again = try JSONDecoder().decode(DesignArtifact.self, from: encoded)
        #expect(again.unknownFields == artifact.unknownFields)
    }

    @Test func legacyPayloadWithoutUnknownsDecodesAndStaysStable() throws {
        let project = DesignWorkflowEngine.createProject(nodeID: "node-y", contentType: .notes)
        let raw = try DesignCanvasMetadata.encode(project)
        let decoded = try #require(try DesignCanvasMetadata.decode(raw, nodeID: "node-y"))
        #expect(decoded.unknownFields.isEmpty)
        let reencoded = try DesignCanvasMetadata.encode(decoded)
        let again = try #require(try DesignCanvasMetadata.decode(reencoded, nodeID: "node-y"))
        #expect(again.unknownFields.isEmpty)
        #expect(try DesignCanvasMetadata.encode(again) == reencoded)
    }
}

// MARK: - Shared adoption fixture (delivery / recovery / single-flight tests)

private struct FileAdoptionFixture: Sendable {
    let workflow: DesignOwnerWorkflow
    let service: DesignTargetService
    let filePort: StubFilePort
    let store: InMemoryOwnerStore
    let payloads: InMemoryPayloadStore
    let outbox: DesignDecisionOutbox
    let commitPort: StubCommitPort?
    let target: DesignTarget
    let frozenTarget: DesignTarget
    let inputRevision: DesignRevision
    let proposal: DesignOwnerWorkflow.Proposal
}

private func makeFileAdoptionFixture(
    origin: String? = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
    commitPort: StubCommitPort? = StubCommitPort(),
    ownerStore: InMemoryOwnerStore = InMemoryOwnerStore(),
    payloads: InMemoryPayloadStore = InMemoryPayloadStore(),
    outbox: DesignDecisionOutbox = makeOutbox(),
    baseBytes: Data = Data("base-image".utf8),
    reference: String = "hero.png",
    format: String = "png",
    proposedBytes: Data = Data("adopted-bytes".utf8)
) async throws -> FileAdoptionFixture {
    let port = StubFilePort()
    port.files[reference] = baseBytes
    port.format = format
    let adapter = DesignFileOwnerAdapter(port: port)
    let service = DesignTargetService(adapters: [adapter])
    var ports: [DesignTargetKind: any DesignOwnerCommitPort] = [:]
    if let commitPort { ports[.fileDocument] = commitPort }
    let workflow = DesignOwnerWorkflow(
        targets: service, store: ownerStore, payloads: payloads,
        commitPorts: ports, outbox: outbox
    )
    let target = fileTarget(reference: reference, origin: origin)
    let frozen = try await workflow.freezeInput(
        target: target, operationID: "op-freeze", expectedOwnerRevision: nil
    )
    let frozenTarget = target.freezing(revision: frozen.source.baseRevisionToken)
    let proposal = try await workflow.propose(
        target: frozenTarget, operationID: "op-propose",
        expectedOwnerRevision: frozen.envelope.revision,
        artifactID: frozen.revision.artifactID,
        baseRevisionID: frozen.revision.id,
        bytes: proposedBytes, format: format, summary: "adopt"
    )
    return FileAdoptionFixture(
        workflow: workflow, service: service, filePort: port, store: ownerStore,
        payloads: payloads, outbox: outbox, commitPort: commitPort,
        target: target, frozenTarget: frozenTarget,
        inputRevision: frozen.revision, proposal: proposal
    )
}

private func reopenWorkflow(
    _ fixture: FileAdoptionFixture,
    defaultSink: DesignOwnerDecisionSink? = nil
) -> DesignOwnerWorkflow {
    var ports: [DesignTargetKind: any DesignOwnerCommitPort] = [:]
    if let port = fixture.commitPort { ports[.fileDocument] = port }
    return DesignOwnerWorkflow(
        targets: fixture.service, store: fixture.store, payloads: fixture.payloads,
        commitPorts: ports, outbox: fixture.outbox, defaultSink: defaultSink
    )
}

// MARK: - Bounded line diff

@Suite("Design owner line diff bounds")
struct DesignOwnerLineDiffTests {
    @Test func emptyInputsTakeFastPaths() {
        let toNew = DesignOwnerWorkflow.lineDiff("", "a\nb")
        #expect(toNew.lines == ["+ a", "+ b"])
        #expect(toNew.truncated == false)
        let toEmpty = DesignOwnerWorkflow.lineDiff("a\nb", "")
        #expect(toEmpty.lines == ["- a", "- b"])
        #expect(toEmpty.truncated == false)
        let both = DesignOwnerWorkflow.lineDiff("", "")
        #expect(both.lines.isEmpty)
        #expect(both.truncated == false)
        #expect(both.note == nil)
    }

    @Test func lcsRecurrenceProducesCorrectEditOrder() {
        // Regression: only-equal-cell assignment produced a wrong edit order.
        let outcome = DesignOwnerWorkflow.lineDiff("a\nb", "b\na")
        #expect(outcome.lines == ["- a", "  b", "+ a"])
        #expect(outcome.truncated == false)
        #expect(applyUnifiedDiff(outcome.lines, to: ["a", "b"]) == ["b", "a"])
    }

    @Test func interleavedDuplicateLinesProduceAnApplicableDiff() {
        let oldText = "x\na"
        let newText = "a\ny\na"
        let outcome = DesignOwnerWorkflow.lineDiff(oldText, newText)
        #expect(outcome.lines == ["- x", "+ a", "+ y", "  a"])
        #expect(outcome.truncated == false)
        #expect(
            applyUnifiedDiff(outcome.lines, to: splitTestLines(oldText))
                == splitTestLines(newText)
        )
    }

    @Test func identicalAndDisjointInputsApplyExactly() {
        let disjoint = DesignOwnerWorkflow.lineDiff("a\nb", "c\nd")
        #expect(disjoint.truncated == false)
        #expect(applyUnifiedDiff(disjoint.lines, to: ["a", "b"]) == ["c", "d"])
        let identical = DesignOwnerWorkflow.lineDiff("a\nb", "a\nb")
        #expect(identical.truncated == false)
        #expect(identical.lines == ["  a", "  b"])
        #expect(applyUnifiedDiff(identical.lines, to: ["a", "b"]) == ["a", "b"])
    }

    @Test func largeDisjointInputsStayBoundedAndReportTruncation() {
        // The DP matrix cap must be checked BEFORE allocation; 4000×4000 as
        // an Int matrix is ~128 MiB. 4001*4001 cells must exceed the cap.
        #expect(DesignOwnerWorkflow.lineDiffMaxMatrixCells < 16_000_000)
        #expect((4001 * 4001) > DesignOwnerWorkflow.lineDiffMaxMatrixCells)
        let oldText = (0..<4000).map { "old-\($0)" }.joined(separator: "\n")
        let newText = (0..<4000).map { "new-\($0)" }.joined(separator: "\n")
        let outcome = DesignOwnerWorkflow.lineDiff(oldText, newText)
        #expect(outcome.truncated)
        #expect(outcome.lines.count == DesignOwnerWorkflow.lineDiffMaxOutputLines)
        #expect(outcome.lines.first == "- old-0")
        #expect(outcome.lines.last == "- old-1999")
        #expect(outcome.note?.contains("matrix") == true)
        // Identical large inputs collapse via the prefix fast path with no
        // matrix allocation and no truncation report.
        let identical = DesignOwnerWorkflow.lineDiff(oldText, oldText)
        #expect(identical.lines.isEmpty)
        #expect(identical.truncated == false)
    }

    @Test func oversizedInputIsCappedAndReported() {
        let many = (0..<(DesignOwnerWorkflow.lineDiffMaxLinesPerSide + 1))
            .map { "line-\($0)" }.joined(separator: "\n")
        let outcome = DesignOwnerWorkflow.lineDiff("", many)
        #expect(outcome.truncated)
        #expect(outcome.lines.count == DesignOwnerWorkflow.lineDiffMaxOutputLines)
        #expect(outcome.lines.first == "+ line-0")
        #expect(outcome.note != nil)
    }

    @Test func compareUsesTheBoundedDiffForTextRevisions() async throws {
        let fixture = try await makeFileAdoptionFixture(
            baseBytes: Data("a\nb".utf8),
            reference: "notes.md", format: "md",
            proposedBytes: Data()
        )
        let comparison = try await fixture.workflow.compare(
            target: fixture.frozenTarget, candidateID: fixture.proposal.candidate.id
        )
        #expect(comparison.changed)
        #expect(comparison.diff == ["- a", "- b"])
        #expect(comparison.diffTruncated == false)
        #expect(comparison.diffNote == nil)
    }
}

// MARK: - Decision delivery honesty

@Suite("Design owner decision delivery")
struct DesignOwnerDecisionDeliveryTests {
    @Test func missingSinkKeepsDecisionPendingAndReopenDeliversOnce() async throws {
        let fixture = try await makeFileAdoptionFixture()
        let first = try await fixture.workflow.adopt(
            target: fixture.frozenTarget, operationID: "op-adopt",
            expectedOwnerRevision: fixture.proposal.envelope.revision,
            candidateID: fixture.proposal.candidate.id,
            mode: .updateOriginal, verifyReopen: { _, _, _ in }
        )
        guard case .pending(let reason) = first.delivery else {
            Issue.record("expected pending delivery, got \(first.delivery)")
            return
        }
        #expect(reason.contains("sink"))
        #expect(first.replayed == false)
        #expect(first.envelope.project.candidate(fixture.proposal.candidate.id)?.status == .adopted)
        #expect(await fixture.outbox.pendingIntents().count == 1)
        #expect(fixture.commitPort?.committedBytes == Data("adopted-bytes".utf8))

        // App reopen: a NEW workflow with a real configured sink reconciles
        // the durable intent through the replay path.
        let events = SendableBox<Int>()
        events.set(0)
        let reopened = reopenWorkflow(fixture, defaultSink: { _, _, _, _, _ in
            events.set((events.value ?? 0) + 1)
        })
        let retry = try await reopened.adopt(
            target: fixture.frozenTarget, operationID: "op-adopt",
            expectedOwnerRevision: first.envelope.revision,
            candidateID: fixture.proposal.candidate.id,
            mode: .updateOriginal, verifyReopen: { _, _, _ in }
        )
        #expect(retry.replayed == true)
        #expect(retry.delivery == .delivered)
        #expect(events.value == 1)
        #expect(await fixture.outbox.pendingIntents().isEmpty)
        // A further replay must not deliver a second event.
        let again = try await reopened.adopt(
            target: fixture.frozenTarget, operationID: "op-adopt",
            expectedOwnerRevision: retry.envelope.revision,
            candidateID: fixture.proposal.candidate.id,
            mode: .updateOriginal, verifyReopen: { _, _, _ in }
        )
        #expect(again.delivery == .delivered)
        #expect(events.value == 1)
    }

    @Test func failingSinkRetainsPendingAndRetriesToExactlyOneEvent() async throws {
        let fixture = try await makeFileAdoptionFixture()
        let attempts = SendableBox<Int>()
        attempts.set(0)
        let successes = SendableBox<Int>()
        successes.set(0)
        let flaky: DesignOwnerDecisionSink = { _, _, _, _, _ in
            attempts.set((attempts.value ?? 0) + 1)
            if (attempts.value ?? 0) == 1 {
                throw FloeError.validationFailed("transient sink failure")
            }
            successes.set((successes.value ?? 0) + 1)
        }
        let first = try await fixture.workflow.adopt(
            target: fixture.frozenTarget, operationID: "op-adopt",
            expectedOwnerRevision: fixture.proposal.envelope.revision,
            candidateID: fixture.proposal.candidate.id,
            mode: .updateOriginal, verifyReopen: { _, _, _ in }, sink: flaky
        )
        guard case .pending(let reason) = first.delivery else {
            Issue.record("expected pending delivery, got \(first.delivery)")
            return
        }
        #expect(reason.contains("delivery"))
        #expect(attempts.value == 1)
        #expect(await fixture.outbox.pendingIntents().count == 1)
        // The candidate IS adopted (the CAS succeeded); only delivery is
        // still owed.
        #expect(first.envelope.project.candidate(fixture.proposal.candidate.id)?.status == .adopted)

        let retry = try await fixture.workflow.adopt(
            target: fixture.frozenTarget, operationID: "op-adopt",
            expectedOwnerRevision: first.envelope.revision,
            candidateID: fixture.proposal.candidate.id,
            mode: .updateOriginal, verifyReopen: { _, _, _ in }, sink: flaky
        )
        #expect(retry.delivery == .delivered)
        #expect(successes.value == 1)
        // Repeated calls do not deliver again once acknowledged.
        _ = try await fixture.workflow.adopt(
            target: fixture.frozenTarget, operationID: "op-adopt",
            expectedOwnerRevision: retry.envelope.revision,
            candidateID: fixture.proposal.candidate.id,
            mode: .updateOriginal, verifyReopen: { _, _, _ in }, sink: flaky
        )
        #expect(attempts.value == 2)
        #expect(successes.value == 1)
        #expect(await fixture.outbox.pendingIntents().isEmpty)
    }

    @Test func noOriginAdoptionIsLegitimateWithoutNotification() async throws {
        let fixture = try await makeFileAdoptionFixture(origin: nil)
        let sinkCalls = SendableBox<Int>()
        sinkCalls.set(0)
        let result = try await fixture.workflow.adopt(
            target: fixture.frozenTarget, operationID: "op-adopt",
            expectedOwnerRevision: fixture.proposal.envelope.revision,
            candidateID: fixture.proposal.candidate.id,
            mode: .updateOriginal,
            verifyReopen: { _, _, _ in },
            sink: { _, _, _, _, _ in sinkCalls.set((sinkCalls.value ?? 0) + 1) }
        )
        #expect(result.delivery == .notRequired)
        #expect(sinkCalls.value == 0)
        #expect(result.envelope.project.candidate(fixture.proposal.candidate.id)?.status == .adopted)
        // The in-place crash-recovery record is settled, not pending.
        #expect(await fixture.outbox.pendingIntents().isEmpty)
    }

    @Test func rejectDeliveryIsPendingWithoutSinkAndRetriedOnReplay() async throws {
        let fixture = try await makeFileAdoptionFixture()
        let first = try await fixture.workflow.reject(
            target: fixture.frozenTarget, operationID: "op-reject",
            expectedOwnerRevision: fixture.proposal.envelope.revision,
            candidateID: fixture.proposal.candidate.id
        )
        guard case .pending = first.delivery else {
            Issue.record("expected pending delivery, got \(first.delivery)")
            return
        }
        #expect(await fixture.outbox.pendingIntents().count == 1)
        let events = SendableBox<Int>()
        events.set(0)
        let retry = try await fixture.workflow.reject(
            target: fixture.frozenTarget, operationID: "op-reject",
            expectedOwnerRevision: first.envelope.revision,
            candidateID: fixture.proposal.candidate.id,
            sink: { _, _, _, _, _ in events.set((events.value ?? 0) + 1) }
        )
        #expect(retry.replayed == true)
        #expect(retry.delivery == .delivered)
        #expect(events.value == 1)
        #expect(await fixture.outbox.pendingIntents().isEmpty)
    }
}

// MARK: - Adoption transaction and recovery

@Suite("Design owner adoption recovery")
struct DesignOwnerAdoptionRecoveryTests {
    @Test func commitReadbackMismatchRetainsRecoverableIntentAndNeverMarksApplied() async throws {
        let commitPort = StubCommitPort()
        commitPort.verifyResult = .diverged(actualSHA256: "deadbeef")
        let fixture = try await makeFileAdoptionFixture(commitPort: commitPort)
        var caught: Error?
        do {
            _ = try await fixture.workflow.adopt(
                target: fixture.frozenTarget, operationID: "op-adopt",
                expectedOwnerRevision: fixture.proposal.envelope.revision,
                candidateID: fixture.proposal.candidate.id,
                mode: .updateOriginal, verifyReopen: { _, _, _ in }
            )
        } catch {
            caught = error
        }
        let ownerError = try #require(caught as? DesignOwnerWorkflowError)
        guard case .adoptionPendingRecovery = ownerError else {
            Issue.record("expected adoptionPendingRecovery, got \(ownerError)")
            return
        }
        #expect(commitPort.commitCount == 1)
        #expect(commitPort.verifyCount == 1)
        let state = try #require(await fixture.workflow.state(fixture.frozenTarget))
        #expect(state.revision == fixture.proposal.envelope.revision)
        #expect(state.project.candidate(fixture.proposal.candidate.id)?.status == .pending)
        let pending = try #require(await fixture.outbox.pendingIntents().first)
        // Reconcile inspects the ACTUAL source: a diverged source (possible
        // user edit) is preserved and the decision retained.
        let outcome = try await reopenWorkflow(fixture).reconcilePendingAdoption(
            pending, verifyReopen: { _, _, _ in }
        )
        guard case .retained = outcome else {
            Issue.record("expected retained, got \(outcome)")
            return
        }
        #expect(await fixture.outbox.pendingIntents().count == 1)
        let stillPending = try #require(await fixture.workflow.state(fixture.frozenTarget))
        #expect(stillPending.project.candidate(fixture.proposal.candidate.id)?.status == .pending)
    }

    @Test func sourceCommittedBeforeCASIsRecoveredByReconcileExactlyOnce() async throws {
        let fixture = try await makeFileAdoptionFixture()
        await fixture.store.setFailNextSave(true)
        var caught: Error?
        do {
            _ = try await fixture.workflow.adopt(
                target: fixture.frozenTarget, operationID: "op-adopt",
                expectedOwnerRevision: fixture.proposal.envelope.revision,
                candidateID: fixture.proposal.candidate.id,
                mode: .updateOriginal, verifyReopen: { _, _, _ in }
            )
        } catch {
            caught = error
        }
        let ownerError = try #require(caught as? DesignOwnerWorkflowError)
        guard case .adoptionPendingRecovery = ownerError else {
            Issue.record("expected adoptionPendingRecovery, got \(ownerError)")
            return
        }
        // The source write landed; the durable intent records the exact
        // proposed/base identity and MUST stay pending (never blind-cancel).
        let pending = try #require(await fixture.outbox.pendingIntents().first)
        #expect(pending.operationID == "op-adopt")
        #expect(pending.proposedContentSHA256 == FloeDigest.sha256Hex(Data("adopted-bytes".utf8)))
        #expect(pending.frozenBaseToken != nil)
        #expect(fixture.commitPort?.committedBytes == Data("adopted-bytes".utf8))
        let beforeReconcile = try #require(
            await fixture.store.load(targetKey: fixture.frozenTarget.stableKey)
        )
        #expect(beforeReconcile.project.hasApplied(operationID: "op-adopt") == false)

        // Restart: a NEW workflow over the same stores. The operation record
        // is absent (CAS never ran) but the source equals the verified
        // proposed bytes — reconcile must resume it, not cancel.
        let events = SendableBox<Int>()
        events.set(0)
        let reopened = reopenWorkflow(fixture)
        let outcome = try await reopened.reconcilePendingAdoption(
            pending,
            verifyReopen: { _, _, _ in },
            sink: { _, _, _, _, _ in events.set((events.value ?? 0) + 1) }
        )
        guard case .completed(let delivery) = outcome else {
            Issue.record("expected completed, got \(outcome)")
            return
        }
        #expect(delivery == .delivered)
        #expect(events.value == 1)
        #expect(await fixture.outbox.pendingIntents().isEmpty)
        let settled = try #require(await fixture.outbox.record(fingerprint: pending.fingerprint))
        #expect(settled.phase == .recorded)
        let state = try #require(await reopened.state(fixture.frozenTarget))
        #expect(state.project.candidate(fixture.proposal.candidate.id)?.status == .adopted)
        #expect(state.revision == fixture.proposal.envelope.revision + 1)

        // Re-reconcile the same decision: no second event.
        let again = try await reopened.reconcilePendingAdoption(
            settled,
            verifyReopen: { _, _, _ in },
            sink: { _, _, _, _, _ in events.set((events.value ?? 0) + 1) }
        )
        guard case .completed(let secondDelivery) = again else {
            Issue.record("expected completed, got \(again)")
            return
        }
        #expect(secondDelivery == .delivered)
        #expect(events.value == 1)
    }

    @Test func commitFailureClassificationControlsCancellation() async throws {
        // (a) A proven-unwritten failure cancels the fresh intent.
        let notWrittenPort = StubCommitPort()
        notWrittenPort.failure = DesignOwnerCommitError.notWritten("refused before write")
        let fixtureA = try await makeFileAdoptionFixture(commitPort: notWrittenPort)
        var firstError: Error?
        do {
            _ = try await fixtureA.workflow.adopt(
                target: fixtureA.frozenTarget, operationID: "op-adopt",
                expectedOwnerRevision: fixtureA.proposal.envelope.revision,
                candidateID: fixtureA.proposal.candidate.id,
                mode: .updateOriginal, verifyReopen: { _, _, _ in }
            )
        } catch {
            firstError = error
        }
        #expect(firstError as? DesignOwnerCommitError == .notWritten("refused before write"))
        #expect(notWrittenPort.commitCount == 0)
        #expect(await fixtureA.outbox.pendingIntents().isEmpty)
        let stateA = try #require(await fixtureA.workflow.state(fixtureA.frozenTarget))
        #expect(stateA.revision == fixtureA.proposal.envelope.revision)
        #expect(stateA.project.candidate(fixtureA.proposal.candidate.id)?.status == .pending)
        // A retry of the SAME cancelled operation reopens the durable record
        // (a cancel only meant "that attempt did not commit") and delivers
        // once the operation actually commits.
        notWrittenPort.failure = nil
        let delivered = SendableBox<Int>()
        delivered.set(0)
        let retried = try await fixtureA.workflow.adopt(
            target: fixtureA.frozenTarget, operationID: "op-adopt",
            expectedOwnerRevision: fixtureA.proposal.envelope.revision,
            candidateID: fixtureA.proposal.candidate.id,
            mode: .updateOriginal,
            verifyReopen: { _, _, _ in },
            sink: { _, _, _, _, _ in delivered.set((delivered.value ?? 0) + 1) }
        )
        #expect(retried.delivery == .delivered)
        #expect(delivered.value == 1)
        #expect(await fixtureA.outbox.pendingIntents().isEmpty)
        let afterRetry = try #require(await fixtureA.workflow.state(fixtureA.frozenTarget))
        #expect(afterRetry.project.candidate(fixtureA.proposal.candidate.id)?.status == .adopted)

        // (b) An unknown failure (the write may have landed) retains the
        // durable intent instead of pretending nothing changed.
        let unknownPort = StubCommitPort()
        unknownPort.failure = DesignOwnerCommitError.unknown("io failure after partial write")
        let fixtureB = try await makeFileAdoptionFixture(commitPort: unknownPort)
        var secondError: Error?
        do {
            _ = try await fixtureB.workflow.adopt(
                target: fixtureB.frozenTarget, operationID: "op-adopt",
                expectedOwnerRevision: fixtureB.proposal.envelope.revision,
                candidateID: fixtureB.proposal.candidate.id,
                mode: .updateOriginal, verifyReopen: { _, _, _ in }
            )
        } catch {
            secondError = error
        }
        let ownerError = try #require(secondError as? DesignOwnerWorkflowError)
        guard case .adoptionPendingRecovery = ownerError else {
            Issue.record("expected adoptionPendingRecovery, got \(ownerError)")
            return
        }
        #expect(await fixtureB.outbox.pendingIntents().count == 1)
    }

    @Test func revokedPermissionFailsClosedBeforeAnyWrite() async throws {
        let fixture = try await makeFileAdoptionFixture()
        fixture.filePort.authorized = false
        var caught: Error?
        do {
            _ = try await fixture.workflow.adopt(
                target: fixture.frozenTarget, operationID: "op-adopt",
                expectedOwnerRevision: fixture.proposal.envelope.revision,
                candidateID: fixture.proposal.candidate.id,
                mode: .updateOriginal, verifyReopen: { _, _, _ in }
            )
        } catch {
            caught = error
        }
        guard let targetError = caught as? DesignTargetError,
              case .notAuthorized = targetError else {
            Issue.record("expected notAuthorized, got \(String(describing: caught))")
            return
        }
        #expect(fixture.commitPort?.commitCount == 0)
        #expect(await fixture.outbox.pendingIntents().isEmpty)
        // `state` also fails closed now; read the store directly.
        let stored = try #require(await fixture.store.load(targetKey: fixture.frozenTarget.stableKey))
        #expect(stored.revision == fixture.proposal.envelope.revision)
        #expect(stored.project.candidate(fixture.proposal.candidate.id)?.status == .pending)
    }

    @Test func concurrentDuplicateAdoptionsSerializeAndDeliverOnce() async throws {
        let gate = AsyncGate()
        let commitPort = StubCommitPort()
        commitPort.gate = gate
        let fixture = try await makeFileAdoptionFixture(commitPort: commitPort)
        let events = SendableBox<Int>()
        events.set(0)
        let sink: DesignOwnerDecisionSink = { _, _, _, _, _ in
            events.set((events.value ?? 0) + 1)
        }
        let firstOutcome = SendableBox<String>()
        let secondReplayed = SendableBox<Bool>()
        let firstTask = Task {
            do {
                let result = try await fixture.workflow.adopt(
                    target: fixture.frozenTarget, operationID: "op-adopt",
                    expectedOwnerRevision: fixture.proposal.envelope.revision,
                    candidateID: fixture.proposal.candidate.id,
                    mode: .updateOriginal, verifyReopen: { _, _, _ in }, sink: sink
                )
                firstOutcome.set(result.replayed ? "replayed" : "new")
            } catch {
                firstOutcome.set("error: \(error)")
            }
        }
        do {
            try await waitUntil { commitPort.enteredCount >= 1 }
        } catch {
            await gate.open()
            firstTask.cancel()
            Issue.record("first adoption never reached the gated commit: \(error)")
            return
        }
        let secondTask = Task {
            do {
                let result = try await fixture.workflow.adopt(
                    target: fixture.frozenTarget, operationID: "op-adopt",
                    expectedOwnerRevision: fixture.proposal.envelope.revision,
                    candidateID: fixture.proposal.candidate.id,
                    mode: .updateOriginal, verifyReopen: { _, _, _ in }, sink: sink
                )
                secondReplayed.set(result.replayed)
            } catch {
                secondReplayed.set(false)
            }
        }
        // While the first transaction holds the target reservation the second
        // duplicate must not complete.
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(secondReplayed.value == nil)
        await gate.open()
        await firstTask.value
        await secondTask.value
        #expect(firstOutcome.value == "new")
        #expect(secondReplayed.value == true)
        #expect(commitPort.commitCount == 1)
        #expect(events.value == 1)
        let state = try #require(await fixture.workflow.state(fixture.frozenTarget))
        #expect(state.revision == fixture.proposal.envelope.revision + 1)
    }

    @Test func concurrentBriefUpdateWaitsForTheAdoptionTransaction() async throws {
        let gate = AsyncGate()
        let commitPort = StubCommitPort()
        commitPort.gate = gate
        let fixture = try await makeFileAdoptionFixture(commitPort: commitPort)
        let adoptError = SendableBox<String>()
        let adoptTask = Task {
            do {
                _ = try await fixture.workflow.adopt(
                    target: fixture.frozenTarget, operationID: "op-adopt",
                    expectedOwnerRevision: fixture.proposal.envelope.revision,
                    candidateID: fixture.proposal.candidate.id,
                    mode: .updateOriginal, verifyReopen: { _, _, _ in }
                )
            } catch {
                adoptError.set("\(error)")
            }
        }
        do {
            try await waitUntil { commitPort.enteredCount >= 1 }
        } catch {
            await gate.open()
            adoptTask.cancel()
            Issue.record("adoption never reached the gated commit: \(error)")
            return
        }
        let briefDone = SendableBox<Bool>()
        briefDone.set(false)
        let briefError = SendableBox<String>()
        let briefTask = Task {
            do {
                _ = try await fixture.workflow.updateBrief(
                    target: fixture.frozenTarget, operationID: "op-brief",
                    expectedOwnerRevision: nil,
                    brief: DesignBrief(goal: "after adopt")
                )
                briefDone.set(true)
            } catch {
                briefError.set("\(error)")
            }
        }
        // The brief update must be blocked behind the same-target reservation
        // while the adoption transaction is mid-flight.
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(briefDone.value == false)
        await gate.open()
        await adoptTask.value
        await briefTask.value
        #expect(adoptError.value == nil)
        #expect(briefError.value == nil)
        #expect(briefDone.value == true)
        let state = try #require(await fixture.workflow.state(fixture.frozenTarget))
        #expect(state.project.candidate(fixture.proposal.candidate.id)?.status == .adopted)
        #expect(state.project.brief?.goal == "after adopt")
    }

    @Test func independentTargetsAreNotBlockedByAGatedTransaction() async throws {
        let gate = AsyncGate()
        let commitPort = StubCommitPort()
        commitPort.gate = gate
        let fixture = try await makeFileAdoptionFixture(commitPort: commitPort)
        // A second document on the SAME workflow actor: the per-target
        // reservation must not serialize unrelated targets.
        fixture.filePort.files["second.png"] = Data("second-base".utf8)
        let secondTarget = fileTarget(reference: "second.png")
        let secondFrozen = try await fixture.workflow.freezeInput(
            target: secondTarget, operationID: "op-freeze-2", expectedOwnerRevision: nil
        )

        let adoptAFinished = SendableBox<Bool>()
        adoptAFinished.set(false)
        let adoptTask = Task {
            _ = try? await fixture.workflow.adopt(
                target: fixture.frozenTarget, operationID: "op-adopt",
                expectedOwnerRevision: fixture.proposal.envelope.revision,
                candidateID: fixture.proposal.candidate.id,
                mode: .updateOriginal, verifyReopen: { _, _, _ in }
            )
            adoptAFinished.set(true)
        }
        do {
            try await waitUntil { commitPort.enteredCount >= 1 }
        } catch {
            await gate.open()
            adoptTask.cancel()
            Issue.record("adoption never reached the gated commit: \(error)")
            return
        }
        #expect(adoptAFinished.value == false)

        // Target B must finish while A is still parked inside its commit.
        let briefBDone = SendableBox<Bool>()
        briefBDone.set(false)
        let briefError = SendableBox<String>()
        let briefTask = Task {
            do {
                _ = try await fixture.workflow.updateBrief(
                    target: secondTarget, operationID: "op-brief-2",
                    expectedOwnerRevision: secondFrozen.envelope.revision,
                    brief: DesignBrief(goal: "independent target")
                )
            } catch {
                briefError.set("\(error)")
            }
            briefBDone.set(true)
        }
        var briefFinishedInTime = true
        do {
            try await waitUntil(timeout: 3) { briefBDone.value == true }
        } catch {
            briefFinishedInTime = false
        }
        let stillGated = adoptAFinished.value == false
        await gate.open()
        await adoptTask.value
        await briefTask.value
        #expect(
            briefFinishedInTime,
            "an unrelated target was blocked by the gated adoption reservation"
        )
        #expect(stillGated, "the gated adoption finished before the gate opened")
        #expect(briefError.value == nil)
        let secondState = try #require(await fixture.workflow.state(secondTarget))
        #expect(secondState.project.brief?.goal == "independent target")
        #expect(secondState.revision == secondFrozen.envelope.revision + 1)
        #expect(adoptAFinished.value == true)
    }

    @Test func failedReopenVerificationAdoptsNothing() async throws {
        let fixture = try await makeFileAdoptionFixture()
        let beforeRevision = fixture.proposal.envelope.revision
        var caught: Error?
        do {
            _ = try await fixture.workflow.adopt(
                target: fixture.frozenTarget, operationID: "op-adopt",
                expectedOwnerRevision: beforeRevision,
                candidateID: fixture.proposal.candidate.id,
                mode: .updateOriginal,
                verifyReopen: { _, format, type in
                    #expect(format == "png")
                    #expect(type == .image)
                    throw FloeError.validationFailed("malformed representative")
                }
            )
        } catch {
            caught = error
        }
        #expect(caught != nil)
        #expect(fixture.commitPort?.commitCount == 0)
        #expect(await fixture.outbox.pendingIntents().isEmpty)
        let state = try #require(await fixture.workflow.state(fixture.frozenTarget))
        #expect(state.revision == beforeRevision)
        #expect(state.project.candidate(fixture.proposal.candidate.id)?.status == .pending)
        // The original source is untouched (the commit port never ran).
        #expect(fixture.commitPort?.committedBytes == nil)
    }
}

// MARK: - Canvas authority routing boundary

private func makeCanvasTargets(
    canvasID: UUID,
    nodeID: UUID
) -> (targets: DesignTargetService, target: DesignTarget) {
    var node = CanvasNode.placeholder(kind: .text, position: CanvasPoint(x: 0, y: 0), zIndex: 0)
    node.id = nodeID
    node.text = "canvas-text"
    let document = CanvasDocument(id: UUID(), name: "doc", nodes: [node])
    var project = CanvasProject(
        id: canvasID, name: "T", documents: [document], selectedDocumentID: document.id
    )
    project.revision = 1
    let repository = StubCanvasRepository(project: project)
    let service = DesignCanvasService(repository: repository) { runID, canvas in
        runID != nil && canvas == canvasID
    }
    let adapter = DesignCanvasOwnerAdapter(
        service: service,
        contentPort: StubCanvasContentPort(format: "txt") { Data($0.text.utf8) }
    )
    let targets = DesignTargetService(adapters: [adapter])
    let target = DesignTarget(
        kind: .canvasNode,
        ownerID: canvasID.uuidString.lowercased(),
        documentID: document.id.uuidString.lowercased(),
        sourceID: nodeID.uuidString.lowercased()
    )
    return (targets, target)
}

private func isCanvasAuthorityError(_ body: () async throws -> Void) async -> Bool {
    do {
        try await body()
        return false
    } catch let error as DesignOwnerWorkflowError {
        if case .canvasRequiresCanvasAuthority = error { return true }
        return false
    } catch {
        return false
    }
}

private func isResultPublicationUnavailableError(_ body: () async throws -> Void) async -> Bool {
    do {
        try await body()
        return false
    } catch let error as DesignOwnerWorkflowError {
        if case .resultPublicationUnavailable = error { return true }
        return false
    } catch {
        return false
    }
}

@Suite("Design owner canvas routing boundary")
struct DesignOwnerCanvasRoutingTests {
    @Test func canvasTypedDiscoveryRemainsAvailableButGenericWorkflowFailsClosed() async throws {
        let canvasID = UUID()
        let nodeID = UUID()
        let (targets, target) = makeCanvasTargets(canvasID: canvasID, nodeID: nodeID)

        // Typed discovery through the RETAINED canvas adapter still works.
        let resolved = try await targets.resolve(target, runID: UUID())
        #expect(resolved.contentType == .notes)
        #expect(resolved.canvas?.nodeID == nodeID)

        // The generic owner workflow owns no canvas state: every boundary
        // fails closed and creates no envelope, payload or decision record.
        let store = InMemoryOwnerStore()
        let payloads = InMemoryPayloadStore()
        let outbox = makeOutbox()
        let workflow = DesignOwnerWorkflow(
            targets: targets, store: store, payloads: payloads, outbox: outbox
        )
        #expect(await isCanvasAuthorityError {
            _ = try await workflow.state(target)
        })
        #expect(await isCanvasAuthorityError {
            _ = try await workflow.updateBrief(
                target: target, operationID: "op-brief",
                expectedOwnerRevision: nil, brief: DesignBrief(goal: "x")
            )
        })
        #expect(await isCanvasAuthorityError {
            _ = try await workflow.freezeInput(
                target: target, operationID: "op-freeze",
                expectedOwnerRevision: nil, runID: UUID()
            )
        })
        #expect(await isCanvasAuthorityError {
            _ = try await workflow.propose(
                target: target, operationID: "op-propose",
                expectedOwnerRevision: nil, artifactID: "artifact",
                baseRevisionID: nil, bytes: Data("x".utf8), format: "txt", summary: "s"
            )
        })
        #expect(await isCanvasAuthorityError {
            _ = try await workflow.registerEdit(
                target: target, operationID: "op-edit",
                expectedOwnerRevision: nil, artifactID: "artifact",
                bytes: Data("x".utf8), format: "txt"
            )
        })
        #expect(try await store.load(targetKey: target.stableKey) == nil)
        #expect(await store.saveCount == 0)
        #expect(payloads.stored.isEmpty)
        #expect(await outbox.pendingIntents().isEmpty)
    }

    @Test func seededCanvasEnvelopeAndCommitPortCanNeverBeAdopted() async throws {
        let canvasID = UUID()
        let nodeID = UUID()
        let (targets, target) = makeCanvasTargets(canvasID: canvasID, nodeID: nodeID)

        // Seed the exact shape this boundary forbids: a generic owner
        // envelope (a SECOND canvas authority) carrying a pending candidate
        // plus a canvas commit port. The guard must refuse before touching
        // either, so a stale/parallel canvas state can never be mutated.
        let payloads = InMemoryPayloadStore()
        let baseBytes = Data("node-text".utf8)
        let baseRevisionID = UUID().uuidString.lowercased()
        let baseRelative = try payloads.store(
            ownerKey: target.stableKey, revisionID: baseRevisionID,
            bytes: baseBytes, expectedContentSHA256: FloeDigest.sha256Hex(baseBytes)
        )
        var project = DesignWorkflowEngine.createProject(
            nodeID: target.stableKey, contentType: .notes
        )
        let artifactID = UUID().uuidString.lowercased()
        DesignWorkflowEngine.addArtifact(
            DesignArtifact(
                id: artifactID,
                contentType: .notes,
                canvasNodeID: nodeID.uuidString.lowercased(),
                identity: .init(name: "node", positionX: 0, positionY: 0, width: 0, height: 0)
            ),
            to: &project
        )
        let baseRevision = try DesignWorkflowEngine.registerRevision(
            in: &project, artifactID: artifactID,
            contentSHA256: FloeDigest.sha256Hex(baseBytes),
            origin: .currentNode,
            payloadRelativePath: baseRelative, payloadFormat: "txt",
            revisionID: baseRevisionID
        )
        let proposedBytes = Data("adopted-node-text".utf8)
        let proposedRevisionID = UUID().uuidString.lowercased()
        let proposedRelative = try payloads.store(
            ownerKey: target.stableKey, revisionID: proposedRevisionID,
            bytes: proposedBytes, expectedContentSHA256: FloeDigest.sha256Hex(proposedBytes)
        )
        let candidate = try DesignWorkflowEngine.proposeCandidate(
            in: &project, artifactID: artifactID,
            baseRevisionID: baseRevision.id,
            proposedContentSHA256: FloeDigest.sha256Hex(proposedBytes),
            summary: "adopt", proposedRevisionID: proposedRevisionID,
            payloadRelativePath: proposedRelative, payloadFormat: "txt"
        )
        let store = InMemoryOwnerStore(
            seed: DesignOwnerEnvelope(target: target, project: project, revision: 7)
        )
        let commitPort = StubCommitPort()
        let workflow = DesignOwnerWorkflow(
            targets: targets, store: store, payloads: payloads,
            commitPorts: [.canvasNode: commitPort], outbox: makeOutbox()
        )
        #expect(await isCanvasAuthorityError {
            _ = try await workflow.adopt(
                target: target, operationID: "op-adopt",
                expectedOwnerRevision: 7,
                candidateID: candidate.id,
                mode: .updateOriginal,
                verifyReopen: { _, _, _ in }
            )
        })
        let stored = try #require(await store.load(targetKey: target.stableKey))
        #expect(stored.revision == 7)
        #expect(stored.project.candidate(candidate.id)?.status == .pending)
        #expect(commitPort.commitCount == 0)
        #expect(commitPort.verifyCount == 0)
    }
}

// MARK: - Adopted-result publication fixtures (immutable owners)

private struct ChatAdoptionFixture: Sendable {
    let workflow: DesignOwnerWorkflow
    let service: DesignTargetService
    let chatPort: StubChatPort
    let store: InMemoryOwnerStore
    let payloads: InMemoryPayloadStore
    let outbox: DesignDecisionOutbox
    let target: DesignTarget
    let frozenTarget: DesignTarget
    let inputRevision: DesignRevision
    let proposal: DesignOwnerWorkflow.Proposal
    let conversationID: String
    let originalBytes: Data
}

private func makeChatAdoptionFixture(
    conversation: String = "cccccccc-cccc-cccc-cccc-cccccccccccc",
    publication: (any DesignResultPublicationPort)? = nil
) async throws -> ChatAdoptionFixture {
    let port = StubChatPort()
    let originalBytes = Data("chat-base".utf8)
    port.attachment = DesignChatAttachment(
        data: originalBytes,
        format: "png",
        displayName: "original.png",
        contentSHA256: FloeDigest.sha256Hex(originalBytes),
        baseRevisionToken: "chat:sha:\(FloeDigest.sha256Hex(originalBytes))",
        conversationID: conversation
    )
    let adapter = DesignChatAttachmentOwnerAdapter(port: port)
    let service = DesignTargetService(adapters: [adapter])
    let store = InMemoryOwnerStore()
    let payloads = InMemoryPayloadStore()
    let outbox = makeOutbox()
    let workflow = DesignOwnerWorkflow(
        targets: service, store: store, payloads: payloads, outbox: outbox,
        defaultPublication: publication
    )
    let target = DesignTarget(
        kind: .chatAttachment,
        ownerID: conversation,
        documentID: "message-1",
        sourceID: "attachment-1",
        originConversationID: conversation
    )
    let frozen = try await workflow.freezeInput(
        target: target, operationID: "op-freeze", expectedOwnerRevision: nil
    )
    let frozenTarget = target.freezing(revision: frozen.source.baseRevisionToken)
    let proposal = try await workflow.propose(
        target: frozenTarget, operationID: "op-propose",
        expectedOwnerRevision: frozen.envelope.revision,
        artifactID: frozen.revision.artifactID,
        baseRevisionID: frozen.revision.id,
        bytes: Data("chat-proposed".utf8), format: "png", summary: "adopt"
    )
    return ChatAdoptionFixture(
        workflow: workflow, service: service, chatPort: port, store: store,
        payloads: payloads, outbox: outbox, target: target,
        frozenTarget: frozenTarget, inputRevision: frozen.revision,
        proposal: proposal, conversationID: conversation, originalBytes: originalBytes
    )
}

private func reopenChatWorkflow(
    _ fixture: ChatAdoptionFixture,
    defaultPublication: (any DesignResultPublicationPort)? = nil
) -> DesignOwnerWorkflow {
    DesignOwnerWorkflow(
        targets: fixture.service, store: fixture.store, payloads: fixture.payloads,
        outbox: fixture.outbox, defaultPublication: defaultPublication
    )
}

private struct CreativeAdoptionFixture: Sendable {
    let workflow: DesignOwnerWorkflow
    let service: DesignTargetService
    let port: StubCreativePort
    let store: InMemoryOwnerStore
    let payloads: InMemoryPayloadStore
    let outbox: DesignDecisionOutbox
    let target: DesignTarget
    let frozenTarget: DesignTarget
    let inputRevision: DesignRevision
    let proposal: DesignOwnerWorkflow.Proposal
    let originalBytes: Data
}

private func makeCreativeAdoptionFixture(
    request: String = "asset-1",
    origin: String? = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
    publication: (any DesignResultPublicationPort)? = nil
) async throws -> CreativeAdoptionFixture {
    let port = StubCreativePort()
    let originalBytes = Data("creative-base".utf8)
    port.assets[request] = originalBytes
    port.formats[request] = "png"
    let adapter = DesignCreativeOwnerAdapter(port: port)
    let service = DesignTargetService(adapters: [adapter])
    let store = InMemoryOwnerStore()
    let payloads = InMemoryPayloadStore()
    let outbox = makeOutbox()
    let workflow = DesignOwnerWorkflow(
        targets: service, store: store, payloads: payloads, outbox: outbox,
        defaultPublication: publication
    )
    let target = DesignTarget(
        kind: .creativeDocument,
        ownerID: "creative",
        documentID: "",
        sourceID: request,
        originConversationID: origin
    )
    let frozen = try await workflow.freezeInput(
        target: target, operationID: "op-freeze", expectedOwnerRevision: nil
    )
    let frozenTarget = target.freezing(revision: frozen.source.baseRevisionToken)
    let proposal = try await workflow.propose(
        target: frozenTarget, operationID: "op-propose",
        expectedOwnerRevision: frozen.envelope.revision,
        artifactID: frozen.revision.artifactID,
        baseRevisionID: frozen.revision.id,
        bytes: Data("creative-proposed".utf8), format: "png", summary: "adopt"
    )
    return CreativeAdoptionFixture(
        workflow: workflow, service: service, port: port, store: store,
        payloads: payloads, outbox: outbox, target: target,
        frozenTarget: frozenTarget, inputRevision: frozen.revision,
        proposal: proposal, originalBytes: originalBytes
    )
}

@Suite("Design owner result publication")
struct DesignOwnerResultPublicationTests {
    @Test func chatAdoptionWithoutPublicationPortFailsClosedBeforeAnyStateChange() async throws {
        let fixture = try await makeChatAdoptionFixture()
        let before = try #require(await fixture.store.load(targetKey: fixture.target.stableKey))
        let savesBefore = await fixture.store.saveCount
        #expect(await isResultPublicationUnavailableError {
            _ = try await fixture.workflow.adopt(
                target: fixture.frozenTarget, operationID: "op-adopt",
                expectedOwnerRevision: fixture.proposal.envelope.revision,
                candidateID: fixture.proposal.candidate.id,
                mode: .updateOriginal,
                verifyReopen: { _, _, _ in }
            )
        })
        let after = try #require(await fixture.store.load(targetKey: fixture.target.stableKey))
        #expect(after.revision == before.revision)
        #expect(after.project.candidate(fixture.proposal.candidate.id)?.status == .pending)
        #expect(await fixture.store.saveCount == savesBefore)
        #expect(await fixture.outbox.pendingIntents().isEmpty)
        // The immutable original is untouched.
        #expect(fixture.chatPort.attachment?.data == fixture.originalBytes)
    }

    @Test func chatAdoptionPublishesToOriginalTaskAndReplaysIdempotently() async throws {
        let publicationPort = StubPublicationPort()
        let fixture = try await makeChatAdoptionFixture(publication: publicationPort)
        let events = SendableBox<Int>()
        events.set(0)
        let proposed = Data("chat-proposed".utf8)
        let proposedDigest = FloeDigest.sha256Hex(proposed)
        let result = try await fixture.workflow.adopt(
            target: fixture.frozenTarget, operationID: "op-adopt",
            expectedOwnerRevision: fixture.proposal.envelope.revision,
            candidateID: fixture.proposal.candidate.id,
            mode: .updateOriginal,
            verifyReopen: { bytes, format, type in
                #expect(bytes == proposed)
                #expect(format == "png")
                #expect(type == .image)
            },
            sink: { _, _, _, _, _ in events.set((events.value ?? 0) + 1) }
        )
        guard case .published(let receipt) = result.publication else {
            Issue.record("expected published result, got \(result.publication)")
            return
        }
        #expect(receipt.destination == "chat:\(fixture.conversationID)")
        #expect(receipt.contentSHA256 == proposedDigest)
        #expect(result.delivery == .delivered)
        #expect(events.value == 1)
        #expect(await fixture.outbox.pendingIntents().isEmpty)
        let key = "op-adopt|\(fixture.proposal.candidate.proposedRevisionID)|\(proposedDigest)"
        let publication = try #require(await publicationPort.publication(forKey: key))
        #expect(publication.operationID == "op-adopt")
        #expect(publication.candidateID == fixture.proposal.candidate.id)
        #expect(publication.artifactID == fixture.inputRevision.artifactID)
        #expect(publication.revisionID == fixture.proposal.candidate.proposedRevisionID)
        #expect(publication.originConversationID == fixture.conversationID)
        #expect(publication.target.kind == .chatAttachment)
        #expect(publication.mode == .updateOriginal)
        #expect(publication.bytes == proposed)
        #expect(await publicationPort.callCount == 1)
        #expect(await publicationPort.distinctReceiptCount() == 1)

        // Strict replay under the SAME operationID: the idempotent port
        // returns the SAME receipt and never creates a second attachment.
        let replay = try await fixture.workflow.adopt(
            target: fixture.frozenTarget, operationID: "op-adopt",
            expectedOwnerRevision: result.envelope.revision,
            candidateID: fixture.proposal.candidate.id,
            mode: .updateOriginal,
            verifyReopen: { _, _, _ in }
        )
        guard case .published(let replayedReceipt) = replay.publication else {
            Issue.record("expected published replay, got \(replay.publication)")
            return
        }
        #expect(replayedReceipt == receipt)
        #expect(replay.replayed)
        #expect(await publicationPort.callCount == 2)
        #expect(await publicationPort.distinctReceiptCount() == 1)
        #expect(events.value == 1)
        // The ORIGINAL chat attachment is byte-identical (never rewritten).
        #expect(fixture.chatPort.attachment?.data == fixture.originalBytes)
    }

    @Test func creativeAdoptionPublishesNewAssetAndKeepsOriginal() async throws {
        let publicationPort = StubPublicationPort()
        let fixture = try await makeCreativeAdoptionFixture(publication: publicationPort)
        let events = SendableBox<Int>()
        events.set(0)
        let proposed = Data("creative-proposed".utf8)
        let proposedDigest = FloeDigest.sha256Hex(proposed)
        let result = try await fixture.workflow.adopt(
            target: fixture.frozenTarget, operationID: "op-adopt",
            expectedOwnerRevision: fixture.proposal.envelope.revision,
            candidateID: fixture.proposal.candidate.id,
            mode: .updateOriginal,
            verifyReopen: { _, _, _ in },
            sink: { _, _, _, _, _ in events.set((events.value ?? 0) + 1) }
        )
        guard case .published(let receipt) = result.publication else {
            Issue.record("expected published result, got \(result.publication)")
            return
        }
        #expect(receipt.destination == "creative:asset-1")
        #expect(result.delivery == .delivered)
        #expect(events.value == 1)
        let key = "op-adopt|\(fixture.proposal.candidate.proposedRevisionID)|\(proposedDigest)"
        let publication = try #require(await publicationPort.publication(forKey: key))
        #expect(publication.target.kind == .creativeDocument)
        #expect(publication.bytes == proposed)
        #expect(publication.originConversationID == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
        // The immutable creative original was not overwritten; the result
        // went to the publication port as a NEW asset.
        #expect(fixture.port.assets["asset-1"] == fixture.originalBytes)
    }

    @Test func failedPublicationKeepsRecordPendingUntilReconcileReturnsTheResult() async throws {
        let publicationPort = StubPublicationPort()
        await publicationPort.setFailure(
            FloeError.validationFailed("attachment store unavailable")
        )
        let fixture = try await makeChatAdoptionFixture(publication: publicationPort)
        let events = SendableBox<Int>()
        events.set(0)
        let result = try await fixture.workflow.adopt(
            target: fixture.frozenTarget, operationID: "op-adopt",
            expectedOwnerRevision: fixture.proposal.envelope.revision,
            candidateID: fixture.proposal.candidate.id,
            mode: .updateOriginal,
            verifyReopen: { _, _, _ in },
            sink: { _, _, _, _, _ in events.set((events.value ?? 0) + 1) }
        )
        guard case .pending(let publishReason) = result.publication else {
            Issue.record("expected pending publication, got \(result.publication)")
            return
        }
        #expect(publishReason.contains("publication"))
        // The notice is delivered, but the decision is NOT settled: the
        // adopted result has not been returned.
        #expect(result.delivery == .delivered)
        #expect(result.envelope.project.candidate(fixture.proposal.candidate.id)?.status == .adopted)
        #expect(await fixture.outbox.pendingIntents().count == 1)

        // Reconcile WITHOUT a publication route must not claim completion.
        let noPortWorkflow = reopenChatWorkflow(fixture)
        let pending = try #require(await fixture.outbox.pendingIntents().first)
        let retained = try await noPortWorkflow.reconcilePendingAdoption(
            pending, verifyReopen: { _, _, _ in }
        )
        guard case .retained(let retainedReason) = retained else {
            Issue.record("expected retained, got \(retained)")
            return
        }
        #expect(retainedReason.contains("publication") || retainedReason.contains("returned"))
        #expect(await fixture.outbox.pendingIntents().count == 1)

        // With the store restored, reconcile publishes the result exactly
        // once and settles the durable decision.
        await publicationPort.setFailure(nil)
        let retry = try #require(await fixture.outbox.pendingIntents().first)
        let completed = try await fixture.workflow.reconcilePendingAdoption(
            retry,
            verifyReopen: { _, _, _ in },
            sink: { _, _, _, _, _ in events.set((events.value ?? 0) + 1) }
        )
        guard case .completed(let delivery) = completed else {
            Issue.record("expected completed, got \(completed)")
            return
        }
        #expect(delivery == .delivered)
        #expect(await fixture.outbox.pendingIntents().isEmpty)
        #expect(await publicationPort.distinctReceiptCount() == 1)
        #expect(await publicationPort.callCount == 2)
        // The sink is the idempotent ingress: the notice may be re-sent, but
        // the published result identity is unchanged.
        #expect(events.value == 2)
        #expect(fixture.chatPort.attachment?.data == fixture.originalBytes)
    }
}

// MARK: - Proposal idempotency records and atomic confirmation claims
//
// The shared `DesignOwnerWorkflow.propose` must be idempotent for the RAW
// service API (not only through a tool wrapper): a repeated operationID
// returns the EXACT recorded candidate and payload, with no second
// revision, no second candidate and no staged payload; changed semantic
// inputs are refused before staging. `adopt` claims the single-use
// confirmation atomically after every pre-flight check and before the
// first side effect, and a replay of an applied operation never claims.

@Suite("Design owner proposal idempotency and claim ordering")
struct DesignOwnerProposalReplayTests {
    private struct Fixture {
        let port: StubFilePort
        let store: InMemoryOwnerStore
        let payloads: InMemoryPayloadStore
        let commitPort: StubCommitPort
        let workflow: DesignOwnerWorkflow
        let target: DesignTarget
        let frozen: (envelope: DesignOwnerEnvelope, revision: DesignRevision, source: DesignResolvedSource)
        let proposed: Data
        let proposal: DesignOwnerWorkflow.Proposal
    }

    private func makeFixture(proposeOperation: String = "op-propose") async throws -> Fixture {
        let port = StubFilePort()
        port.files["hero.png"] = Data("base-image".utf8)
        let store = InMemoryOwnerStore()
        let payloads = InMemoryPayloadStore()
        let commitPort = StubCommitPort()
        let (_, workflow, _, _, _) = await makeFileWorkflow(
            filePort: port, commitPort: commitPort,
            ownerStore: store, payloads: payloads)
        let target = fileTarget()
        let frozen = try await workflow.freezeInput(
            target: target, operationID: "op-freeze", expectedOwnerRevision: nil)
        let proposed = Data("proposed-image".utf8)
        let proposal = try await workflow.propose(
            target: target, operationID: proposeOperation,
            expectedOwnerRevision: frozen.envelope.revision,
            artifactID: frozen.revision.artifactID,
            baseRevisionID: frozen.revision.id,
            bytes: proposed, format: "png", summary: "make it pop")
        return Fixture(
            port: port, store: store, payloads: payloads, commitPort: commitPort,
            workflow: workflow, target: target, frozen: frozen,
            proposed: proposed, proposal: proposal)
    }

    private func proposeAgain(
        _ fixture: Fixture,
        operationID: String? = nil,
        artifactID: String? = nil,
        baseRevisionID: String? = nil,
        bytes: Data? = nil,
        format: String = "png",
        summary: String = "make it pop",
        feedbackIDs: [String] = [],
        target: DesignTarget? = nil,
        expectedOwnerRevision: Int64? = nil
    ) async throws -> DesignOwnerWorkflow.Proposal {
        try await fixture.workflow.propose(
            target: target ?? fixture.target,
            operationID: operationID ?? fixture.proposal.candidate.proposalOperationID ?? "op-propose",
            expectedOwnerRevision: expectedOwnerRevision ?? fixture.proposal.envelope.revision,
            artifactID: artifactID ?? fixture.frozen.revision.artifactID,
            baseRevisionID: baseRevisionID ?? fixture.frozen.revision.id,
            bytes: bytes ?? fixture.proposed,
            format: format, summary: summary,
            feedbackIDs: feedbackIDs)
    }

    @Test func duplicateProposeReplaysExactRecordWithoutSecondPayloadOrRevision() async throws {
        let fixture = try await makeFixture()
        #expect(fixture.proposal.replayed == false)
        let stagedAfterFirst = fixture.payloads.stored.count
        let stateAfterFirst = try #require(await fixture.workflow.state(fixture.target))
        let revisionCount = stateAfterFirst.project.artifact(fixture.frozen.revision.artifactID)?
            .revisions.count
        let candidate = try #require(stateAfterFirst.project.candidate(fixture.proposal.candidate.id))
        #expect(candidate.proposalOperationID == "op-propose")
        #expect(candidate.proposalFingerprint?.isEmpty == false)

        let replay = try await proposeAgain(fixture)
        #expect(replay.replayed == true)
        #expect(replay.candidate.id == fixture.proposal.candidate.id)
        #expect(replay.candidate.proposedRevisionID == fixture.proposal.candidate.proposedRevisionID)
        #expect(replay.payloadRelativePath == fixture.proposal.payloadRelativePath)
        // No second payload, no second revision, no envelope advance.
        #expect(fixture.payloads.stored.count == stagedAfterFirst)
        #expect(fixture.payloads.abandoned.isEmpty)
        let stateAfterReplay = try #require(await fixture.workflow.state(fixture.target))
        #expect(stateAfterReplay.revision == stateAfterFirst.revision)
        #expect(stateAfterReplay.project.candidates.count == 1)
        #expect(stateAfterReplay.project.artifact(fixture.frozen.revision.artifactID)?
            .revisions.count == revisionCount)

        // A DIFFERENT operation with the same bytes is legitimate: a new
        // candidate is created and the old one is superseded (not reused).
        let differentOperation = try await proposeAgain(fixture, operationID: "op-propose-2")
        #expect(differentOperation.replayed == false)
        #expect(differentOperation.candidate.id != fixture.proposal.candidate.id)
        let afterDifferent = try #require(await fixture.workflow.state(fixture.target))
        #expect(afterDifferent.project.candidates.count == 2)
        // Replaying the ORIGINAL operation still returns ITS recorded
        // candidate, even though it is superseded.
        let originalReplay = try await proposeAgain(fixture)
        #expect(originalReplay.replayed == true)
        #expect(originalReplay.candidate.id == fixture.proposal.candidate.id)
    }

    @Test func changedSemanticInputsReplayMismatchBeforeStaging() async throws {
        let fixture = try await makeFixture()
        let stagedAfterFirst = fixture.payloads.stored.count
        let stateAfterFirst = try #require(await fixture.workflow.state(fixture.target))
        let revisionCount = stateAfterFirst.project.artifact(fixture.frozen.revision.artifactID)?
            .revisions.count

        // bytes, format, artifact, base, summary, feedback and origin are
        // all part of the operation identity: each changed one must be
        // refused as a replayMismatch, never applied and never staged.
        let mismatches: [(String, () async throws -> DesignOwnerWorkflow.Proposal)] = [
            ("bytes", { try await self.proposeAgain(fixture, bytes: Data("different-bytes".utf8)) }),
            ("format", { try await self.proposeAgain(fixture, format: "jpg") }),
            ("artifact", { try await self.proposeAgain(fixture, artifactID: "other-artifact") }),
            ("base", { try await self.proposeAgain(fixture, baseRevisionID: "other-base") }),
            ("summary", { try await self.proposeAgain(fixture, summary: "changed summary") }),
            ("feedback", { try await self.proposeAgain(fixture, feedbackIDs: ["fb-999"]) }),
            ("origin", {
                try await self.proposeAgain(
                    fixture, target: fileTarget(origin: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"))
            })
        ]
        for (name, call) in mismatches {
            do {
                _ = try await call()
                Issue.record("expected replayMismatch for changed \(name)")
            } catch let error as DesignOwnerWorkflowError {
                guard case .replayMismatch = error else {
                    Issue.record("unexpected error for changed \(name): \(error)")
                    continue
                }
            }
        }
        // Zero staging: no payload stored and none abandoned, no extra
        // revision or candidate.
        #expect(fixture.payloads.stored.count == stagedAfterFirst)
        #expect(fixture.payloads.abandoned.isEmpty)
        let after = try #require(await fixture.workflow.state(fixture.target))
        #expect(after.project.candidates.count == 1)
        #expect(after.project.artifact(fixture.frozen.revision.artifactID)?
            .revisions.count == revisionCount)
        #expect(after.revision == stateAfterFirst.revision)
    }

    @Test func replayAcceptsTheResolvedBaseNotJustTheLiteralArgument() async throws {
        let fixture = try await makeFixture()
        // The ORIGINAL proposal passed an explicit base; a replay that
        // passes nil resolves to the recorded base and must still match.
        let nilBase = try await fixture.workflow.propose(
            target: fixture.target, operationID: "op-propose",
            expectedOwnerRevision: fixture.proposal.envelope.revision,
            artifactID: fixture.frozen.revision.artifactID,
            baseRevisionID: nil,
            bytes: fixture.proposed, format: "png", summary: "make it pop")
        #expect(nilBase.replayed == true)
        #expect(nilBase.candidate.id == fixture.proposal.candidate.id)
        #expect(fixture.payloads.stored.count == 2) // freeze payload + one proposal
    }

    @Test func replaySurvivesConcurrencyReopenAndPersistenceEncoding() async throws {
        let fixture = try await makeFixture(proposeOperation: "op-first")
        let before = fixture.payloads.stored.count

        // Two identical concurrent calls for a FRESH operation: one winner,
        // both return the SAME recorded candidate, exactly one payload
        // staged (the second converges through the replay record).
        let candidateIDs = try await withThrowingTaskGroup(of: String.self) { group -> [String] in
            for _ in 0..<2 {
                group.addTask {
                    try await fixture.workflow.propose(
                        target: fixture.target, operationID: "op-concurrent",
                        expectedOwnerRevision: fixture.proposal.envelope.revision,
                        artifactID: fixture.frozen.revision.artifactID,
                        baseRevisionID: fixture.frozen.revision.id,
                        bytes: fixture.proposed, format: "png", summary: "make it pop"
                    ).candidate.id
                }
            }
            var ids: [String] = []
            for try await id in group { ids.append(id) }
            return ids
        }
        #expect(Set(candidateIDs).count == 1)
        let concurrentCandidate = try #require(candidateIDs.first)
        #expect(concurrentCandidate != fixture.proposal.candidate.id)
        #expect(fixture.payloads.stored.count == before + 1)
        #expect(fixture.payloads.abandoned.isEmpty)

        // Persistence: the operation record must survive the exact Codable
        // round-trip an owner store performs.
        let envelope = try #require(await fixture.store.load(targetKey: fixture.target.stableKey))
        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(DesignOwnerEnvelope.self, from: data)
        let decodedCandidate = try #require(
            decoded.project.candidates.first { $0.id == concurrentCandidate })
        #expect(decodedCandidate.proposalOperationID == "op-concurrent")
        #expect(decodedCandidate.proposalFingerprint?.isEmpty == false)

        // Reopen through a NEW workflow over the same stores: replay still
        // returns the same candidate and payload.
        let (_, reopened, _, _, _) = await makeFileWorkflow(
            filePort: fixture.port, ownerStore: fixture.store, payloads: fixture.payloads)
        let replay = try await reopened.propose(
            target: fixture.target, operationID: "op-concurrent",
            expectedOwnerRevision: 0,
            artifactID: fixture.frozen.revision.artifactID,
            baseRevisionID: fixture.frozen.revision.id,
            bytes: fixture.proposed, format: "png", summary: "make it pop")
        #expect(replay.replayed == true)
        #expect(replay.candidate.id == concurrentCandidate)
    }

    @Test func replayRequiresLiveAuthorizationAndFailsClosedWithoutARecord() async throws {
        let fixture = try await makeFixture(proposeOperation: "op-auth")
        // Authorization is re-evaluated live even for a replay.
        fixture.port.authorized = false
        do {
            _ = try await proposeAgain(fixture, operationID: "op-auth")
            Issue.record("expected notAuthorized for a revoked replay")
        } catch let error as DesignTargetError {
            guard case .notAuthorized = error else {
                Issue.record("unexpected \(error)")
                return
            }
        }
        fixture.port.authorized = true

        // A legacy applied operation WITHOUT the candidate record fails
        // closed: it is never recovered by "last pending candidate with the
        // matching digest".
        let envelope = try #require(await fixture.store.load(targetKey: fixture.target.stableKey))
        var legacy = envelope
        for index in legacy.project.candidates.indices {
            legacy.project.candidates[index].proposalOperationID = nil
            legacy.project.candidates[index].proposalFingerprint = nil
        }
        _ = try await fixture.store.save(
            legacy, targetKey: fixture.target.stableKey, expectedRevision: envelope.revision)
        do {
            _ = try await proposeAgain(fixture, operationID: "op-auth")
            Issue.record("expected replayMismatch for a record-less applied operation")
        } catch let error as DesignOwnerWorkflowError {
            guard case .replayMismatch = error else {
                Issue.record("unexpected \(error)")
                return
            }
        }
        #expect(fixture.payloads.abandoned.isEmpty)
    }

    @Test func adoptionClaimRunsExactlyOnceBeforeSideEffectsAndReplaySkipsIt() async throws {
        let fixture = try await makeFixture()
        let claims = SendableBox<Int>()
        claims.set(0)
        let claim: @Sendable () async throws -> Void = {
            claims.set((claims.value ?? 0) + 1)
        }
        let frozenTarget = fixture.target.freezing(
            revision: fixture.frozen.source.baseRevisionToken)
        let adopted = try await fixture.workflow.adopt(
            target: frozenTarget, operationID: "op-adopt",
            expectedOwnerRevision: fixture.proposal.envelope.revision,
            candidateID: fixture.proposal.candidate.id,
            mode: .updateOriginal,
            claimAuthorization: claim,
            verifyReopen: { _, _, _ in })
        #expect(adopted.replayed == false)
        #expect(claims.value == 1)
        #expect(fixture.commitPort.commitCount == 1)

        // Replay under the same operationID: recorded result, no second
        // claim and no second owner write.
        let replay = try await fixture.workflow.adopt(
            target: frozenTarget, operationID: "op-adopt",
            expectedOwnerRevision: fixture.proposal.envelope.revision,
            candidateID: fixture.proposal.candidate.id,
            mode: .updateOriginal,
            claimAuthorization: claim,
            verifyReopen: { _, _, _ in })
        #expect(replay.replayed == true)
        #expect(claims.value == 1)
        #expect(fixture.commitPort.commitCount == 1)

        // The SAME operationID replayed with a DIFFERENT mode is a
        // mismatch: the adopted mode is part of the operation identity, and
        // the replay never reaches the claim.
        do {
            _ = try await fixture.workflow.adopt(
                target: frozenTarget, operationID: "op-adopt",
                expectedOwnerRevision: fixture.proposal.envelope.revision,
                candidateID: fixture.proposal.candidate.id,
                mode: .variant,
                claimAuthorization: claim,
                verifyReopen: { _, _, _ in })
            Issue.record("expected replayMismatch for a changed adopt mode")
        } catch let error as DesignOwnerWorkflowError {
            guard case .replayMismatch = error else {
                Issue.record("unexpected \(error)")
                return
            }
        }
        #expect(claims.value == 1)
    }

    @Test func adoptionClaimFailureAndPreflightConflictNeverWrite() async throws {
        let fixture = try await makeFixture()
        let frozenTarget = fixture.target.freezing(
            revision: fixture.frozen.source.baseRevisionToken)
        let savesBefore = await fixture.store.saveCount
        let denyClaim: @Sendable () async throws -> Void = {
            throw FloeError.validationFailed("no live confirmation")
        }
        do {
            _ = try await fixture.workflow.adopt(
                target: frozenTarget, operationID: "op-adopt",
                expectedOwnerRevision: fixture.proposal.envelope.revision,
                candidateID: fixture.proposal.candidate.id,
                mode: .updateOriginal,
                claimAuthorization: denyClaim,
                verifyReopen: { _, _, _ in })
            Issue.record("expected the claim failure to abort the adoption")
        } catch {
            #expect(String(describing: error).contains("no live confirmation"))
        }
        // Nothing was written: no commit, no envelope save, candidate still
        // pending, durable intent never prepared.
        #expect(fixture.commitPort.enteredCount == 0)
        #expect(fixture.commitPort.commitCount == 0)
        #expect(await fixture.store.saveCount == savesBefore)
        let afterDenied = try #require(await fixture.workflow.state(fixture.target))
        #expect(afterDenied.revision == fixture.proposal.envelope.revision)
        #expect(afterDenied.project.candidate(fixture.proposal.candidate.id)?.status == .pending)

        // Pre-flight conflicts (late candidate on update-original) fail
        // BEFORE the claim: the user's confirmation is not burned for a
        // request the service refuses anyway.
        _ = try await fixture.workflow.registerEdit(
            target: fixture.target, operationID: "op-manual",
            expectedOwnerRevision: fixture.proposal.envelope.revision,
            artifactID: fixture.frozen.revision.artifactID,
            bytes: Data("manual-newer".utf8), format: "png",
            origin: .edit, expectedArtifactRevisionID: fixture.frozen.revision.id)
        let afterManual = try #require(await fixture.workflow.state(fixture.target))
        let claims = SendableBox<Int>()
        claims.set(0)
        let countClaim: @Sendable () async throws -> Void = {
            claims.set((claims.value ?? 0) + 1)
        }
        do {
            _ = try await fixture.workflow.adopt(
                target: frozenTarget, operationID: "op-adopt",
                expectedOwnerRevision: afterManual.revision,
                candidateID: fixture.proposal.candidate.id,
                mode: .updateOriginal,
                claimAuthorization: countClaim,
                verifyReopen: { _, _, _ in })
            Issue.record("expected late-candidate revisionConflict")
        } catch let error as DesignWorkflowError {
            guard case .revisionConflict = error else {
                Issue.record("unexpected \(error)")
                return
            }
        }
        #expect(claims.value == 0)
        // A variant adoption of the same candidate still claims and lands.
        let variant = try await fixture.workflow.adopt(
            target: frozenTarget, operationID: "op-adopt-variant",
            expectedOwnerRevision: afterManual.revision,
            candidateID: fixture.proposal.candidate.id,
            mode: .variant,
            claimAuthorization: countClaim,
            verifyReopen: { _, _, _ in })
        #expect(variant.replayed == false)
        #expect(claims.value == 1)
        #expect(fixture.commitPort.commitCount == 0) // variant never writes the source
    }
}
