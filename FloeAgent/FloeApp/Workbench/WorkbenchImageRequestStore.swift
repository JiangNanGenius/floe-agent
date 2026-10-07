// FloeApp — Durable image generation request records.
//
// Image generation is a single request/response call with no provider job
// ID, so unlike video jobs it cannot be polled after a process death or a
// dropped connection. To stay truthful we persist the request BEFORE the
// call and classify the outcome afterwards:
//
//   * submitted  — call in flight; on app relaunch a record left in this
//                  state is reclassified to `interrupted` (the provider may
//                  have generated images we never received).
//   * interrupted — the app stopped waiting; never auto-resubmitted.
//   * unknown    — the local call failed after submission in a way that does
//                  not prove the provider rejected it (timeout/network); we
//                  cannot know whether images were produced. Never
//                  auto-resubmitted.
//   * failed     — the provider definitively rejected the request; the
//                  recorded message explains why.
//
// Records are scoped to the project the review was confirmed against, so
// switching projects while the call is in flight never attaches the outcome
// (or the request record) to the wrong project.

import Foundation

@MainActor
final class WorkbenchImageRequestStore {
    enum Status: String, Codable, Sendable {
        case submitted
        case interrupted
        case unknown
        case failed
    }

    struct Record: Identifiable, Codable, Hashable, Sendable {
        var id: UUID
        var projectID: UUID
        var prompt: String
        var modelID: UUID
        var modelName: String
        var detail: String
        var createdAt: Date
        var status: Status
        var message: String?
    }

    private let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    private func fileURL(for projectID: UUID) -> URL {
        directory.appendingPathComponent("\(projectID.uuidString).json", isDirectory: false)
    }

    private func loadRaw(projectID: UUID) -> [Record] {
        let url = fileURL(for: projectID)
        guard let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([Record].self, from: data) else {
            return []
        }
        return records
    }

    /// Reads the persisted records WITHOUT reclassifying an in-flight
    /// request. Used while a request is actually waiting.
    func current(projectID: UUID) -> [Record] {
        loadRaw(projectID: projectID).sorted { $0.createdAt < $1.createdAt }
    }

    /// Loads the requests for a project. A request left `.submitted` means
    /// the app never recorded an outcome; reclassify it to `.interrupted`
    /// and persist the truthful status.
    func load(projectID: UUID) -> [Record] {
        let records = loadRaw(projectID: projectID)
        var changed = false
        let reclassified = records.map { record -> Record in
            guard record.status == .submitted else { return record }
            var copy = record
            copy.status = .interrupted
            changed = true
            return copy
        }
        if changed {
            try? save(projectID: projectID, records: reclassified)
        }
        return reclassified.sorted { $0.createdAt < $1.createdAt }
    }

    func save(projectID: UUID, records: [Record]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(records).write(to: fileURL(for: projectID), options: .atomic)
    }

    /// Adds (or replaces, by id) the record for its project.
    func upsert(_ record: Record) throws {
        var records = loadRaw(projectID: record.projectID)
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        try save(projectID: record.projectID, records: records)
    }

    func remove(projectID: UUID, recordID: UUID) {
        var records = loadRaw(projectID: projectID)
        records.removeAll { $0.id == recordID }
        try? save(projectID: projectID, records: records)
    }
}
