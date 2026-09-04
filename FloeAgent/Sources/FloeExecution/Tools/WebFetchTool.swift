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
    }

    public static let name = "web.fetch"
    public static let toolDescription =
        "Fetch and extract readable content from a public HTTPS URL without opening the visual browser. Supports bounded HTML, JSON, and text responses. Returns source metadata and a browserFallback reason when the response is PDF/binary, client-rendered, authenticated, interactive, unavailable, or insufficient. Prefer this after web.search; use browser or document tools only for the reported fallback cases."
    public static let parametersJSON = #"""
    {"type":"object","properties":{
      "url":{"type":"string","description":"HTTPS URL, or local HTTP URL for user-requested diagnostics"},
      "localNetwork":{"type":"boolean","description":"Enable only for a local-network target requested by the user"},
      "maxCharacters":{"type":"integer","minimum":1000,"maximum":200000},
      "timeout":{"type":"number","minimum":1,"maximum":120}
    },"required":["url"],"additionalProperties":false}
    """#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess]
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly

    private let service: HTTPRequestService
    public init(service: HTTPRequestService = HTTPRequestService()) { self.service = service }

    public func validate(_ args: Arguments) throws {
        guard let url = URL(string: args.url) else {
            throw FloeError.validationFailed("url must be a public HTTPS URL")
        }
        if args.localNetwork == true { try DiagnosticNetworkTargetPolicy.validate(url) }
        else { try PublicNetworkTargetPolicy.validate(url) }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        guard let url = URL(string: args.url) else { throw FloeError.validationFailed("invalid URL") }
        let traceID = UUID().uuidString
        let startedAt = Date()
        let maxCharacters = max(1_000, min(args.maxCharacters ?? 80_000, 200_000))
        FloeLogger(category: .tools).info(
            "webFetchStarted trace=\(traceID) host=\(url.host ?? "none") maxCharacters=\(maxCharacters) timeoutSeconds=\(Int(args.timeout ?? 30))"
        )
        let response: HTTPResponse
        do {
            let transport = args.localNetwork == true ? HTTPRequestService(allowsPrivateNetwork: true) : service
            response = try await transport.send(
                method: "GET", url: url, headers: ["Accept": "text/html,application/json,text/plain,application/pdf"],
                body: nil, timeout: args.timeout ?? 30,
                maxResponseBytes: min(256 * 1_024, maxCharacters * 4)
            )
        } catch {
            let nsError = error as NSError
            FloeLogger(category: .tools).warning(
                "webFetchFailed trace=\(traceID) host=\(url.host ?? "none") domain=\(nsError.domain) code=\(nsError.code) durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1_000))"
            )
            throw error
        }
        let extracted = Self.extract(response.body, contentType: response.contentType)
        let lower = extracted.lowercased()
        let isBinary = response.contentType.lowercased().contains("pdf")
            || response.contentType.lowercased().contains("octet-stream")
        let fallback: String? = isBinary
            || extracted.trimmingCharacters(in: .whitespacesAndNewlines).count < 200
            || lower.contains("enable javascript") || lower.contains("sign in to continue")
            ? "structured_content_unavailable_or_insufficient"
            : nil
        FloeLogger(category: .tools).info(
            "webFetchFinished trace=\(traceID) host=\(url.host ?? "none") status=\(response.statusCode) contentType=\(String(response.contentType.prefix(80))) extractedCharacters=\(extracted.count) truncated=\(response.truncated) fallback=\(fallback ?? "none") durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1_000))"
        )
        let payload: [String: Any] = [
            "url": url.absoluteString, "statusCode": response.statusCode,
            "contentType": response.contentType, "truncated": response.truncated,
            "browserFallback": fallback ?? "",
            "text": isBinary ? "" : String(extracted.prefix(maxCharacters))
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let summary = String(decoding: data, as: UTF8.self)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return ToolExecutionOutput(summary: summary, fullOutputSHA256: digest, exitStatus: 0)
    }

    static func extract(_ source: String, contentType: String) -> String {
        guard contentType.lowercased().contains("html") || source.contains("<html") else { return source }
        var text = source
        for tag in ["script", "style", "noscript", "svg"] {
            text = text.replacingOccurrences(
                of: "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive]
            )
        }
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\""]
        for (entity, value) in entities { text = text.replacingOccurrences(of: entity, with: value) }
        return text.replacingOccurrences(of: "[\\t ]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
