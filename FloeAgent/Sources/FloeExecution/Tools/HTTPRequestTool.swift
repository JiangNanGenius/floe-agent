// FloeExecution — network.http agent tool.

import Foundation
import Crypto
import FloeCore
import FloeTools

/// Sends a bounded request (GET/POST/PUT/DELETE/HEAD) to a public HTTPS URL.
/// Always side-effecting and network-flagged.
public struct HTTPRequestTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var url: String
        public var method: String?
        public var headers: String?
        public var body: String?
        public var timeout: Double?
        public var maxResponseBytes: Int?
        public var localNetwork: Bool?

        public init(
            url: String,
            method: String? = nil,
            headers: String? = nil,
            body: String? = nil,
            timeout: Double? = nil,
            maxResponseBytes: Int? = nil,
            localNetwork: Bool? = nil
        ) {
            self.url = url
            self.method = method
            self.headers = headers
            self.body = body
            self.timeout = timeout
            self.maxResponseBytes = maxResponseBytes
            self.localNetwork = localNetwork
        }
    }

    public static let name = "network.http"
    public static let toolDescription =
        "Send a bounded HTTP request. Public endpoints require HTTPS. Set localNetwork for user-requested LAN diagnostics, including local HTTP. Metadata/link-local endpoints are blocked and every redirect is revalidated."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "url": {"type": "string", "description": "HTTPS URL or local HTTP diagnostic endpoint"},
        "localNetwork": {"type": "boolean", "description": "Enable only for a local-network target requested by the user"},
        "method": {"type": "string", "description": "HTTP method: GET (default), POST, PUT, DELETE, HEAD"},
        "headers": {"type": "string", "description": "Optional JSON object of header name/value pairs"},
        "body": {"type": "string", "description": "Optional request body (for POST/PUT/DELETE)"},
        "timeout": {"type": "number", "description": "Timeout in seconds (default 30, max 120)"},
        "maxResponseBytes": {"type": "integer", "description": "Response body cap in bytes (default 65536, max 262144)"}
      },
      "required": ["url"],
      "additionalProperties": false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess, .sendsDataToProvider]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    static let defaultTimeout: TimeInterval = 30
    static let defaultMaxResponseBytes = 64 * 1024

    private let service: HTTPRequestService

    public init(service: HTTPRequestService = HTTPRequestService()) {
        self.service = service
    }

    public func validate(_ args: Arguments) throws {
        guard let url = URL(string: args.url), !args.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FloeError.validationFailed("url must be a valid http/https URL")
        }
        do {
            if args.localNetwork == true { try DiagnosticNetworkTargetPolicy.validate(url) }
            else { try PublicNetworkTargetPolicy.validate(url) }
        }
        catch { throw FloeError.validationFailed(error.localizedDescription) }
        if let headers = args.headers, !headers.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard (try? JSONSerialization.jsonObject(with: Data(headers.utf8))) is [String: String] else {
                throw FloeError.validationFailed("headers must be a JSON object of string pairs")
            }
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()

        guard let url = URL(string: args.url) else {
            return Self.output("status=error error=\(HTTPRequestError.invalidURL(args.url).localizedDescription)", exitStatus: 2)
        }
        let headers: [String: String] = {
            guard let raw = args.headers,
                  let data = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                return [:]
            }
            return obj
        }()
        let body = args.body?.data(using: .utf8)

        do {
            let transport = args.localNetwork == true ? HTTPRequestService(allowsPrivateNetwork: true) : service
            let response = try await transport.send(
                method: args.method ?? "GET",
                url: url,
                headers: headers,
                body: body,
                timeout: args.timeout ?? Self.defaultTimeout,
                maxResponseBytes: args.maxResponseBytes ?? Self.defaultMaxResponseBytes
            )
            var summary = "statusCode=\(response.statusCode) contentType=\(response.contentType) truncated=\(response.truncated)\n"
            summary += response.body
            return Self.output(summary, exitStatus: 0)
        } catch let error as HTTPRequestError {
            return Self.output("status=error error=\(error.localizedDescription)", exitStatus: 2)
        } catch {
            return Self.output("status=error error=\(error.localizedDescription)", exitStatus: 2)
        }
    }

    private static func output(_ text: String, exitStatus: Int32) -> ToolExecutionOutput {
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return ToolExecutionOutput(summary: text, fullOutputSHA256: digest, exitStatus: exitStatus)
    }
}
