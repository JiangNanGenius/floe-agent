// SPDX-License-Identifier: MPL-2.0
import Foundation

enum HelpResourceURL {
    static func url(path: String) -> URL? {
        guard valid(path) else { return nil }
        var components = URLComponents()
        components.scheme = "floe-help"
        components.host = "bundle"
        components.path = "/" + path
        return components.url
    }

    static func path(url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "floe-help", components.host == "bundle",
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil,
              let decoded = components.percentEncodedPath.removingPercentEncoding,
              decoded.hasPrefix("/") else { return nil }
        // Encoded separators and second decoding cannot change resource identity.
        let encoded = components.percentEncodedPath.lowercased()
        guard !encoded.contains("%2f"), !encoded.contains("%5c") else { return nil }
        let path = String(decoded.dropFirst())
        return valid(path) ? path : nil
    }

    private static func valid(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 1024,
              !path.contains("\\"), !path.contains("%"), !path.contains(":"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}
