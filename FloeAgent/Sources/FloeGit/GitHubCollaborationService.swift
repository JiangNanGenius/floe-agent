// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore

public struct GitHubMutationRecord: Codable, Sendable, Equatable, Identifiable {
    public enum State: String, Codable, Sendable { case prepared, sending, acknowledged, rejected, unknown }
    public var id: UUID { request.id }
    public let request: GitHubPreparedMutation
    public let requestSHA256: String
    public let preparedAt: Date
    public var updatedAt: Date
    public var state: State
    public var authenticatedActor: String?
    public var result: GitHubMutationResult?
    public var rejectionStatus: Int?
}

/// Task-owned durable delivery, separate from views. A persisted `sending`
/// request becomes uncertain after interruption, never an automatic retry.
/// The URL is app-owned support storage, not a model-supplied workspace path.
public actor GitHubCollaborationService {
    private let client: GitHubCollaborationClient
    private let journalURL: URL
    private var records: [UUID: GitHubMutationRecord]
    private var admitted = Set<UUID>()
    public init(client: GitHubCollaborationClient, journalURL: URL) throws {
        self.client = client; self.journalURL = journalURL
        if FileManager.default.fileExists(atPath: journalURL.path) {
            let info = try journalURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? .max) <= 16_777_216 else { throw GitHubCollaborationError.invalidInput("journal") }
            let values = try JSONDecoder().decode([GitHubMutationRecord].self, from: Data(contentsOf: journalURL))
            guard values.count <= 2000, Set(values.map(\.id)).count == values.count,
                  values.allSatisfy({ $0.requestSHA256 == $0.request.requestSHA256 }) else { throw GitHubCollaborationError.operationMismatch }
            records = Dictionary(uniqueKeysWithValues: values.map { value in
                var record = value
                if record.state == .sending { record.state = .unknown }
                return (record.id, record)
            })
        } else { records = [:] }
    }
    public func recent(ownerTaskID: UUID) -> [GitHubMutationRecord] {
        records.values.filter { $0.request.ownerTaskID == ownerTaskID }.sorted { $0.updatedAt > $1.updatedAt }
    }
    @discardableResult public func prepare(_ request: GitHubPreparedMutation, ownerTaskID: UUID) throws -> GitHubMutationRecord {
        guard request.ownerTaskID == ownerTaskID else { throw GitHubCollaborationError.operationMismatch }
        try request.validateContract()
        if let prior = records[request.id] {
            guard prior.request == request, prior.requestSHA256 == request.requestSHA256 else { throw GitHubCollaborationError.operationMismatch }
            return prior
        }
        guard records.count < 2000 else { throw GitHubCollaborationError.invalidInput("journal full") }
        let now = Date()
        let record = GitHubMutationRecord(request: request, requestSHA256: request.requestSHA256, preparedAt: now, updatedAt: now, state: .prepared)
        try save(record); return record
    }
    public func execute(id: UUID, ownerTaskID: UUID, token: String, authorize: @Sendable () throws -> Void = {}) async throws -> GitHubMutationResult {
        var record = try owned(id, ownerTaskID: ownerTaskID)
        if let result = record.result, record.state == .acknowledged { return result }
        if record.state == .rejected { throw GitHubCollaborationError.rejected(record.rejectionStatus ?? 400) }
        guard record.state == .prepared, !admitted.contains(id) else { throw GitHubCollaborationError.outcomeUnknown(id) }
        // Admission is before the first await. A second tap/model retry cannot
        // pass the same prepared state while preflight awaits GitHub.
        admitted.insert(id); defer { admitted.remove(id) }
        guard !token.isEmpty else { throw GitHubCollaborationError.authenticationRequired }
        try authorize()
        let actor = try await client.authenticatedActor(token: token)
        try await client.validateBeforeSend(record.request, token: token)
        try authorize()
        try Task.checkCancellation()
        record.authenticatedActor = actor; record.state = .sending; record.updatedAt = Date()
        try save(record)
        do {
            let result = try await client.send(record.request, token: token)
            record.result = result; record.updatedAt = Date()
            try save(record)
            try await client.confirm(record.request, result: result, actor: actor, token: token)
            record.result = result; record.state = .acknowledged; record.updatedAt = Date()
            do { try save(record) } catch { throw GitHubCollaborationError.outcomeUnknown(id) }
            return result
        } catch GitHubCollaborationError.rejected(let status) {
            record.state = .rejected; record.rejectionStatus = status; record.updatedAt = Date()
            try save(record); throw GitHubCollaborationError.rejected(status)
        } catch {
            // This includes cancellation after `.sending`, response decoding,
            // 5xx, redirects and a local failure recording an acknowledged send.
            record.state = .unknown; record.updatedAt = Date()
            try save(record); throw GitHubCollaborationError.outcomeUnknown(id)
        }
    }
    public func reconcile(id: UUID, ownerTaskID: UUID, token: String) async throws -> GitHubMutationRecord {
        var record = try owned(id, ownerTaskID: ownerTaskID)
        guard !admitted.contains(id) else { throw GitHubCollaborationError.outcomeUnknown(id) }
        guard record.state == .unknown || record.state == .sending else { return record }
        admitted.insert(id); defer { admitted.remove(id) }
        let actor = try await client.authenticatedActor(token: token)
        guard actor.caseInsensitiveCompare(record.authenticatedActor ?? "") == .orderedSame else { throw GitHubCollaborationError.operationMismatch }
        if let result = try await client.reconcile(record.request, actor: actor, token: token) {
            record.result = result; record.state = .acknowledged; record.updatedAt = Date(); try save(record)
        }
        // Not found within a bounded page range means still uncertain. It is
        // neither proof of failure nor permission to repeat the mutation.
        return record
    }
    private func owned(_ id: UUID, ownerTaskID: UUID) throws -> GitHubMutationRecord {
        guard let value = records[id], value.request.ownerTaskID == ownerTaskID,
              value.requestSHA256 == value.request.requestSHA256 else { throw GitHubCollaborationError.operationMismatch }
        try value.request.validateContract(); return value
    }
    private func save(_ record: GitHubMutationRecord) throws {
        var updated = records; updated[record.id] = record
        let values = updated.values.sorted { $0.id.uuidString < $1.id.uuidString }
        let bytes = try JSONEncoder().encode(values)
        guard bytes.count <= 16_777_216 else { throw GitHubCollaborationError.invalidInput("journal size") }
        let parent = journalURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: journalURL.path) {
            let info = try journalURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true else { throw GitHubCollaborationError.invalidInput("journal") }
        }
        try bytes.write(to: journalURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        records = updated
    }
}
