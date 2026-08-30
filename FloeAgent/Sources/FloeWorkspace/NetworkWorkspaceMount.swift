import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
@preconcurrency import SMBClient

public enum NetworkWorkspaceProtocol: String, Codable, Sendable, CaseIterable {
    case webDAV
    case smb
}

public enum NetworkWorkspaceMountStatus: String, Codable, Sendable {
    case disconnected
    case connecting
    case connected
    case authenticationFailed
    case unreachable
    case readOnly
    case failed
}

/// Secret-free persistent configuration for a virtual `Network/<name>` root.
/// `credentialRef` identifies a Keychain record; the password body is never
/// encoded with the mount or exposed to a provider/model.
public struct NetworkWorkspaceMount: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var workspaceID: UUID
    public var name: String
    public var transport: NetworkWorkspaceProtocol
    public var endpoint: URL
    public var rootPath: String
    public var username: String
    public var credentialRef: UUID?
    public var readOnly: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        workspaceID: UUID,
        name: String,
        transport: NetworkWorkspaceProtocol,
        endpoint: URL,
        rootPath: String = "",
        username: String,
        credentialRef: UUID?,
        readOnly: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.name = name
        self.transport = transport
        self.endpoint = endpoint
        self.rootPath = rootPath
        self.username = username
        self.credentialRef = credentialRef
        self.readOnly = readOnly
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var virtualRoot: String { "Network/\(name)" }
}

public struct NetworkWorkspaceEntry: Codable, Hashable, Sendable {
    public var name: String
    public var path: String
    public var isDirectory: Bool
    public var byteCount: Int64
    public var modifiedAt: Date?
    public var entityTag: String?
}

public struct NetworkWorkspaceFileMetadata: Codable, Hashable, Sendable {
    public var path: String
    public var isDirectory: Bool
    public var byteCount: Int64
    public var modifiedAt: Date?
    public var entityTag: String?
}

public enum NetworkWorkspaceErrorCode: String, Codable, Sendable {
    case invalidConfiguration
    case credentialMissing
    case authenticationFailed
    case networkUnreachable
    case timedOut
    case remoteRejected
    case conflict
    case readOnly
    case notFound
    case unsupported
    case protocolFailure
}

public struct NetworkWorkspaceError: Error, Codable, LocalizedError, Sendable {
    public var code: NetworkWorkspaceErrorCode
    public var stage: String
    public var retryable: Bool
    public var safeDetail: String

    public init(
        code: NetworkWorkspaceErrorCode,
        stage: String,
        retryable: Bool,
        safeDetail: String
    ) {
        self.code = code
        self.stage = stage
        self.retryable = retryable
        self.safeDetail = safeDetail
    }

    public var errorDescription: String? {
        "networkMount.\(code.rawValue) stage=\(stage) retryable=\(retryable): \(safeDetail)"
    }
}

public protocol WorkspaceMountAdapter: Sendable {
    func list(path: String) async throws -> [NetworkWorkspaceEntry]
    func read(path: String, offset: Int, limit: Int?) async throws -> Data
    func metadata(path: String) async throws -> NetworkWorkspaceFileMetadata
    func write(path: String, data: Data, expectedEntityTag: String?) async throws -> NetworkWorkspaceFileMetadata
    func createDirectory(path: String) async throws
    func move(from: String, to: String, expectedEntityTag: String?) async throws
    func delete(path: String, expectedEntityTag: String?) async throws
}

public typealias NetworkCredentialResolver = @Sendable (UUID) async throws -> Data

public enum WorkspaceMountAdapterFactory {
    public static func make(
        mount: NetworkWorkspaceMount,
        credentialResolver: @escaping NetworkCredentialResolver
    ) throws -> any WorkspaceMountAdapter {
        switch mount.transport {
        case .webDAV:
            return try WebDAVWorkspaceMountAdapter(mount: mount, credentialResolver: credentialResolver)
        case .smb:
            return try SMBWorkspaceMountAdapter(mount: mount, credentialResolver: credentialResolver)
        }
    }
}

