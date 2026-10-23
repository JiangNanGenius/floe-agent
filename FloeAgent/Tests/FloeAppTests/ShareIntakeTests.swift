// FloeAppTests — inbound share transport and reviewed draft intake (S5 P1).
//
// PREPARED DEFINITIONS — deliberately NOT executed in this lane.
// The unified qualification run owns execution after the primary integrates
// the Share extension, test membership and App Group profiles.
//
// Coverage:
// * real filesystem staging, manifest-last atomicity, original bytes/digests
// * FIFO claim, exclusive live lease, crash recovery grace and token ack
// * TTL, queue/item/envelope limits, malformed paths, symlinks, corrupt manifests
// * reviewed draft consumption: existing draft preserved, attachment rollback,
//   busy/failed destinations keeping the envelope, staged copies retained
//   whenever the envelope already has a durable disk proof (a verified
//   landing whose reconciled follow-up failed or deferred must never leave
//   the durable draft pointing at deleted files), discard without a task,
//   crash-after-commit-before-ack idempotency and no auto-run.
//
// Synthetic content only. No provider is contacted and no real user file is
// read.

#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeModels
@testable import FloeApp

// MARK: - Helpers

private func makeInboxRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("share-inbox-tests-\(UUID().uuidString)", isDirectory: true)
}

private func makeSourceDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("share-inbox-sources-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@discardableResult
private func writeSource(
    _ name: String,
    _ data: Data,
    in directory: URL
) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try data.write(to: url)
    return url
}

private func writeManifest(
    _ envelope: ShareEnvelope,
    in directory: URL,
    replacingStorageNameWith storageName: String? = nil
) throws {
    var copy = envelope
    if let storageName, !copy.items.isEmpty {
        copy.items[0].storageName = storageName
    }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    try encoder.encode(copy).write(
        to: directory.appendingPathComponent("envelope.json"),
        options: .atomic
    )
}

// MARK: - Transport

@Suite("FloeCore.ShareInbox")
struct ShareInboxTransportTests {

    @Test("Documented production limits and item caps")
    func productionLimits() {
        let limits = ShareInboxLimits.standard
        #expect(limits.maxItems == 5)
        #expect(limits.maxTextBytes == 1_048_576)
        #expect(limits.maxItemBytes == 67_108_864)
        #expect(limits.maxEnvelopeBytes == 134_217_728)
        #expect(limits.maxPendingEnvelopes == 20)
        #expect(limits.maxPendingBytes == 268_435_456)
        #expect(limits.ttl == 604_800)
        #expect(limits.claimRecoveryGrace == 300)
    }

