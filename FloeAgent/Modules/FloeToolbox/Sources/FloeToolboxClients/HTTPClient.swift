import Foundation
import Security
import FloeToolboxCore

public enum HTTPRedirectPolicy: Sendable { case sameOrigin, none }
public struct HTTPClientRequest: Sendable {
    public let url: URL
    public let method: String
    public let headers: [String:String]
    public let body: Data?
    public let maximumResponseBytes: Int
    public let timeout: TimeInterval
    public let redirectPolicy: HTTPRedirectPolicy
    public init(url: URL, method: String = "GET", headers: [String:String] = [:], body: Data? = nil,
                maximumResponseBytes: Int = 2*1024*1024, timeout: TimeInterval = 30, redirectPolicy: HTTPRedirectPolicy = .sameOrigin) throws {
        try ClientHTTPValidation.url(url,schemes:["http","https"])
        guard !method.isEmpty, method.utf8.count <= 32, method.utf8.allSatisfy(ClientHTTPValidation.token),
              (1...64*1024*1024).contains(maximumResponseBytes), (body?.count ?? 0) <= 16*1024*1024,
              timeout.isFinite, (0.05...300).contains(timeout) else { throw ClientError.invalidConfiguration }
        try ClientHTTPValidation.headers(headers)
        self.url = url; self.method = method.uppercased(); self.headers = headers; self.body = body
        self.maximumResponseBytes = maximumResponseBytes; self.timeout = timeout; self.redirectPolicy = redirectPolicy
    }
}
public struct HTTPClientReply: Sendable, Equatable {
    public let status: Int
    public let headers: [String:String]
    public let bytes: Data
    public let truncated: Bool
    public let expectedByteCount: Int64?
    public init(status: Int, headers: [String:String], bytes: Data, truncated: Bool = false, expectedByteCount: Int64? = nil) {
        self.status = status; self.headers = headers; self.bytes = bytes; self.truncated = truncated; self.expectedByteCount = expectedByteCount
    }
}
public enum HTTPClientFailure: Error, Sendable { case responseLimit(HTTPClientReply), invalidRedirect }

enum ClientHTTPValidation {
    static func token(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || Array("!#$%&'*+-.^_`|~".utf8).contains(byte)
    }
    static func url(_ url: URL, schemes: Set<String>) throws {
        guard let scheme = url.scheme?.lowercased(), schemes.contains(scheme), let host = url.host,
              !host.isEmpty, host.utf8.count <= 253, url.user == nil, url.password == nil,
              url.fragment == nil, url.absoluteString.utf8.count <= 32768,
              url.port.map({ (1...65535).contains($0) }) ?? true else { throw ClientError.invalidConfiguration }
    }
    static func headers(_ headers: [String:String]) throws {
        guard headers.count <= 128, headers.reduce(0,{ $0+$1.key.utf8.count+$1.value.utf8.count }) <= 65536,
              headers.allSatisfy({ !$0.key.isEmpty && $0.key.utf8.allSatisfy(token) && !$0.value.utf8.contains(where:{ $0 == 13 || $0 == 10 || $0 == 0 }) }),
              !headers.keys.contains(where:{ ["host","content-length","transfer-encoding","connection","upgrade"].contains($0.lowercased()) }) else { throw ClientError.invalidConfiguration }
    }
    static func origin(_ url: URL?) -> String? {
        guard let url, let host = url.host?.lowercased(), let original = url.scheme?.lowercased() else { return nil }
        let scheme = original == "ws" ? "http" : original == "wss" ? "https" : original
        return "\(scheme)://\(host):\(url.port ?? (scheme == "https" ? 443 : 80))"
    }
    static func trust(_ trust: SecTrust, host: String, configuration: ClientTLSConfiguration) -> Bool {
        guard SecTrustSetPolicies(trust,SecPolicyCreateSSL(true,host as CFString)) == errSecSuccess else { return false }
        let roots = configuration.additionalRootCertificates
        if !roots.isEmpty {
            let certificates = roots.compactMap { SecCertificateCreateWithData(nil,$0 as CFData) }
            guard certificates.count == roots.count,
                  SecTrustSetAnchorCertificates(trust,certificates as CFArray) == errSecSuccess,
                  SecTrustSetAnchorCertificatesOnly(trust,false) == errSecSuccess else { return false }
        }
        return SecTrustEvaluateWithError(trust,nil)
    }
}