public actor NetworkWorkspaceMountRegistry {
    public static let shared = NetworkWorkspaceMountRegistry()

    public struct Route: Sendable {
        public let mount: NetworkWorkspaceMount
        public let relativePath: String
        public let adapter: any WorkspaceMountAdapter
    }

    private struct WorkspaceEntry: Sendable {
        var mounts: [String: NetworkWorkspaceMount]
        var resolver: NetworkCredentialResolver
        var adapters: [UUID: any WorkspaceMountAdapter]
    }

    private var entries: [String: WorkspaceEntry] = [:]

    public func register(
        rootURL: URL,
        mounts: [NetworkWorkspaceMount],
        credentialResolver: @escaping NetworkCredentialResolver
    ) {
        let byName = Dictionary(uniqueKeysWithValues: mounts.map { ($0.name, $0) })
        entries[Self.key(rootURL)] = WorkspaceEntry(
            mounts: byName,
            resolver: credentialResolver,
            adapters: [:]
        )
    }

    public func unregister(rootURL: URL) {
        entries.removeValue(forKey: Self.key(rootURL))
    }

    public func mounts(rootURL: URL) -> [NetworkWorkspaceMount] {
        Array(entries[Self.key(rootURL)]?.mounts.values ?? [:].values)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func route(rootURL: URL, virtualPath: String) throws -> Route? {
        let components = virtualPath
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard components.first == "Network" else { return nil }
        guard components.count >= 2 else { return nil }
        let key = Self.key(rootURL)
        guard var workspace = entries[key], let mount = workspace.mounts[components[1]] else {
            throw NetworkWorkspaceError(
                code: .notFound,
                stage: "route",
                retryable: false,
                safeDetail: "Network mount '\(components[1])' is not configured for this workspace."
            )
        }
        let adapter: any WorkspaceMountAdapter
        if let cached = workspace.adapters[mount.id] {
            adapter = cached
        } else {
            adapter = try WorkspaceMountAdapterFactory.make(
                mount: mount,
                credentialResolver: workspace.resolver
            )
            workspace.adapters[mount.id] = adapter
            entries[key] = workspace
        }
        return Route(
            mount: mount,
            relativePath: components.dropFirst(2).joined(separator: "/"),
            adapter: adapter
        )
    }

    private static func key(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

public actor WebDAVWorkspaceMountAdapter: WorkspaceMountAdapter {
    private let mount: NetworkWorkspaceMount
    private let credentialResolver: NetworkCredentialResolver
    private let session: URLSession

    public init(
        mount: NetworkWorkspaceMount,
        credentialResolver: @escaping NetworkCredentialResolver,
        session: URLSession = .shared
    ) throws {
        guard ["http", "https"].contains(mount.endpoint.scheme?.lowercased() ?? "") else {
            throw NetworkWorkspaceError(
                code: .invalidConfiguration,
                stage: "configuration",
                retryable: false,
                safeDetail: "WebDAV endpoint must use HTTPS or HTTP."
            )
        }
        self.mount = mount
        self.credentialResolver = credentialResolver
        self.session = session
    }

    public func list(path: String) async throws -> [NetworkWorkspaceEntry] {
        var request = try await request(method: "PROPFIND", path: path)
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.httpBody = Data(#"<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/><d:getetag/></d:prop></d:propfind>"#.utf8)
        let (data, response) = try await perform(request, stage: "list")
        try require(response, allowed: [207], stage: "list")
        // RFC 4918 Depth: 1 responses begin with the requested collection.
        // It is metadata for the parent, not one of its children.
        return WebDAVMultiStatusParser.parse(data: data).dropFirst().compactMap { row in
            let decoded = row.href.removingPercentEncoding ?? row.href
            let relative = decoded.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let name = relative.split(separator: "/").last.map(String.init) ?? relative
            guard !name.isEmpty else { return nil }
            return NetworkWorkspaceEntry(
                name: name,
                path: [path, name].filter { !$0.isEmpty }.joined(separator: "/"),
                isDirectory: row.isDirectory,
                byteCount: row.byteCount,
                modifiedAt: row.modifiedAt,
                entityTag: row.entityTag
            )
        }
    }

    public func read(path: String, offset: Int, limit: Int?) async throws -> Data {
        var request = try await request(method: "GET", path: path)
        if offset > 0 || limit != nil {
            let end = limit.map { offset + max(0, $0) - 1 }
            request.setValue("bytes=\(offset)-\(end.map(String.init) ?? "")", forHTTPHeaderField: "Range")
        }
        let (data, response) = try await perform(request, stage: "read")
        try require(response, allowed: [200, 206], stage: "read")
        return data
    }

    public func metadata(path: String) async throws -> NetworkWorkspaceFileMetadata {
        var request = try await request(method: "PROPFIND", path: path)
        request.setValue("0", forHTTPHeaderField: "Depth")
        request.httpBody = Data(#"<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/><d:getetag/></d:prop></d:propfind>"#.utf8)
        let (data, response) = try await perform(request, stage: "metadata")
        try require(response, allowed: [207], stage: "metadata")
        guard let row = WebDAVMultiStatusParser.parse(data: data).first else {
            throw NetworkWorkspaceError(code: .protocolFailure, stage: "metadata", retryable: false, safeDetail: "WebDAV response did not include resource metadata.")
        }
        return NetworkWorkspaceFileMetadata(path: path, isDirectory: row.isDirectory, byteCount: row.byteCount, modifiedAt: row.modifiedAt, entityTag: row.entityTag)
    }

    public func write(path: String, data: Data, expectedEntityTag: String?) async throws -> NetworkWorkspaceFileMetadata {
        try writable(stage: "write")
        var request = try await request(method: "PUT", path: path)
        request.httpBody = data
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        if let expectedEntityTag { request.setValue(expectedEntityTag, forHTTPHeaderField: "If-Match") }
        let (_, response) = try await perform(request, stage: "write")
        try require(response, allowed: [200, 201, 204], stage: "write")
        return NetworkWorkspaceFileMetadata(path: path, isDirectory: false, byteCount: Int64(data.count), modifiedAt: Date(), entityTag: response.value(forHTTPHeaderField: "ETag"))
    }

    public func createDirectory(path: String) async throws {
        try writable(stage: "createDirectory")
        let request = try await request(method: "MKCOL", path: path)
        let (_, response) = try await perform(request, stage: "createDirectory")
        try require(response, allowed: [201, 204], stage: "createDirectory")
    }

    public func move(from: String, to: String, expectedEntityTag: String?) async throws {
        try writable(stage: "move")
        var request = try await request(method: "MOVE", path: from)
        request.setValue(url(path: to).absoluteString, forHTTPHeaderField: "Destination")
        request.setValue("F", forHTTPHeaderField: "Overwrite")
        if let expectedEntityTag { request.setValue(expectedEntityTag, forHTTPHeaderField: "If-Match") }
        let (_, response) = try await perform(request, stage: "move")
        try require(response, allowed: [201, 204], stage: "move")
    }

    public func delete(path: String, expectedEntityTag: String?) async throws {
        try writable(stage: "delete")
        var request = try await request(method: "DELETE", path: path)
        if let expectedEntityTag { request.setValue(expectedEntityTag, forHTTPHeaderField: "If-Match") }
        let (_, response) = try await perform(request, stage: "delete")
        try require(response, allowed: [200, 202, 204], stage: "delete")
    }

    private func request(method: String, path: String) async throws -> URLRequest {
        var request = URLRequest(url: url(path: path))
        request.httpMethod = method
        if let credentialRef = mount.credentialRef {
            let secret: Data
            do { secret = try await credentialResolver(credentialRef) }
            catch {
                throw NetworkWorkspaceError(code: .credentialMissing, stage: "credentials", retryable: false, safeDetail: "The saved credential is unavailable on this device.")
            }
            guard let password = String(data: secret, encoding: .utf8) else {
                throw NetworkWorkspaceError(code: .credentialMissing, stage: "credentials", retryable: false, safeDetail: "The saved credential is not UTF-8 text.")
            }
            let token = Data("\(mount.username):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 30
        return request
    }

    private func perform(_ request: URLRequest, stage: String) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw NetworkWorkspaceError(code: .protocolFailure, stage: stage, retryable: false, safeDetail: "WebDAV returned a non-HTTP response.")
            }
            return (data, response)
        } catch let error as NetworkWorkspaceError {
            throw error
        } catch let error as URLError {
            let timedOut = error.code == .timedOut
            throw NetworkWorkspaceError(
                code: timedOut ? .timedOut : .networkUnreachable,
                stage: stage,
                retryable: true,
                safeDetail: timedOut ? "The WebDAV request timed out." : "The WebDAV server is unreachable."
            )
        }
    }

    private func require(_ response: HTTPURLResponse, allowed: Set<Int>, stage: String) throws {
        guard allowed.contains(response.statusCode) else {
            let code: NetworkWorkspaceErrorCode
            let retryable: Bool
            switch response.statusCode {
            case 401, 403: (code, retryable) = (.authenticationFailed, false)
            case 404: (code, retryable) = (.notFound, false)
            case 409, 412, 423: (code, retryable) = (.conflict, false)
            case 429, 500...599: (code, retryable) = (.remoteRejected, true)
            default: (code, retryable) = (.remoteRejected, false)
            }
            throw NetworkWorkspaceError(code: code, stage: stage, retryable: retryable, safeDetail: "WebDAV returned HTTP \(response.statusCode).")
        }
    }

    private func writable(stage: String) throws {
        guard !mount.readOnly else {
            throw NetworkWorkspaceError(code: .readOnly, stage: stage, retryable: false, safeDetail: "This network mount is read-only.")
        }
    }

    private func normalized(_ path: String) -> String {
        [mount.rootPath, path]
            .flatMap { $0.split(separator: "/").map(String.init) }
            .joined(separator: "/")
    }

    private func url(path: String) -> URL {
        normalized(path).split(separator: "/").reduce(mount.endpoint) { partial, component in
            partial.appendingPathComponent(String(component), isDirectory: false)
        }
    }
}

private struct WebDAVResponseRow: Sendable {
    var href = ""
    var isDirectory = false
    var byteCount: Int64 = 0
    var modifiedAt: Date?
    var entityTag: String?
}

private final class WebDAVMultiStatusParser: NSObject, XMLParserDelegate, @unchecked Sendable {
    private var rows: [WebDAVResponseRow] = []
    private var row: WebDAVResponseRow?
    private var currentElement = ""
    private var text = ""

    static func parse(data: Data) -> [WebDAVResponseRow] {
        let delegate = WebDAVMultiStatusParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { return [] }
        return delegate.rows
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName.lowercased()
        text = ""
        if currentElement.hasSuffix("response") { row = WebDAVResponseRow() }
        if currentElement.hasSuffix("collection") { row?.isDirectory = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let element = elementName.lowercased()
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if element.hasSuffix("href") { row?.href = value }
        else if element.hasSuffix("getcontentlength") { row?.byteCount = Int64(value) ?? 0 }
        else if element.hasSuffix("getetag") { row?.entityTag = value }
        else if element.hasSuffix("getlastmodified") {
            row?.modifiedAt = Self.httpDate.date(from: value)
        } else if element.hasSuffix("response"), let row {
            rows.append(row)
            self.row = nil
        }
        currentElement = ""
        text = ""
    }

    private static let httpDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
}

public actor SMBWorkspaceMountAdapter: WorkspaceMountAdapter {
    private let mount: NetworkWorkspaceMount
    private let credentialResolver: NetworkCredentialResolver
    private var client: SMBClient?

    public init(
        mount: NetworkWorkspaceMount,
        credentialResolver: @escaping NetworkCredentialResolver
    ) throws {
        guard mount.endpoint.scheme?.lowercased() == "smb", mount.endpoint.host != nil else {
            throw NetworkWorkspaceError(code: .invalidConfiguration, stage: "configuration", retryable: false, safeDetail: "SMB endpoint must use smb://host/share.")
        }
        self.mount = mount
        self.credentialResolver = credentialResolver
    }

    public func list(path: String) async throws -> [NetworkWorkspaceEntry] {
        let client = try await connected(stage: "list")
        return try await translated(stage: "list") {
            try await client.listDirectory(path: remote(path)).filter { $0.name != "." && $0.name != ".." }.map {
                NetworkWorkspaceEntry(name: $0.name, path: [path, $0.name].filter { !$0.isEmpty }.joined(separator: "/"), isDirectory: $0.isDirectory, byteCount: Int64(clamping: $0.size), modifiedAt: $0.lastWriteTime, entityTag: nil)
            }
        }
    }

    public func read(path: String, offset: Int, limit: Int?) async throws -> Data {
        let client = try await connected(stage: "read")
        return try await translated(stage: "read") {
            if offset > 0 || limit != nil {
                let reader = client.fileReader(path: remote(path))
                defer { Task { try? await reader.close() } }
                return try await reader.read(offset: UInt64(max(0, offset)), length: UInt32(clamping: limit ?? 65_536))
            }
            return try await client.download(path: remote(path))
        }
    }

    public func metadata(path: String) async throws -> NetworkWorkspaceFileMetadata {
        let client = try await connected(stage: "metadata")
        return try await translated(stage: "metadata") {
            let stat = try await client.fileStat(path: remote(path))
            return NetworkWorkspaceFileMetadata(path: path, isDirectory: stat.isDirectory, byteCount: Int64(clamping: stat.size), modifiedAt: stat.lastWriteTime, entityTag: nil)
        }
    }

    public func write(path: String, data: Data, expectedEntityTag: String?) async throws -> NetworkWorkspaceFileMetadata {
        try writable(stage: "write")
        let client = try await connected(stage: "write")
        return try await translated(stage: "write") {
            try await client.upload(content: data, path: remote(path))
            return NetworkWorkspaceFileMetadata(path: path, isDirectory: false, byteCount: Int64(data.count), modifiedAt: Date(), entityTag: nil)
        }
    }

    public func createDirectory(path: String) async throws {
        try writable(stage: "createDirectory")
        let client = try await connected(stage: "createDirectory")
        try await translated(stage: "createDirectory") { try await client.createDirectory(path: remote(path)) }
    }

    public func move(from: String, to: String, expectedEntityTag: String?) async throws {
        try writable(stage: "move")
        let client = try await connected(stage: "move")
        try await translated(stage: "move") { try await client.move(from: remote(from), to: remote(to)) }
    }

    public func delete(path: String, expectedEntityTag: String?) async throws {
        try writable(stage: "delete")
        let client = try await connected(stage: "delete")
        try await translated(stage: "delete") {
            let stat = try await client.fileStat(path: remote(path))
            if stat.isDirectory { try await client.deleteDirectory(path: remote(path)) }
            else { try await client.deleteFile(path: remote(path)) }
        }
    }

    private func connected(stage: String) async throws -> SMBClient {
        if let client {
            do { _ = try await client.keepAlive(); return client }
            catch { self.client = nil }
        }
        guard let host = mount.endpoint.host else {
            throw NetworkWorkspaceError(code: .invalidConfiguration, stage: stage, retryable: false, safeDetail: "SMB host is missing.")
        }
        let password: String?
        if let ref = mount.credentialRef {
            do {
                let bytes = try await credentialResolver(ref)
                password = String(data: bytes, encoding: .utf8)
            } catch {
                throw NetworkWorkspaceError(code: .credentialMissing, stage: "credentials", retryable: false, safeDetail: "The saved SMB credential is unavailable on this device.")
            }
        } else { password = nil }
        let newClient = SMBClient(host: host, port: mount.endpoint.port ?? 445)
        do {
            _ = try await newClient.login(username: mount.username.isEmpty ? nil : mount.username, password: password)
            guard let share = mount.endpoint.path.split(separator: "/").first.map(String.init), !share.isEmpty else {
                throw NetworkWorkspaceError(code: .invalidConfiguration, stage: "share", retryable: false, safeDetail: "SMB endpoint must include a share name.")
            }
            _ = try await newClient.connectShare(share)
            client = newClient
            return newClient
        } catch let error as NetworkWorkspaceError {
            throw error
        } catch {
            throw classifySMB(error, stage: "authentication")
        }
    }

    private func remote(_ path: String) -> String {
        [mount.rootPath, path]
            .flatMap { $0.split(separator: "/").map(String.init) }
            .joined(separator: "\\")
    }

    private func writable(stage: String) throws {
        guard !mount.readOnly else {
            throw NetworkWorkspaceError(code: .readOnly, stage: stage, retryable: false, safeDetail: "This network mount is read-only.")
        }
    }

    private func translated<T>(stage: String, operation: () async throws -> T) async throws -> T {
        do { return try await operation() }
        catch let error as NetworkWorkspaceError { throw error }
        catch {
            client = nil
            throw classifySMB(error, stage: stage)
        }
    }

    private func classifySMB(_ error: Error, stage: String) -> NetworkWorkspaceError {
        if let response = error as? ErrorResponse {
            let status = NTStatus(response.header.status)
            switch status {
            case .logonFailure, .accessDenied, .smbBadUID, .userSessionDeleted:
                return NetworkWorkspaceError(code: .authenticationFailed, stage: stage, retryable: false, safeDetail: "SMB credentials were rejected.")
            case .noSuchFile, .objectNameNotFound, .objectPathNotFound:
                return NetworkWorkspaceError(code: .notFound, stage: stage, retryable: false, safeDetail: "The SMB path does not exist.")
            case .objectNameCollision, .sharingViolation, .deletePending:
                return NetworkWorkspaceError(code: .conflict, stage: stage, retryable: false, safeDetail: "The SMB item changed or is in use.")
            case .ioTimeout:
                return NetworkWorkspaceError(code: .timedOut, stage: stage, retryable: true, safeDetail: "The SMB2 operation timed out.")
            case .connectionRefused, .networkNameDeleted, .networkSessionExpired:
                return NetworkWorkspaceError(code: .networkUnreachable, stage: stage, retryable: true, safeDetail: "The SMB2 server or session is unavailable.")
            case .badNetworkName:
                return NetworkWorkspaceError(code: .remoteRejected, stage: stage, retryable: false, safeDetail: "The SMB share name was rejected.")
            case .notSupported, .notImplemented, .invalidSMB:
                return NetworkWorkspaceError(code: .unsupported, stage: stage, retryable: false, safeDetail: "The server does not support the required SMB2 operation.")
            default:
                return NetworkWorkspaceError(code: .protocolFailure, stage: stage, retryable: false, safeDetail: "The SMB2 server returned an unsupported status.")
            }
        }
        if let connection = error as? ConnectionError {
            let (detail, retryable): (String, Bool) = switch connection {
            case .cancelled: ("The SMB2 operation was cancelled.", false)
            case .disconnected, .noData: ("The SMB2 connection ended before a response arrived.", true)
            case .unknown: ("The SMB2 connection failed.", true)
            }
            return NetworkWorkspaceError(code: .networkUnreachable, stage: stage, retryable: retryable, safeDetail: detail)
        }
        return NetworkWorkspaceError(code: .protocolFailure, stage: stage, retryable: true, safeDetail: "The SMB2 operation failed and the connection was reset.")
    }
}
