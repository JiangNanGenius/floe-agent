// FloeAppTests — T6 returned-result publication port (production behavior).
//
// These tests drive the REAL `AppDesignResultPublicationPort` against the
// preview environment (in-memory database + the existing ConversationStore /
// CreativeAssetStore). They cover the recoverability and cross-task
// guarantees that a receipt fastpath alone cannot provide:
//   * interrupted staged write / attachment-only / message-part repair;
//   * corrupt existing bytes are re-verified and repaired at the SAME
//     deterministic identity;
//   * the same operation + digest for a DIFFERENT task or creative target can
//     never alias another owner's attachment/receipt;
//   * duplicate callbacks return the same receipt and never duplicate rows.
//
// They execute in the FloeApp unit-test bundle (full App target, T7). Static
// checks in this lane are NOT runtime evidence.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeModels
import FloePersistence
@testable import FloeApp

@Suite("T6 publication port recovery and cross-owner isolation")
@MainActor
struct T6PublicationPortTests {

    private func makeConversation(_ environment: AppEnvironment) async throws -> UUID {
        try await environment.database.migrate()
        let conversationID = UUID()
        try await environment.conversationStore.saveConversation(ConversationRecord(
            id: conversationID, title: "publication \(conversationID.uuidString.prefix(8))",
            createdAt: Date(), updatedAt: Date()))
        return conversationID
    }

    private func chatPublication(
        conversationID: UUID,
        operationID: String = "op-1",
        revisionID: String = "revision-1",
        bytes: Data
    ) -> DesignResultPublication {
        let target = DesignOwnerTargets.chatAttachment(
            conversationID: conversationID, messageID: UUID(), attachmentID: UUID())
        return DesignResultPublication(
            target: target,
            targetStableKey: target.stableKey,
            operationID: operationID,
            candidateID: "candidate-1",
            mode: .updateOriginal,
            artifactID: "artifact-1",
            revisionID: revisionID,
            payloadRelativePath: "DesignRevisions/owners/x/revision-1",
            contentSHA256: FloeDigest.sha256Hex(bytes),
            format: "md",
            displayName: "adopted-result.md",
            originConversationID: conversationID.uuidString,
            ownerRevision: 1,
            bytes: bytes)
    }

    // MARK: - Duplicate callback / full replay

