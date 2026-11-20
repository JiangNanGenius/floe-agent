// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore

/// Shared web.fetch response representation for the iPad transport and native Mac reader.
public enum WebFetchPage {
    public enum Format: String, Decodable, Sendable {
        case text, markdown, html, json
    }

    public static func output(body: String, statusCode: Int, contentType: String, url: String,
                              truncated: Bool, format: Format, startCharacter: Int, maxCharacters: Int,
                              cookieCount: Int = 0, cookieOrigin: String? = nil) throws -> ToolExecutionOutput {
        let rendered = render(body: body, contentType: contentType, format: format, baseURL: URL(string: url))
        let total = rendered.count
        let pageStart = min(max(0, startCharacter), total)
        let returned = String(rendered.dropFirst(pageStart).prefix(max(0, maxCharacters)))
        let nextStart = pageStart + returned.count < total ? pageStart + returned.count : nil
        let binary = Self.isBinary(contentType)
        let lower = rendered.lowercased()
        let fallback: String? = binary ? "binary_use_browser_download"
            : lower.contains("enable javascript") || lower.contains("sign in to continue")
                ? "page_may_require_browser_interaction"
                : nil
        let title = Self.extractTitle(body)
        var payload: [String: Any] = [
            "url": url,
            "statusCode": statusCode,
            "contentType": contentType,
            "format": format.rawValue,
            "truncated": truncated || nextStart != nil,
            "totalCharacters": total,
            "returnedCharacters": returned.count,
            "browserFallback": fallback ?? "",
            "title": title ?? "",
            "text": binary ? "" : returned
        ]
        if let nextStart { payload["nextStartCharacter"] = nextStart }
        if cookieCount > 0 { payload["cookieCount"] = cookieCount }
        if let origin = cookieOrigin { payload["cookieOrigin"] = origin }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let summary = String(decoding: data, as: UTF8.self)
        let digest = FloeDigest.sha256Hex(data)
        let capture = !binary && rendered.count > returned.count
            ? String(rendered.prefix(262_144))
            : nil
        return ToolExecutionOutput(
            summary: summary,
            fullOutputSHA256: digest,
            exitStatus: (200...399).contains(statusCode) ? 0 : 22,
            maximumSummaryCharacters: 262_144,
            capturedOutput: capture,
            capturedOutputTruncated: rendered.count > 262_144
        )
    }

    // MARK: - Rendering

    private static func render(
        body: String, contentType: String,
        format: Format,
        baseURL: URL?
    ) -> String {
        let isHTML = contentType.lowercased().contains("html")
            || body.localizedCaseInsensitiveContains("<html")
        switch format {
        case .html:
            return body
        case .json:
            return body
        case .text:
            guard isHTML else { return body }
            return extract(body, contentType: contentType)
        case .markdown:
            guard isHTML else { return body }
            return markdown(fromHTML: body, baseURL: baseURL)
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
