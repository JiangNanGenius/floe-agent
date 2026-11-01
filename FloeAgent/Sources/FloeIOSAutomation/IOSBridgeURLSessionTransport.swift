// FloeIOSAutomation — bounded loopback HTTP transport.
//
// One ephemeral URLSession per request, no cookies, no cache, no proxy, no
// redirect follow and hard request/response byte caps. The host is always the
// IPv4 loopback literal; this client cannot be pointed at a LAN or remote
// address by a model argument or saved configuration.

import Foundation

public final class IOSBridgeURLSessionTransport: IOSBridgeHTTPTransport, @unchecked Sendable {
    public let maxRequestBytes: Int
    public let maxResponseBytes: Int

    public init(
        maxRequestBytes: Int = IOSBridgeProtocol.maxRequestBodyBytes,
        maxResponseBytes: Int = IOSBridgeProtocol.maxJSONResponseBytes
    ) {
        self.maxRequestBytes = maxRequestBytes
        self.maxResponseBytes = maxResponseBytes
    }

    public func send(
        _ request: IOSBridgeHTTPRequest,
        endpoint: IOSBridgeEndpoint,
        timeout: TimeInterval,
        cancellation: IOSAutomationCancellationToken?
    ) async throws -> IOSBridgeHTTPResponse {
        guard endpoint.host == IOSBridgeEndpoint.loopbackIPv4 else {
            throw IOSBridgeTransportError.invalidEndpoint
        }
        guard timeout > 0, timeout.isFinite else {
            throw IOSBridgeTransportError.invalidRequest("Invalid timeout.")
        }
        guard request.method == "GET" || request.method == "POST" else {
            throw IOSBridgeTransportError.invalidRequest("Only GET and POST are allowed.")
        }
        guard request.path.hasPrefix("/"), request.path.utf8.count <= 2_048,
              !request.path.utf8.contains(where: { $0 < 0x21 || $0 == 0x7F }) else {
            throw IOSBridgeTransportError.invalidRequest("Invalid request path.")
        }
        guard request.body.count <= maxRequestBytes else {
            throw IOSBridgeTransportError.requestTooLarge(request.body.count)
        }
        guard let url = URL(string: request.path, relativeTo: endpoint.baseURL)?.absoluteURL,
              url.scheme == "http",
              url.host == endpoint.host,
              url.port == Int(endpoint.port),
              url.query == nil,
              url.fragment == nil else {
            throw IOSBridgeTransportError.invalidEndpoint
        }
        if cancellation?.isCancelled == true {
            throw IOSBridgeTransportError.cancelled
        }

        var urlRequest = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeout
        )
        urlRequest.httpMethod = request.method
        urlRequest.allowsCellularAccess = false
        urlRequest.allowsExpensiveNetworkAccess = false
        urlRequest.allowsConstrainedNetworkAccess = false
        for (name, value) in request.headers {
            guard Self.isValidHeaderName(name), Self.isValidHeaderValue(value) else {
                throw IOSBridgeTransportError.invalidRequest("Invalid request header.")
            }
            let lowercased = name.lowercased()
            guard lowercased != "host", lowercased != "content-length",
                  lowercased != "connection", lowercased != "proxy-connection" else {
                continue
            }
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        if request.body.isEmpty {
            urlRequest.httpBody = nil
        } else {
            urlRequest.httpBody = request.body
            if urlRequest.value(forHTTPHeaderField: "Content-Type") == nil {
                urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        }
        if cancellation?.isCancelled == true {
            throw IOSBridgeTransportError.cancelled
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.connectionProxyDictionary = [:]
        configuration.waitsForConnectivity = false
        configuration.allowsCellularAccess = false
        configuration.allowsExpensiveNetworkAccess = false
        configuration.allowsConstrainedNetworkAccess = false
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout + 30

        let oneShot = IOSBridgeURLSessionRequest(maxResponseBytes: maxResponseBytes)
        return try await oneShot.run(
            urlRequest,
            configuration: configuration,
            cancellation: cancellation
        )
    }

    private static func isValidHeaderName(_ value: String) -> Bool {
        guard (1...64).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy { byte in
            (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
                || (0x30...0x39).contains(byte)
                || [0x21, 0x23, 0x24, 0x25, 0x26, 0x27, 0x2A, 0x2B, 0x2D, 0x2E,
                    0x5E, 0x5F, 0x60, 0x7C, 0x7E].contains(byte)
        }
    }

    private static func isValidHeaderValue(_ value: String) -> Bool {
        guard value.utf8.count <= 1_024 else { return false }
        return !value.utf8.contains(where: { $0 < 0x20 || $0 == 0x7F })
    }
}

private final class IOSBridgeURLSessionRequest: NSObject, URLSessionDataDelegate,
                                                @unchecked Sendable {
    private let maxResponseBytes: Int
    private let lock = NSLock()
    private var continuation: CheckedContinuation<IOSBridgeHTTPResponse, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var cancellationRegistration: IOSAutomationCancellationRegistration?
    private var response: HTTPURLResponse?
    private var body = Data()
    private var completed = false

    init(maxResponseBytes: Int) {
        self.maxResponseBytes = maxResponseBytes
    }

    func run(
        _ request: URLRequest,
        configuration: URLSessionConfiguration,
        cancellation: IOSAutomationCancellationToken?
    ) async throws -> IOSBridgeHTTPResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            let session = URLSession(
                configuration: configuration,
                delegate: self,
                delegateQueue: nil
            )
            lock.lock()
            self.session = session
            lock.unlock()

            let task = session.dataTask(with: request)
            lock.lock()
            self.task = task
            lock.unlock()

            if let cancellation {
                let registration = cancellation.register { [weak self] in
                    self?.cancelTask()
                }
                lock.lock()
                cancellationRegistration = registration
                let alreadyCancelled = cancellation.isCancelled
                lock.unlock()
                if alreadyCancelled { task.cancel() }
            }
            task.resume()
        }
    }

    private func cancelTask() {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    private func finish(_ result: Result<IOSBridgeHTTPResponse, Error>, cancel: Bool = false) {
        var continuation: CheckedContinuation<IOSBridgeHTTPResponse, Error>?
        var registration: IOSAutomationCancellationRegistration?
        var session: URLSession?
        var taskToCancel: URLSessionDataTask?
        lock.lock()
        if completed {
            lock.unlock()
            return
        }
        completed = true
        continuation = self.continuation
        self.continuation = nil
        registration = cancellationRegistration
        cancellationRegistration = nil
        session = self.session
        self.session = nil
        taskToCancel = cancel ? self.task : nil
        self.task = nil
        self.response = nil
        body = Data()
        lock.unlock()

        registration?.remove()
        taskToCancel?.cancel()
        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }

    private func fail(_ error: IOSBridgeTransportError) {
        finish(.failure(error), cancel: true)
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            fail(.invalidResponse("The response was not HTTP."))
            completionHandler(.cancel)
            return
        }
        let expected = http.expectedContentLength
        if expected > 0, expected > Int64(maxResponseBytes) {
            fail(.responseTooLarge(Int(expected)))
            completionHandler(.cancel)
            return
        }
        lock.lock()
        if !completed { self.response = http }
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        if completed {
            lock.unlock()
            return
        }
        if body.count + data.count > maxResponseBytes {
            lock.unlock()
            fail(.responseTooLarge(body.count + data.count))
            return
        }
        body.append(data)
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
        fail(.redirectRefused)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            lock.lock()
            let alreadyCompleted = completed
            lock.unlock()
            if alreadyCompleted { return }
            fail(Self.map(error))
            return
        }
        lock.lock()
        let http = response
        let data = body
        let alreadyCompleted = completed
        lock.unlock()
        guard !alreadyCompleted else { return }
        guard let http else {
            fail(.invalidResponse("The response head was missing."))
            return
        }
        finish(.success(IOSBridgeHTTPResponse(
            status: http.statusCode,
            headers: http.allHeaderFields.reduce(into: [String: String]()) { result, pair in
                guard let name = pair.key as? String, let value = pair.value as? String else { return }
                result[name] = value
            },
            body: data
        )))
    }

    private static func map(_ error: Error) -> IOSBridgeTransportError {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return .cancelled
            case .timedOut:
                return .timedOut
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                 .notConnectedToInternet, .resourceUnavailable:
                return .unreachable
            case .networkConnectionLost:
                return .connectionLost
            case .appTransportSecurityRequiresSecureConnection,
                 .secureConnectionFailed, .serverCertificateUntrusted,
                 .serverCertificateHasBadDate, .serverCertificateNotYetValid,
                 .serverCertificateHasUnknownRoot:
                return .transportNotPermitted
            default:
                return .invalidResponse(urlError.localizedDescription)
            }
        }
        return .invalidResponse("The URL session failed.")
    }
}
