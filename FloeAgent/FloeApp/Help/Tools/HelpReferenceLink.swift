// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore

/// A citation for public help, not an OS deep link or settings command.
enum HelpReferenceLink {
    enum LinkError: Error, LocalizedError {
        case invalidReference
        var errorDescription: String? { "Invalid Floe help reference. Search the current guides for a valid reference." }
    }

    static func url(for reference: HelpReference) throws -> URL {
        try validate(reference)
        var components = URLComponents()
        components.scheme = "floe-help"
        components.host = "guide"
        components.path = "/" + reference.articleID
        components.queryItems = [
            URLQueryItem(name: "package", value: reference.packageID),
            URLQueryItem(name: "version", value: reference.version),
            URLQueryItem(name: "locale", value: reference.language.rawValue)
        ]
        if let section = reference.sectionID {
            components.queryItems?.append(URLQueryItem(name: "section", value: section))
        }
        guard let url = components.url, url.absoluteString.utf8.count <= 1_024 else {
            throw LinkError.invalidReference
        }
        return url
    }

    static func isHelpLink(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "floe-help"
    }

    static func reference(from rawValue: String) throws -> HelpReference {
        guard rawValue.utf8.count <= 1_024,
              rawValue.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }),
              let url = URL(string: rawValue) else { throw LinkError.invalidReference }
        return try reference(from: url)
    }

    static func reference(from url: URL) throws -> HelpReference {
        guard url.absoluteString.utf8.count <= 1_024,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "floe-help", components.host == "guide",
              components.user == nil, components.password == nil, components.port == nil,
              components.fragment == nil, components.percentEncodedPath == components.path,
              components.path.hasPrefix("/"),
              components.path.dropFirst().contains("/") == false,
              let items = components.queryItems, (3...4).contains(items.count) else {
            throw LinkError.invalidReference
        }
        let allowed: Set<String> = ["package", "version", "locale", "section"]
        var values: [String: String] = [:]
        for item in items {
            guard allowed.contains(item.name), values[item.name] == nil,
                  let value = item.value, !value.isEmpty else { throw LinkError.invalidReference }
            values[item.name] = value
        }
        guard let package = values["package"], let version = values["version"],
              let locale = values["locale"], let language = HelpLanguage(rawValue: locale) else {
            throw LinkError.invalidReference
        }
        let result = HelpReference(packageID: package, version: version, language: language,
            articleID: String(components.path.dropFirst()), sectionID: values["section"])
        try validate(result)
        // Enforce one spelling for references, including query order and percent encoding.
        // This also refuses encoded separators, duplicate encodings and query-only aliases.
        guard try self.url(for: result).absoluteString == url.absoluteString else {
            throw LinkError.invalidReference
        }
        return result
    }

    private static func validate(_ reference: HelpReference) throws {
        guard reference.packageID == HelpBundleMetadata.packageID,
              identifier(reference.articleID),
              reference.sectionID.map(identifier) ?? true,
              reference.version.utf8.count <= 64,
              reference.version.range(of: #"\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?(\+[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?\z"#,
                  options: .regularExpression) != nil else { throw LinkError.invalidReference }
    }

    private static func identifier(_ value: String) -> Bool {
        (1...128).contains(value.utf8.count)
            && value.range(of: #"\A[a-z0-9]+([.-][a-z0-9]+)*\z"#, options: .regularExpression) != nil
    }
}
