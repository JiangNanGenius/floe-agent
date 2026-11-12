// FloeDocuments — bounded DOCX input preparation for the bundled Markdown
// conversion engine.
//
// The app's real DOCX→Markdown executor is the pinned Mammoth build inside
// `DocumentConversion/converter.js` (see `document.convert`). Mammoth's
// DEFAULT style map recognizes Word's Heading 1...6 styles but not the
// semantic `Title` style emitted by `OfficeDocumentBuilder.createWord`, so a
// Title paragraph falls back to a plain `<p>` and the Markdown has no heading.
//
// Mammoth already reads an EMBEDDED style map from the `mammoth/style-map`
// package member (its `docx/style-map.js` / `options-reader.js`). This helper
// adds/merges exactly that member in an IN-MEMORY conversion input; the source
// file on disk is never rewritten. It is a real executor contract, not a
// guessed Mammoth option: the style-map member is the pinned library's own
// documented embedded-map path.
//
// The mapping is deliberately semantic, not a page-layout claim:
//   * `p.Title` / `p[style-name='Title']` -> `h1:fresh`
//   * Mammoth's own Heading 1...6 mappings stay unchanged.
// An authored embedded map wins for any selector it already declares; this
// helper never overrides an author's explicit Title mapping and is idempotent.

import Foundation
import FloeCore
import ZIPFoundation

public enum OfficeMarkdownStyleMap {
    /// Mammoth's embedded style-map package member.
    public static let partName = "mammoth/style-map"

    /// The semantic Title mapping. Mammoth's default Heading n mappings are
    /// deliberately not repeated here.
    public static let titleMappings = """
    p.Title => h1:fresh
    p[style-name='Title'] => h1:fresh

    """

    public struct Outcome: Sendable, Equatable {
        /// Bytes to hand to the conversion engine.
        public var data: Data
        /// True when the docx will carry a Title -> H1 mapping (either newly
        /// added by this helper or already present in an authored map).
        public var titleMappingPresent: Bool
        /// True when an authored embedded map was retained. When it already
        /// contained a Title mapping the package is returned byte-identical.
        public var authoredMapPreserved: Bool
        /// True when this call actually rewrote the in-memory package.
        public var rewrotePackage: Bool

        public init(data: Data, titleMappingPresent: Bool,
                    authoredMapPreserved: Bool, rewrotePackage: Bool) {
            self.data = data
            self.titleMappingPresent = titleMappingPresent
            self.authoredMapPreserved = authoredMapPreserved
            self.rewrotePackage = rewrotePackage
        }
    }

    /// Adds/merges the semantic Title mapping into an in-memory DOCX.
    /// Fails closed for a non-ZIP input, an unreadable authored style map or
    /// a package beyond the bounded entry/byte limits. `maximumBytes` is the
    /// same 16 MiB conversion input ceiling used by `document.convert`.
    public static func addingTitleHeadingMap(
        to docx: Data,
        maximumBytes: Int = 16 * 1_024 * 1_024
    ) throws -> Outcome {
        guard !docx.isEmpty, docx.count <= maximumBytes else {
            throw FloeError.validationFailed(
                "DOCX conversion input must be a non-empty package up to 16 MiB")
        }
        let source: Archive
        do {
            source = try Archive(data: docx, accessMode: .read)
        } catch {
            throw FloeError.validationFailed(
                "DOCX conversion input is not a readable ZIP package")
        }

        var files: [(path: String, data: Data)] = []
        var authoredMap: String?
        var totalBytes = 0
        for entry in source where entry.type == .file {
            guard files.count < 4_096 else {
                throw FloeError.validationFailed(
                    "DOCX conversion input contains too many package members")
            }
            if entry.path == partName {
                let bytes = try read(entry, from: source, limit: maximumBytes)
                guard let text = String(data: bytes, encoding: .utf8) else {
                    throw FloeError.validationFailed(
                        "DOCX embedded style map is not valid UTF-8; refusing to guess its semantics")
                }
                authoredMap = text
                continue
            }
            let bytes = try read(entry, from: source, limit: maximumBytes)
            totalBytes += bytes.count
            guard totalBytes <= maximumBytes * 8 else {
                throw FloeError.validationFailed(
                    "DOCX conversion input expands beyond the bounded conversion budget")
            }
            files.append((entry.path, bytes))
        }

        let existing = authoredMap ?? ""
        if styleMapHasTitleMapping(existing) {
            // The authored map already decides Title semantics. Preserve the
            // exact input bytes and make a repeated call a no-op.
            return Outcome(data: docx, titleMappingPresent: true,
                           authoredMapPreserved: authoredMap != nil,
                           rewrotePackage: false)
        }

        var merged = existing
        if !merged.isEmpty, !merged.hasSuffix("\n") { merged += "\n" }
        merged += titleMappings

        let output: Archive
        do {
            output = try Archive(data: Data(), accessMode: .create)
        } catch {
            throw FloeError.validationFailed(
                "The conversion package could not be prepared")
        }
        do {
            for file in files {
                try output.addFloeEntry(path: file.path, data: file.data)
            }
            try output.addFloeEntry(path: partName, data: Data(merged.utf8))
        } catch {
            throw FloeError.validationFailed(
                "The conversion package could not be written")
        }
        guard let result = output.data, result.count <= maximumBytes + 65_536 else {
            throw FloeError.validationFailed(
                "The prepared conversion package is unavailable or oversized")
        }
        return Outcome(data: result, titleMappingPresent: true,
                       authoredMapPreserved: authoredMap != nil,
                       rewrotePackage: true)
    }

    /// True when an embedded map already contains a Title selector. Comments
    /// (`#`) are ignored; both the style-id selector and the style-name
    /// selector count. Escaped quotes inside selectors are not used by
    /// Mammoth's style-map syntax, so a line scan is the complete contract.
    static func styleMapHasTitleMapping(_ styleMap: String) -> Bool {
        for rawLine in styleMap.split(whereSeparator: \.isNewline) {
            let line = rawLine.split(separator: "#", maxSplits: 1,
                                     omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let normalized = line.lowercased()
            if normalized.contains("p.title")
                || normalized.contains("style-name='title'")
                || normalized.contains("style-name=\"title\"") {
                return true
            }
        }
        return false
    }

    private static func read(_ entry: Entry, from archive: Archive,
                             limit: Int) throws -> Data {
        guard entry.uncompressedSize <= UInt64(limit) else {
            throw FloeError.validationFailed(
                "DOCX package member exceeds the conversion budget")
        }
        var result = Data()
        result.reserveCapacity(Int(entry.uncompressedSize))
        do {
            _ = try archive.extract(entry) { chunk in
                guard result.count <= limit - chunk.count else {
                    throw FloeError.validationFailed(
                        "DOCX package member exceeds the conversion budget")
                }
                result.append(chunk)
            }
        } catch let error as FloeError {
            throw error
        } catch {
            throw FloeError.validationFailed(
                "DOCX package member could not be read")
        }
        return result
    }
}
