// SPDX-License-Identifier: MPL-2.0
import Foundation
import Darwin

public struct InteractiveState: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let owner: ContentOwner
    public let documentSHA256: String
    public let revision: UInt64
    public let modelContent: JSONValue
    public let privateContent: JSONValue

    public init(document: InteractiveDocument, revision: UInt64 = 0,
                modelContent: JSONValue? = nil, privateContent: JSONValue? = nil) {
        schemaVersion = 1
        owner = document.owner
        documentSHA256 = document.digest
        self.revision = revision
        self.modelContent = modelContent ?? document.initialModelContent
        self.privateContent = privateContent ?? document.initialPrivateContent
    }

    public func validate(for document: InteractiveDocument) throws {
        guard schemaVersion == 1 else { throw InteractiveError.unsupportedVersion(schemaVersion) }
        guard owner == document.owner else { throw InteractiveError.ownershipMismatch }
        guard documentSHA256 == document.digest else { throw InteractiveError.contentChanged }
        try InteractiveLimits.checkState(modelContent)
        try InteractiveLimits.checkState(privateContent)
    }
}

/// Mainline may implement this with its existing transactional database.
/// compareAndSwap must re-read and compare inside the actual commit boundary.
public protocol InteractiveStateRepository: Sendable {
    func load(document: InteractiveDocument) async throws -> InteractiveState
    func compareAndSwap(document: InteractiveDocument, expectedRevision: UInt64,
                        modelContent: JSONValue, privateContent: JSONValue) async throws -> InteractiveState
    func remove(document: InteractiveDocument) async throws
}

public actor MemoryInteractiveStateRepository: InteractiveStateRepository {
    private var records: [String: InteractiveState] = [:]
    public init() {}

    public func load(document: InteractiveDocument) throws -> InteractiveState {
        try document.validate()
        let state = records[document.owner.storageKey] ?? InteractiveState(document: document)
        try state.validate(for: document)
        return state
    }

    public func compareAndSwap(document: InteractiveDocument, expectedRevision: UInt64,
                               modelContent: JSONValue, privateContent: JSONValue) throws -> InteractiveState {
        let current = try load(document: document)
        let next = try nextState(document: document, current: current,
                                 expectedRevision: expectedRevision,
                                 modelContent: modelContent, privateContent: privateContent)
        records[document.owner.storageKey] = next
        return next
    }

    public func remove(document: InteractiveDocument) {
        records.removeValue(forKey: document.owner.storageKey)
    }
}

/// Opt-in sidecar for standalone qualification. It never chooses an App directory.
/// Independent instances coordinate through the SAME per-content file lock.
/// Mainline can retain its existing DB using InteractiveStateRepository instead.
public actor FileInteractiveStateRepository: InteractiveStateRepository {
    public let directory: URL

    public init(directory: URL) throws {
        guard directory.isFileURL else { throw InteractiveError.unsafeStorage }
        let root = directory.standardizedFileURL
        if FileManager.default.fileExists(atPath: root.path) {
            try Self.rejectSymlink(root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try Self.rejectSymlink(root)
        self.directory = root
    }

    public func load(document: InteractiveDocument) throws -> InteractiveState {
        try document.validate()
        return try locked(document: document) { try read(document: document) }
    }

    public func compareAndSwap(document: InteractiveDocument, expectedRevision: UInt64,
                               modelContent: JSONValue, privateContent: JSONValue) throws -> InteractiveState {
        try document.validate()
        return try locked(document: document) {
            let current = try read(document: document)
            let next = try nextState(document: document, current: current,
                                     expectedRevision: expectedRevision,
                                     modelContent: modelContent, privateContent: privateContent)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(next)
            let target = stateURL(document)
            try Self.rejectSymlinkIfPresent(target)
            // Atomic replacement preserves the previous valid record on a failed write.
            try data.write(to: target, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            return next
        }
    }

    public func remove(document: InteractiveDocument) throws {
        try locked(document: document) {
            let target = stateURL(document)
            try Self.rejectSymlinkIfPresent(target)
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
        }
    }

    private func stateURL(_ document: InteractiveDocument) -> URL {
        directory.appendingPathComponent(document.owner.storageKey + ".json")
    }

    private func read(document: InteractiveDocument) throws -> InteractiveState {
        let url = stateURL(document)
        try Self.rejectSymlinkIfPresent(url)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return InteractiveState(document: document)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber,
              size.intValue <= InteractiveLimits.bridgeBytes + 4_096 else {
            throw InteractiveError.limitExceeded
        }
        let data = try Data(contentsOf: url)
        try InteractiveLimits.checkJSON(data, maximum: InteractiveLimits.bridgeBytes + 4_096)
        let state = try JSONDecoder().decode(InteractiveState.self, from: data)
        try state.validate(for: document)
        return state
    }

    private func locked<T>(document: InteractiveDocument, _ operation: () throws -> T) throws -> T {
        try Self.rejectSymlink(directory)
        let lockURL = directory.appendingPathComponent(document.owner.storageKey + ".lock")
        let fd = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw InteractiveError.unsafeStorage }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw InteractiveError.storageFailure }
        defer { flock(fd, LOCK_UN) }
        return try operation()
    }

    private static func rejectSymlinkIfPresent(_ url: URL) throws {
        // attributesOfItem also detects dangling symlinks.
        if (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil {
            try rejectSymlink(url)
        }
    }

    private static func rejectSymlink(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
            throw InteractiveError.unsafeStorage
        }
    }
}

private func nextState(document: InteractiveDocument, current: InteractiveState,
                       expectedRevision: UInt64, modelContent: JSONValue,
                       privateContent: JSONValue) throws -> InteractiveState {
    guard current.revision == expectedRevision else {
        throw InteractiveError.staleRevision(expected: expectedRevision, actual: current.revision)
    }
    guard current.revision < InteractiveLimits.maximumBridgeInteger else { throw InteractiveError.limitExceeded }
    try InteractiveLimits.checkState(modelContent)
    try InteractiveLimits.checkState(privateContent)
    return InteractiveState(document: document, revision: current.revision + 1,
                            modelContent: modelContent, privateContent: privateContent)
}
