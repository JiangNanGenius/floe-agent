import Crypto
import Foundation
import FloeCore
import FloeTools

public struct WebFetchTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var url: String
        public var maxCharacters: Int?
        public var timeout: Double?
        public var localNetwork: Bool?
        /// text (default readable extraction), markdown, html or json.
        public var format: String?
        /// default | inherit | desktop | mobile | custom.
        public var userAgent: String?
        public var customUserAgent: String?
        /// Optional JSON object of bounded request headers.
        public var headers: String?
        /// default | revalidate | reload.
        public var cachePolicy: String?
        /// none (default) | browser | transient.
        public var cookieContext: String?
        /// Optional JSON array of transient cookie objects.
        public var cookies: String?
        /// Character offset for long-output paging.
        public var startCharacter: Int?

        public init(
            url: String,
            maxCharacters: Int? = nil,
            timeout: Double? = nil,
            localNetwork: Bool? = nil,
            format: String? = nil,
            userAgent: String? = nil,
            customUserAgent: String? = nil,
            headers: String? = nil,
            cachePolicy: String? = nil,
            cookieContext: String? = nil,
            cookies: String? = nil,
            startCharacter: Int? = nil
        ) {
            self.url = url
            self.maxCharacters = maxCharacters
            self.timeout = timeout
            self.localNetwork = localNetwork
            self.format = format
            self.userAgent = userAgent
            self.customUserAgent = customUserAgent
            self.headers = headers
            self.cachePolicy = cachePolicy
            self.cookieContext = cookieContext
            self.cookies = cookies
            self.startCharacter = startCharacter
        }
    }

    public static let name = "web.fetch"
    public static let toolDescription =
        "Fetch readable HTML, JSON or text without opening the browser. Prefer this over network.http when the goal is reading page content. Public targets require HTTPS; set localNetwork=true only for a user-requested LAN diagnostic. Every redirect is revalidated; credential URLs and metadata endpoints are blocked. Optional browser cookie context is limited to the active task-browser origin and requires the model recipient to be authorized. Use transient cookies only when the user supplied them. Returns real status, final URL, content type, format, paging offset and a browserFallback reason for binary, interactive or insufficient content."
    public static let parametersJSON = #"""
    {"type":"object","properties":{
      "url":{"type":"string","description":"HTTPS URL, or local HTTP URL for user-requested diagnostics"},
      "localNetwork":{"type":"boolean","description":"Enable only for a local-network target requested by the user"},
      "maxCharacters":{"type":"integer","minimum":1000,"maximum":200000},
      "startCharacter":{"type":"integer","minimum":0,"maximum":10000000,"description":"Start offset into the extracted output for long pages"},
      "format":{"type":"string","enum":["text","markdown","html","json"],"description":"Output format; text is readable extraction, html is raw response HTML"},
      "userAgent":{"type":"string","enum":["default","inherit","desktop","mobile","custom"],"description":"inherit uses the active browser tab UA when browser cookies are requested"},
      "customUserAgent":{"type":"string","maxLength":1024},
      "headers":{"type":"string","description":"Optional JSON object of bounded request headers; Cookie and User-Agent belong in dedicated fields"},
      "cachePolicy":{"type":"string","enum":["default","revalidate","reload"]},
      "cookieContext":{"type":"string","enum":["none","browser","transient"],"description":"browser reuses the active task-browser origin cookies; transient uses the cookies field"},
      "cookies":{"type":"string","description":"JSON array of transient cookie objects: name,value,domain,path,secure,httpOnly,expiresAt,sameSite"},
      "timeout":{"type":"number","minimum":1,"maximum":120}
    },"required":["url"],"additionalProperties":false}
    """#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess]
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly

    private let service: HTTPRequestService
    public init(service: HTTPRequestService = HTTPRequestService()) { self.service = service }

    private static let desktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    private static let mobileUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    private enum OutputFormat: String {
        case text, markdown, html, json
    }

    public func validate(_ args: Arguments) throws {
        guard let url = URL(string: args.url) else {
            throw FloeError.validationFailed("url must be a valid HTTP or HTTPS URL")
        }
        if args.localNetwork == true { try DiagnosticNetworkTargetPolicy.validate(url) }
        else { try PublicNetworkTargetPolicy.validate(url) }
        if let format = args.format, OutputFormat(rawValue: format.lowercased()) == nil {
            throw FloeError.validationFailed("format must be text, markdown, html or json")
        }
        if let maxCharacters = args.maxCharacters, !(1_000...200_000).contains(maxCharacters) {
            throw FloeError.validationFailed("maxCharacters must be between 1000 and 200000")
        }
        if let start = args.startCharacter, !(0...10_000_000).contains(start) {
            throw FloeError.validationFailed("startCharacter is out of bounds")
        }
        if let mode = args.userAgent?.lowercased(),
           !["default", "inherit", "desktop", "mobile", "custom"].contains(mode) {
            throw FloeError.validationFailed("Unknown userAgent mode")
        }
        if args.userAgent?.lowercased() == "custom" {
            guard let custom = args.customUserAgent,
                  !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  custom.utf8.count <= 1_024 else {
                throw FloeError.validationFailed("customUserAgent is required for userAgent=custom")
            }
        }
        let context = args.cookieContext?.lowercased() ?? "none"
        guard ["none", "browser", "transient"].contains(context) else {
            throw FloeError.validationFailed("cookieContext must be none, browser or transient")
        }
        if context == "transient" {
            guard args.cookies?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw FloeError.validationFailed("cookieContext=transient requires cookies")
            }
        }
        if context == "browser", args.cookies?.isEmpty == false {
            throw FloeError.validationFailed("Use either browser cookie context or explicit transient cookies")
        }
        _ = try Self.parseHeaders(args.headers)
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        guard let url = URL(string: args.url) else { throw FloeError.validationFailed("invalid URL") }
        // Per-run boundary (temporary chat is public-web-only): refuse the
        // LAN opt-in and every non-public target here even when ordinary
        // policy would allow them. The public transport revalidates every
        // redirect through the same policy, so DNS/redirect rebinding cannot
        // widen the boundary mid-request.
        if context.publicWebOnly {
            guard args.localNetwork != true else {
                throw FloeError.validationFailed("Temporary chats can only fetch public web targets")
            }
            try PublicNetworkTargetPolicy.validate(url)
        } else if args.localNetwork == true {
            try DiagnosticNetworkTargetPolicy.validate(url)
        } else {
            try PublicNetworkTargetPolicy.validate(url)
        }
        let headers = try Self.parseHeaders(args.headers)
        let outputFormat = OutputFormat(rawValue: (args.format ?? "text").lowercased()) ?? .text

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
        if context.temporaryReadOnly || context.publicWebOnly {
            // The approved temporary/public-web ceiling is public retrieval
            // only. Explicit transient cookies are still private credentials;
            // they are not a loophole around the browser-context check below.
            guard cookieMode == "none" else {
                throw FloeError.validationFailed(
                    "Temporary chats cannot use explicit or browser cookies"
                )
            }
        }
        var browserContext = BrowserWebContext()
        if cookieMode == "browser" {
            guard !context.temporaryReadOnly, !context.publicWebOnly else {
                throw FloeError.validationFailed("Temporary chats cannot use browser cookies")
            }
            guard let conversationID = context.conversationID else {
                throw FloeError.validationFailed("Browser cookie context requires a task-owned browser")
            }
            browserContext = try await BrowserCookieProviderRegistry.shared.context(
                for: url,
                conversationID: conversationID,
                runID: context.runID
            )
        }
        let cookies: [HTTPCookieSnapshot]
        if cookieMode == "transient" {
            cookies = try HTTPCookieInputParser.parse(args.cookies, for: url)
        } else {
            cookies = browserContext.cookies
        }
        let userAgent = try Self.resolveUserAgent(
            args.userAgent,
            custom: args.customUserAgent,
            browserUserAgent: browserContext.userAgent
        )

        let traceID = UUID().uuidString
        let startedAt = Date()
        let maxCharacters = max(1_000, min(args.maxCharacters ?? 80_000, 200_000))
        let startCharacter = max(0, min(args.startCharacter ?? 0, 10_000_000))
        FloeLogger(category: .tools).info(
            "webFetchStarted trace=\(traceID) host=\(url.host ?? "none") maxCharacters=\(maxCharacters) timeoutSeconds=\(Int(args.timeout ?? 30)) cookies=\(cookies.count) format=\(outputFormat.rawValue)"
        )
        let response: HTTPResponse
        do {
            let transport = args.localNetwork == true ? HTTPRequestService(allowsPrivateNetwork: true) : service
            response = try await transport.send(
                method: "GET",
                url: url,
                headers: headers.merging(["Accept": "text/html,application/json,text/plain,application/pdf,image/*"], uniquingKeysWith: { current, _ in current }),
                body: nil,
                timeout: args.timeout ?? 30,
                maxResponseBytes: min(
                    HTTPRequestService.maximumResponseBytes,
                    max(8_192, maxCharacters * 8 + 16_384)
                ),
                cachePolicy: HTTPCachePolicy.parse(args.cachePolicy),
                cookies: cookies,
                userAgent: userAgent
            )
        } catch {
            let nsError = error as NSError
            FloeLogger(category: .tools).warning(
                "webFetchFailed trace=\(traceID) host=\(url.host ?? "none") domain=\(nsError.domain) code=\(nsError.code) durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1_000))"
            )
            throw error
        }
        try context.cancellation.throwIfCancelled()
        if cookieMode == "browser" {
            try await BrowserCookieProviderRegistry.shared.revalidate(
                browserContext,
                conversationID: context.conversationID,
                runID: context.runID
            )
        }

        let rendered = Self.render(
            response,
            format: outputFormat,
            baseURL: URL(string: response.finalURL ?? url.absoluteString)
        )
        let total = rendered.count
        let pageStart = min(startCharacter, total)
        let returned = String(rendered.dropFirst(pageStart).prefix(maxCharacters))
        let nextStart = pageStart + returned.count < total ? pageStart + returned.count : nil
        let binary = Self.isBinary(response.contentType)
        let lower = rendered.lowercased()
        let fallback: String? = binary ? "binary_use_browser_download"
            : lower.contains("enable javascript") || lower.contains("sign in to continue")
                ? "page_may_require_browser_interaction"
                : nil
        let title = Self.extractTitle(response.body)
        FloeLogger(category: .tools).info(
            "webFetchFinished trace=\(traceID) host=\(url.host ?? "none") status=\(response.statusCode) contentType=\(String(response.contentType.prefix(80))) characters=\(total) returned=\(returned.count) truncated=\(response.truncated) fallback=\(fallback ?? "none") durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1_000))"
        )

        var payload: [String: Any] = [
            "url": response.finalURL ?? url.absoluteString,
            "statusCode": response.statusCode,
            "contentType": response.contentType,
            "format": outputFormat.rawValue,
            "truncated": response.truncated || nextStart != nil,
            "totalCharacters": total,
            "returnedCharacters": returned.count,
            "browserFallback": fallback ?? "",
            "title": title ?? "",
            "text": binary ? "" : returned
        ]
        if let nextStart { payload["nextStartCharacter"] = nextStart }
        if !cookies.isEmpty { payload["cookieCount"] = cookies.count }
        if let origin = browserContext.origin { payload["cookieOrigin"] = origin }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let summary = String(decoding: data, as: UTF8.self)
        let digest = FloeDigest.sha256Hex(data)
        let capture = !binary && rendered.count > returned.count
            ? String(rendered.prefix(262_144))
            : nil
        return ToolExecutionOutput(
            summary: summary,
            fullOutputSHA256: digest,
            exitStatus: (200...399).contains(response.statusCode) ? 0 : 22,
            maximumSummaryCharacters: 262_144,
            capturedOutput: capture,
            capturedOutputTruncated: rendered.count > 262_144
        )
    }

    // MARK: - Request helpers

    static func parseHeaders(_ raw: String?) throws -> [String: String] {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        guard raw.utf8.count <= 8 * 1_024,
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: String] else {
            throw FloeError.validationFailed("headers must be a JSON object of string pairs")
        }
        guard dictionary.count <= 24 else {
            throw FloeError.validationFailed("At most 24 request headers are allowed")
        }
        var result: [String: String] = [:]
        for (name, value) in dictionary {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = trimmed.lowercased()
            guard !trimmed.isEmpty,
                  PublicNetworkTargetPolicy.isAllowedHeader(trimmed),
                  lower != "set-cookie",
                  value.utf8.count <= 4_096,
                  !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
                throw FloeError.validationFailed("Request header is not allowed or is unbounded: \(trimmed)")
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
        case "default":
            return nil
        case "inherit":
            return browserUserAgent
        case "desktop":
            return desktopUserAgent
        case "mobile":
            return mobileUserAgent
        case "custom":
            guard let custom, !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FloeError.validationFailed("customUserAgent is required")
            }
            return custom
        default:
            throw FloeError.validationFailed("Unknown userAgent mode")
        }
    }

    // MARK: - Rendering

    private static func render(
        _ response: HTTPResponse,
        format: OutputFormat,
        baseURL: URL?
    ) -> String {
        let isHTML = response.contentType.lowercased().contains("html")
            || response.body.localizedCaseInsensitiveContains("<html")
        switch format {
        case .html:
            return response.body
        case .json:
            return response.body
        case .text:
            guard isHTML else { return response.body }
            return extract(response.body, contentType: response.contentType)
        case .markdown:
            guard isHTML else { return response.body }
            return markdown(fromHTML: response.body, baseURL: baseURL)
        }
    }

    private static func isBinary(_ contentType: String) -> Bool {
        let lower = contentType.lowercased()
        return lower.contains("pdf")
            || lower.contains("octet-stream")
            || lower.hasPrefix("image/")
            || lower.contains("zip")
    }

    private static func extractTitle(_ html: String) -> String? {
        guard let range = html.range(of: "<title[^>]*>([\\s\\S]*?)</title>", options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        let raw = String(html[range])
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let decoded = decodeEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return decoded.isEmpty ? nil : String(decoded.prefix(300))
    }

    static func extract(_ source: String, contentType: String) -> String {
        guard contentType.lowercased().contains("html") || source.contains("<html") else { return source }
        var text = source
        for tag in ["script", "style", "noscript", "svg", "template"] {
            text = text.replacingOccurrences(
                of: "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive]
            )
        }
        text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "</(p|div|section|article|li|tr|h[1-6])>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        text = decodeEntities(text)
        return text.replacingOccurrences(of: "[\\t ]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " *\\n *", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func markdown(fromHTML html: String, baseURL: URL?) -> String {
        var text = html
        for tag in ["script", "style", "noscript", "svg", "template"] {
            text = text.replacingOccurrences(
                of: "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive]
            )
        }
        text = text.replacingOccurrences(
            of: "<a\\b[^>]*href\\s*=\\s*[\"']([^\"']+)[\"'][^>]*>([\\s\\S]*?)</a>",
            with: "[$2]($1)",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(
            of: "<img\\b[^>]*alt\\s*=\\s*[\"']([^\"']*)[\"'][^>]*src\\s*=\\s*[\"']([^\"']+)[\"'][^>]*>",
            with: "![$1]($2)",
            options: [.regularExpression, .caseInsensitive]
        )
        for level in 1...6 {
            let prefix = String(repeating: "#", count: level)
            text = text.replacingOccurrences(
                of: "<h\(level)\\b[^>]*>([\\s\\S]*?)</h\(level)>",
                with: "\n\n\(prefix) $1\n\n",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        text = text.replacingOccurrences(of: "<li\\b[^>]*>", with: "\n- ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(
            of: "</(p|div|section|article|tr|ul|ol|blockquote|pre)>",
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(of: "</t[dh]>", with: " | ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = decodeEntities(text)
        text = text.replacingOccurrences(of: "[\\t ]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " *\\n *", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Resolve relative markdown links after tag stripping. A relative URL
        // in a page is meaningful only against the final response URL.
        guard let baseURL else { return text }
        return text.replacingOccurrences(
            of: #"\]\((?!https?://|#|mailto:)([^)]+)\)"#,
            with: "](" + baseURL.absoluteString + "/$1)",
            options: .regularExpression
        )
    }

    private static func decodeEntities(_ source: String) -> String {
        var text = source
        let named = [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&mdash;": "—",
            "&ndash;": "–", "&hellip;": "…"
        ]
        for (entity, value) in named { text = text.replacingOccurrences(of: entity, with: value) }
        guard let regex = try? NSRegularExpression(pattern: "&#(x?[0-9A-Fa-f]+);") else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var replacements: [(Range<String.Index>, String)] = []
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match,
                  let full = Range(match.range, in: text),
                  let valueRange = Range(match.range(at: 1), in: text) else { return }
            let raw = String(text[valueRange])
            let scalarValue: UInt32?
            if raw.lowercased().hasPrefix("x") {
                scalarValue = UInt32(raw.dropFirst(), radix: 16)
            } else {
                scalarValue = UInt32(raw, radix: 10)
            }
            if let scalarValue, let scalar = Unicode.Scalar(scalarValue) {
                replacements.append((full, String(Character(scalar))))
            }
        }
        for (range, value) in replacements.reversed() {
            text.replaceSubrange(range, with: value)
        }
        return text
    }
}
