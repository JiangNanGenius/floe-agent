// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore

enum HelpAnswerReferences {
    /// Inspect only actual Markdown links. Code samples and arbitrary printed
    /// URI strings never acquire an actionable help card.
    static func references(in source: String, limit: Int = 3) -> [HelpReference] {
        guard limit > 0, let text = try? AttributedString(markdown: String(source.prefix(65_536))) else { return [] }
        var references: [HelpReference] = []
        var seen = Set<HelpReference>()
        for run in text.runs {
            guard let url = run.link, let reference = try? HelpReferenceLink.reference(from: url),
                  seen.insert(reference).inserted else { continue }
            references.append(reference)
            if references.count == min(limit, 6) { break }
        }
        return references
    }
}
