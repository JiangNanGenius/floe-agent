// FloeExecution — network.http agent tool.

import Foundation
import Crypto
import FloeCore
import FloeTools

/// Sends a bounded request (GET/POST/PUT/PATCH/DELETE/HEAD/OPTIONS) to a public HTTPS URL.
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
        /// default | revalidate | reload.
        public var cachePolicy: String?
        /// default | inherit | desktop | mobile | custom.
        public var userAgent: String?
        public var customUserAgent: String?
        /// none (default) | browser | transient.
        public var cookieContext: String?
        /// JSON array of transient cookies.
        public var cookies: String?
        /// Opt into the in-memory per-task cookie jar across calls. Off by default.
        public var stateful: Bool?
        /// Clear the task's stateful jar before this call.
        public var clearStatefulCookies: Bool?

        public init(
            url: String,
            method: String? = nil,
            headers: String? = nil,
            body: String? = nil,
            timeout: Double? = nil,
            maxResponseBytes: Int? = nil,
            localNetwork: Bool? = nil,
            cachePolicy: String? = nil,
            userAgent: String? = nil,
            customUserAgent: String? = nil,
            cookieContext: String? = nil,
            cookies: String? = nil,
            stateful: Bool? = nil,
            clearStatefulCookies: Bool? = nil
        ) {
            self.url = url
            self.method = method
            self.headers = headers
            self.body = body
            self.timeout = timeout
            self.maxResponseBytes = maxResponseBytes
            self.localNetwork = localNetwork
            self.cachePolicy = cachePolicy
            self.userAgent = userAgent
            self.customUserAgent = customUserAgent
            self.cookieContext = cookieContext
            self.cookies = cookies
            self.stateful = stateful
            self.clearStatefulCookies = clearStatefulCookies
        }
    }

    public static let name = "network.http"
    public static let toolDescription =
        "Send a bounded HTTP request with method/headers/body control for APIs, status checks and non-browser HTTP. Public endpoints require HTTPS; set localNetwork for user-requested LAN diagnostics. Every redirect is revalidated and cross-origin credentials are stripped. Cookies are stateless by default. Opt into stateful=true for an in-memory per-task cookie jar that applies Set-Cookie across later calls in this task (temporary chats cannot retain it), or use cookieContext=browser for the active task-browser origin. Browser cookie context and stateful cookies require the active model recipient to be authorized. Returns real status, final URL, selected cache/pagination headers, Set-Cookie metadata (names/attributes only, never values) and a bounded body. When reading page content, prefer web.fetch."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "url": {"type": "string", "description": "HTTPS URL or local HTTP diagnostic endpoint"},
        "localNetwork": {"type": "boolean", "description": "Enable only for a local-network target requested by the user"},
        "method": {"type": "string", "description": "HTTP method: GET (default), POST, PUT, PATCH, DELETE, HEAD, OPTIONS"},
        "headers": {"type": "string", "description": "Optional JSON object of header name/value pairs; use cookies for Cookie values"},
        "body": {"type": "string", "description": "Optional request body (for POST/PUT/PATCH/DELETE)"},
        "timeout": {"type": "number", "description": "Timeout in seconds (default 30, max 120)"},
        "maxResponseBytes": {"type": "integer", "description": "Response body cap in bytes (default 65536, max 1048576)"},
        "cachePolicy": {"type": "string", "enum": ["default", "revalidate", "reload"]},
        "userAgent": {"type": "string", "enum": ["default", "inherit", "desktop", "mobile", "custom"]},
        "customUserAgent": {"type": "string", "maxLength": 1024},
        "cookieContext": {"type": "string", "enum": ["none", "browser", "transient"], "description": "browser reuses the active task-browser origin cookies; transient uses the cookies field"},
        "cookies": {"type": "string", "description": "JSON array of transient cookies: name,value,domain,path,secure,httpOnly,expiresAt,sameSite"},
        "stateful": {"type": "boolean", "description": "Keep Set-Cookie in an in-memory jar for later calls in this task; values are never printed"},
        "clearStatefulCookies": {"type": "boolean", "description": "Clear this task's stateful jar before this call"}
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
        if let maxBytes = args.maxResponseBytes, !(1...HTTPRequestService.maximumResponseBytes).contains(maxBytes) {
            throw FloeError.validationFailed("maxResponseBytes is out of bounds")
        }
        let cookieMode = args.cookieContext?.lowercased() ?? "none"
        guard ["none", "browser", "transient"].contains(cookieMode) else {
            throw FloeError.validationFailed("cookieContext must be none, browser or transient")
        }
        if cookieMode == "transient", args.cookies?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            throw FloeError.validationFailed("cookieContext=transient requires cookies")
        }
        if cookieMode == "browser", args.stateful == true {
            throw FloeError.validationFailed("Use browser cookie context or stateful cookies, not both")
        }
        if cookieMode == "browser", args.cookies?.isEmpty == false {
            throw FloeError.validationFailed("Use browser cookie context or explicit transient cookies, not both")
        }
        if args.stateful != true, args.clearStatefulCookies == true {
            throw FloeError.validationFailed("clearStatefulCookies requires stateful=true")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()

        guard let url = URL(string: args.url) else {
            return Self.output("status=error error=\(HTTPRequestError.invalidURL(args.url).localizedDescription)", exitStatus: 2)
        }
        let headers = try Self.parseHeaders(args.headers)
        let body = args.body?.data(using: .utf8)
        if context.temporaryReadOnly || context.publicWebOnly {
            let credentialHeader = headers.keys.contains {
                ["cookie", "authorization", "proxy-authorization"].contains($0.lowercased())
            }
            guard !credentialHeader else {
                throw FloeError.validationFailed(
                    "Temporary chats cannot send authorization headers"
                )
            }
        }
        let cookieMode = args.cookieContext?.lowercased() ?? "none"
        let taskKey = context.conversationID ?? context.runID

        if context.temporaryReadOnly || context.publicWebOnly {
            guard cookieMode == "none", args.stateful != true else {
                throw FloeError.validationFailed(
                    "Temporary chats cannot retain HTTP cookies; use a stateless public request"
                )
            }
        }

        var browserContext = BrowserWebContext()
        var cookies: [HTTPCookieSnapshot] = []
        if cookieMode == "browser" {
            guard let conversationID = context.conversationID else {
                throw FloeError.validationFailed("Browser cookie context requires a task-owned browser")
            }
            browserContext = try await BrowserCookieProviderRegistry.shared.context(
                for: url,
                conversationID: conversationID,
                runID: context.runID
            )
            cookies = browserContext.cookies
        } else if cookieMode == "transient" {
            cookies = try HTTPCookieInputParser.parse(args.cookies, for: url)
        }

        var statefulCount = 0
        if args.stateful == true {
            if args.clearStatefulCookies == true {
                await HTTPStatefulCookieStore.shared.clear(taskID: taskKey)
            } else {
                cookies.append(contentsOf: await HTTPStatefulCookieStore.shared.cookies(for: taskKey))
            }
            statefulCount = cookies.count
        }
        let userAgent = try Self.resolveUserAgent(
            args.userAgent,
            custom: args.customUserAgent,
            browserUserAgent: browserContext.userAgent
        )

        do {
            let transport = args.localNetwork == true ? HTTPRequestService(allowsPrivateNetwork: true) : service
            let response = try await transport.send(
                method: args.method ?? "GET",
                url: url,
                headers: headers,
                body: body,
                timeout: args.timeout ?? Self.defaultTimeout,
                maxResponseBytes: args.maxResponseBytes ?? Self.defaultMaxResponseBytes,
                cachePolicy: HTTPCachePolicy.parse(args.cachePolicy),
                cookies: cookies,
                userAgent: userAgent
            )
            if cookieMode == "browser" {
                try await BrowserCookieProviderRegistry.shared.revalidate(
                    browserContext,
                    conversationID: context.conversationID,
                    runID: context.runID
                )
            }
            if args.stateful == true {
                statefulCount = await HTTPStatefulCookieStore.shared.merge(
                    response.setCookies,
                    for: taskKey
                )
            }
            var summary = "statusCode=\(response.statusCode) contentType=\(response.contentType) truncated=\(response.truncated)\n"
            if let finalURL = response.finalURL { summary += "finalURL=\(finalURL)\n" }
            summary += "cachePolicy=\(HTTPCachePolicy.parse(args.cachePolicy).rawValue)\n"
            if !cookies.isEmpty { summary += "cookieCount=\(cookies.count)\n" }
            if let origin = browserContext.origin { summary += "cookieOrigin=\(origin)\n" }
            if args.stateful == true { summary += "statefulCookieCount=\(statefulCount)\n" }
            let metadata = try JSONSerialization.data(withJSONObject: response.headers, options: [.sortedKeys])
            summary += "headers=\(String(decoding: metadata, as: UTF8.self))\n"
            if !response.setCookies.isEmpty {
                let names = response.setCookies.map(\.name).sorted()
                summary += "setCookieNames=\(names.joined(separator: ","))\n"
            }
            summary += response.body
            return Self.output(summary, exitStatus: (200...399).contains(response.statusCode) ? 0 : 22)
        } catch let error as HTTPRequestError {
            return Self.output("status=error error=\(error.localizedDescription)", exitStatus: 2)
        } catch {
            return Self.output("status=error error=\(error.localizedDescription)", exitStatus: 2)
        }
    }

    static func parseHeaders(_ raw: String?) throws -> [String: String] {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        guard raw.utf8.count <= 8 * 1_024,
              let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)),
              let dictionary = object as? [String: String] else {
            throw FloeError.validationFailed("headers must be a JSON object of string pairs")
        }
        guard dictionary.count <= 24 else {
            throw FloeError.validationFailed("At most 24 headers are allowed")
        }
        var result: [String: String] = [:]
        for (name, value) in dictionary {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  PublicNetworkTargetPolicy.isAllowedHeader(trimmed),
                  value.utf8.count <= 4_096,
                  !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
                throw FloeError.validationFailed("Header is not allowed or is unbounded: \(trimmed)")
            }
            result[trimmed] = value
        }
        return result
    }

    private static func resolveUserAgent(
        _ mode: String?,
        custom: String?,
        browserUserAgent: String?
    ) throws -> String? {
        switch (mode ?? "default").lowercased() {
        case "default": return nil
        case "inherit": return browserUserAgent
        case "desktop":
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        case "mobile":
            return "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        case "custom":
            guard let custom, !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  custom.utf8.count <= 1_024 else {
                throw FloeError.validationFailed("customUserAgent is required")
            }
            return custom
        default:
            throw FloeError.validationFailed("Unknown userAgent mode")
        }
    }

    private static func output(_ text: String, exitStatus: Int32) -> ToolExecutionOutput {
        return ToolExecutionOutput(digesting: text, exitStatus: exitStatus)
    }
}
