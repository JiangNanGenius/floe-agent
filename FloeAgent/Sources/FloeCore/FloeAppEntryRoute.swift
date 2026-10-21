import Foundation

/// A navigation or intake request, never authority to execute a task or read
/// a file. The App must still resolve ownership and coordinated file access.
public enum FloeAppEntryRoute: Equatable, Sendable {
    case newTask
    case task(UUID)
    case shareInbox(UUID?)
    case externalFile(URL)

    public static let maximumURLBytes = 8_192

    public static func parse(_ url: URL) throws -> Self {
        guard url.absoluteString.utf8.count <= maximumURLBytes else {
            throw FloeAppEntryRouteError.tooLong
        }
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.fragment == nil, !parts.path.contains("\0") else {
            throw FloeAppEntryRouteError.malformedURL
        }
        let query = parts.queryItems ?? []
        if url.isFileURL {
            guard parts.host == nil || parts.host?.isEmpty == true
                    || parts.host?.lowercased() == "localhost",
                  parts.path.hasPrefix("/"), parts.path != "/" else {
                throw FloeAppEntryRouteError.malformedURL
            }
            guard query.isEmpty else { throw FloeAppEntryRouteError.unexpectedParameters }
            // Keep the original URL: normalizing it here could discard the
            // security-scoped identity supplied by the system document provider.
            return .externalFile(url)
        }
        guard parts.scheme?.lowercased() == "floe" else {
            throw FloeAppEntryRouteError.unsupportedScheme
        }
        switch parts.host?.lowercased() {
        case "new":
            guard parts.path.isEmpty || parts.path == "/" else {
                throw FloeAppEntryRouteError.malformedURL
            }
            guard query.isEmpty else { throw FloeAppEntryRouteError.unexpectedParameters }
            return .newTask
        case "task":
            guard query.isEmpty else { throw FloeAppEntryRouteError.unexpectedParameters }
            let segments = parts.path.split(separator: "/", omittingEmptySubsequences: false)
            guard segments.count == 2, segments[0].isEmpty else {
                throw FloeAppEntryRouteError.invalidTarget
            }
            return .task(try parseID(String(segments[1])))
        case "share":
            guard parts.path.isEmpty || parts.path == "/" else {
                throw FloeAppEntryRouteError.malformedURL
            }
            guard !query.isEmpty else { return .shareInbox(nil) }
            guard query.count == 1, query[0].name == "envelope" else {
                throw FloeAppEntryRouteError.unexpectedParameters
            }
            guard let value = query[0].value else { throw FloeAppEntryRouteError.invalidTarget }
            return .shareInbox(try parseID(value))
        default:
            throw FloeAppEntryRouteError.unsupportedAction
        }
    }

    /// Canonical links for trusted App/extension producers. Consumers still
    /// parse the incoming link and validate the referenced resource.
    public var url: URL {
        switch self {
        case .newTask:
            URL(string: "floe://new")!
        case .task(let id):
            URL(string: "floe://task/" + id.uuidString.lowercased())!
        case .shareInbox(let id):
            URL(string: "floe://share" + (id.map { "?envelope=" + $0.uuidString.lowercased() } ?? ""))!
        case .externalFile(let url):
            url
        }
    }

    private static func parseID(_ value: String) throws -> UUID {
        guard value.utf8.count == 36, let id = UUID(uuidString: value) else {
            throw FloeAppEntryRouteError.invalidTarget
        }
        return id
    }
}

public enum FloeAppEntryRouteError: Error, Equatable, Sendable {
    case tooLong
    case malformedURL
    case unsupportedScheme
    case unsupportedAction
    case unexpectedParameters
    case invalidTarget
}