    @Test("Multi-item staging preserves text, URL, image and file bytes")
    func multiItemStagingPreservesOriginalBytes() throws {
        let root = makeInboxRoot()
        let sources = try makeSourceDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sources)
        }
        let inbox = ShareInbox(rootURL: root)
        let imageBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02])
        let fileBytes = Data("synthetic-pdf-payload".utf8)
        let fileURL = try writeSource("report.pdf", fileBytes, in: sources)
        let createdAt = Date(timeIntervalSince1970: 1_000)

        let envelope = try inbox.stage(inputs: [
            ShareInboxInput(kind: .text, payload: .text("Summarize this")),
            ShareInboxInput(
                kind: .url,
                payload: .url("https://example.com/a?b=1")
            ),
            ShareInboxInput(
                kind: .image,
                payload: .data(imageBytes),
                displayName: "photo.png",
                typeIdentifier: "public.png"
            ),
            ShareInboxInput(
                kind: .file,
                payload: .file(fileURL),
                displayName: "report.pdf",
                typeIdentifier: "com.adobe.pdf"
            ),
        ], producer: "tests", createdAt: createdAt)

        #expect(envelope.items.count == 4)
        #expect(envelope.totalByteCount == envelope.items.reduce(0) { $0 + $1.byteCount })
        #expect(envelope.items[0].kind == .text)
        #expect(envelope.items[0].text == "Summarize this")
        #expect(envelope.items[1].kind == .url)
        #expect(envelope.items[1].text == "https://example.com/a?b=1")
        #expect(envelope.items[2].kind == .image)
        #expect(envelope.items[2].sha256 == FloeDigest.sha256Hex(imageBytes))
        #expect(envelope.items[3].kind == .file)
        #expect(envelope.items[3].typeIdentifier == "com.adobe.pdf")
        #expect(envelope.items[3].fileName == "report.pdf")

        let stagedImage = try inbox.payloadURL(for: envelope.items[2], in: envelope)
        let stagedFile = try inbox.payloadURL(for: envelope.items[3], in: envelope)
        #expect(try Data(contentsOf: stagedImage) == imageBytes)
        #expect(try Data(contentsOf: stagedFile) == fileBytes)
        #expect(try inbox.pending(now: createdAt.addingTimeInterval(1)).map(\.id) == [envelope.id])
    }

    @Test("A failed multi-item stage leaves no readable envelope or staging")
    func failedStagingIsAtomic() throws {
        let root = makeInboxRoot()
        let sources = try makeSourceDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sources)
        }
        let inbox = ShareInbox(rootURL: root)
        let missing = sources.appendingPathComponent("missing.bin")

        #expect(throws: (any Error).self) {
            _ = try inbox.stage(inputs: [
                ShareInboxInput(kind: .text, payload: .text("first")),
                ShareInboxInput(
                    kind: .file,
                    payload: .file(missing),
                    displayName: "missing.bin",
                    typeIdentifier: "public.data"
                ),
            ])
        }
        #expect(try inbox.pending().isEmpty)
        let staging = try FileManager.default.contentsOfDirectory(
            at: inbox.stagingURL,
            includingPropertiesForKeys: nil
        )
        #expect(staging.isEmpty)
    }

    @Test("Adopting an extension temporary file moves bytes; non-temporary sources are refused")
    func adoptTemporaryFileIsBounded() throws {
        let root = makeInboxRoot()
        let temp = try makeSourceDirectory()
        let outside = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("share-inbox-outside-\(UUID().uuidString).bin")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: temp)
            try? FileManager.default.removeItem(at: outside)
        }
        let inbox = ShareInbox(rootURL: root)
        let bytes = Data("extension-temporary-bytes".utf8)
        let temporarySource = try writeSource("photo.bin", bytes, in: temp)
        let session = try inbox.beginStaging()
        try session.adoptTemporaryFile(
            at: temporarySource,
            displayName: "photo.bin",
            typeIdentifier: "public.data",
            kind: .file
        )
        #expect(!FileManager.default.fileExists(atPath: temporarySource.path))
        let envelope = try session.commit()
        let firstItem = try #require(envelope.items.first)
        let staged = try inbox.payloadURL(for: firstItem, in: envelope)
        #expect(try Data(contentsOf: staged) == bytes)

        try bytes.write(to: outside, options: .atomic)
        let second = try inbox.beginStaging()
        #expect(throws: ShareInboxError.invalidState) {
            try second.adoptTemporaryFile(
                at: outside,
                displayName: "outside.bin",
                typeIdentifier: "public.data",
                kind: .file
            )
        }
        second.cancel()
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test("Claim is exclusive; ack deletes only the claimed envelope")
    func claimIsExclusiveAndAckDeletesOnlyClaimedEnvelope() throws {
        let root = makeInboxRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = ShareInbox(rootURL: root)
        let first = try inbox.stage(
            inputs: [ShareInboxInput(kind: .text, payload: .text("first"))],
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let second = try inbox.stage(
            inputs: [ShareInboxInput(kind: .text, payload: .text("second"))],
            createdAt: Date(timeIntervalSince1970: 2_000)
        )
        let now = Date(timeIntervalSince1970: 3_000)

        let claimed = try inbox.claimNext(now: now)
        let claim = try #require(claimed)
        #expect(claim.envelope.id == first.id)
        #expect(throws: ShareInboxError.claimBusy) {
            _ = try inbox.claim(id: first.id, now: now)
        }
        // Strict FIFO: the claimed head blocks claimNext.
        #expect(throws: ShareInboxError.claimBusy) {
            _ = try inbox.claimNext(now: now)
        }
        try inbox.ack(claim)
        #expect(try inbox.pending(now: now).map(\.id) == [second.id])
        #expect(throws: ShareInboxError.invalidState) {
            try inbox.ack(claim)
        }
    }

    @Test("A live claim is never stolen; a dead lease recovers after the grace window")
    func staleClaimRecoveryRequiresDeadLease() throws {
        let root = makeInboxRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = ShareInbox(rootURL: root)
        let envelope = try inbox.stage(
            inputs: [ShareInboxInput(kind: .text, payload: .text("recover me"))],
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let claimedAt = Date(timeIntervalSince1970: 2_000)
        var claim: ShareInboxClaim? = try inbox.claim(id: envelope.id, now: claimedAt)
        let oldToken = try #require(claim?.token)

        let afterGrace = claimedAt.addingTimeInterval(301)
        let liveReport = inbox.maintain(now: afterGrace)
        #expect(liveReport.recoveredClaims == 0)
        #expect(throws: ShareInboxError.claimBusy) {
            _ = try inbox.claim(id: envelope.id, now: afterGrace)
        }

        // Dropping the claim without ack/release simulates process death:
        // the kernel releases the flock, the record remains.
        claim = nil
        let deadReport = inbox.maintain(now: afterGrace)
        #expect(deadReport.recoveredClaims == 1)
        let recovered = try inbox.claim(id: envelope.id, now: afterGrace)
        #expect(recovered.token != oldToken)
        try inbox.release(recovered)
    }

    @Test("Token ack rejects a mismatch and settles the exact claim")
    func tokenAckIsStrict() throws {
        let root = makeInboxRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = ShareInbox(rootURL: root)
        let envelope = try inbox.stage(
            inputs: [ShareInboxInput(kind: .text, payload: .text("ack me"))],
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let claimedAt = Date(timeIntervalSince1970: 2_000)
        var claim: ShareInboxClaim? = try inbox.claim(id: envelope.id, now: claimedAt)
        let token = try #require(claim?.token)
        claim = nil // process death, record retained

        #expect(try inbox.ack(id: envelope.id, claimToken: "wrong-token") == false)
        #expect(try inbox.pending(now: claimedAt).count == 1)
        #expect(try inbox.ack(id: envelope.id, claimToken: token) == true)
        #expect(try inbox.pending(now: claimedAt).isEmpty)
    }

    @Test("TTL removes unreviewed envelopes and they are no longer pending")
    func expiredEnvelopeIsRemoved() throws {
        let root = makeInboxRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = ShareInbox(rootURL: root)
        let createdAt = Date(timeIntervalSince1970: 1_000)
        let envelope = try inbox.stage(
            inputs: [ShareInboxInput(kind: .text, payload: .text("old share"))],
            createdAt: createdAt
        )
        let afterTTL = createdAt.addingTimeInterval(ShareInboxLimits.standard.ttl + 1)
        #expect(try inbox.pending(now: afterTTL).isEmpty)

        let report = inbox.maintain(now: afterTTL)
        #expect(report.expiredEnvelopes == 1)
        #expect(!FileManager.default.fileExists(
            atPath: inbox.envelopeDirectory(for: envelope.id).path
        ))
    }

    @Test("Queue and byte limits reject a new envelope without dropping existing ones")
    func queueLimits() throws {
        let root = makeInboxRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var limits = ShareInboxLimits()
        limits.maxPendingEnvelopes = 2
        limits.maxPendingBytes = 1_000
        let inbox = ShareInbox(rootURL: root, limits: limits)

        _ = try inbox.stage(inputs: [ShareInboxInput(kind: .text, payload: .text("a"))])
        _ = try inbox.stage(inputs: [ShareInboxInput(kind: .text, payload: .text("b"))])
        #expect(throws: ShareInboxError.queueFull(envelopes: 2, bytes: 2)) {
            _ = try inbox.stage(inputs: [ShareInboxInput(kind: .text, payload: .text("c"))])
        }
        #expect(try inbox.pending().count == 2)
    }

    @Test("Text, item and envelope limits reject oversize input")
    func sizeLimits() throws {
        let root = makeInboxRoot()
        let sources = try makeSourceDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sources)
        }
        var limits = ShareInboxLimits()
        limits.maxItems = 3
        limits.maxTextBytes = 5
        limits.maxItemBytes = 8
        limits.maxEnvelopeBytes = 10
        let inbox = ShareInbox(rootURL: root, limits: limits)

        #expect(throws: ShareInboxError.textTooLarge(byteCount: 6, limit: 5)) {
            _ = try inbox.stage(inputs: [
                ShareInboxInput(kind: .text, payload: .text("123456")),
            ])
        }
        let bigFile = try writeSource("big.bin", Data(repeating: 0x41, count: 9), in: sources)
        #expect(throws: ShareInboxError.itemTooLarge(byteCount: 9, limit: 8)) {
            _ = try inbox.stage(inputs: [
                ShareInboxInput(
                    kind: .file,
                    payload: .file(bigFile),
                    displayName: "big.bin",
                    typeIdentifier: "public.data"
                ),
            ])
        }
        let six = try writeSource("six.bin", Data(repeating: 0x42, count: 6), in: sources)
        let session = try inbox.beginStaging()
        try session.appendText("12345", kind: .text)
        #expect(throws: ShareInboxError.envelopeTooLarge(byteCount: 11, limit: 10)) {
            try session.appendFile(
                at: six,
                displayName: "six.bin",
                typeIdentifier: "public.data",
                kind: .file
            )
        }
        session.cancel()
    }

    @Test("Traversal, corrupt manifests and symlinked payloads are rejected")
    func unsafeManifestsAreRejected() throws {
        let root = makeInboxRoot()
        let sources = try makeSourceDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sources)
        }
        let inbox = ShareInbox(rootURL: root)
        let bytes = Data("safe-looking-bytes".utf8)
        let source = try writeSource("payload.txt", bytes, in: sources)

        let traversal = try inbox.stage(inputs: [
            ShareInboxInput(
                kind: .file,
                payload: .file(source),
                displayName: "payload.txt",
                typeIdentifier: "public.plain-text"
            ),
        ])
        try writeManifest(
            traversal,
            in: inbox.envelopeDirectory(for: traversal.id),
            replacingStorageNameWith: "../escape.txt"
        )
        #expect(try inbox.pending().isEmpty)
        #expect(throws: ShareInboxError.self) {
            _ = try inbox.claim(id: traversal.id)
        }

        let corrupt = try inbox.stage(inputs: [
            ShareInboxInput(
                kind: .file,
                payload: .file(source),
                displayName: "payload.txt",
                typeIdentifier: "public.plain-text"
            ),
        ])
        try Data("{not-a-manifest".utf8).write(
            to: inbox.envelopeDirectory(for: corrupt.id).appendingPathComponent("envelope.json")
        )
        #expect(try inbox.pending().isEmpty)
        #expect(inbox.diagnostics().count == 2)

        let symlinked = try inbox.stage(inputs: [
            ShareInboxInput(
                kind: .file,
                payload: .file(source),
                displayName: "payload.txt",
                typeIdentifier: "public.plain-text"
            ),
        ])
        let directory = inbox.envelopeDirectory(for: symlinked.id)
        let item = try #require(symlinked.items.first)
        let itemURL = try inbox.payloadURL(for: item, in: symlinked)
        try FileManager.default.removeItem(at: itemURL)
        try FileManager.default.createSymbolicLink(at: itemURL, withDestinationURL: source)
        #expect(try inbox.pending().isEmpty)
        #expect(throws: ShareInboxError.self) {
            _ = try inbox.claim(id: symlinked.id)
        }
    }

    @Test("Text items cannot be resolved as payload files")
    func textItemHasNoPayloadURL() throws {
        let root = makeInboxRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = ShareInbox(rootURL: root)
        let envelope = try inbox.stage(inputs: [
            ShareInboxInput(kind: .text, payload: .text("inline only")),
        ])
        let item = try #require(envelope.items.first)
        #expect(throws: ShareInboxError.unsupportedItem(reason: "textPayload")) {
            _ = try inbox.payloadURL(for: item, in: envelope)
        }
    }
}

