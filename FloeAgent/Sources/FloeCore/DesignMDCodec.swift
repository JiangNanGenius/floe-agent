import Foundation

// FloeCore — DESIGN.md import/edit/export.
//
// The design spec is optionally expressed as a human-editable `DESIGN.md`.
// Floe only understands a small set of sections (palette, typography, layout,
// spacing, brand assets, voice, prohibitions); every other section, comment,
// preamble and formatting choice is preserved verbatim on import and re-emitted
// on export. Floe never rewrites, reorders or drops unknown text.

public enum DesignMDCodec {
    public struct Section: Sendable, Equatable {
        public let heading: String
        public let body: [String]
        /// Heading + body with trailing blank lines removed, so re-exporting an
        /// imported document is byte-stable and never accumulates blank lines.
        public var raw: String {
            var trimmedBody = body
            while let last = trimmedBody.last,
                  last.trimmingCharacters(in: .whitespaces).isEmpty {
                trimmedBody.removeLast()
            }
            return ([heading] + trimmedBody).joined(separator: "\n")
        }
        public var normalizedTitle: String {
            heading
                .drop(while: { $0 == "#" || $0 == " " })
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
        }
    }

    private static func isHeading(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return false }
        let hashes = trimmed.prefix { $0 == "#" }
        return (1...6).contains(hashes.count) && trimmed.count > hashes.count
            && trimmed.dropFirst(hashes.count).hasPrefix(" ")
    }

    /// Split a markdown document into a preamble and ordered sections. Unknown
    /// sections are simply sections whose normalized title is not recognized.
    public static func sections(in markdown: String) -> (preamble: [String], sections: [Section]) {
        let lines = markdown.components(separatedBy: "\n")
        var preamble: [String] = []
        var sections: [Section] = []
        var currentHeading: String?
        var currentBody: [String] = []

        func flush() {
            if let heading = currentHeading {
                sections.append(Section(heading: heading, body: currentBody))
            }
            currentHeading = nil
            currentBody = []
        }

        for line in lines {
            if isHeading(line) {
                flush()
                currentHeading = line
            } else if currentHeading == nil {
                preamble.append(line)
            } else {
                currentBody.append(line)
            }
        }
        flush()
        return (preamble, sections)
    }

    // MARK: - Parse

    public static func parse(_ markdown: String) -> DesignSpec {
        let (_, sections) = sections(in: markdown)
        var spec = DesignSpec()
        spec.rawMarkdown = markdown
        for section in sections {
            switch section.normalizedTitle {
            case "palette":
                spec.palette = bulletValues(section.body)
            case "typography":
                spec.typography = joinedBody(section.body)
            case "layout":
                spec.layout = joinedBody(section.body)
            case "spacing":
                spec.spacing = joinedBody(section.body)
            case "brand assets", "brand":
                spec.brandAssetRefs = bulletValues(section.body)
            case "voice":
                spec.voice = joinedBody(section.body)
            case "prohibitions":
                spec.prohibitions = bulletValues(section.body)
            default:
                continue
            }
        }
        return spec
    }

    // MARK: - Export

    private struct KnownSection {
        let title: String
        let bullets: [String]?
        let text: String?
    }

    public static func export(_ spec: DesignSpec) -> String {
        var output: [String] = []

        // Preserve the original preamble (title, comments, unknown prose)
        // verbatim, then emit the known sections, then every unknown section.
        if let raw = spec.rawMarkdown {
            let (preamble, _) = sections(in: raw)
            let trimmedPreamble = preamble.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedPreamble.isEmpty { output.append(trimmedPreamble) }
        }

        let known: [KnownSection] = [
            KnownSection(title: "Palette", bullets: spec.palette, text: nil),
            KnownSection(title: "Typography", bullets: nil, text: spec.typography),
            KnownSection(title: "Layout", bullets: nil, text: spec.layout),
            KnownSection(title: "Spacing", bullets: nil, text: spec.spacing),
            KnownSection(title: "Brand Assets", bullets: spec.brandAssetRefs, text: nil),
            KnownSection(title: "Voice", bullets: nil, text: spec.voice),
            KnownSection(title: "Prohibitions", bullets: spec.prohibitions, text: nil)
        ]

        for section in known {
            if let bullets = section.bullets, !bullets.isEmpty {
                output.append("## \(section.title)")
                output.append(contentsOf: bullets.map { "- \($0)" })
                output.append("")
            } else if let text = section.text,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                output.append("## \(section.title)")
                output.append(text)
                output.append("")
            }
        }

        // Re-emit every unknown section (and only those) verbatim.
        if let raw = spec.rawMarkdown {
            let knownTitles: Set<String> = [
                "palette", "typography", "layout", "spacing", "brand assets", "brand", "voice", "prohibitions"
            ]
            let (_, parsed) = sections(in: raw)
            for section in parsed where !knownTitles.contains(section.normalizedTitle) {
                output.append(section.raw)
                output.append("")
            }
        }

        var text = output.joined(separator: "\n")
        // Normalize trailing whitespace to a single newline.
        while text.hasSuffix("\n\n") { text.removeLast() }
        if !text.hasSuffix("\n") { text.append("\n") }
        return text
    }

    /// Canonical hash used to freeze a spec for a run. Hashes the exported
    /// document, so formatting/unknown sections participate.
    public static func sha256(of spec: DesignSpec) -> String {
        FloeDigest.sha256Hex(Data(export(spec).utf8))
    }

    // MARK: - Helpers

    private static func bulletValues(_ body: [String]) -> [String]? {
        let values = body.compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") else { return nil }
            let value = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return values.isEmpty ? nil : values
    }

    private static func joinedBody(_ body: [String]) -> String? {
        let text = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
