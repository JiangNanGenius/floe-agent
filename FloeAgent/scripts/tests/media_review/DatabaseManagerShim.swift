// Build191 media-review — test-local stand-in for the app's actor-isolated
// GRDB facade. The edited FloePersistence sources compile against this exact
// API surface.

import Foundation
import GRDB

public actor DatabaseManager {
    private let queue: DatabaseQueue
    public init(queue: DatabaseQueue) { self.queue = queue }
    public func reader<T: Sendable>(_ block: @Sendable (Database) throws -> T) async throws -> T {
        try await queue.read { db in try block(db) }
    }
    public func writer<T: Sendable>(_ block: @Sendable (Database) throws -> T) async throws -> T {
        try await queue.write { db in try block(db) }
    }
}