// MARK: - Fakes

@MainActor
private final class FakeShareDestination: ShareIntakeDestination {
    var text: String
    var attachments: [AttachmentRef]
    var isBusy = false
    var resultOverride: ShareDraftApplyResult?
    /// Simulates the reviewed durability job's shape: a placement of THIS
    /// envelope verified durable on disk during this apply, and only then
    /// the reconciled follow-up failed or deferred. With a failing/busy
    /// override this marks the receipt proven BEFORE returning the override,
    /// so the center's staged-file retention can be exercised deterministically.
    var provesPlacementBeforeFailingOutcome = false
    private(set) var applyCount = 0
    private(set) var appliedEnvelopeIDs: Set<UUID> = []
    /// Receipts treated by this fake as PROVEN ON DISK.
    var receipts: [UUID: String] = [:]

    init(text: String = "", attachments: [AttachmentRef] = []) {
        self.text = text
        self.attachments = attachments
    }

    var shareIntakeDestinationID: String { "test.home.draft" }

    func shareIntakeSnapshot() -> ShareDraftSnapshot {
        ShareDraftSnapshot(
            text: text,
            attachmentIDs: attachments.map(\.id),
            storedRevision: nil,
            isBusy: isBusy
        )
    }

    func shareIntakeAppliedClaimToken(envelopeID: UUID) -> String? {
        receipts[envelopeID]
    }

