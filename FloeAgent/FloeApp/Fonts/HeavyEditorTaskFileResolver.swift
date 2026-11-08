// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import UniformTypeIdentifiers
import FloeCore
import FloeModels
import FloePersistence
import FloeTools
import FloeHeavyEditorSupport

/// Resolves only indexed originals belonging to the actual saved task. Native
/// file services select every URL; the quoted opaque ID never grants access.
/// Domain hosts retain their own project/type/operation checks in validate.
@MainActor enum HeavyEditorTaskFileResolver {
    static func resolve(_ fileID: String, context: ToolContext, environment: AppEnvironment,
                        allowedExtensions: Set<String>, maximumBytes: Int = 128 * 1024 * 1024,
                        validate: @escaping @MainActor @Sendable () async throws -> Void) async throws -> HeavyEditorArtifact {
        guard (1...128 * 1024 * 1024).contains(maximumBytes), fileID.utf8.count <= 512 else { throw HeavyEditorError.invalidCommand }
        try await validate()
        let conversationID = try await environment.studioCoordinator.savedConversation(context), token = context.cancellation
        let components = fileID.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let original: PersonalPreviewFile, name: String, digest: String, count: Int
        var securityURL: URL?
        defer { securityURL?.stopAccessingSecurityScopedResource() }
        if components.count == 2, components[0] == "attachment", let id = UUID(uuidString: components[1]) {
            guard let reference = try await environment.conversationStore.attachment(id: id), reference.conversationID == conversationID,
                  (1...maximumBytes).contains(reference.byteCount), RunOutputFile.isValidSHA256Hex(reference.sha256) else { throw HeavyEditorError.wrongDocument }
            let url = try environment.filesCenter.resolveURL(for: reference)
            if url.startAccessingSecurityScopedResource() { securityURL = url }
            original = try PersonalPreviewFile(root: url.deletingLastPathComponent(), url: url, maximumBytes: maximumBytes)
            name = reference.displayName; digest = reference.sha256; count = reference.byteCount
            let data = try await personalPreviewOffMain { try original.data(expectedSHA256: digest) { try token.throwIfCancelled(); try Task.checkCancellation() } }
            try await validate()
            guard try await environment.conversationStore.attachment(id: id) == reference, data.count == count else { throw PersonalContentError.changedDocument }
            return try artifact(name: name, data: data, allowedExtensions: allowedExtensions)
        } else if components.count == 3, components[0] == "output", let runID = UUID(uuidString: components[1]), RunOutputFile.isValidSHA256Hex(components[2]) {
            let rows = try await SQLiteRunOutputReader(database: environment.database).manifestRows(runID: runID, expectedConversationID: conversationID)
            let receipts = rows.flatMap(\.receipts).filter { $0.outputID == components[2] }
            guard let receipt = receipts.first, receipts.allSatisfy({ $0 == receipt }), receipt.taskID == conversationID,
                  receipt.byteCount <= maximumBytes,
                  case .verified(let url) = RunOutputSnapshotStore.verify(receipt) else { throw HeavyEditorError.wrongDocument }
            original = try PersonalPreviewFile(root: url.deletingLastPathComponent(), url: url, maximumBytes: maximumBytes)
            name = receipt.displayName; digest = receipt.sha256; count = receipt.byteCount
            let data = try await personalPreviewOffMain { try original.data(expectedSHA256: digest) { try token.throwIfCancelled(); try Task.checkCancellation() } }
            try await validate()
            guard data.count == count, case .verified = RunOutputSnapshotStore.verify(receipt) else { throw PersonalContentError.changedDocument }
            return try artifact(name: name, data: data, allowedExtensions: allowedExtensions)
        }
        throw HeavyEditorError.invalidCommand
    }
    private static func artifact(name: String, data: Data, allowedExtensions: Set<String>) throws -> HeavyEditorArtifact {
        guard allowedExtensions.contains((name as NSString).pathExtension.lowercased()) else { throw HeavyEditorError.invalidDocument }
        return try .init(name: name, mediaType: UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream", data: data)
    }
    static func inventory(context: ToolContext, environment: AppEnvironment, allowedExtensions: Set<String>,
                          maximumBytes: Int = 128 * 1024 * 1024, validate: @escaping @MainActor @Sendable () async throws -> Void) async throws -> EditorJSON {
        try await validate()
        let id = try await environment.studioCoordinator.savedConversation(context)
        guard (1...128 * 1024 * 1024).contains(maximumBytes) else { throw HeavyEditorError.invalidCommand }
        let attachments = try await environment.conversationStore.attachments(conversationID: id).filter {
            $0.conversationID == id && (1...maximumBytes).contains($0.byteCount) && RunOutputFile.isValidSHA256Hex($0.sha256)
                && $0.displayName.count < 240 && allowedExtensions.contains(($0.displayName as NSString).pathExtension.lowercased())
        }
        var entries: [EditorJSON] = attachments.prefix(128).map { .object(["fileID": .string("attachment:" + $0.id.uuidString), "name": .string($0.displayName), "byteCount": .number(Double($0.byteCount)), "sha256": .string($0.sha256)]) }
        let rows = try await SQLiteRunOutputReader(database: environment.database).manifestRows(runID: context.runID, expectedConversationID: id)
        let outputs = rows.flatMap(\.receipts).filter { $0.byteCount > 0 && $0.byteCount <= maximumBytes && $0.displayName.count < 240 && allowedExtensions.contains(($0.displayName as NSString).pathExtension.lowercased()) }
        var seen = Set<String>()
        for item in outputs where entries.count < 128 && seen.insert(item.outputID).inserted {
            entries.append(.object(["fileID": .string("output:\(item.runID.uuidString):\(item.outputID)"), "name": .string(item.displayName), "byteCount": .number(Double(item.byteCount)), "sha256": .string(item.sha256)]))
        }
        try await validate()
        return .object(["files": .array(entries), "limit": .number(128), "truncated": .bool(attachments.count + Set(outputs.map(\.outputID)).count > entries.count)])
    }
}
#endif
