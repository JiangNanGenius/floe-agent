import Foundation
import Darwin
import FloeCore

/// A retained session. Listing it does not reopen or overwrite its original.
public struct DocumentRecoveryRecord: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let displayName: String
    public let updatedAt: Date
    public let workingURL: URL
    public let recoveryURL: URL
    public let hasEngineCopies: Bool
}

public struct DocumentRecoveryVersion: Identifiable, Sendable, Hashable {
    public enum Kind: String, Sendable { case current, lastSave, editor, previousEdit, export }
    public let id: String
    public let kind: Kind
    public let fileURL: URL
    public let updatedAt: Date
    public let byteCount: Int
    public let sha256: String
}

struct DocumentRecoveryManifest: Codable, Sendable {
    static let fileName = ".floe-session.json"
    var formatVersion = 1
    var id: UUID
    var originalBookmark: Data
    var displayName: String
    var fileExtension: String
    var committedDigest: String
    var pendingDigest: String?
    var updatedAt: Date

    static func read(from directory: URL) throws -> Self {
        let url = directory.appendingPathComponent(fileName)
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true,
              let size = values.fileSize, size <= 1_048_576 else {
            throw FloeError.validationFailed("Invalid document recovery record")
        }
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard value.formatVersion == 1, UUID(uuidString: directory.lastPathComponent) == value.id,
              value.fileExtension.count <= 16,
              value.fileExtension.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }),
              validDigest(value.committedDigest),
              value.pendingDigest.map(validDigest) ?? true,
              !value.originalBookmark.isEmpty else {
            throw FloeError.validationFailed("Unsupported document recovery record")
        }
        return value
    }
    func write(to directory: URL) throws {
        let data = try JSONEncoder().encode(self)
        try data.write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
    }
    private static func validDigest(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    func session(originalURL: URL, directory: URL) -> DocumentSession {
        DocumentSession(id: id, originalURL: originalURL,
            workingURL: directory.appendingPathComponent("working").appendingPathExtension(fileExtension),
            recoveryURL: directory.appendingPathComponent("recovery").appendingPathExtension(fileExtension))
    }
}

/// The kernel releases this lock if the app terminates. Independent windows or
/// workspace actors cannot resume the same private working file concurrently.
final class DocumentRecoveryLease: @unchecked Sendable {
    static let fileName = ".floe-session-lock"
    private let descriptor: Int32
    init(directory: URL) throws {
        let path = directory.appendingPathComponent(Self.fileName).path
        descriptor = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            Darwin.close(descriptor)
            throw FloeError.validationFailed("This document recovery session is already open")
        }
    }
    deinit { Darwin.close(descriptor) }
}