    func shareIntakeSettle(envelopeID: UUID, claimToken: String) {
        if receipts[envelopeID] == claimToken {
            receipts[envelopeID] = nil
        }
    }

    func shareIntakeApply(_ application: ShareDraftApplication) async -> ShareDraftApplyResult {
        applyCount += 1
        if isBusy { return .busy }
        if let resultOverride {
            if provesPlacementBeforeFailingOutcome,
               resultOverride == .failed || resultOverride == .busy || resultOverride == .unavailable {
                receipts[application.envelopeID] = application.receipt.claimToken
            }
            return resultOverride
        }
        text = ShareDraftMerger.mergedText(
            existing: text,
            incoming: application.incomingText
        )
        attachments = ShareDraftMerger.mergedAttachments(
            existing: attachments,
            incoming: application.stagedAttachments
        )
        receipts[application.envelopeID] = application.receipt.claimToken
        appliedEnvelopeIDs.insert(application.envelopeID)
        return .applied
    }
}

@MainActor
private final class FakeShareAttachmentStaging: ShareAttachmentStaging {
    var failOnDisplayName: String?
    var afterStaging: (() -> Void)?
    private(set) var staged: [AttachmentRef] = []
    private(set) var discardedIDs: [UUID] = []
    private(set) var stagedDisplayNames: [String] = []

    func stageShareAttachment(
        from url: URL,
        displayName: String,
        typeIdentifier: String,
        kind: ShareInboxItemKind,
        envelopeID: UUID
    ) async throws -> AttachmentRef {
        if let failOnDisplayName, failOnDisplayName == displayName {
            throw FloeError.validationFailed("synthetic staging failure")
        }
        let data = try Data(contentsOf: url)
        let attachment = AttachmentRef(
            kind: kind == .image ? .image : .document,
            displayName: displayName,
            uti: typeIdentifier,
            byteCount: data.count,
            sha256: FloeDigest.sha256Hex(data)
        )
        staged.append(attachment)
        stagedDisplayNames.append(displayName)
        afterStaging?()
        return attachment
    }

    func discardShareAttachment(_ attachment: AttachmentRef) async {
        discardedIDs.append(attachment.id)
        staged.removeAll { $0.id == attachment.id }
    }
}

// MARK: - Center

@Suite("FloeApp.ShareIntakeCenter")
@MainActor
struct ShareIntakeCenterTests {

    private func makeInbox() -> (inbox: ShareInbox, root: URL) {
        let root = makeInboxRoot()
        return (ShareInbox(rootURL: root), root)
    }

    private func stageTextAndFile(
        in inbox: ShareInbox,
        sources: URL,
        text: String = "Shared body",
        fileName: String = "note.txt"
    ) throws -> ShareEnvelope {
        let file = try writeSource(
            fileName,
            Data("synthetic attachment body".utf8),
            in: sources
        )
        return try inbox.stage(inputs: [
            ShareInboxInput(kind: .text, payload: .text(text)),
            ShareInboxInput(
                kind: .file,
                payload: .file(file),
                displayName: fileName,
                typeIdentifier: "public.plain-text"
            ),
        ])
    }

    @Test("Merge is non-destructive and keeps attachment identity")
    func mergePreservesDraft() {
        let existingAttachment = AttachmentRef(
            kind: .document,
            displayName: "existing.pdf",
            uti: "com.adobe.pdf",
            byteCount: 3
        )
        let sharedAttachment = AttachmentRef(
            kind: .image,
            displayName: "shared.png",
            uti: "public.png",
            byteCount: 4
        )
        #expect(ShareDraftMerger.mergedText(existing: "", incoming: "Shared") == "Shared")
        #expect(ShareDraftMerger.mergedText(existing: "  \n", incoming: "Shared") == "Shared")
        #expect(ShareDraftMerger.mergedText(existing: "Existing", incoming: "Shared") == "Existing\n\nShared")
        #expect(ShareDraftMerger.mergedText(existing: "Existing\n", incoming: "Shared") == "Existing\n\nShared")
        let merged = ShareDraftMerger.mergedAttachments(
            existing: [existingAttachment],
            incoming: [existingAttachment, sharedAttachment]
        )
        #expect(merged.map(\.id) == [existingAttachment.id, sharedAttachment.id])
    }

