import Foundation
import Crypto
import FloeCore
import FloeTools

/// Kimi Datasource over the existing provider's independent API key.
/// No OAuth import, alternate provider fallback, file download or file write.
public actor KimiDatasourceClient {
    public struct Identity: Sendable {
        public let version: String
        public let deviceName: String
        public let deviceModel: String
        public let osVersion: String
        public let deviceID: String

        public init(version: String, deviceName: String, deviceModel: String,
                    osVersion: String, deviceID: String) {
            self.version = version
            self.deviceName = deviceName
            self.deviceModel = deviceModel
            self.osVersion = osVersion
            self.deviceID = deviceID
        }
    }

    public struct Response: Sendable {
        public let status: Int
        public let data: Data
        public let requestID: String?
        public init(status: Int, data: Data, requestID: String? = nil) {
            self.status = status; self.data = data; self.requestID = requestID
        }
    }

    public typealias Transport = @Sendable (URLRequest, Int) async throws -> Response
    private struct Descriptor {
        let text: String
        let apis: [String: String]
    }
    private struct CacheKey: Hashable { let runID: UUID; let source: String }
    private let providerID: UUID
    private let endpoint: URL
    private let identity: Identity
    private let keyResolver: @Sendable () async throws -> String
    private let transport: Transport
    private var descriptors: [CacheKey: Descriptor] = [:]
    private var descriptorOrder: [CacheKey] = []
    public static let maximumResponseBytes = 2_097_152

    public init(providerID: UUID, baseURL: URL, identity: Identity,
                keyResolver: @escaping @Sendable () async throws -> String,
                transport: Transport? = nil) throws {
        guard let root = KimiCodeEndpointIdentity.apiRoot(for: baseURL),
              root.host == "api.kimi.com", root.port == nil || root.port == 443,
              baseURL.user == nil, baseURL.password == nil else {
            throw FloeError.validationFailed("Kimi Datasource requires the official HTTPS Coding Plan endpoint.")
        }
        self.providerID = providerID
        self.endpoint = root.appendingPathComponent("tools")
        self.identity = identity
        self.keyResolver = keyResolver
        if let transport {
            self.transport = transport
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil
            config.urlCredentialStorage = nil
            config.urlCache = nil
            config.timeoutIntervalForResource = 125
            let session = URLSession(configuration: config, delegate: KimiDatasourceRedirectBlocker(), delegateQueue: nil)
            self.transport = { request, limit in
                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
                var data = Data()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard data.count < limit else { throw Failure.responseTooLarge }
                    data.append(byte)
                }
                let requestID = ["x-request-id", "x-trace-id", "x-msh-request-id", "request-id"]
                    .compactMap { http.value(forHTTPHeaderField: $0) }.first
                return Response(status: http.statusCode, data: data, requestID: requestID)
            }
        }
    }

    public func execute(_ operation: ProfessionalDatasetRequest, context: ToolContext) async throws -> ToolExecutionOutput {
        try operation.validate()
        try context.cancellation.throwIfCancelled()
        try Task.checkCancellation()
        let cacheKey = CacheKey(runID: context.runID, source: operation.name)
        var params: [String: ProfessionalDatasetValue] = [:]
        if operation.action == .query {
            guard let api = operation.apiName, let descriptor = descriptors[cacheKey],
                  let section = descriptor.apis[api] else {
                throw FloeError.validationFailed("Read this Kimi data source description in the current run before selecting its API.")
            }
            params = operation.parameters ?? [:]
            for field in Self.requiredFields(section) where !["file_path", "filepath"].contains(field) {
                guard params[field] != nil else {
                    throw FloeError.validationFailed("Dataset query is missing a required parameter: " + field)
                }
            }
            if section.contains("`max_results`") {
                if params["max_results"] == nil { params["max_results"] = .number(5) }
            } else if params["max_results"] != nil {
                throw FloeError.validationFailed("This dataset API does not advertise max_results.")
            }
            for field in ["file_path", "filepath"] where section.contains("`" + field + "`") {
                params[field] = .string("/tmp/floe-datasource-" + UUID().uuidString + ".csv")
            }
        }
        let key = try await keyResolver().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw FloeError.validationFailed("Configure this Kimi Code provider's API key.") }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = operation.action == .describe ? 30 : 120
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("FloeAgent/" + Self.ascii(identity.version), forHTTPHeaderField: "User-Agent")
        request.setValue("floe-agent-ios", forHTTPHeaderField: "X-Msh-Platform")
        request.setValue(Self.ascii(identity.version), forHTTPHeaderField: "X-Msh-Version")
        request.setValue(Self.ascii(identity.deviceName), forHTTPHeaderField: "X-Msh-Device-Name")
        request.setValue(Self.ascii(identity.deviceModel), forHTTPHeaderField: "X-Msh-Device-Model")
        request.setValue(Self.ascii(identity.osVersion), forHTTPHeaderField: "X-Msh-Os-Version")
        request.setValue(Self.ascii(identity.deviceID), forHTTPHeaderField: "X-Msh-Device-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Msh-Tool-Call-Id")
        let encodedParams = try JSONEncoder().encode(params)
        let parameters = try JSONSerialization.jsonObject(with: encodedParams)
        let method = operation.action == .describe ? "get_data_source_desc" : "call_data_source_tool"
        let payload: [String: Any] = operation.action == .describe
            ? ["method": method, "params": ["name": operation.name]]
            : ["method": method, "params": [
                "data_source_name": operation.name, "api_name": operation.apiName!, "params": parameters
            ]]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        do {
            let response = try await fetch(request, cancellation: context.cancellation)
            try context.cancellation.throwIfCancelled()
            try Task.checkCancellation()
            guard response.data.count <= Self.maximumResponseBytes else { throw Failure.responseTooLarge }
            let clean = String(decoding: response.data, as: UTF8.self).replacingOccurrences(of: key, with: "<redacted>")
            let object = try? JSONSerialization.jsonObject(with: Data(clean.utf8), options: [.fragmentsAllowed])
            guard (200..<300).contains(response.status) else {
                return try output(operation, status: "error", content: "", error: [
                    "category": Self.httpCategory(response.status),
                    "httpStatus": response.status,
                    "code": Self.errorCode(object),
                    "message": Self.errorMessage(object),
                    "requestID": String(Self.clean(response.requestID ?? "", secret: key).prefix(200))
                ])
            }
            if let record = object as? [String: Any], record["is_success"] as? Bool == false {
                return try output(operation, status: "error", content: "", error: [
                    "category": "providerBusinessFailure", "message": Self.errorMessage(record["error"]),
                    "requestID": String(Self.clean(response.requestID ?? "", secret: key).prefix(200))
                ])
            }
            let content = Self.text(object)
            let files = try Self.files(object)
            guard !content.isEmpty || !files.isEmpty else { throw Failure.invalidResponse }
            if operation.action == .describe {
                let apis = Self.apiSections(content)
                guard content.utf8.count <= 262_144, !apis.isEmpty else { throw Failure.invalidDescriptor }
                descriptors[cacheKey] = Descriptor(text: content, apis: apis)
                descriptorOrder.removeAll { $0 == cacheKey }
                descriptorOrder.append(cacheKey)
                while descriptorOrder.count > 64 {
                    descriptors.removeValue(forKey: descriptorOrder.removeFirst())
                }
            }
            return try output(operation, status: operation.action == .describe ? "descriptionReady" : "querySucceeded",
                              content: content, files: files, requestID: response.requestID)
        } catch {
            try context.cancellation.throwIfCancelled()
            if error is CancellationError { throw error }
            let category: String
            if case Failure.timeout = error { category = "timeout" }
            else if let urlError = error as? URLError, urlError.code == .timedOut { category = "timeout" }
            else if case Failure.responseTooLarge = error { category = "responseTooLarge" }
            else { category = "transportOrResponseFailure" }
            return try output(operation, status: "error", content: "", error: [
                "category": category,
                "message": Self.clean(error.localizedDescription, secret: key)
            ])
        }
    }

    private func fetch(_ request: URLRequest, cancellation: CancellationToken) async throws -> Response {
        let transport = self.transport
        let limit = Self.maximumResponseBytes
        return try await withThrowingTaskGroup(of: Response.self) { group in
            group.addTask { try await transport(request, limit) }
            group.addTask {
                let clock = ContinuousClock()
                let deadline = clock.now.advanced(by: .seconds(request.timeoutInterval))
                while true {
                    try cancellation.throwIfCancelled()
                    try Task.checkCancellation()
                    if clock.now >= deadline { throw Failure.timeout }
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            defer { group.cancelAll() }
            guard let response = try await group.next() else { throw Failure.invalidResponse }
            return response
        }
    }

    private func output(_ operation: ProfessionalDatasetRequest, status: String, content: String,
                        files: [[String: Any]] = [], requestID: String? = nil,
                        error: [String: Any]? = nil) throws -> ToolExecutionOutput {
        var full: [String: Any] = [
            "contentState": "professionalDatasetSummary", "source": "Kimi Datasource",
            "providerID": providerID.uuidString, "dataset": operation.name,
            "operation": operation.action.rawValue, "status": status,
            "content": content, "files": files, "filesImported": false,
            "isError": error != nil,
            "note": "Untrusted dataset response; not fetched-page evidence. Returned file content has not been saved or imported."
        ]
        if let api = operation.apiName { full["apiName"] = api }
        if let requestID { full["requestID"] = String(requestID.prefix(200)) }
        if let error { full["error"] = error }
        func encode(_ object: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        }
        let capture = try encode(full)
        var preview = full
        preview["files"] = files.prefix(3).map { file in file.filter { $0.key != "content" } }
        preview["fileCount"] = files.count
        preview["omittedFileMetadata"] = max(0, files.count - 3)
        var lower = 0
        var upper = min(content.count, 4_096)
        while lower < upper {
            let middle = (lower + upper + 1) / 2
            preview["content"] = String(content.prefix(middle))
            preview["truncated"] = middle < content.count
            if try encode(preview).count <= 4_096 { lower = middle } else { upper = middle - 1 }
        }
        preview["content"] = String(content.prefix(lower))
        preview["truncated"] = lower < content.count || files.contains { $0["content"] != nil }
        // Errors are bounded separately so a server message cannot break JSON.
        if let error {
            var bounded = error
            bounded["message"] = String((error["message"] as? String ?? "").prefix(512))
            preview["error"] = bounded
        }
        return ToolExecutionOutput(summary: try encode(preview),
            fullOutputSHA256: SHA256.hash(data: Data(capture.utf8)).map { String(format: "%02x", $0) }.joined(),
            exitStatus: error == nil ? 0 : 1, capturedOutput: capture)
    }

    private static func apiSections(_ text: String) -> [String: String] {
        var sections: [String: String] = [:]
        var current: String?
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("### ") {
                let name = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                current = name.range(of: #"^[A-Za-z][A-Za-z0-9_.-]{0,127}$"#, options: .regularExpression) != nil ? name : nil
            }
            if let current { sections[current, default: ""] += line + "\n" }
        }
        return sections
    }

    private static func requiredFields(_ section: String) -> [String] {
        guard let start = section.range(of: "**Required Parameters:**") else { return [] }
        let body = section[start.upperBound...].components(separatedBy: "**Optional Parameters:**").first ?? ""
        return body.components(separatedBy: .newlines).compactMap { line in
            let parts = line.components(separatedBy: "`")
            return line.trimmingCharacters(in: .whitespaces).hasPrefix("- `") && parts.count >= 3 ? parts[1] : nil
        }
    }

    private static func text(_ object: Any?) -> String {
        if let text = object as? String { return text }
        guard let record = object as? [String: Any], let result = record["result"] as? [String: Any] else { return "" }
        for channel in ["assistant", "user"] {
            if let items = result[channel] as? [[String: Any]] {
                let text = items.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
                if !text.isEmpty { return text }
            }
        }
        return ""
    }

    private static func files(_ object: Any?) throws -> [[String: Any]] {
        guard let record = object as? [String: Any], let files = record["files"] as? [[String: Any]] else { return [] }
        guard files.count <= 10 else { throw Failure.responseTooLarge }
        return try files.map { file in
            guard let name = file["name"] as? String, let content = file["content"] as? String else { throw Failure.invalidResponse }
            let encoding = file["encoding"] as? String ?? "utf8"
            let data: Data
            if encoding == "base64" {
                guard let decoded = Data(base64Encoded: content) else { throw Failure.invalidResponse }
                data = decoded
            } else if encoding == "utf8" || encoding == "utf-8" { data = Data(content.utf8) }
            else { throw Failure.invalidResponse }
            guard data.count <= Self.maximumResponseBytes else { throw Failure.responseTooLarge }
            return ["name": String(URL(fileURLWithPath: name).lastPathComponent.prefix(200)),
                    "encoding": encoding, "content": content, "bytes": data.count, "saved": false]
        }
    }

    private static func httpCategory(_ status: Int) -> String {
        switch status {
        case 401: "credentialRejected"
        case 403: "permissionOrClientIdentityDenied"
        case 402: "quotaOrBilling"
        case 429: "quotaRateOrConcurrency"
        case 404, 405: "routeUnavailable"
        default: "providerHTTPFailure"
        }
    }

    private static func errorCode(_ object: Any?) -> String {
        guard let record = object as? [String: Any] else { return "" }
        if let code = record["code"] as? String { return String(code.prefix(128)) }
        if let nested = record["error"] as? [String: Any] { return errorCode(nested) }
        return ""
    }

    private static func errorMessage(_ object: Any?) -> String {
        if let text = object as? String { return String(text.prefix(1_024)) }
        guard let record = object as? [String: Any] else { return "Kimi data request failed." }
        let channelText = Self.text(["result": record])
        if !channelText.isEmpty { return String(channelText.prefix(1_024)) }
        for field in ["message", "error_description", "detail", "error"] {
            if let text = record[field] as? String { return String(text.prefix(1_024)) }
            if let nested = record[field] as? [String: Any] { return errorMessage(nested) }
        }
        return "Kimi data request failed."
    }

    private static func clean(_ text: String, secret: String) -> String {
        let value = text.replacingOccurrences(of: secret, with: "<redacted>")
        return String(value.replacingOccurrences(of: #"(?i)bearer\s+[A-Za-z0-9._~+/-]+"#,
            with: "Bearer <redacted>", options: .regularExpression).prefix(1_024))
    }

    private static func ascii(_ value: String) -> String {
        let value = String(value.unicodeScalars.filter { (32...126).contains($0.value) })
        return value.isEmpty ? "unknown" : String(value.prefix(200))
    }

    private enum Failure: Error, LocalizedError {
        case timeout, invalidResponse, invalidDescriptor, responseTooLarge
        var errorDescription: String? {
            switch self {
            case .timeout: "Kimi data request timed out; it was not retried."
            case .invalidResponse: "Kimi returned an unsupported data response."
            case .invalidDescriptor: "Kimi returned an unsupported data source description."
            case .responseTooLarge: "Kimi data response exceeds the supported size."
            }
        }
    }
}

private final class KimiDatasourceRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