/// Foundation callbacks only aggregate a bounded response. Cross-origin redirects never inherit auth.
private final class HTTPReplyDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let completion = ClientCompletion<HTTPClientReply>()
    private let lock = NSLock()
    private let request: HTTPClientRequest
    private let tls: ClientTLSConfiguration?
    private var response: HTTPURLResponse?
    private var body = Data()
    private var finished = false
    private var redirects = 0
    init(request: HTTPClientRequest, tls: ClientTLSConfiguration?) { self.request = request; self.tls = tls }
    private func snapshot(truncated: Bool) -> HTTPClientReply {
        let headers = response?.allHeaderFields.reduce(into:[String:String]()) { result,pair in result[String(describing:pair.key)] = String(describing:pair.value) } ?? [:]
        return HTTPClientReply(status:response?.statusCode ?? 0,headers:headers,bytes:body,truncated:truncated,
            expectedByteCount:response.flatMap { $0.expectedContentLength >= 0 ? $0.expectedContentLength : nil })
    }
    private func finish(_ result: Result<HTTPClientReply,any Error>) {
        lock.lock(); guard !finished else { lock.unlock(); return }; finished = true; lock.unlock()
        completion.finish(result)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else { finish(.failure(ClientError.protocolViolation)); completionHandler(.cancel); return }
        lock.lock(); self.response = response
        let headerBytes = response.allHeaderFields.reduce(0) { $0+String(describing:$1.key).utf8.count+String(describing:$1.value).utf8.count }
        let oversize = request.method != "HEAD" && response.expectedContentLength > Int64(request.maximumResponseBytes)
        let partial = snapshot(truncated:true); lock.unlock()
        if headerBytes > 65536 || response.allHeaderFields.count > 128 { finish(.failure(ClientError.tooLarge)); completionHandler(.cancel) }
        else if oversize { finish(.failure(HTTPClientFailure.responseLimit(partial))); completionHandler(.cancel) }
        else { completionHandler(.allow) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); guard !finished else { lock.unlock(); return }
        let remaining = request.maximumResponseBytes-body.count
        body.append(data.prefix(remaining)); let tooLarge = data.count > remaining
        let partial = tooLarge ? snapshot(truncated:true) : nil; lock.unlock()
        if let partial { finish(.failure(HTTPClientFailure.responseLimit(partial))); dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock(); let value = snapshot(truncated:false); let hasResponse = response != nil; lock.unlock()
        if error != nil { finish(.failure(ClientError.networkFailure)) }
        else if hasResponse { finish(.success(value)) }
        else { finish(.failure(ClientError.protocolViolation)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        lock.lock(); redirects += 1; let count = redirects; lock.unlock()
        guard request.redirectPolicy == .sameOrigin, count <= 10, ClientHTTPValidation.origin(newRequest.url) == ClientHTTPValidation.origin(request.url) else {
            finish(.failure(HTTPClientFailure.invalidRedirect)); completionHandler(nil); task.cancel(); return
        }
        completionHandler(newRequest)
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition,URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust, let tls else { completionHandler(.performDefaultHandling,nil); return }
        guard ClientHTTPValidation.trust(trust,host:request.url.host ?? "",configuration:tls) else { completionHandler(.cancelAuthenticationChallenge,nil); return }
        completionHandler(.useCredential,URLCredential(trust:trust))
    }
}

public enum HTTPClient {
    public static func send(_ value: HTTPClientRequest, tls: ClientTLSConfiguration? = nil) async throws -> HTTPClientReply {
        var request = URLRequest(url:value.url,cachePolicy:.reloadIgnoringLocalAndRemoteCacheData,timeoutInterval:value.timeout)
        request.httpMethod = value.method; request.httpBody = value.body
        if let body = value.body { request.setValue(String(body.count),forHTTPHeaderField:"Content-Length") }
        for (key,value) in value.headers { request.setValue(value,forHTTPHeaderField:key) }
        let delegate = HTTPReplyDelegate(request:value,tls:tls), configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = value.timeout; configuration.timeoutIntervalForResource = value.timeout
        let session = URLSession(configuration:configuration,delegate:delegate,delegateQueue:nil)
        let task = session.dataTask(with:request)
        defer { task.cancel(); session.invalidateAndCancel() }
        task.resume()
        return try await withTaskCancellationHandler { try await delegate.completion.wait(seconds:value.timeout) }
            onCancel: { task.cancel(); delegate.completion.finish(.failure(CancellationError())) }
    }
    /// An immutable, host-owned staged file; URLSession streams it rather than aggregating it.
    public static func upload(_ value: HTTPClientRequest, file: URL, tls: ClientTLSConfiguration? = nil) async throws -> HTTPClientReply {
        let resource = try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
        guard file.isFileURL, resource.isRegularFile == true, resource.isSymbolicLink != true, value.body == nil,
              let size = resource.fileSize, size >= 0, UInt64(size) <= 1024*1024*1024*1024 else { throw ClientError.invalidConfiguration }
        var request = URLRequest(url:value.url,cachePolicy:.reloadIgnoringLocalAndRemoteCacheData,timeoutInterval:value.timeout)
        request.httpMethod = value.method
        request.setValue(String(size),forHTTPHeaderField:"Content-Length")
        for (key,value) in value.headers { request.setValue(value,forHTTPHeaderField:key) }
        let delegate = HTTPReplyDelegate(request:value,tls:tls), configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForResource = value.timeout
        let session = URLSession(configuration:configuration,delegate:delegate,delegateQueue:nil), task = session.uploadTask(with:request,fromFile:file)
        defer { task.cancel(); session.invalidateAndCancel() }; task.resume()
        return try await withTaskCancellationHandler { try await delegate.completion.wait(seconds:value.timeout) }
            onCancel: { task.cancel(); delegate.completion.finish(.failure(CancellationError())) }
    }
}

/// User-facing HTTP operations share the same existing serial authorization/journal boundary.
public actor HTTPDebugSession {
    public nonisolated let lease: SessionLease
    public nonisolated let endpoint: SerialEndpoint
    private let origin: String
    private let analysisSession: SerialSession
    private let journal: CaptureJournal
    private let authorize: SerialAuthorizer
    private let redactor: CaptureRedactor
    private var closed = false
    private var active: Task<HTTPClientReply,any Error>?
    private var inFlight = false
    public init(lease: SessionLease, targetURL: URL, journal: CaptureJournal, redactor: CaptureRedactor = CaptureRedactor(), authorize: @escaping SerialAuthorizer) throws {
        guard journal.ownerID == lease.ownerID, journal.captureID == lease.sessionID else { throw ToolboxError.invalid("HTTP owner") }
        try ClientHTTPValidation.url(targetURL,schemes:["http","https"])
        guard let origin = ClientHTTPValidation.origin(targetURL) else { throw ClientError.invalidConfiguration }
        self.origin = origin
        let endpoint = try SerialEndpoint(title:"HTTP",transport:.tcp,host:targetURL.host,port:targetURL.port ?? (targetURL.scheme == "https" ? 443 : 80))
        self.endpoint = endpoint
        analysisSession = try SerialSession(lease:lease,endpoint:endpoint,journal:journal,connection:HTTPAnalysisOnlyConnection(),redactor:redactor,authorize:authorize)
        self.lease = lease; self.journal = journal; self.redactor = redactor; self.authorize = authorize
    }
    public func send(_ request: HTTPClientRequest, expected: SessionLease, tls: ClientTLSConfiguration? = nil) async throws -> HTTPClientReply {
        guard !closed, lease == expected, !Task.isCancelled else { throw ToolboxError.staleSession }
        guard !inFlight else { throw ClientError.busy }
        inFlight = true; defer { inFlight = false; active = nil }
        guard ClientHTTPValidation.origin(request.url) == origin else { throw ClientError.invalidConfiguration }
        let effect: SerialActionEffect = ["GET","HEAD","OPTIONS"].contains(request.method) ? .read : .deviceWrite
        let safeBody = redactor.sanitize(request.body ?? Data(),wireProtocol:.raw)
        var target = URLComponents(url:request.url,resolvingAgainstBaseURL:false); target?.query = nil; target?.fragment = nil
        let summary = request.method+" "+redactor.sanitizeText(target?.string ?? "HTTP")
        guard try await authorize(SerialAuthorizationRequest(lease:lease,endpoint:endpoint,effect:effect,bytes:safeBody.bytes,
            originalByteCount:request.body?.count ?? 0,payloadRedacted:safeBody.redacted,operationSummary:summary)) else { throw ToolboxError.denied }
        guard !closed, !Task.isCancelled else { throw ToolboxError.staleSession }
        var sent = safeBody; sent.direction = .sent; sent.notes = [summary,"Request started; delivery is not yet confirmed"]
        try await journal.append([sent])
        guard !closed, !Task.isCancelled else { throw ToolboxError.staleSession }
        let operation = Task { try await HTTPClient.send(request,tls:tls) }; active = operation
        do {
            let result = try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
            try await record(result)
            guard !closed, !Task.isCancelled else { throw ToolboxError.staleSession }; return result
        } catch HTTPClientFailure.responseLimit(let partial) { try await record(partial); throw HTTPClientFailure.responseLimit(partial) }
        catch {
            if !closed { var failure = redactor.sanitize(Data(),wireProtocol:.raw); failure.direction = .observation; failure.notes = ["HTTP request failed; delivery or response is unconfirmed"]; try? await journal.append([failure]) }
            throw error
        }
    }
    private func record(_ response: HTTPClientReply) async throws {
        var event = redactor.sanitize(response.bytes,wireProtocol:.raw); event.direction = .received
        event.notes = ["HTTP \(response.status)"]+(response.truncated ? ["Response stopped at configured limit"] : [])
        try await journal.append([event])
    }
    public func analyze(question: String, selectedSequences: Set<UInt64>? = nil, expected: SessionLease,
                        provider: any SerialAnalysisProvider) async throws -> SerialAnalysisResult {
        guard !closed, expected == lease else { throw ToolboxError.staleSession }
        return try await analysisSession.analyze(question:question,selectedSequences:selectedSequences,expected:expected,provider:provider)
    }
    public func close() async { closed = true; active?.cancel(); await analysisSession.close() }
}
private struct HTTPAnalysisOnlyConnection: SerialConnection {
    func send(_ bytes: Data) throws { throw ClientError.unsupported }
    func receive(maximumBytes: Int) throws -> Data { throw ClientError.unsupported }
    func close() {}
}
