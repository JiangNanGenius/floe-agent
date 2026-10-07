// FloeApp — Durable AI candidate records.
//
// Image generation results are delivered as files; without a durable record
// they vanish when the workbench closes. This store keeps one JSON file per
// project (inside Application Support, next to the projects themselves) so a
// delivered candidate survives reopening the project or relaunching the app.
// Records whose file no longer exists are dropped on load — recovery never
// invents a candidate that cannot be imported.

import Foundation
import FloeWorkbench

actor WorkbenchCandidateStore {
    private struct Record: Codable {
        var id: UUID
        var path: String
        var kind: MediaAssetKind
        var modelName: String
        var parametersSummary: String
        var createdAt: Date
    }

    private let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    private func fileURL(for projectID: UUID) -> URL {
        directory.appendingPathComponent("\(projectID.uuidString).json", isDirectory: false)
    }

    func save(projectID: UUID, candidates: [WorkbenchCenter.Candidate]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let records = candidates.map { candidate in
            Record(id: candidate.id, path: candidate.url.path, kind: candidate.kind,
                   modelName: candidate.modelName,
                   parametersSummary: candidate.parametersSummary,
                   createdAt: candidate.createdAt)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(records).write(to: fileURL(for: projectID), options: .atomic)
    }

    /// Loads candidates whose backing file still exists; stale records are
    /// removed from disk instead of being reported.
    func load(projectID: UUID) -> [WorkbenchCenter.Candidate] {
        let url = fileURL(for: projectID)
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        guard let records = try? decoder.decode([Record].self, from: data) else { return [] }
        var candidates: [WorkbenchCenter.Candidate] = []
        for record in records {
            let fileURL = URL(fileURLWithPath: record.path)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }
            candidates.append(WorkbenchCenter.Candidate(id: record.id, url: fileURL,
                                                        kind: record.kind,
                                                        modelName: record.modelName,
                                                        parametersSummary: record.parametersSummary,
                                                        createdAt: record.createdAt))
        }
        if candidates.count != records.count {
            try? save(projectID: projectID, candidates: candidates)
        }
        return candidates
    }

    /// Appends delivered candidates without the existence-pruning that
    /// `load` performs: a just-delivered remote file must be recorded even
    /// if its backing file is momentarily unavailable, so the outcome of a
    /// completed generation is never lost.
    func append(projectID: UUID, candidates: [WorkbenchCenter.Candidate]) throws {
        var records = loadRaw(projectID: projectID)
        records.append(contentsOf: candidates)
        try save(projectID: projectID, candidates: records)
    }

    private func loadRaw(projectID: UUID) -> [WorkbenchCenter.Candidate] {
        let url = fileURL(for: projectID)
        guard let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([Record].self, from: data) else {
            return []
        }
        return records.map { record in
            WorkbenchCenter.Candidate(id: record.id, url: URL(fileURLWithPath: record.path),
                                      kind: record.kind, modelName: record.modelName,
                                      parametersSummary: record.parametersSummary,
                                      createdAt: record.createdAt)
        }
    }

    func removeAll(projectID: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: projectID))
    }
}
