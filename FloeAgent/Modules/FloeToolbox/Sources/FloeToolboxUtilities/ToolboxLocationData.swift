import Foundation

/// A copied system fix. Missing or invalid optional measurements stay unknown.
public struct ToolboxLocationFix: Codable, Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let horizontalAccuracy: Double
    public let timestamp: Date
    public let altitude: Double?
    public let verticalAccuracy: Double?
    public let speed: Double?
    public let course: Double?

    public init(latitude: Double, longitude: Double, horizontalAccuracy: Double, timestamp: Date,
                altitude: Double? = nil, verticalAccuracy: Double? = nil,
                speed: Double? = nil, course: Double? = nil) {
        self.latitude = latitude; self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy; self.timestamp = timestamp
        let validHeight = verticalAccuracy.map { $0.isFinite && $0 >= 0 } == true
        self.altitude = validHeight ? altitude.flatMap { $0.isFinite ? $0 : nil } : nil
        self.verticalAccuracy = validHeight ? verticalAccuracy : nil
        self.speed = speed.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.course = course.flatMap { $0.isFinite && (0..<360).contains($0) ? $0 : nil }
    }

    public var isValid: Bool {
        latitude.isFinite && (-90...90).contains(latitude)
            && longitude.isFinite && (-180...180).contains(longitude)
            && horizontalAccuracy.isFinite && horizontalAccuracy >= 0
            && timestamp.timeIntervalSince1970.isFinite
            && (altitude.map { $0.isFinite && verticalAccuracy != nil } ?? true)
            && (verticalAccuracy.map { $0.isFinite && $0 >= 0 } ?? true)
            && (speed.map { $0.isFinite && $0 >= 0 } ?? true)
            && (course.map { $0.isFinite && (0..<360).contains($0) } ?? true)
    }

    public func isFresh(at now: Date, maximumAge: TimeInterval = 15) -> Bool {
        isValid && timestamp <= now.addingTimeInterval(1) && now.timeIntervalSince(timestamp) <= maximumAge
    }

    public var coordinateText: String {
        String(format: "%.6f, %.6f", locale: Locale(identifier: "en_US_POSIX"), latitude, longitude)
    }

    public var mapsURL: URL? {
        guard isValid else { return nil }
        var value = URLComponents(string: "https://maps.apple.com/")
        value?.queryItems = [URLQueryItem(name: "ll", value: coordinateText), URLQueryItem(name: "q", value: coordinateText)]
        return value?.url
    }
}

public struct ToolboxSavedLocation: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let fix: ToolboxLocationFix
    public init(id: UUID = UUID(), name: String, fix: ToolboxLocationFix) {
        self.id = id; self.name = name; self.fix = fix
    }
}

/// One service owns the local archive. Loading failure never turns into an
/// empty successful write; a corrupt archive remains recoverable on disk.
public actor ToolboxLocationArchive {
    private let url: URL
    private let maximumCount = 200
    public init(url: URL) { self.url = url }

    public func load() throws -> [ToolboxSavedLocation] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 1_048_576 else { throw ArchiveError.invalidArchive }
        let data = try Data(contentsOf: url)
        guard let result = try? JSONDecoder().decode([ToolboxSavedLocation].self, from: data) else {
            throw ArchiveError.invalidArchive
        }
        guard result.count <= maximumCount, Set(result.map(\.id)).count == result.count,
              result.allSatisfy({ $0.fix.isValid && !$0.name.isEmpty && $0.name.utf8.count <= 512 }) else {
            throw ArchiveError.invalidArchive
        }
        return result
    }

    public func save(name: String, fix: ToolboxLocationFix) throws -> [ToolboxSavedLocation] {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 512, fix.isValid else { throw ArchiveError.invalidLocation }
        var values = try load()
        guard values.count < maximumCount else { throw ArchiveError.archiveFull }
        values.insert(.init(name: name, fix: fix), at: 0)
        try write(values)
        return values
    }

    public func remove(id: UUID) throws -> [ToolboxSavedLocation] {
        var values = try load()
        values.removeAll { $0.id == id }
        try write(values)
        return values
    }

    private func write(_ values: [ToolboxSavedLocation]) throws {
        let data = try JSONEncoder().encode(values)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public enum ArchiveError: Error, Sendable { case invalidArchive, invalidLocation, archiveFull }
}
