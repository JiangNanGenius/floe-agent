import Foundation
import FloeCore
import SWCompression

/// Release/Packages index parsing and hash-chain validation.
public struct AptPackage: Sendable, Equatable {
    public var name: String
    public var version: String
    public var architecture: String
    public var filename: String
    public var size: Int
    public var sha256: String
    public var depends: String?
    public var preDepends: String?
    public var recommends: String?
    public var suggests: String?
    public var provides: String?
    public var conflicts: String?
    public var breaks: String?
    public var replaces: String?
    public var description: String?
    public var section: String?
    public var license: String?
    public var requiresBase: String?
    public var source: String?
    public var component: String
    public var repository: String

    public static func parse(stanza: Deb822, component: String, repository: String) -> AptPackage? {
        guard let name = stanza["Package"],
              let version = stanza["Version"],
              let filename = stanza["Filename"],
              let sha256 = stanza["SHA256"] else { return nil }
        return AptPackage(
            name: name,
            version: version,
            architecture: stanza["Architecture"] ?? "all",
            filename: filename,
            size: Int(stanza["Size"] ?? "0") ?? 0,
            sha256: sha256,
            depends: stanza["Depends"],
            preDepends: stanza["Pre-Depends"],
            recommends: stanza["Recommends"],
            suggests: stanza["Suggests"],
            provides: stanza["Provides"],
            conflicts: stanza["Conflicts"],
            breaks: stanza["Breaks"],
            replaces: stanza["Replaces"],
            description: stanza["Description"],
            section: stanza["Section"],
            license: stanza["License"],
            requiresBase: stanza["Floe-Requires-Base"] ?? stanza["Floe-MinAppVersion"],
            source: stanza["Source"],
            component: component,
            repository: repository
        )
    }
}

public struct AptRelease: Sendable {
    public var suite: String
    public var codename: String
    public var date: Date?
    public var validUntil: Date?
    public var architectures: [String]
    public var components: [String]
    public var hashes: [String: String]

    public static func parse(_ stanza: Deb822) -> AptRelease? {
        guard let suite = stanza["Suite"] ?? stanza["Codename"] else { return nil }
        let formatter = ISO8601DateFormatter()
        var hashes: [String: String] = [:]
        if let sha256 = stanza["SHA256"] {
            for line in sha256.split(separator: "\n") {
                let parts = line.split(whereSeparator: { $0 == " " }).map(String.init)
                guard parts.count == 3 else { continue }
                hashes[parts[2]] = parts[0]
            }
        }
        return AptRelease(
            suite: suite,
            codename: stanza["Codename"] ?? suite,
            date: stanza["Date"].flatMap { formatter.date(from: $0) },
            validUntil: stanza["Valid-Until"].flatMap { formatter.date(from: $0) },
            architectures: (stanza["Architectures"] ?? "").split(separator: " ").map(String.init),
            components: (stanza["Components"] ?? "").split(separator: " ").map(String.init),
            hashes: hashes
        )
    }

    public func isValid(at now: Date = Date()) -> Bool {
        if let validUntil, now > validUntil { return false }
        return true
    }
}

public enum AptIndex {
    public struct FetchedIndex: Sendable {
        public var packages: [AptPackage]
        public var release: AptRelease?
    }

    public enum IndexError: Error, CustomStringConvertible {
        case hashMismatch(String)
        case expired(String)
        case unsupportedCompression(String)

        public var description: String {
            switch self {
            case .hashMismatch(let path): return "hash mismatch for \(path)"
            case .expired(let suite): return "release expired for \(suite)"
            case .unsupportedCompression(let name): return "unsupported compression: \(name)"
            }
        }
    }

    public static func decompressPackages(_ data: Data, memberName: String) throws -> Data {
        if memberName.hasSuffix(".gz") { return try GzipArchive.unarchive(archive: data) }
        if memberName.hasSuffix(".xz") { throw IndexError.unsupportedCompression(memberName) }
        return data
    }

    public static func parsePackages(_ document: String, component: String, repository: String) -> [AptPackage] {
        Deb822.parseAll(document).compactMap {
            AptPackage.parse(stanza: $0, component: component, repository: repository)
        }
    }

    /// Validates a downloaded Packages payload against the Release hash list.
    public static func validate(
        packagesData: Data,
        relativePath: String,
        release: AptRelease,
        digest: (Data) -> String
    ) throws {
        guard let expected = release.hashes[relativePath] else { return }
        let actual = digest(packagesData)
        guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
            throw IndexError.hashMismatch(relativePath)
        }
    }

    public static func validateDeb(data: Data, package: AptPackage, digest: (Data) -> String) throws {
        guard digest(data).caseInsensitiveCompare(package.sha256) == .orderedSame else {
            throw IndexError.hashMismatch(package.filename)
        }
    }
}
