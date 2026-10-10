import Foundation

// FloeCore — Design project persistence and typed adapter capabilities.
//
// Projects are stored one JSON file per project under `<root>/DesignProjects/`,
// written atomically. A versioned envelope rejects newer schemas by moving the
// file aside for recovery instead of overwriting it (never destroys user data).
// The capability registry records only operations that are actually connected;
// every unavailable operation must carry a clear, user-readable reason and is
// never faked (no screenshot/PDF masquerading as an editable original).

public struct DesignProjectEnvelope: Codable, Sendable {
    public var schemaVersion: Int
    public var project: DesignProject

    public init(project: DesignProject) {
        self.schemaVersion = DesignProject.currentSchemaVersion
        self.project = project
    }
}

public enum DesignStoreError: Error, Equatable {
    case projectNotFound(String)
    case newerSchema(found: Int, supported: Int)
    case corrupt(String)
    case notADirectory
}

public actor DesignProjectStore {
    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    public var projectsURL: URL {
        rootURL.appendingPathComponent("DesignProjects", isDirectory: true)
    }

    public func projectURL(id: String) -> URL {
        projectsURL.appendingPathComponent("\(id).json", isDirectory: false)
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: projectsURL, withIntermediateDirectories: true)
    }

    /// All loadable projects plus the IDs of files that could not be decoded.
    /// Corrupt files are reported, never deleted.
    public func loadAll() -> (projects: [DesignProject], corruptIDs: [String]) {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: projectsURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ([], [])
        }
        var projects: [DesignProject] = []
        var corrupt: [String] = []
        for url in entries where url.pathExtension == "json" {
            do {
                projects.append(try decodeProject(at: url))
            } catch {
                corrupt.append(url.deletingPathExtension().lastPathComponent)
            }
        }
        return (projects.sorted { $0.updatedAt > $1.updatedAt }, corrupt)
    }

    public func load(id: String) throws -> DesignProject {
        let url = projectURL(id: id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DesignStoreError.projectNotFound(id)
        }
        return try decodeProject(at: url)
    }

    public func loadIfPresent(id: String) throws -> DesignProject? {
        guard FileManager.default.fileExists(atPath: projectURL(id: id).path) else { return nil }
        return try decodeProject(at: projectURL(id: id))
    }

    @discardableResult
    public func save(_ project: DesignProject) throws -> URL {
        try ensureDirectory()
        var copy = project
        copy.updatedAt = Date()
        let envelope = DesignProjectEnvelope(project: copy)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(envelope)
        let url = projectURL(id: project.id)
        try data.write(to: url, options: [.atomic])
        return url
    }

    public func delete(id: String) throws {
        let url = projectURL(id: id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DesignStoreError.projectNotFound(id)
        }
        try FileManager.default.removeItem(at: url)
    }

    /// Move a corrupt/newer-schema file aside under `.quarantine/` so it can be
    /// inspected/recovered and is never silently overwritten.
    @discardableResult
    public func quarantine(id: String) throws -> URL {
        let url = projectURL(id: id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DesignStoreError.projectNotFound(id)
        }
        let directory = projectsURL.appendingPathComponent(".quarantine", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(id)-\(UUID().uuidString.prefix(8)).json")
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    private func decodeProject(at url: URL) throws -> DesignProject {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Try the envelope first; a bare project body (older drafts) still loads.
        if let envelope = try? decoder.decode(DesignProjectEnvelope.self, from: data) {
            guard envelope.schemaVersion <= DesignProject.currentSchemaVersion else {
                throw DesignStoreError.newerSchema(
                    found: envelope.schemaVersion,
                    supported: DesignProject.currentSchemaVersion
                )
            }
            return envelope.project
        }
        if let project = try? decoder.decode(DesignProject.self, from: data) {
            guard project.schemaVersion <= DesignProject.currentSchemaVersion else {
                throw DesignStoreError.newerSchema(
                    found: project.schemaVersion,
                    supported: DesignProject.currentSchemaVersion
                )
            }
            return project
        }
        throw DesignStoreError.corrupt(url.deletingPathExtension().lastPathComponent)
    }
}

// MARK: - Typed adapter capabilities

/// Operations a content adapter can really perform. Anything not listed here is
/// unavailable and must carry a reason.
public enum DesignOperation: String, Codable, Sendable, CaseIterable {
    case importSource
    case generate
    case editRegion
    case preview
    case anchoredFeedback
    case candidateRevision
    case compareAdopt
    case sourceExport
    case verifiedExport
}

public struct DesignAdapterCapability: Sendable, Equatable {
    public let contentType: DesignContentType
    /// Only operations that are genuinely connected in this build.
    public let available: Set<DesignOperation>
    /// Reason shown for each unavailable operation.
    public let unavailableReasons: [DesignOperation: String]

    public init(
        contentType: DesignContentType,
        available: Set<DesignOperation>,
        unavailableReasons: [DesignOperation: String] = [:]
    ) {
        self.contentType = contentType
        self.available = available
        var reasons = unavailableReasons
        for operation in DesignOperation.allCases where !available.contains(operation) {
            if reasons[operation] == nil {
                // Every unavailable operation must explain itself honestly.
                reasons[operation] = "Not connected in this build"
            }
        }
        self.unavailableReasons = reasons
    }

    public func supports(_ operation: DesignOperation) -> Bool {
        available.contains(operation)
    }

    public func reason(for operation: DesignOperation) -> String? {
        available.contains(operation) ? nil : unavailableReasons[operation]
    }
}

/// Registry the app populates from its actual services. Consumers must consult
/// this before offering an operation in the UI or to the agent.
public struct DesignCapabilityRegistry: Sendable {
    private let capabilities: [DesignContentType: DesignAdapterCapability]

    public init(capabilities: [DesignContentType: DesignAdapterCapability]) {
        self.capabilities = capabilities
    }

    /// Nothing connected: every operation reports a reason. This is the honest
    /// default rather than pretending capabilities exist.
    public static func disconnected(reason: String = "Not connected in this build") -> DesignCapabilityRegistry {
        var caps: [DesignContentType: DesignAdapterCapability] = [:]
        for type in DesignContentType.allCases {
            var reasons: [DesignOperation: String] = [:]
            for operation in DesignOperation.allCases { reasons[operation] = reason }
            caps[type] = DesignAdapterCapability(contentType: type, available: [], unavailableReasons: reasons)
        }
        return DesignCapabilityRegistry(capabilities: caps)
    }

    public func capability(for contentType: DesignContentType) -> DesignAdapterCapability {
        capabilities[contentType]
            ?? DesignAdapterCapability(contentType: contentType, available: [])
    }

    public func supports(_ operation: DesignOperation, for contentType: DesignContentType) -> Bool {
        capability(for: contentType).supports(operation)
    }

    public func reason(_ operation: DesignOperation, for contentType: DesignContentType) -> String? {
        capability(for: contentType).reason(for: operation)
    }
}
