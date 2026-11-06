import Foundation
import Darwin

public struct TemplateLibraryEntry: Codable, Hashable, Sendable {
    public var revision: Int
    public var versions: [CanvasTemplate]
    public var archived: Bool
    public var latest: CanvasTemplate { versions[versions.count - 1] }
}

/// User templates are one atomic record each, with a process-shared CAS lock.
/// The template library does not own live canvas documents.
public actor CanvasTemplateLibrary {
    public let root: URL
    private let maxRecordBytes = 64 * 1024 * 1024
    public init(root: URL) throws {
        let canonical = root.standardizedFileURL.resolvingSymlinksInPath()
        guard canonical.pathComponents.count > 3 else { throw TemplateError.invalid("library root too broad") }
        self.root = canonical
        try FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: true)
    }
    public func list(includeArchived: Bool = false) throws -> [TemplateLibraryEntry] {
        try locked {
            try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
                .map { try read($0) }
                .filter { includeArchived || !$0.archived }
                .sorted { $0.latest.title.zh < $1.latest.title.zh }
        }
    }
    public func load(id: UUID) throws -> TemplateLibraryEntry {
        try locked { try read(url(id)) }
    }
    @discardableResult
    public func save(_ template: CanvasTemplate, expectedRevision: Int?) throws -> TemplateLibraryEntry {
        try CanvasTemplateEngine.validate(template)
        guard !template.isBuiltIn, BuiltInCanvasTemplates.template(id: template.id) == nil else {
            throw TemplateError.builtInImmutable
        }
        return try locked {
            let path = url(template.id)
            let existing = FileManager.default.fileExists(atPath: path.path) ? try read(path) : nil
            guard existing?.revision == expectedRevision else {
                throw TemplateError.conflict(expected: expectedRevision, actual: existing?.revision)
            }
            guard template.version == (existing?.latest.version ?? 0) + 1 else {
                throw TemplateError.invalid("template version must advance exactly once")
            }
            let next = TemplateLibraryEntry(revision: (existing?.revision ?? 0) + 1,
                versions: (existing?.versions ?? []) + [template], archived: false)
            try write(next, to: path)
            return next
        }
    }
    @discardableResult
    public func archive(id: UUID, expectedRevision: Int, archived: Bool = true) throws -> TemplateLibraryEntry {
        try locked {
            var entry = try read(url(id))
            guard entry.revision == expectedRevision else {
                throw TemplateError.conflict(expected: expectedRevision, actual: entry.revision)
            }
            entry.revision += 1; entry.archived = archived
            try write(entry, to: url(id)); return entry
        }
    }
    @discardableResult
    public func restoreVersion(id: UUID, version: Int, expectedRevision: Int) throws -> TemplateLibraryEntry {
        let entry = try load(id: id)
        guard var old = entry.versions.first(where: { $0.version == version }) else { throw TemplateError.notFound(id) }
        old.version = entry.latest.version + 1
        return try save(old, expectedRevision: expectedRevision)
    }
    public func importAsNew(_ data: Data) throws -> TemplateLibraryEntry {
        var template = try CanvasTemplateEngine.decode(data)
        template.id = UUID(); template.version = 1; template.isBuiltIn = false
        return try save(template, expectedRevision: nil)
    }
    private func url(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString + ".json") }
    private func read(_ url: URL) throws -> TemplateLibraryEntry {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TemplateError.notFound(UUID(uuidString: url.deletingPathExtension().lastPathComponent) ?? UUID())
        }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw TemplateError.invalid("unreadable template record") }
        defer { Darwin.close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
              st.st_size > 0, st.st_size <= maxRecordBytes else { throw TemplateError.invalid("invalid template record size") }
        var bytes = Data(count: Int(st.st_size))
        try bytes.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw TemplateError.invalid("truncated template record") }
                offset += count
            }
        }
        let entry = try JSONDecoder().decode(TemplateLibraryEntry.self, from: bytes)
        guard entry.revision > 0, !entry.versions.isEmpty,
              entry.versions.enumerated().allSatisfy({ $0.element.version == $0.offset + 1 }),
              entry.versions.allSatisfy({ $0.id == entry.latest.id && !$0.isBuiltIn }),
              entry.latest.id.uuidString == url.deletingPathExtension().lastPathComponent
        else { throw TemplateError.invalid("invalid template history") }
        for t in entry.versions { try CanvasTemplateEngine.validate(t) }
        return entry
    }
    private func locked<T>(_ operation: () throws -> T) throws -> T {
        let fd = Darwin.open(root.appendingPathComponent("library.lock").path,
                             O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw TemplateError.invalid("cannot lock template library") }
        defer { _ = flock(fd, LOCK_UN); Darwin.close(fd) }
        while flock(fd, LOCK_EX) != 0 { if errno != EINTR { throw TemplateError.invalid("template lock failed") } }
        return try operation()
    }
    private func write(_ entry: TemplateLibraryEntry, to destination: URL) throws {
        let data = try JSONEncoder().encode(entry)
        guard data.count <= maxRecordBytes else { throw TemplateError.invalid("template history is too large") }
        let staged = root.appendingPathComponent(".template-" + UUID().uuidString + ".tmp")
        let fd = Darwin.open(staged.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw TemplateError.invalid("cannot stage template") }
        var descriptorOpen = true
        defer { if descriptorOpen { Darwin.close(fd) }; _ = unlink(staged.path) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw TemplateError.invalid("template write failed") }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw TemplateError.invalid("template flush failed") }
        Darwin.close(fd); descriptorOpen = false
        guard rename(staged.path, destination.path) == 0 else { throw TemplateError.invalid("template commit failed") }
        let directoryFD = Darwin.open(root.path, O_RDONLY)
        if directoryFD >= 0 { defer { Darwin.close(directoryFD) }; _ = fsync(directoryFD) }
    }
}