    @Test("Apply preserves an existing draft and acknowledges only after commit")
    func applyPreservesExistingDraft() async throws {
        let (inbox, root) = makeInbox()
        let sources = try makeSourceDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sources)
        }
        let envelope = try stageTextAndFile(in: inbox, sources: sources)
        let destination = FakeShareDestination(text: "Existing draft")
        let staging = FakeShareAttachmentStaging()
        let center = ShareIntakeCenter(inbox: inbox, staging: staging)

        let outcome = await center.apply(envelope, to: destination)

        #expect(outcome == .applied(envelopeID: envelope.id))
        #expect(destination.text == "Existing draft\n\nShared body")
        #expect(destination.attachments.count == 1)
        #expect(destination.applyCount == 1)
        #expect(staging.staged.count == 1)
        #expect(try inbox.pending().isEmpty)
    }

    @Test("Cancellation before intake or after the final attachment never commits a draft", arguments: [false, true])
    func cancellationRetainsSourceAndDraft(afterAttachment: Bool) async throws {
        let (inbox, root) = makeInbox()
        let sources = try makeSourceDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sources)
        }
        let envelope = try afterAttachment
            ? stageTextAndFile(in: inbox, sources: sources)
            : inbox.stage(inputs: [ShareInboxInput(kind: .text, payload: .text("Shared text"))])
        let destination = FakeShareDestination(text: "Existing draft")
        let staging = FakeShareAttachmentStaging()
        if afterAttachment {
            staging.afterStaging = { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let center = ShareIntakeCenter(inbox: inbox, staging: staging)
        let attempt = Task { @MainActor in
            if !afterAttachment { withUnsafeCurrentTask { $0?.cancel() } }
            return await center.apply(envelope, to: destination)
        }
        #expect(await attempt.value == .deferred(envelopeID: envelope.id, reason: .cancelled))
        #expect(destination.applyCount == 0)
        #expect(destination.text == "Existing draft")
        #expect(destination.attachments.isEmpty)
        #expect(staging.staged.isEmpty)
        #expect(try inbox.pending().map(\.id) == [envelope.id])
        let retry = try #require(try inbox.claimNext())
        try inbox.release(retry)
    }

    @Test("A busy destination keeps the envelope and discards this attempt's copies")
    func busyDestinationKeepsEnvelope() async throws {
        let (inbox, root) = makeInbox()
        let sources = try makeSourceDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sources)
        }
        let envelope = try stageTextAndFile(in: inbox, sources: sources)
        let destination = FakeShareDestination(text: "Existing draft")
        destination.resultOverride = .busy
        let staging = FakeShareAttachmentStaging()
        let center = ShareIntakeCenter(inbox: inbox, staging: staging)

        let outcome = await center.apply(envelope, to: destination)

        #expect(outcome == .deferred(envelopeID: envelope.id, reason: .composerBusy))
        #expect(destination.text == "Existing draft")
        #expect(destination.applyCount == 1)
        #expect(staging.staged.isEmpty)
        #expect(staging.discardedIDs.count == 1)
        #expect(try inbox.pending().count == 1)

        // The failed attempt released its claim: a later retry succeeds.
        destination.resultOverride = nil
        let retry = await center.apply(envelope, to: destination)
        #expect(retry == .applied(envelopeID: envelope.id))
        #expect(try inbox.pending().isEmpty)
    }

    @Test("A failed durable commit retains the envelope and the human draft")
    func failedCommitRetainsEnvelope() async throws {
        let (inbox, root) = makeInbox()
        let sources = try makeSourceDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sources)
        }
        let envelope = try stageTextAndFile(in: inbox, sources: sources)
        let destination = FakeShareDestination(text: "Human draft")
        destination.resultOverride = .failed
        let staging = FakeShareAttachmentStaging()
        let center = ShareIntakeCenter(inbox: inbox, staging: staging)

        let outcome = await center.apply(envelope, to: destination)

        #expect(outcome == .failed(
            envelopeID: envelope.id,
            message: FloeL10n.l("share.intake.failed")
        ))
        #expect(destination.text == "Human draft")
        #expect(destination.attachments.isEmpty)
        #expect(destination.receipts.isEmpty)
        #expect(staging.staged.isEmpty)
        #expect(try inbox.pending().count == 1)
        // The released claim can be retried.
        destination.resultOverride = nil
        let retry = await center.apply(envelope, to: destination)
        #expect(retry == .applied(envelopeID: envelope.id))
        #expect(destination.text == "Human draft\n\nShared body")
    }

    @Test("A failed apply with a durably proven envelope keeps this attempt's staged copies")
    func failedApplyKeepsStagedWhenDurableProofExists() async throws {
        let (inbox, root) = makeInbox()
        let sources = try makeSourceDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sources)
        }
        let envelope = try stageTextAndFile(in: inbox, sources: sources)
        let destination = FakeShareDestination(text: "Human draft")
        destination.resultOverride = .failed
        destination.provesPlacementBeforeFailingOutcome = true
        let staging = FakeShareAttachmentStaging()
        let center = ShareIntakeCenter(inbox: inbox, staging: staging)

        let outcome = await center.apply(envelope, to: destination)

        #expect(outcome == .failed(
            envelopeID: envelope.id,
            message: FloeL10n.l("share.intake.failed")
        ))
        // The durable snapshot of THIS envelope references the staged copy
        // (a verified landing whose reconciliation then failed). Deleting
        // the staged bytes while the envelope is still pending would leave
        // the durable draft pointing at removed files, so they stay owned;
        // only the claim is released and the envelope remains recoverable.
        #expect(staging.staged.count == 1)
        #expect(staging.discardedIDs.isEmpty)
        #expect(try inbox.pending().count == 1)

        // The next pass settles the proven landing without staging or
        // appending a second copy (the same crash-recovery authority).
        destination.resultOverride = nil
        let retry = await center.apply(envelope, to: destination)
        #expect(retry == .alreadyApplied(envelopeID: envelope.id))
        #expect(destination.applyCount == 1)
        #expect(staging.staged.count == 1)
        #expect(staging.discardedIDs.isEmpty)
        #expect(try inbox.pending().isEmpty)
    }

    @Test("A busy apply with a durably proven envelope keeps this attempt's staged copies")
    func busyApplyKeepsStagedWhenDurableProofExists() async throws {
        let (inbox, root) = makeInbox()
        let sources = try makeSourceDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sources)
        }
        let envelope = try stageTextAndFile(in: inbox, sources: sources)
        let destination = FakeShareDestination(text: "Human draft")
        destination.resultOverride = .busy
        destination.provesPlacementBeforeFailingOutcome = true
        let staging = FakeShareAttachmentStaging()
        let center = ShareIntakeCenter(inbox: inbox, staging: staging)

        let outcome = await center.apply(envelope, to: destination)

        #expect(outcome == .deferred(envelopeID: envelope.id, reason: .composerBusy))
        // Bounded reconciliation exhaustion has the same ownership shape as
        // a failed reconcile: an earlier placement may already be durable,
        // so the staged files it references must survive the deferral.
        #expect(staging.staged.count == 1)
        #expect(staging.discardedIDs.isEmpty)
        #expect(try inbox.pending().count == 1)
        destination.resultOverride = nil
        let retry = await center.apply(envelope, to: destination)
        #expect(retry == .alreadyApplied(envelopeID: envelope.id))
        #expect(try inbox.pending().isEmpty)
    }

    @Test("Crash after commit but before ack settles without a duplicate append")
    func crashAfterCommitBeforeAckIsIdempotent() async throws {
        let (inbox, root) = makeInbox()
        let sources = try makeSourceDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sources)
        }
        let envelope = try stageTextAndFile(in: inbox, sources: sources)
        let destination = FakeShareDestination(text: "Human draft")
        // Simulate the previous process: the merged draft and its receipt are
        // durable, but the source envelope was never acknowledged.
        destination.text = "Human draft\n\nShared body"
        destination.receipts[envelope.id] = "previous-process-token"
        let staging = FakeShareAttachmentStaging()
        let center = ShareIntakeCenter(inbox: inbox, staging: staging)

        let outcome = await center.apply(envelope, to: destination)

        #expect(outcome == .alreadyApplied(envelopeID: envelope.id))
        #expect(destination.applyCount == 0)
        #expect(destination.text == "Human draft\n\nShared body")
        #expect(destination.receipts.isEmpty)
        #expect(try inbox.pending().isEmpty)
    }

    @Test("Discard acknowledges the source without touching the draft")
    func discardDoesNotTouchDraft() async throws {
        let (inbox, root) = makeInbox()
        let sources = try makeSourceDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sources)
        }
        let envelope = try stageTextAndFile(in: inbox, sources: sources)
        let destination = FakeShareDestination(text: "Keep this draft")
        let staging = FakeShareAttachmentStaging()
        let center = ShareIntakeCenter(inbox: inbox, staging: staging)

        let outcome = await center.discard(envelope)

        #expect(outcome == .discarded(envelopeID: envelope.id))
        #expect(destination.text == "Keep this draft")
        #expect(destination.applyCount == 0)
        #expect(try inbox.pending().isEmpty)
    }

    @Test("A live claim from another consumer defers instead of double-consuming")
    func foreignClaimDefers() async throws {
        let (inbox, root) = makeInbox()
        let sources = try makeSourceDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sources)
        }
        let envelope = try stageTextAndFile(in: inbox, sources: sources)
        let destination = FakeShareDestination()
        let staging = FakeShareAttachmentStaging()
        let center = ShareIntakeCenter(inbox: inbox, staging: staging)
        let foreign = try inbox.claim(id: envelope.id, now: Date())

        let deferred = await center.apply(envelope, to: destination)
        #expect(deferred == .deferred(
            envelopeID: envelope.id,
            reason: .anotherShareInProgress
        ))
        #expect(destination.applyCount == 0)
        #expect(try inbox.pending().count == 1)

        try inbox.release(foreign)
        let applied = await center.apply(envelope, to: destination)
        #expect(applied == .applied(envelopeID: envelope.id))
    }

    @Test("Attachment staging failure keeps the envelope and leaves the draft alone")
    func stagingFailureKeepsEnvelope() async throws {
        let (inbox, root) = makeInbox()
        let sources = try makeSourceDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sources)
        }
        let envelope = try stageTextAndFile(in: inbox, sources: sources)
        let destination = FakeShareDestination(text: "Existing")
        let staging = FakeShareAttachmentStaging()
        staging.failOnDisplayName = "note.txt"
        let center = ShareIntakeCenter(inbox: inbox, staging: staging)

        let outcome = await center.apply(envelope, to: destination)

        #expect(outcome == .failed(
            envelopeID: envelope.id,
            message: FloeL10n.l("share.intake.failed")
        ))
        #expect(destination.text == "Existing")
        #expect(destination.applyCount == 0)
        #expect(staging.staged.isEmpty)
        #expect(try inbox.pending().count == 1)
    }

    @Test("Corrupt pending data is diagnosed and never auto-applied")
    func corruptEnvelopeIsDiagnosed() async throws {
        let (inbox, root) = makeInbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let envelope = try inbox.stage(inputs: [
            ShareInboxInput(kind: .text, payload: .text("corrupt me")),
        ])
        try Data("{broken".utf8).write(
            to: inbox.envelopeDirectory(for: envelope.id).appendingPathComponent("envelope.json")
        )
        let destination = FakeShareDestination()
        let staging = FakeShareAttachmentStaging()
        let center = ShareIntakeCenter(inbox: inbox, staging: staging)

        await center.refresh()
        #expect(center.pending.isEmpty)
        #expect(center.diagnostics.count == 1)
        #expect(center.queueIssueMessage != nil)
        let outcome = await center.applyNext(to: destination)
        #expect(outcome == .empty)
        #expect(destination.applyCount == 0)
    }

    @Test("Summary keeps a compact preview and item counts")
    func summaryIsCompact() throws {
        let root = makeInboxRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = ShareInbox(rootURL: root)
        let envelope = try inbox.stage(inputs: [
            ShareInboxInput(
                kind: .text,
                payload: .text("  First line\n\nSecond   line  ")
            ),
            ShareInboxInput(
                kind: .file,
                payload: .data(Data("synthetic".utf8)),
                displayName: "report.pdf",
                typeIdentifier: "com.adobe.pdf"
            ),
        ])
        let summary = ShareIntakeCenter.summary(for: envelope)
        #expect(summary.itemCount == 2)
        #expect(summary.attachmentCount == 1)
        #expect(summary.textPreview == "First line Second line")
        #expect(summary.fileNames == ["report.pdf"])
    }
}

