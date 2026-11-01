// SPDX-License-Identifier: MPL-2.0
//
// C07 App-entry shared contract.
//
// This is the cross-platform, side-effect-free policy for external links and
// share/open descriptors. It deliberately owns NO storage, grant, network,
// task, approval or execution authority: parsing a link or validating a share
// never opens a file, starts a run or approves anything. The Android platform
// host (app/host/entryflow) performs the real Intent, grant, store and Notes
// hand-offs; this file keeps the contract identical to the iOS donor.
import Foundation

// MARK: - Routes

/// A navigation or intake request, never authority to execute or read.
public enum C07AppEntryRoute: Equatable, Sendable {
    case newTask
    case task(UUID)
    case schedule(UUID)
    case share(UUID?)

    public static let maximumURLBytes = 8_192

    public static func parse(_ raw: String) throws -> Self {
        guard raw.utf8.count <= maximumURLBytes else {
            throw C07AppEntryRouteError.tooLong
        }
        guard !raw.isEmpty,
              !raw.unicodeScalars.contains(where: { $0.value < 0x21 || $0.value == 0x7F }) else {
            throw C07AppEntryRouteError.malformedURL
        }
        guard raw.lowercased().hasPrefix("floe://") else {
            throw C07AppEntryRouteError.unsupportedScheme
        }
        guard let parts = URLComponents(string: raw),
              parts.scheme?.lowercased() == "floe",
              parts.user == nil,
              parts.password == nil,
              parts.port == nil,
              parts.fragment == nil else {
            throw C07AppEntryRouteError.malformedURL
        }
        let host = parts.host?.lowercased() ?? ""
        let path = parts.percentEncodedPath
        guard !path.contains("%"), !path.contains("\\"), !path.contains("..") else {
            throw C07AppEntryRouteError.malformedURL
        }
        let query = parts.percentEncodedQuery
        switch host {
        case "new":
            guard path.isEmpty || path == "/" else {
                throw C07AppEntryRouteError.malformedURL
            }
            guard query == nil else { throw C07AppEntryRouteError.unexpectedParameters }
            return .newTask
        case "task":
            return .task(try parseIDRoute(path: path, query: query))
        case "schedule":
            return .schedule(try parseIDRoute(path: path, query: query))
        case "share":
            guard path.isEmpty || path == "/" else {
                throw C07AppEntryRouteError.malformedURL
            }
            guard let query else { return .share(nil) }
            guard !query.contains("%"), !query.contains("&"),
                  query.filter({ $0 == "=" }).count == 1 else {
                throw C07AppEntryRouteError.unexpectedParameters
            }
            let name = String(query.prefix(while: { $0 != "=" }))
            let value = String(query.drop(while: { $0 != "=" }).dropFirst())
            guard name == "intake" else {
                throw C07AppEntryRouteError.unexpectedParameters
            }
            guard let id = canonicalUUID(value) else {
                throw C07AppEntryRouteError.invalidTarget
            }
            return .share(id)
        default:
            throw C07AppEntryRouteError.unsupportedAction
        }
    }

    public static func parse(url: URL) throws -> Self {
        try parse(url.absoluteString)
    }

    public var url: URL {
        switch self {
        case .newTask:
            return URL(string: "floe://new")!
        case .task(let id):
            return URL(string: "floe://task/" + id.uuidString.lowercased())!
        case .schedule(let id):
            return URL(string: "floe://schedule/" + id.uuidString.lowercased())!
        case .share(let id):
            let suffix = id.map { "?intake=" + $0.uuidString.lowercased() } ?? ""
            return URL(string: "floe://share" + suffix)!
        }
    }

    private static func parseIDRoute(path: String, query: String?) throws -> UUID {
        guard query == nil else { throw C07AppEntryRouteError.unexpectedParameters }
        guard path.count == 37, path.hasPrefix("/") else {
            throw C07AppEntryRouteError.invalidTarget
        }
        guard let id = canonicalUUID(String(path.dropFirst())) else {
            throw C07AppEntryRouteError.invalidTarget
        }
        return id
    }

    private static func canonicalUUID(_ value: String) -> UUID? {
        let characters = Array(value)
        guard characters.count == 36,
              characters[8] == "-",
              characters[13] == "-",
              characters[18] == "-",
              characters[23] == "-",
              characters.allSatisfy({ $0.isHexDigit || $0 == "-" }),
              let parsed = UUID(uuidString: value),
              parsed.uuidString.lowercased() == value.lowercased() else {
            return nil
        }
        return parsed
    }
}

public enum C07AppEntryRouteError: String, Error, Equatable, Sendable {
    case tooLong
    case malformedURL
    case unsupportedScheme
    case unsupportedAction
    case unexpectedParameters
    case invalidTarget
}

// MARK: - Share/open policy

public enum C07ShareItemKind: String, Sendable, Equatable {
    case text
    case file
}

/// One untrusted incoming item descriptor. `byteCount == -1` means the
/// provider did not declare a size; the platform then enforces the cap while
/// copying. The type and size are hints, never permissions.
public struct C07ShareItemDescriptor: Equatable, Sendable {
    public var kind: C07ShareItemKind
    public var mimeType: String
    public var byteCount: Int64
    public var textBytes: Int64
    public var fileName: String?

