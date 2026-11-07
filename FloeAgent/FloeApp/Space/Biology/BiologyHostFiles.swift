// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore
import FloeBiologyCore
import FloeBiologyEngine

/// Uses the component's verified streaming/opaque-file implementation, with
/// grants resolved from the actual App original and durable execution owner.
/// Environment namespaces are identities, never user-authored filesystem paths.
actor BiologyHostFiles: BiologyFileAccessing {
    nonisolated let root: URL
    private let access: BiologyHostAccess
    private var stores: [String: BiologyWorkspaceFiles] = [:]
    private var nativeExports: [UUID: BiologyWorkspaceFiles] = [:]
    init(root: URL, access: BiologyHostAccess) {
        self.root = root.standardizedFileURL
        self.access = access
    }
    private func store(_ environmentID: String) throws -> BiologyWorkspaceFiles {
        if let value = stores[environmentID] { return value }
        let key = FloeDigest.sha256Hex(Data(environmentID.utf8))
        let value = try BiologyWorkspaceFiles(root: root.appendingPathComponent(key, isDirectory: true),
            environmentID: environmentID, authorize: { [access] context, writing in
                _ = try await access.location(context.projectID)
                // Native reads/shares of an explicitly selected reference do
                // not grant Linux execution or adopt another task's owner.
                if context.owner != nil {
                    guard try await access.fileEnvironment(context, writing: writing) == environmentID else { throw BiologyHostError.changed }
                }
            })
        stores[environmentID] = value
        return value
    }
    private func owned(_ reference: BiologyFileReference, _ context: BiologyFileContext) async throws -> BiologyWorkspaceFiles {
        guard reference.projectID == context.projectID else { throw BiologyHostError.readOnly }
        _ = try await access.location(context.projectID)
        if context.owner != nil {
            guard try await access.fileEnvironment(context, writing: false) == reference.environmentID else { throw BiologyHostError.changed }
        }
        return try store(reference.environmentID)
    }
    func register(trustedSourceURL: URL, fileName: String, context: BiologyFileContext) async throws -> BiologyFileReference {
        let environment = try await access.fileEnvironment(context, writing: true)
        return try await store(environment).register(trustedSourceURL: trustedSourceURL, fileName: fileName, context: context)
    }
    func resolve(_ fileID: UUID, context: BiologyFileContext) async throws -> BiologyFileReference {
        let environment = try await access.fileEnvironment(context, writing: false)
        return try await store(environment).resolve(fileID, context: context)
    }
    func read(_ reference: BiologyFileReference, offset: UInt64, length: Int, context: BiologyFileContext) async throws -> Data {
        try await owned(reference, context).read(reference, offset: offset, length: length, context: context)
    }
    func export(_ data: Data, fileName: String, context: BiologyFileContext) async throws -> BiologyExportReceipt {
        let environment = try await access.fileEnvironment(context, writing: true)
        return try await store(environment).export(data, fileName: fileName, context: context)
    }
    func export(_ reference: BiologyFileReference, fileName: String, context: BiologyFileContext) async throws -> BiologyExportReceipt {
        try await owned(reference, context).export(reference, fileName: fileName, context: context)
    }
    func prepareNativeExport(_ reference: BiologyFileReference, context: BiologyFileContext) async throws -> BiologyNativeFileExport {
        let store = try await owned(reference, context)
        let result = try await store.prepareNativeExport(reference, context: context)
        nativeExports[result.id] = store
        return result
    }
    func finishNativeExport(_ export: BiologyNativeFileExport) async {
        guard let store = nativeExports.removeValue(forKey: export.id) else { return }
        await store.finishNativeExport(export)
    }
    /// Explicit native reauthorization. It returns a NEW opaque handle for
    /// the selected task/environment and never silently rewrites an asset or
    /// turns an exported project JSON into a portable original-file archive.
    func reauthorize(_ original: BiologyFileReference, to context: BiologyFileContext) async throws -> BiologyFileReference {
        guard original.projectID == context.projectID, context.owner != nil else { throw BiologyHostError.changed }
        let environment = try await access.fileEnvironment(context, writing: true)
        let native = BiologyFileContext(projectID: context.projectID, owner: nil)
        let prepared = try await prepareNativeExport(original, context: native)
        do {
            let result = try await store(environment).register(trustedSourceURL: prepared.url,
                fileName: original.fileName, context: context)
            guard result.sha256 == original.sha256, result.byteCount == original.byteCount else { throw BiologyHostError.changed }
            await finishNativeExport(prepared)
            return result
        } catch { await finishNativeExport(prepared); throw error }
    }
}
#endif