#if DEBUG
/// Real Home adapter and real on-disk ComposerDraftStore; only input file
/// staging is synthetic. No model request, send, live draft or account data.
@Suite("FloeApp.ShareHomePersistence", .serialized)
@MainActor
struct ShareHomePersistenceTests {
    private func home(file: URL, id: UUID, initial: String? = nil) async throws -> (HomeLaunchpadViewModel, ComposerDraftStore) {
        let environment = try await appQualificationEnvironment()
        let drafts = ComposerDraftStore(fileURL: file)
        let vm = HomeLaunchpadViewModel(
            center: environment.conversationCenter,
            draftStorageID: id,
            initialDraft: initial,
            acceptsShortcutInbox: true,
            draftStore: drafts
        )
        return (vm, drafts)
    }

    @Test("Reviewed share reaches the real Home draft and survives a fresh store read")
    func realHomeCommitAndReopen() async throws {
        let root = makeInboxRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = ShareInbox(rootURL: root.appendingPathComponent("inbox"))
        let envelope = try inbox.stage(inputs: [ShareInboxInput(kind: .text, payload: .text("Incoming"))])
        let file = root.appendingPathComponent("drafts.json")
        let id = UUID()
        let (vm, drafts) = try await home(file: file, id: id, initial: "Existing")
        defer { _ = drafts.flushAndWait() }
        let center = ShareIntakeCenter(inbox: inbox, staging: FakeShareAttachmentStaging())
        #expect(await center.apply(envelope, to: vm) == .applied(envelopeID: envelope.id))
        #expect(vm.draft == "Existing\n\nIncoming")
        #expect(ComposerDraftStore(fileURL: file).entry(for: id)?.text == vm.draft)
        #expect(try inbox.pending().isEmpty)
    }