    @Test("A duplicate publication returns the same receipt and never duplicates rows")
    func duplicatePublicationIsIdempotent() async throws {
        let environment = AppEnvironment.preview()
        let conversationID = try await makeConversation(environment)
        let bytes = Data("# adopted\nfirst result".utf8)
        let publication = chatPublication(conversationID: conversationID, bytes: bytes)
        let port = environment.designResultPublicationPort

        let first = try await port.publish(publication)
        let second = try await port.publish(publication)
        let third = try await port.publish(publication)

        #expect(first == second)
        #expect(second == third)
        #expect(first.destination == "chat:\(conversationID.uuidString)")

        let attachments = try await environment.conversationStore.attachments(
            conversationID: conversationID)
        #expect(attachments.count == 1)
        #expect(attachments.first?.id.uuidString == first.identifier)
        #expect(attachments.first?.sha256 == FloeDigest.sha256Hex(bytes))

        let messages = try await environment.conversationStore.messages(
            conversationID: conversationID)
        #expect(messages.count == 1)
        #expect(messages.first?.parts.contains { $0.attachmentID?.uuidString == first.identifier } == true)

        // Real file readback: the staged bytes are exactly the verified payload.
        let bindingKey = try AppDesignResultPublicationPort.chatBindingKey(for: publication)
        let attachmentID = AppDesignResultPublicationPort.chatAttachmentID(bindingKey: bindingKey)
        let relative = "\(attachmentID.uuidString)-adopted-result.md"
        let staged = try AppDesignResultPublicationPort.attachmentStagingDirectory()
            .appendingPathComponent(relative)
        #expect(try AppDesignResultPublicationPort.verifiedFileDigest(
            of: staged, expectedByteCount: bytes.count) == FloeDigest.sha256Hex(bytes))
        try? FileManager.default.removeItem(at: staged)
    }

    // MARK: - Returned attachment rendering (data path)

    @Test("A returned result maps to the correct reusable attachment chip and timeline row")
    func returnedResultMapsToAttachmentChip() async throws {
        let environment = AppEnvironment.preview()
        let conversationID = try await makeConversation(environment)
        let imageBytes = Data([0x89, 0x50, 0x4E, 0x47] + [UInt8](repeating: 0x0A, count: 64))
        let target = DesignOwnerTargets.chatAttachment(
            conversationID: conversationID, messageID: UUID(), attachmentID: UUID())
        let publication = DesignResultPublication(
            target: target,
            targetStableKey: target.stableKey,
            operationID: "op-image",
            candidateID: "candidate-image",
            mode: .updateOriginal,
            artifactID: "artifact-image",
            revisionID: "revision-image",
            payloadRelativePath: "DesignRevisions/owners/x/revision-image",
            contentSHA256: FloeDigest.sha256Hex(imageBytes),
            format: "png",
            displayName: "result.png",
            originConversationID: conversationID.uuidString,
            ownerRevision: 1,
            bytes: imageBytes)
        let receipt = try await environment.designResultPublicationPort.publish(publication)

        let messages = try await environment.conversationStore.messages(
            conversationID: conversationID)
        let message = try #require(messages.first)
        #expect(message.role == "assistant")
        #expect(message.parts.first?.kind == .image)
        let chips = AttachmentChipItem.items(in: message.parts)
        #expect(chips.count == 1)
        #expect(chips.first?.kind == .image)
        #expect(chips.first?.name == "result.png")
        #expect(chips.first?.systemImage == "photo")
        #expect(chips.first?.id == receipt.identifier)

        // The unified timeline projects the same durable notice; the thread
        // row resolves it back to the persisted message (no second path).
        let timeline = ThreadTimelineBuilder.buildConversation(
            messages: messages, runs: [], eventsByRun: [:],
            liveRunID: nil, isRunning: false,
            liveStreamedText: "", liveReasoningText: "", pendingApprovals: [])
        let assistantIDs = timeline.compactMap { item -> String? in
            if case .assistantMessage(_, let idSuffix) = item { return idSuffix }
            return nil
        }
        #expect(assistantIDs.contains(message.id.uuidString))
        let resolved = UUID(uuidString: assistantIDs.first(where: {
            $0 == message.id.uuidString
        }) ?? "").flatMap { id in messages.first { $0.id == id } }
        #expect(AttachmentChipItem.items(in: resolved?.parts ?? []).count == 1)

        let bindingKey = try AppDesignResultPublicationPort.chatBindingKey(for: publication)
        let attachmentID = AppDesignResultPublicationPort.chatAttachmentID(bindingKey: bindingKey)
        let staged = try AppDesignResultPublicationPort.attachmentStagingDirectory()
            .appendingPathComponent("\(attachmentID.uuidString)-result.png")
        try? FileManager.default.removeItem(at: staged)
    }

    // MARK: - Crash windows

    @Test("An attachment written before its message is repaired into a durable notice")
    func attachmentOnlyCrashIsRepaired() async throws {
        let environment = AppEnvironment.preview()
        let conversationID = try await makeConversation(environment)
        let bytes = Data("attachment-only crash".utf8)
        let publication = chatPublication(conversationID: conversationID, bytes: bytes)
        let digest = FloeDigest.sha256Hex(bytes)
        let bindingKey = try AppDesignResultPublicationPort.chatBindingKey(for: publication)
        let attachmentID = AppDesignResultPublicationPort.chatAttachmentID(bindingKey: bindingKey)
        let messageID = AppDesignResultPublicationPort.chatMessageID(bindingKey: bindingKey)

        // Simulate the crash window: staged bytes + attachment row exist, the
        // durable transcript notice does not.
        let staged = try AppDesignResultPublicationPort.attachmentStagingDirectory()
            .appendingPathComponent("\(attachmentID.uuidString)-adopted-result.md")
        try AppDesignResultPublicationPort.ensureStagedBytes(bytes, at: staged, digest: digest)
        try await environment.conversationStore.saveAttachment(AttachmentRef(
            id: attachmentID, conversationID: conversationID, messageID: nil,
            kind: .document, displayName: "adopted-result.md",
            uti: "public.data", byteCount: bytes.count, sha256: digest,
            storage: .applicationSupport, relativePath: "\(attachmentID.uuidString)-adopted-result.md"))

        let receipt = try await environment.designResultPublicationPort.publish(publication)
        #expect(receipt.identifier == attachmentID.uuidString)

        let messages = try await environment.conversationStore.messages(
            conversationID: conversationID)
        #expect(messages.count == 1)
        #expect(messages.first?.id == messageID)
        #expect(messages.first?.role == "assistant")
        #expect(messages.first?.parts.first?.attachmentID == attachmentID)
        try? FileManager.default.removeItem(at: staged)
    }

    @Test("A persisted notice missing its attachment part is repaired on replay")
    func messageWithoutPartIsRepaired() async throws {
        let environment = AppEnvironment.preview()
        let conversationID = try await makeConversation(environment)
        let bytes = Data("message without part".utf8)
        let publication = chatPublication(conversationID: conversationID, bytes: bytes)
        let digest = FloeDigest.sha256Hex(bytes)
        let bindingKey = try AppDesignResultPublicationPort.chatBindingKey(for: publication)
        let attachmentID = AppDesignResultPublicationPort.chatAttachmentID(bindingKey: bindingKey)
        let messageID = AppDesignResultPublicationPort.chatMessageID(bindingKey: bindingKey)

        let relativePath = "\(attachmentID.uuidString)-adopted-result.md"
        let staged = try AppDesignResultPublicationPort.attachmentStagingDirectory()
            .appendingPathComponent(relativePath)
        try AppDesignResultPublicationPort.ensureStagedBytes(bytes, at: staged, digest: digest)
        try await environment.conversationStore.saveAttachment(AttachmentRef(
            id: attachmentID, conversationID: conversationID, messageID: nil,
            kind: .document, displayName: "adopted-result.md",
            uti: "public.data", byteCount: bytes.count, sha256: digest,
            storage: .applicationSupport, relativePath: relativePath))
        // Message row exists but carries no attachment part.
        try await environment.conversationStore.appendMessage(PersistedMessage(
            id: messageID, conversationID: conversationID, role: "assistant",
            content: "damaged notice", createdAt: Date(), parts: []))

        let receipt = try await environment.designResultPublicationPort.publish(publication)
        #expect(receipt.identifier == attachmentID.uuidString)
        let messages = try await environment.conversationStore.messages(
            conversationID: conversationID)
        #expect(messages.filter { $0.id == messageID }.count == 1)
        let repaired = messages.first { $0.id == messageID }
        #expect(repaired?.parts.contains { $0.attachmentID == attachmentID } == true)
        #expect(repaired?.parts.first?.metadata["design.publicationKey"] != nil)
        try? FileManager.default.removeItem(at: staged)
    }

    @Test("Corrupt staged bytes are repaired through the same deterministic identity")
    func corruptStagedBytesAreRepaired() async throws {
        let environment = AppEnvironment.preview()
        let conversationID = try await makeConversation(environment)
        let bytes = Data("corruption repair payload".utf8)
        let publication = chatPublication(conversationID: conversationID, bytes: bytes)
        let port = environment.designResultPublicationPort
        let first = try await port.publish(publication)

        let bindingKey = try AppDesignResultPublicationPort.chatBindingKey(for: publication)
        let attachmentID = AppDesignResultPublicationPort.chatAttachmentID(bindingKey: bindingKey)
        let staged = try AppDesignResultPublicationPort.attachmentStagingDirectory()
            .appendingPathComponent("\(attachmentID.uuidString)-adopted-result.md")
        try Data("corrupted".utf8).write(to: staged, options: [.atomic])

        let second = try await port.publish(publication)
        #expect(first == second)
        #expect(try AppDesignResultPublicationPort.verifiedFileDigest(
            of: staged, expectedByteCount: bytes.count) == FloeDigest.sha256Hex(bytes))
        let messages = try await environment.conversationStore.messages(
            conversationID: conversationID)
        #expect(messages.count == 1)
        try? FileManager.default.removeItem(at: staged)
    }

    // MARK: - Cross-owner isolation

    @Test("The same operation and digest for a different task never aliases an attachment")
    func sameOperationDifferentTasksStayIsolated() async throws {
        let environment = AppEnvironment.preview()
        let firstTask = try await makeConversation(environment)
        let secondTask = try await makeConversation(environment)
        let bytes = Data("shared payload across owners".utf8)
        let first = chatPublication(conversationID: firstTask, bytes: bytes)
        let second = chatPublication(conversationID: secondTask, bytes: bytes)

        // The model-influenced operation identity is identical for both; only
        // the frozen target differs.
        #expect(first.operationID == second.operationID)
        #expect(first.contentSHA256 == second.contentSHA256)

        let port = environment.designResultPublicationPort
        let firstReceipt = try await port.publish(first)
        let secondReceipt = try await port.publish(second)

        #expect(firstReceipt.identifier != secondReceipt.identifier)
        #expect(firstReceipt.destination == "chat:\(firstTask.uuidString)")
        #expect(secondReceipt.destination == "chat:\(secondTask.uuidString)")

        let firstAttachments = try await environment.conversationStore.attachments(
            conversationID: firstTask)
        let secondAttachments = try await environment.conversationStore.attachments(
            conversationID: secondTask)
        #expect(firstAttachments.map(\.id.uuidString) == [firstReceipt.identifier])
        #expect(secondAttachments.map(\.id.uuidString) == [secondReceipt.identifier])

        // Cleanup deterministic staging files.
        for publication in [first, second] {
            let key = try AppDesignResultPublicationPort.chatBindingKey(for: publication)
            let id = AppDesignResultPublicationPort.chatAttachmentID(bindingKey: key)
            let staged = try AppDesignResultPublicationPort.attachmentStagingDirectory()
                .appendingPathComponent("\(id.uuidString)-adopted-result.md")
            try? FileManager.default.removeItem(at: staged)
        }
    }

    @Test("A publication whose frozen target does not match its live owner is rejected")
    func frozenTargetMismatchIsRejected() async throws {
        let environment = AppEnvironment.preview()
        let conversationID = try await makeConversation(environment)
        let bytes = Data("mismatched frozen target".utf8)
        let target = DesignOwnerTargets.chatAttachment(
            conversationID: conversationID, messageID: UUID(), attachmentID: UUID())
        let publication = DesignResultPublication(
            target: target,
            targetStableKey: "foreign-target-key",
            operationID: "op-mismatch",
            candidateID: "candidate-1",
            mode: .updateOriginal,
            artifactID: "artifact-1",
            revisionID: "revision-1",
            payloadRelativePath: "DesignRevisions/owners/x/revision-1",
            contentSHA256: FloeDigest.sha256Hex(bytes),
            format: "md",
            displayName: "adopted-result.md",
            originConversationID: conversationID.uuidString,
            ownerRevision: 1,
            bytes: bytes)
        await #expect(throws: (any Error).self) {
            _ = try await environment.designResultPublicationPort.publish(publication)
        }
        let attachments = try await environment.conversationStore.attachments(
            conversationID: conversationID)
        #expect(attachments.isEmpty)
    }

    // MARK: - Creative library

    @Test("Creative publication is content-addressed, replay-safe and repaired")
    func creativePublicationIsReplaySafe() async throws {
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        let bytes = Data("creative adopted payload".utf8)
        let digest = FloeDigest.sha256Hex(bytes)
        func publication(requestID: UUID) -> DesignResultPublication {
            let target = DesignOwnerTargets.creative(requestID: requestID, kind: .notes)
            return DesignResultPublication(
                target: target,
                targetStableKey: target.stableKey,
                operationID: "op-creative",
                candidateID: "candidate-2",
                mode: .updateOriginal,
                artifactID: "artifact-2",
                revisionID: "revision-2",
                payloadRelativePath: "DesignRevisions/owners/y/revision-2",
                contentSHA256: digest,
                format: "md",
                displayName: "adopted-notes.md",
                originConversationID: nil,
                ownerRevision: 1,
                bytes: bytes)
        }
        let firstPublication = publication(requestID: UUID())
        let secondPublication = publication(requestID: UUID())
        let port = environment.designResultPublicationPort

        let first = try await port.publish(firstPublication)
        let replay = try await port.publish(firstPublication)
        #expect(first == replay)
        #expect(first.destination.hasPrefix("creative:"))

        // Same bytes for a DIFFERENT creative target: it publishes through its
        // OWN target binding key, while the content-addressed library shares
        // the one canonical row (the visible destination names the library
        // surface both requests publish into).
        let second = try await port.publish(secondPublication)
        #expect(second.destination == "creative:\(secondPublication.target.ownerID)")
        #expect(first.destination == second.destination)
        #expect(first.contentSHA256 == second.contentSHA256)

        guard let assetID = UUID(uuidString: first.identifier),
              let asset = try await environment.creativeAssetStore.asset(id: assetID) else {
            Issue.record("creative receipt does not resolve to an asset row"); return
        }
        #expect(asset.contentHash == digest)
        guard let relative = asset.localRelativePath else {
            Issue.record("creative asset has no local bytes"); return
        }
        let url = try AppDesignResultPublicationPort.artifactRoot()
            .appendingPathComponent(relative)
        #expect(try AppDesignResultPublicationPort.verifiedFileDigest(
            of: url, expectedByteCount: bytes.count) == digest)

        // Corrupt the canonical bytes; the replay repairs them at the same id.
        try Data("corrupt".utf8).write(to: url, options: [.atomic])
        let repaired = try await port.publish(firstPublication)
        #expect(repaired == first)
        #expect(try AppDesignResultPublicationPort.verifiedFileDigest(
            of: url, expectedByteCount: bytes.count) == digest)

        let all = try await environment.creativeAssetStore.allAssets()
        #expect(all.filter { $0.contentHash == digest }.count == 1)
        try? FileManager.default.removeItem(at: url)
    }
}
#endif
