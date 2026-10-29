// SPDX-License-Identifier: MPL-2.0
//
// Freezing the compiled built-in prompt sections into the same package shape
// the signed prompts feed uses, so a run that started on built-in prompts
// keeps byte-identical content across resume — even after an app upgrade
// changes the compiled bodies. The frozen bytes are consumed through the
// exact codec/overlay path as an installed package (`content.json` with
// sections), never through a parallel parser.

import Foundation

public enum BuiltInPromptFreeze {
    public struct Section: Sendable, Equatable {
        public let id: String
        /// Review title (first heading line of the compiled body).
        public let title: String
        /// Verbatim compiled layer text.
        public let body: String

        public init(id: String, title: String, body: String) {
            self.id = id
            self.title = title
            self.body = body
        }
    }

    /// Builds the `content.json` bytes for a built-in prompt freeze payload.
    /// The shape matches the signed prompts package schema so the existing
    /// `ContentPackageCodec.promptSections` / `runtimePromptOverlay` path
    /// consumes it unchanged.
    public static func contentJSON(sections: [Section]) throws -> Data {
        let serialized: [[String: Any]] = sections.map { section in
            [
                "id": section.id,
                "title": ["en": section.title],
                "body": ["en": section.body]
            ]
        }
        let object: [String: Any] = ["sections": serialized]
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            throw ContentPackageError.invalidContent("built-in prompt freeze payload is not valid JSON")
        }
        return data
    }

    /// Derives the review title (first heading line, without the leading
    /// `#`) from a compiled layer body. The frozen body stays the verbatim
    /// compiled text — including its heading — so a resumed run rebuilds a
    /// byte-identical prompt layer.
    public static func section(id: String, compiledBody: String) -> Section {
        let heading = compiledBody
            .split(separator: "\n", maxSplits: 1)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let title = heading.hasPrefix("#")
            ? String(heading.dropFirst()).trimmingCharacters(in: .whitespaces)
            : heading
        return Section(id: id, title: title, body: compiledBody)
    }
}
