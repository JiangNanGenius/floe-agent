import Foundation
import FloeToolboxCore
import FloeToolboxClients
import FloeToolboxRemoteFiles

public typealias RemoteHTTPHeaders = @Sendable () async throws -> [String:String]
/// Reuses the host's mount/credential owner. Ranged reads are verified; a server ignoring
/// Range cannot turn a large download into an unbounded in-memory response.
public actor WebDAVRemoteFileBackend: RemoteFileBackend {
    public nonisolated let capabilities: Set<RemoteFileCapability> = [.list,.read,.resumeRead,.createDirectory,.rename,.delete]
    private let baseURL: URL
    private let basePath: String
    private let headers: RemoteHTTPHeaders
    private let tls: ClientTLSConfiguration?
    private var closed = false, busy = false
    private var revisions: [RemoteFilePath:String] = [:]
    public init(baseURL: URL,tls: ClientTLSConfiguration? = nil,headers: @escaping RemoteHTTPHeaders = { [:] }) throws {
        _ = try HTTPClientRequest(url:baseURL)
        guard baseURL.query == nil, let path = URLComponents(url:baseURL,resolvingAgainstBaseURL:false)?.percentEncodedPath.removingPercentEncoding,
              !path.contains("\0"), !path.split(separator:"/").contains("..") else { throw RemoteFileError.invalidPath }
        self.baseURL = baseURL; basePath = path.hasSuffix("/") ? path : path+"/"; self.headers = headers; self.tls = tls
    }
    private func check() throws { guard !closed, !Task.isCancelled else { throw RemoteFileError.staleSession } }
    private func url(_ path: RemoteFilePath) throws -> URL {
        _ = try path.validated()
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn:"/?#%"))
        let suffix = try path.value.split(separator:"/").map { segment in guard let value = segment.addingPercentEncoding(withAllowedCharacters:allowed) else { throw RemoteFileError.invalidPath }; return value }.joined(separator:"/")
        guard var components = URLComponents(url:baseURL,resolvingAgainstBaseURL:false) else { throw RemoteFileError.invalidPath }
        let prefix = components.percentEncodedPath.hasSuffix("/") ? components.percentEncodedPath : components.percentEncodedPath+"/"
        components.percentEncodedPath = prefix+suffix
        guard let result = components.url else { throw RemoteFileError.invalidPath }; return result
    }
    private func logicalPath(_ href: String) throws -> RemoteFilePath {
        guard let value = URL(string:href,relativeTo:baseURL)?.absoluteURL,
              value.scheme?.lowercased() == baseURL.scheme?.lowercased(), value.host?.lowercased() == baseURL.host?.lowercased(),
              value.port == baseURL.port, value.user == nil, value.password == nil, value.query == nil, value.fragment == nil,
              let decoded = URLComponents(url:value,resolvingAgainstBaseURL:false)?.percentEncodedPath.removingPercentEncoding,
              decoded == String(basePath.dropLast()) || decoded.hasPrefix(basePath) else { throw RemoteFileError.outsideRoot }
        let suffix = decoded == String(basePath.dropLast()) ? "" : String(decoded.dropFirst(basePath.count))
        return try RemoteFilePath("/"+suffix)
    }
    private func request(_ method: String,path: RemoteFilePath,extra: [String:String] = [:],body: Data? = nil,maximum: Int = 65536,file: URL? = nil) async throws -> HTTPClientReply {
        try check(); var fields = try await headers(); try check()
        for (key,value) in extra { fields = fields.filter { $0.key.caseInsensitiveCompare(key) != .orderedSame }; fields[key] = value }
        let request = try HTTPClientRequest(url:url(path),method:method,headers:fields,body:body,maximumResponseBytes:maximum,timeout:60,redirectPolicy:.none)
        let reply: HTTPClientReply
        if let file { reply = try await HTTPClient.upload(request,file:file,tls:tls) } else { reply = try await HTTPClient.send(request,tls:tls) }
        if closed || Task.isCancelled {
            if ["PUT","MKCOL","MOVE","DELETE"].contains(method), (200..<300).contains(reply.status), reply.status != 207 { throw RemoteFileError.mutationCompletedAfterInvalidation }
            throw RemoteFileError.staleSession
        }
        if [401,403].contains(reply.status) { throw RemoteFileError.authenticationFailed }
        if reply.status == 404 { throw RemoteFileError.notFound }
        if [409,412].contains(reply.status) { throw RemoteFileError.conflict }
        return reply
    }
    private func success(_ reply: HTTPClientReply, _ allowed: Set<Int>) throws { guard allowed.contains(reply.status), !reply.truncated else { throw RemoteFileError.serverStatus(UInt32(clamping:reply.status)) } }
    private func properties(_ path: RemoteFilePath,depth: String) async throws -> [RemoteFileEntry] {
        let xml = Data("<?xml version=\"1.0\" encoding=\"utf-8\"?><d:propfind xmlns:d=\"DAV:\"><d:prop><d:resourcetype/><d:getcontentlength/><d:getetag/><d:getlastmodified/></d:prop></d:propfind>".utf8)
        let reply = try await request("PROPFIND",path:path,extra:["Depth":depth,"Content-Type":"application/xml; charset=utf-8"],body:xml,maximum:8*1024*1024)
        try success(reply,[207]); let parser = DAVPropertiesParser(); let properties = try parser.parse(reply.bytes)
        var entries: [RemoteFileEntry] = [], names: Set<RemoteFilePath> = []
        let date = DateFormatter(); date.locale = Locale(identifier:"en_US_POSIX"); date.timeZone = TimeZone(secondsFromGMT:0); date.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        for item in properties {
            let logical = try logicalPath(item.href); guard names.insert(logical).inserted else { throw RemoteFileError.malformedResponse }
            guard logical == path || depth == "1" && logical.parent == path else { throw RemoteFileError.outsideRoot }
            let etag = item.values["getetag"]; if let etag { guard etag.utf8.count <= 8192 else { throw RemoteFileError.limit }; if revisions.count >= 10000 { revisions.removeAll() }; revisions[logical] = etag }
            let size: UInt64?
            if let raw = item.values["getcontentlength"] { guard let parsed = UInt64(raw) else { throw RemoteFileError.malformedResponse }; size = parsed } else { size = nil }
            entries.append(RemoteFileEntry(path:logical,kind:item.collection ? .directory : .file,revision:RemoteFileRevision(entityTag:etag,byteCount:size,modifiedAt:item.values["getlastmodified"].flatMap(date.date(from:)))))
        }
        return entries
    }
    public func list(_ path: RemoteFilePath) async throws -> [RemoteFileEntry] {
        guard !busy else { throw RemoteFileError.busy }; busy = true; defer { busy = false }
        return try await properties(path,depth:"1").filter { $0.path != path }
    }
    public func metadata(_ path: RemoteFilePath) async throws -> RemoteFileEntry {
        guard !busy else { throw RemoteFileError.busy }; busy = true; defer { busy = false }
        guard let result = try await properties(path,depth:"0").first(where:{$0.path == path}) else { throw RemoteFileError.notFound }; return result
    }
    public func read(_ path: RemoteFilePath,offset: UInt64,maximumBytes: Int) async throws -> Data {
        guard !busy, (1...1024*1024).contains(maximumBytes), offset <= UInt64.max-UInt64(maximumBytes) else { throw RemoteFileError.limit }; busy = true; defer { busy = false }
        var fields = ["Range":"bytes=\(offset)-\(offset+UInt64(maximumBytes)-1)","Accept-Encoding":"identity"]
        if let revision = revisions[path] { fields["If-Match"] = revision }
        let reply = try await request("GET",path:path,extra:fields,maximum:maximumBytes)
        let headers = reply.headers.reduce(into:[String:String]()) { $0[$1.key.lowercased()] = $1.value }
        if reply.status == 416, headers["content-range"] == "bytes */\(offset)" { return Data() }
        if reply.status == 200 { guard offset == 0 else { throw RemoteFileError.malformedResponse }; return reply.bytes }
        try success(reply,[206])
        guard let range = headers["content-range"], range.hasPrefix("bytes "), let slash = range.firstIndex(of:"/") else { throw RemoteFileError.malformedResponse }
        let bounds = range[range.index(range.startIndex,offsetBy:6)..<slash].split(separator:"-",omittingEmptySubsequences:false)
        guard bounds.count == 2, let start = UInt64(bounds[0]), let end = UInt64(bounds[1]), start == offset, end >= start,
              end-start < UInt64(maximumBytes), end-start+1 == UInt64(reply.bytes.count),
              headers["content-encoding"].map({$0.lowercased() == "identity"}) ?? true else { throw RemoteFileError.malformedResponse }
        return reply.bytes
    }
    public func write(_ path: RemoteFilePath,offset: UInt64,bytes: Data,createExclusive: Bool) throws { throw RemoteFileError.unsupported }
    /// Whole-file PUT is streamed from the host's protected, immutable staging file. A new
    /// resource uses If-None-Match; save-back uses a strong ETag and fails on conflicts.
    public func uploadFile(_ file: URL,to path: RemoteFilePath,expectedETag: String? = nil,createExclusive: Bool = true) async throws {
        guard !busy, expectedETag == nil || !createExclusive, expectedETag?.hasPrefix("W/") != true else { throw RemoteFileError.conflict }; busy = true; defer { busy = false }
        guard createExclusive || expectedETag != nil else { throw RemoteFileError.conflict }
        var fields = ["Content-Type":"application/octet-stream"]
        if createExclusive { fields["If-None-Match"] = "*" } else if let expectedETag { fields["If-Match"] = expectedETag }
        let reply = try await request("PUT",path:path,extra:fields,maximum:65536,file:file); try success(reply,[200,201,204]); revisions.removeValue(forKey:path)
    }
    public func createDirectory(_ path: RemoteFilePath) async throws { guard !busy else { throw RemoteFileError.busy }; busy = true; defer { busy = false }; try success(try await request("MKCOL",path:path),[201]) }
    public func rename(_ source: RemoteFilePath,to destination: RemoteFilePath,replace: Bool) async throws {
        guard !busy, !replace else { throw RemoteFileError.unsupported }; busy = true; defer { busy = false }
        let reply = try await request("MOVE",path:source,extra:["Destination":try url(destination).absoluteString,"Overwrite":"F"]); try success(reply,[201,204]); revisions.removeValue(forKey:source); revisions.removeValue(forKey:destination)
    }
    public func delete(_ path: RemoteFilePath,directory: Bool) async throws { guard !busy, path.value != "/" else { throw RemoteFileError.busy }; busy = true; defer { busy = false }; try success(try await request("DELETE",path:path),[200,204]); revisions.removeValue(forKey:path) }
    public func resolve(_ path: RemoteFilePath) throws -> RemoteFilePath { throw RemoteFileError.unsupported }
    public func close() { closed = true; revisions.removeAll() }
}
private struct DAVProperties { var href = ""; var values: [String:String] = [:]; var collection = false; var valid = false }
private final class DAVPropertiesParser: NSObject,XMLParserDelegate {
    var results: [DAVProperties] = [], current: DAVProperties?, properties: [String:String] = [:]
    var stack: [String] = [], text = "", status = "", collection = false, totalElements = 0, failed = false
    func parse(_ bytes: Data) throws -> [DAVProperties] {
        guard bytes.count <= 8*1024*1024, let utf8 = String(data:bytes,encoding:.utf8),
              !utf8.uppercased().contains("<!DOCTYPE"), !utf8.uppercased().contains("<!ENTITY") else { throw RemoteFileError.malformedResponse }
        let parser = XMLParser(data:bytes); parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false; parser.delegate = self
        guard parser.parse(), !failed, stack.isEmpty, current == nil else { throw RemoteFileError.malformedResponse }; return results
    }
    func parser(_ parser: XMLParser,didStartElement name: String,namespaceURI: String?,qualifiedName: String?,attributes: [String:String] = [:]) {
        totalElements += 1; stack.append(name); text = ""
        guard stack.count <= 64, totalElements <= 200000, namespaceURI == "DAV:" else { failed = true; parser.abortParsing(); return }
        if name == "response" { guard current == nil, results.count < 10001 else { failed = true; parser.abortParsing(); return }; current = DAVProperties() }
        if name == "propstat" { properties = [:]; status = ""; collection = false }
        if name == "collection" { collection = true }
    }
    func parser(_ parser: XMLParser,foundCharacters string: String) { guard text.utf8.count+string.utf8.count <= 32768 else { failed = true; parser.abortParsing(); return }; text += string }
    func parser(_ parser: XMLParser,didEndElement name: String,namespaceURI: String?,qualifiedName: String?) {
        guard stack.last == name else { failed = true; parser.abortParsing(); return }
        let value = text.trimmingCharacters(in:.whitespacesAndNewlines)
        if name == "href" { current?.href = value }
        else if name == "status" { status = value }
        else if ["getetag","getcontentlength","getlastmodified"].contains(name) { properties[name] = value }
        else if name == "propstat", status.split(separator:" ").dropFirst().first == "200" { current?.values.merge(properties) { _,new in new }; current?.collection = collection; current?.valid = true }
        else if name == "response", let current { if current.href.isEmpty || !current.valid { failed = true; parser.abortParsing() } else { results.append(current) }; self.current = nil }
        stack.removeLast(); text = ""
    }
}
