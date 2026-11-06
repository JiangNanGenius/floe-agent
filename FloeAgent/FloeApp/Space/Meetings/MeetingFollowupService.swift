// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit) && canImport(EventKit)
import Foundation
import Observation
import FloeMeetings

@MainActor @Observable final class MeetingFollowupCenter {
    enum Phase: String, Codable { case preparing, unconfirmed, saved, failed }
    struct Record: Codable {
        let todoID: UUID
        var phase: Phase
        var reminderID: String?
        let createdAt: Date
    }
    private let file: URL
    private(set) var records: [UUID: Record] = [:]
    private(set) var creatingTodoID: UUID?
    var diagnostic: String?
    private var task: Task<Void, Never>?
    var isCreating: Bool { task != nil }

    init(root: URL) throws {
        file = root.appendingPathComponent("followups.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let data = try Data(contentsOf: file)
        guard data.count <= 1_024 * 1_024 else { throw PersonalContentError.invalidProject }
        records = try JSONDecoder().decode([UUID: Record].self, from: data)
        // A durable unconfirmed marker is written BEFORE every EventKit save.
        // A restored preparing item therefore never reached the write boundary.
        for id in Array(records.keys) where records[id]?.phase == .preparing { records[id]?.phase = .failed }
    }
    private func persist(_ value: [UUID: Record]) throws {
        guard value.count <= 4096 else { throw PersonalContentError.invalidProject }
        let data = try JSONEncoder().encode(value)
        guard data.count <= 1_024 * 1_024 else { throw PersonalContentError.invalidProject }
        try data.write(to: file, options: .atomic)
        records = value
    }
    func create(todo: TodoItem, title: String, notes: String, due: Date?) {
        let id = todo.id.rawValue
        guard task == nil, records[id]?.phase != .saved, records[id]?.phase != .unconfirmed else { return }
        diagnostic = nil
        do {
            var next = records
            next[id] = .init(todoID: id, phase: .preparing, createdAt: Date())
            try persist(next)
        } catch { diagnostic = error.localizedDescription; return }
        creatingTodoID = id
        task = Task { [self] in
            defer { task = nil; creatingTodoID = nil }
            do {
                let receipt = try await AppleReminderCreationService.create(.init(title: title, notes: notes, due: due, addAlarm: due != nil)) { [self] in
                    var next = records; next[id]?.phase = .unconfirmed
                    try persist(next)
                }
                var next = records
                next[id]?.phase = .saved; next[id]?.reminderID = receipt.identifier
                try persist(next)
            } catch {
                if records[id]?.phase == .preparing {
                    var next = records; next[id]?.phase = .failed
                    do { try persist(next) } catch { diagnostic = error.localizedDescription }
                }
                if !(error is CancellationError) { diagnostic = error.localizedDescription }
            }
        }
    }
    /// Called only after the user explicitly confirms that no reminder exists.
    func resetUnconfirmed(_ id: UUID) {
        guard task == nil, records[id]?.phase == .unconfirmed else { return }
        var next = records; next.removeValue(forKey: id)
        do { try persist(next); diagnostic = nil } catch { diagnostic = error.localizedDescription }
    }
    func cancelAndWait() async {
        let running = task
        running?.cancel()
        await running?.value
    }
}
#endif