    @Test("A real durable Home receipt recovers commit-before-ack without adding twice")
    func realHomeReceiptRecoversAfterRestart() async throws {
        let root = makeInboxRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = ShareInbox(rootURL: root.appendingPathComponent("inbox"))
        let envelope = try inbox.stage(inputs: [ShareInboxInput(kind: .text, payload: .text("Incoming"))])
        let file = root.appendingPathComponent("drafts.json")
        let id = UUID()
        let (vm, drafts) = try await home(file: file, id: id, initial: "Existing")
        let claim = try inbox.claim(id: envelope.id)
        let receipt = ComposerDraftStore.ShortcutHandoffReceipt(
            destinationID: id.uuidString, entryID: envelope.id, claimToken: claim.token
        )
        let placement = ShareDraftApplication(
            envelopeID: envelope.id, incomingText: "Incoming", stagedAttachments: [], receipt: receipt
        )
        #expect(await vm.shareIntakeApply(placement) == .applied)
        #expect(vm.shareIntakeAppliedClaimToken(envelopeID: envelope.id) == claim.token)
        #expect(drafts.flushAndWait())
        // The source remains unacked. Release only the simulated process
        // lease; a new Home/store instance must consume the on-disk receipt.
        try inbox.release(claim)
        let (restored, restoredDrafts) = try await home(file: file, id: id)
        defer { _ = restoredDrafts.flushAndWait() }
        let center = ShareIntakeCenter(inbox: inbox, staging: FakeShareAttachmentStaging())
        #expect(await center.apply(envelope, to: restored) == .alreadyApplied(envelopeID: envelope.id))
        #expect(restored.draft == "Existing\n\nIncoming")
        #expect(try inbox.pending().isEmpty)
    }

