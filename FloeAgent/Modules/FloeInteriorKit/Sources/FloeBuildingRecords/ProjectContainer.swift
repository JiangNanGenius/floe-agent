import Foundation

enum ProjectFileError: Error, Equatable {
    case missing
    case corrupted
    case pathEscapesProject
}

/// Resolves the only paths this service may touch. Callers never provide a
/// file path beyond the project root; source blobs are addressed by SHA-256 and
/// every directory is checked for symlink escapes before use.
struct ProjectContainer: @unchecked Sendable {
    static let buildingDirectory = "Building"
    static let databaseRelativePath = "Building/Records.sqlite"
    static let sourcesDirectory = "Building/Sources"
    static let blobsDirectory = "Building/Sources/blobs"
    static let stagingDirectory = "Building/Sources/.staging"

    let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    var databaseURL: URL {
        rootURL.appendingPathComponent(Self.databaseRelativePath)
    }

    func prepareRoot() throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: rootURL.path) {
            let attributes = try fileManager.attributesOfItem(atPath: rootURL.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw BuildingRecordsError.invalidProjectContainer("the project root is not a directory")
            }
        } else {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        }
    }

    func prepareDatabaseFile() throws -> URL {
        try ensureDirectory(Self.buildingDirectory)
        let url = databaseURL
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            guard isContained(resolved) else { throw ProjectFileError.pathEscapesProject }
            let attributes = try fileManager.attributesOfItem(atPath: resolved.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw BuildingRecordsError.invalidProjectContainer("the records database is not a regular file")
            }
        }
        return url
    }

    func ensureDirectory(_ relativePath: String) throws -> URL {
        try prepareRoot()
        var current = rootURL
        for rawComponent in relativePath.split(separator: "/") {
            let component = String(rawComponent)
            guard !component.isEmpty, component != ".", component != ".." else {
                throw ProjectFileError.pathEscapesProject
            }
            let next = current.appendingPathComponent(component, isDirectory: true)
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: next.path) {
                let resolved = next.resolvingSymlinksInPath().standardizedFileURL
                guard isContained(resolved), resolved.path == next.standardizedFileURL.path else {
                    throw ProjectFileError.pathEscapesProject
                }
                let attributes = try fileManager.attributesOfItem(atPath: resolved.path)
                guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                    throw ProjectFileError.pathEscapesProject
                }
            } else {
                try fileManager.createDirectory(at: next, withIntermediateDirectories: false)
            }
            current = next
        }
        return current
    }

    func existingRegularFileURL(relativePath: String) throws -> URL {
        let candidate = rootURL.appendingPathComponent(relativePath)
        guard isContained(candidate) else { throw ProjectFileError.pathEscapesProject }
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard isContained(resolved) else { throw ProjectFileError.pathEscapesProject }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: resolved.path) else {
            throw ProjectFileError.missing
        }
        let attributes = try fileManager.attributesOfItem(atPath: resolved.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw ProjectFileError.corrupted
        }
        return resolved
    }

    func blobRelativePath(for sha256: String) throws -> String {
        guard RecordsCodec.isSHA256Hex(sha256) else {
            throw BuildingRecordsError.invalidValue(field: "sha256", reason: "must be 64 lowercase hexadecimal characters")
        }
        let prefix = String(sha256.prefix(2))
        return "\(Self.blobsDirectory)/\(prefix)/\(sha256)"
    }

    func blobURL(for sha256: String) throws -> URL {
        let relative = try blobRelativePath(for: sha256)
        let parent = (relative as NSString).deletingLastPathComponent
        let directory = try ensureDirectory(parent)
        return directory.appendingPathComponent(sha256, isDirectory: false)
    }

    func readBlob(sha256: String, maxBytes: Int) throws -> Data {
        let relative = try blobRelativePath(for: sha256)
        let url = try existingRegularFileURL(relativePath: relative)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size <= maxBytes else {
            throw BuildingRecordsError.contentTooLarge(limit: maxBytes, actual: size)
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard RecordsCodec.sha256Hex(data) == sha256 else {
            throw ProjectFileError.corrupted
        }
        return data
    }

    @discardableResult
    func installBlob(_ data: Data, sha256: String) throws -> String {
        let relative = try blobRelativePath(for: sha256)
        let destination = try blobURL(for: sha256)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try verifyBlob(relativePath: relative, sha256: sha256, expectedSize: data.count)
            return relative
        }

        let staging = try makeStagingURL()
        defer { try? fileManager.removeItem(at: staging) }
        try data.write(to: staging, options: .atomic)

        if fileManager.fileExists(atPath: destination.path) {
            try verifyBlob(relativePath: relative, sha256: sha256, expectedSize: data.count)
            return relative
        }

        do {
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            if fileManager.fileExists(atPath: destination.path) {
                try verifyBlob(relativePath: relative, sha256: sha256, expectedSize: data.count)
                return relative
            }
            throw error
        }
        return relative
    }

    func makeStagingURL() throws -> URL {
        let directory = try ensureDirectory(Self.stagingDirectory)
        return directory.appendingPathComponent("\(UUID().uuidString.lowercased()).part", isDirectory: false)
    }

    func stagingFileNames() throws -> [String] {
        let fileManager = FileManager.default
        let directory = rootURL.appendingPathComponent(Self.stagingDirectory, isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let resolved = directory.resolvingSymlinksInPath().standardizedFileURL
        guard isContained(resolved) else { throw ProjectFileError.pathEscapesProject }
        let names = try fileManager.contentsOfDirectory(atPath: resolved.path)
        var result: [String] = []
        for name in names where name.hasSuffix(".part") {
            let url = resolved.appendingPathComponent(name)
            if let attributes = try? fileManager.attributesOfItem(atPath: url.path),
               attributes[.type] as? FileAttributeType == .typeRegular {
                result.append(name)
            }
        }
        return result.sorted()
    }

    @discardableResult
    func discardStagingFiles() throws -> Int {
        let fileManager = FileManager.default
        let directory = try ensureDirectory(Self.stagingDirectory)
        var removed = 0
        for name in try stagingFileNames() {
            try fileManager.removeItem(at: directory.appendingPathComponent(name))
            removed += 1
        }
        return removed
    }

    func verifyBlob(relativePath: String, sha256: String, expectedSize: Int) throws {
        let url = try existingRegularFileURL(relativePath: relativePath)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? -1
        guard size == expectedSize else { throw ProjectFileError.corrupted }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard RecordsCodec.sha256Hex(data) == sha256 else { throw ProjectFileError.corrupted }
    }

    func isContained(_ url: URL) -> Bool {
        let rootComponents = rootURL.standardizedFileURL.pathComponents
        let candidateComponents = url.standardizedFileURL.pathComponents
        guard candidateComponents.count > rootComponents.count else { return false }
        return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }
}
