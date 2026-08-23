import Foundation
import FloeCore

public struct CloudWorkspaceCleanupTombstone: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let hostID: UUID
    public let workspaceID: String
    public let daemonPort: Int
    public let createdAt: Date
    public var attempts: Int
    public var lastError: String?

    public init(hostID: UUID, workspaceID: String, daemonPort: Int) {
        self.id = UUID(); self.hostID = hostID; self.workspaceID = workspaceID
        self.daemonPort = daemonPort; self.createdAt = Date(); self.attempts = 0; self.lastError = nil
    }
}

/// Durable delete intent. Permanent deletion records this locally before the
/// task row or private workspace disappears, so an offline device can finish
/// cloud cleanup after connectivity returns. The daemon endpoint is
/// idempotent, making replay safe.
public actor CloudWorkspaceCleanupQueue {
    private let service: CloudWorkspaceService
    private let fileURL: URL
    private var tombstones: [CloudWorkspaceCleanupTombstone]

    public init(service: CloudWorkspaceService) {
        self.service = service
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("FloeAgent/CloudCleanup", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = directory.appendingPathComponent("tombstones.json")
        self.tombstones = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([CloudWorkspaceCleanupTombstone].self, from: $0) } ?? []
    }

    public func enqueue(_ values: [CloudWorkspaceCleanupTombstone]) throws {
        for value in values where !tombstones.contains(where: { $0.hostID == value.hostID && $0.workspaceID == value.workspaceID }) {
            tombstones.append(value)
        }
        try persist()
    }

    @discardableResult
    public func drain() async -> (removed: Int, pending: Int) {
        var retained: [CloudWorkspaceCleanupTombstone] = []
        var removed = 0
        for var item in tombstones {
            do {
                _ = try await service.request(
                    hostID: item.hostID, port: item.daemonPort, method: "POST",
                    endpoint: "v1/workspaces/delete", body: ["workspace_id": item.workspaceID]
                )
                removed += 1
            } catch {
                item.attempts += 1
                item.lastError = String(error.localizedDescription.prefix(512))
                retained.append(item)
            }
        }
        tombstones = retained
        try? persist()
        return (removed, retained.count)
    }

    public func pending() -> [CloudWorkspaceCleanupTombstone] { tombstones }

    private func persist() throws {
        try JSONEncoder().encode(tombstones).write(to: fileURL, options: .atomic)
    }
}