    public init(
        kind: C07ShareItemKind,
        mimeType: String,
        byteCount: Int64,
        textBytes: Int64 = 0,
        fileName: String? = nil
    ) {
        self.kind = kind
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.textBytes = textBytes
        self.fileName = fileName
    }
}

public struct C07ShareLimits: Equatable, Sendable {
    public var maxItems: Int
    public var maxTextBytes: Int64
    public var maxItemBytes: Int64
    public var maxTotalBytes: Int64
    public var maxFileNameCharacters: Int

    public init(
        maxItems: Int = 5,
        maxTextBytes: Int64 = 1_048_576,
        maxItemBytes: Int64 = 67_108_864,
        maxTotalBytes: Int64 = 134_217_728,
        maxFileNameCharacters: Int = 120
    ) {
        self.maxItems = max(1, maxItems)
        self.maxTextBytes = max(1, maxTextBytes)
        self.maxItemBytes = max(1, maxItemBytes)
        self.maxTotalBytes = max(1, maxTotalBytes)
        self.maxFileNameCharacters = max(1, maxFileNameCharacters)
    }

    public static let standard = C07ShareLimits()
}

public enum C07ShareRefusal: String, Error, Equatable, Sendable {
    case empty
    case itemLimit
    case textTooLarge
    case itemTooLarge
    case totalTooLarge
    case unsupportedType
    case invalidDescriptor
}

public struct C07ShareAdmission: Equatable, Sendable {
    public let items: [C07ShareItemDescriptor]
    public let totalKnownBytes: Int64
    public let textBytes: Int64
}

public enum C07SharePolicy {
    private static let exactTypes: Set<String> = [
        "text/plain",
        "application/pdf",
        "image/png",
        "image/jpeg",
        "image/webp",
        "image/gif",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "application/zip",
    ]
    private static let octetExtensions: Set<String> = [
        "pdf", "png", "jpg", "jpeg", "webp", "gif", "txt", "md",
        "docx", "xlsx", "pptx", "zip",
    ]

    public static func normalizedMime(_ raw: String) -> String {
        let head = raw.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first ?? ""
        return String(head)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    public static func extensionOf(_ fileName: String?) -> String {
        guard let fileName, let dot = fileName.lastIndex(of: ".") else { return "" }
        return String(fileName[fileName.index(after: dot)...]).lowercased()
    }

    public static func isSupported(mimeType: String, fileName: String?) -> Bool {
        let mime = normalizedMime(mimeType)
        let fileExtension = extensionOf(fileName)
        if mime == "application/zip" {
            return ["zip", "docx", "xlsx", "pptx"].contains(fileExtension)
        }
        if mime == "application/octet-stream" {
            return octetExtensions.contains(fileExtension)
        }
        return exactTypes.contains(mime)
    }

    public static func validate(
        _ items: [C07ShareItemDescriptor],
        limits: C07ShareLimits = .standard
    ) -> Result<C07ShareAdmission, C07ShareRefusal> {
        guard !items.isEmpty else { return .failure(.empty) }
        guard items.count <= limits.maxItems else { return .failure(.itemLimit) }
        var totalKnown: Int64 = 0
        var textBytes: Int64 = 0
        var normalized: [C07ShareItemDescriptor] = []
        normalized.reserveCapacity(items.count)
        for item in items {
            switch item.kind {
            case .text:
                guard item.textBytes > 0 else { return .failure(.empty) }
                textBytes += item.textBytes
                guard item.textBytes <= limits.maxTextBytes,
                      textBytes <= limits.maxTextBytes else {
                    return .failure(.textTooLarge)
                }
                normalized.append(C07ShareItemDescriptor(
                    kind: .text,
                    mimeType: "text/plain",
                    byteCount: item.textBytes,
                    textBytes: item.textBytes,
                    fileName: nil
                ))
            case .file:
                let mime = normalizedMime(item.mimeType)
                guard !mime.isEmpty, item.byteCount >= -1 else {
                    return .failure(.invalidDescriptor)
                }
                if let name = item.fileName {
                    guard name.count <= limits.maxFileNameCharacters,
                          name.utf8.count <= limits.maxFileNameCharacters * 4,
                          !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
                        return .failure(.invalidDescriptor)
                    }
                }
                guard isSupported(mimeType: mime, fileName: item.fileName) else {
                    return .failure(.unsupportedType)
                }
                guard item.byteCount <= limits.maxItemBytes else {
                    return .failure(.itemTooLarge)
                }
                if item.byteCount > 0 {
                    totalKnown += item.byteCount
                    guard totalKnown <= limits.maxTotalBytes else {
                        return .failure(.totalTooLarge)
                    }
                }
                normalized.append(C07ShareItemDescriptor(
                    kind: .file,
                    mimeType: mime,
                    byteCount: item.byteCount,
                    textBytes: 0,
                    fileName: item.fileName
                ))
            }
        }
        return .success(C07ShareAdmission(
            items: normalized,
            totalKnownBytes: totalKnown,
            textBytes: textBytes
        ))
    }
}