    @Test("A real draft write failure preserves Home content and the source envelope")
    func realHomeWriteFailureDoesNotAcknowledge() async throws {
        let root = makeInboxRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = ShareInbox(rootURL: root.appendingPathComponent("inbox"))
        let envelope = try inbox.stage(inputs: [ShareInboxInput(kind: .text, payload: .text("Incoming"))])
        let blockedParent = root.appendingPathComponent("not-a-directory")
        try Data("synthetic blocker".utf8).write(to: blockedParent)
        let (vm, drafts) = try await home(file: blockedParent.appendingPathComponent("drafts.json"), id: UUID(), initial: "Existing")
        defer { _ = drafts.flushAndWait() }
        let center = ShareIntakeCenter(inbox: inbox, staging: FakeShareAttachmentStaging())
        let outcome = await center.apply(envelope, to: vm)
        guard case .failed(let failedID, _) = outcome else {
            Issue.record("A failed real draft write must not acknowledge the envelope")
            return
        }
        #expect(failedID == envelope.id)
        #expect(vm.draft == "Existing")
        #expect(vm.shareIntakeAppliedClaimToken(envelopeID: envelope.id) == nil)
        #expect(try inbox.pending().map(\.id) == [envelope.id])
    }
}
#endif

// MARK: - Durable destination actions (card forwarding)

@MainActor
private final class FakeDestinationImportHandler: ShareEnvelopeDestinationImporting {
    var notesResult: ShareNotesImportResult = .unavailable
    var canvasResult: ShareNotesImportResult = .unavailable
    var notesCalls: [UUID] = []
    var canvasCalls: [(UUID, CanvasDestinationTarget)] = []
    var targets: [CanvasImportTarget] = []

    func importEnvelopeToNotes(_ envelope: ShareEnvelope) async -> ShareNotesImportResult {
        notesCalls.append(envelope.id)
        return notesResult
    }

    func importEnvelopeToCanvas(
        _ envelope: ShareEnvelope,
        target: CanvasDestinationTarget
    ) async -> ShareNotesImportResult {
        canvasCalls.append((envelope.id, target))
        return canvasResult
    }

    func canvasImportTargets() -> [CanvasImportTarget] { targets }
}

@Suite("FloeApp.ShareIntakeDestinationActions")
@MainActor
struct ShareIntakeDestinationActionTests {

    @Test("Card Notes/Canvas actions forward to the handler and publish this envelope's result")
    func forwardingAndStatus() async throws {
        let root = makeInboxRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = ShareInbox(rootURL: root)
        let envelope = try inbox.stage(inputs: [ShareInboxInput(kind: .text, payload: .text("x"))])
        let handler = FakeDestinationImportHandler()
        handler.notesResult = .imported(envelopeID: envelope.id, documentCount: 2)
        let canvasID = UUID()
        handler.canvasResult = .settled(envelopeID: envelope.id)
        handler.targets = [.init(id: canvasID, name: "Study")]
        let center = ShareIntakeCenter(inbox: inbox, staging: FakeShareAttachmentStaging())
        center.configureDestinationHandler(handler)

        let notes = await center.importEnvelopeToNotes(envelope)
        #expect(notes == .imported(envelopeID: envelope.id, documentCount: 2))
        #expect(center.lastDestinationOutcome
                == ShareDestinationOutcome(destination: .notes, result: handler.notesResult))

        let canvas = await center.importEnvelopeToCanvas(envelope, target: .existing(canvasID: canvasID))
        #expect(canvas == .settled(envelopeID: envelope.id))
        #expect(handler.canvasCalls.first?.1 == .existing(canvasID: canvasID))
        #expect(center.lastDestinationOutcome?.destination == .canvas)
        #expect(center.canvasImportTargets() == handler.targets)

        center.clearDestinationOutcome()
        #expect(center.lastDestinationOutcome == nil)

        // A result about an envelope that already left the inbox is cleared
        // by refresh; it must never describe the next share.
        _ = await center.importEnvelopeToNotes(envelope)
        let claim = try inbox.claim(id: envelope.id)
        try inbox.ack(claim)
        await center.refresh()
        #expect(center.lastDestinationOutcome == nil)
    }

    @Test("Without an injected handler the durable action reports unavailable and copies nothing")
    func unavailableWithoutHandler() async throws {
        let root = makeInboxRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = ShareInbox(rootURL: root)
        let envelope = try inbox.stage(inputs: [ShareInboxInput(kind: .text, payload: .text("x"))])
        let center = ShareIntakeCenter(inbox: inbox, staging: FakeShareAttachmentStaging())
        let result = await center.importEnvelopeToNotes(envelope)
        #expect(result == .unavailable)
        #expect(center.lastDestinationOutcome == nil)
        #expect(try inbox.pending().map(\.id) == [envelope.id])
        #expect(center.canvasImportTargets().isEmpty)
    }
}

#endif
