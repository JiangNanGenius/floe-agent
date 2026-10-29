// FloeSkills — native validator for the Hub-authored presentation document
// the App reads at the SAME immutable publication commit Y as the signed
// catalog: `showcase/skills.json` (frozen showcase/CONTRACT.md v1; the Hub is
// the sole authoring source, published from the official-service web client).
//
// Trust model, mirrored byte-for-byte from the web contract
// (web/src/skills/hub-showcase.ts): showcase JSON is UNTRUSTED TEXT even
// though it comes from the pinned official GitHub tree. It can never set
// signatures, grants, status, availability, minimum app version, runtime or
// package bindings — those live only in the signed catalog feeds. This file
// therefore validates shape, bounds, paths and media safety before a single
// byte reaches a renderer:
//
//   * exact key sets (an unknown key is a rejection, not an extension);
//   * bounded arrays (use cases / examples / gallery / picks) and a bounded
//     entry and media-reference count;
//   * strict relative media paths under `showcase/media/` — no URL, no
//     traversal, no empty component, no backslash, no control character;
//   * bilingual {en, zh-Hans} text with a length bound, non-empty where the
//     contract requires, and never raw markup;
//   * a truthful caption is required for anything that is not an
//     illustration (example output / app screenshot must say what it shows);
//   * media bytes are checked against the declared path extension (magic
//     bytes for raster formats, the strict static-SVG scanner for .svg)
//     before any image object exists;
//   * the native renderer NEVER executes SVG: an SVG reference passes the
//     scanner here for contract parity, but the App-side media view falls
//     back to bundled raster artwork instead of a web view.
//
// Screenshots and examples are ILLUSTRATIONS, never proof of execution:
// nothing in this module attaches a capability claim to an image.

import Foundation

/// A rejected showcase document. The message is diagnostic text for logs and
/// detail views, never rendered as markup.
public struct SkillHubShowcaseValidationError: Error, Equatable, Sendable, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// One validated `showcase/skills.json` document, keyed by skill id.
public struct SkillHubShowcase: Sendable, Equatable {

    // MARK: Contract bounds (web hub-showcase.ts / hub-config HUB_BOUNDS)

    public static let schemaVersion = 1
    public static let mediaRoot = "showcase/media/"
    public static let maximumTextLength = 4_000
    public static let maximumArrayItems = 12
    public static let maximumEntries = 256
    public static let maximumEditorPicks = 12
    public static let maximumMediaFiles = 256
    public static let maximumPathLength = 512
    public static let maximumSkillIDLength = 64
    /// Per-file media bound from the published contract (HUB_BOUNDS.mediaFileBytes).
    public static let maximumMediaBytes = 4 * 1024 * 1024
    /// Session-wide media budget from the published contract
    /// (HUB_BOUNDS.mediaTotalBytes / maxMediaFiles).
    public static let maximumSessionBytes = 32 * 1024 * 1024
    public static let maximumSessionFiles = 256
    /// The showcase manifest itself stays far below the transport's existing
    /// anonymous GitHub cap; decoding is refused beyond this bound.
    public static let maximumManifestBytes = 2 * 1024 * 1024

    // MARK: Validated value types

    public struct LocaleText: Sendable, Equatable, Hashable {
        public let en: String
        public let zhHans: String
        /// Picks the value for the user's preferred localizations, falling
        /// back to English. Simplified Chinese (`zh*`) selects `zh-Hans`.
        public func value(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
            for language in preferredLanguages {
                if language.hasPrefix("zh") { return zhHans }
                if language.hasPrefix("en") { return en }
            }
            return en
        }
    }

    public enum MediaKind: String, Sendable, CaseIterable, Equatable {
        case illustration
        case exampleOutput = "example-output"
        case appScreenshot = "app-screenshot"
    }

    public struct MediaRef: Sendable, Equatable, Hashable {
        public let path: String
        public let kind: MediaKind
        public let credit: LocaleText
        public let alt: LocaleText?
        public let caption: LocaleText?
        /// Declared MIME type from the path extension, or nil for an
        /// extension outside the safe allowlist.
        public var mimeType: String? { SkillHubShowcase.mediaMIME(for: path) }
        /// Native policy: raster formats are decodable by ImageIO. SVG (and
        /// anything unknown) is never executed or rasterized natively — the
        /// view falls back to bundled artwork.
        public var isNativelyRenderable: Bool {
            switch mimeType {
            case "image/png", "image/jpeg", "image/webp": return true
            default: return false
            }
        }
    }

    public struct Example: Sendable, Equatable {
        public let prompt: LocaleText
        public let output: LocaleText
    }

    public struct Editorial: Sendable, Equatable {
        public let overview: LocaleText
        public let useCases: [LocaleText]
        public let examples: [Example]
        public let cover: MediaRef?
        public let gallery: [MediaRef]
    }

    public let editorPicks: [String]
    public let entries: [String: Editorial]

    public func editorial(for skillID: String) -> Editorial? { entries[skillID] }
    public func cover(for skillID: String) -> MediaRef? { entries[skillID]?.cover }
    public func gallery(for skillID: String) -> [MediaRef] { entries[skillID]?.gallery ?? [] }

    // MARK: Identity / path / type predicates (shared with the App service)

    /// Canonical immutable GitHub commit object ID: exactly 40 lowercase hex
    /// ASCII bytes — the same publication-commit gate the transport applies.
    public static func isCanonicalPublicationCommit(_ candidate: String) -> Bool {
        candidate.utf8.count == 40 && candidate.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }

    /// The published manifest path inside the hub repository at Y.
    public static let manifestPath = "showcase/skills.json"

    /// Strict relative path under `showcase/media/`: the contract forbids
    /// URLs, traversal, empty components, backslashes, query/fragment bytes,
    /// percent escapes and control characters.
    public static func isSafeMediaPath(_ candidate: String) -> Bool {
        guard candidate.hasPrefix(mediaRoot) else { return false }
        guard candidate.utf8.count <= maximumPathLength else { return false }
        guard !candidate.contains("\\"), !candidate.contains("\0") else { return false }
        guard !candidate.contains("?"), !candidate.contains("#"), !candidate.contains("%") else { return false }
        guard candidate.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else { return false }
        // Any scheme (`name://…`) is a URL, not a contract-relative path.
        guard !candidate.contains("://") else { return false }
        let segments = candidate.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count >= 3 else { return false }
        for segment in segments {
            if segment.isEmpty || segment == "." || segment == ".." || segment.hasPrefix(".") { return false }
        }
        guard let leaf = segments.last else { return false }
        guard leaf.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-") }) else {
            return false
        }
        return mediaMIME(for: candidate) != nil
    }

    /// The allowlisted media MIME types by extension (web MEDIA_EXTENSIONS).
    public static let mediaExtensions: [String: String] = [
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "webp": "image/webp",
        "svg": "image/svg+xml",
    ]

    public static func mediaMIME(for path: String) -> String? {
        guard let dot = path.lastIndex(of: ".") else { return nil }
        let ext = String(path[path.index(after: dot)...]).lowercased()
        return mediaExtensions[ext]
    }

    /// Validate raw bytes against the declared path's MIME before any
    /// renderer sees them: magic bytes for raster formats, the static SVG
    /// scanner for .svg.
    public static func bytesMatchPath(_ bytes: [UInt8], path: String) -> Bool {
        guard let mime = mediaMIME(for: path) else { return false }
        if mime == "image/svg+xml" {
            guard let text = String(bytes: bytes, encoding: .utf8) else { return false }
            return inspectSVGSafety(text).safe
        }
        func has(_ prefix: [UInt8]) -> Bool {
            guard bytes.count >= prefix.count else { return false }
            return Array(bytes.prefix(prefix.count)) == prefix
        }
        switch mime {
        case "image/png":
            return has([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        case "image/jpeg":
            return has([0xFF, 0xD8, 0xFF])
        case "image/webp":
            // "RIFF"...."WEBP". NOTE: the web hub-showcase.ts literal checks
            // byte[10] === 0x56 ('V'), which cannot be part of a real WEBP
            // payload ('B' = 0x42) — a contract typo. The published catalog
            // carries only png/jpg media, so the native validator uses the
            // correct magic; any future .webp publication would then pass
            // native validation and (after the web typo is fixed) web too.
            guard bytes.count > 12, has([0x52, 0x49, 0x46, 0x46]) else { return false }
            return bytes[8] == 0x57 && bytes[9] == 0x45 && bytes[10] == 0x42 && bytes[11] == 0x50
        default:
            return false
        }
    }

    public static func bytesMatchPath(_ data: Data, path: String) -> Bool {
        bytesMatchPath([UInt8](data), path: path)
    }

    // MARK: SVG static safety scanner (contract parity; App never executes SVG)

    public struct SVGSafetyResult: Sendable, Equatable {
        public let safe: Bool
        public let reason: String?
    }

    private static let allowedSVGElements: Set<String> = [
        "svg", "g", "defs", "desc", "title", "metadata",
        "linearGradient", "radialGradient", "stop", "pattern", "clipPath", "mask",
        "filter", "feGaussianBlur", "feOffset", "feMerge", "feMergeNode", "feBlend",
        "rect", "circle", "ellipse", "line", "polyline", "polygon", "path",
        "text", "tspan", "textPath", "symbol", "marker",
    ]

    private static let forbiddenSVGElements: Set<String> = [
        "script", "foreignobject", "iframe", "embed", "object", "link", "image",
        "use", "style", "handler", "set", "animate", "animatetransform",
        "animatemotion", "audio", "video",
    ]

    private static let allowedSVGNamespaces: [String] = [
        "http://www.w3.org/2000/svg",
        "http://www.w3.org/XML/1998/namespace",
        "http://www.w3.org/1999/xlink",
    ]

    /// Mirrors the web `inspectSvgSafety`: anything that can script, load an
    /// external resource, carry CSS or animate is refused. Elements with no
    /// script risk can still never execute natively — the App renders only
    /// the validated raster formats.
    public static func inspectSVGSafety(_ source: String) -> SVGSafetyResult {
        func refuse(_ reason: String) -> SVGSafetyResult { SVGSafetyResult(safe: false, reason: reason) }
        guard !source.isEmpty else { return refuse("empty svg source") }
        guard source.utf8.count <= 512 * 1024 else { return refuse("svg source exceeds the text bound") }
        let lowered = source.lowercased()
        if lowered.contains("<!doctype") || lowered.contains("<!entity") {
            return refuse("svg carries a DTD or entity declaration")
        }
        if lowered.contains("<?") {
            let trimmedStart = String(source.drop(while: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }))
            guard trimmedStart.hasPrefix("<?xml") else { return refuse("svg carries a processing instruction") }
        }
        // Element allowlist / denylist via the same tag scan as the web:
        // every `<name` / `</name` occurrence must pass.
        guard let tagRegex = try? NSRegularExpression(pattern: "</?([A-Za-z][A-Za-z0-9:\\-]*)") else {
            return refuse("svg scanner unavailable")
        }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        let matches = tagRegex.matches(in: source, range: range)
        guard !matches.isEmpty else { return refuse("svg has no elements") }
        for match in matches.dropFirst(0) {
            guard let nameRange = Range(match.range(at: 1), in: source) else { continue }
            let name = String(source[nameRange])
            if forbiddenSVGElements.contains(name.lowercased()) {
                return refuse("svg uses a forbidden element <\(name)>")
            }
            guard allowedSVGElements.contains(name) else {
                return refuse("svg uses an element outside the static allowlist <\(name)>")
            }
        }
        guard hasSVGRoot(lowered) else {
            return refuse("svg has no <svg> root")
        }
        if SkillHubShowcase.matches(pattern: "\\son[a-z\\-]+\\s*=", options: .caseInsensitive, in: source) {
            return refuse("svg carries an event handler attribute")
        }
        // Executable/external resource schemes, after the web's own allowance
        // of the plain w3.org element-namespace literals.
        let withoutW3Namespaces = SkillHubShowcase.replacingMatches(
            pattern: "http://www\\.w3\\.org/[A-Za-z0-9./\\-]*", in: source, with: "")
        if SkillHubShowcase.matches(pattern: "\\b(?:javascript|data|blob|vbscript|file|ftp):",
                                    options: .caseInsensitive, in: withoutW3Namespaces) {
            return refuse("svg references an executable or external resource scheme")
        }
        var namespaceStripped = source
        for uri in allowedSVGNamespaces { namespaceStripped = namespaceStripped.replacingOccurrences(of: uri, with: "") }
        if SkillHubShowcase.matches(pattern: "[a-z][a-z0-9+.\\-]*://", options: .caseInsensitive, in: namespaceStripped) {
            return refuse("svg references an external resource")
        }
        if SkillHubShowcase.matches(pattern: "\\b(?:href|xlink:href|src|action|formaction|data)\\s*=",
                                    options: .caseInsensitive, in: source) {
            return refuse("svg carries a link or resource attribute")
        }
        if SkillHubShowcase.matches(pattern: "@import|expression\\s*\\(|behaviou?r\\s*:",
                                    options: .caseInsensitive, in: source) {
            return refuse("svg carries CSS import or expression")
        }
        if let urlRegex = try? NSRegularExpression(pattern: "url\\(\\s*[^)]*\\)", options: .caseInsensitive) {
            for match in urlRegex.matches(in: source, options: [], range: range) {
                guard let r = Range(match.range, in: source) else { continue }
                let reference = String(source[r]).trimmingCharacters(in: .whitespaces)
                guard !SkillHubShowcase.matches(pattern: "^url\\(\\s*#[A-Za-z0-9_\\-]+\\s*\\)$", options: [], in: reference) else {
                    continue
                }
                return refuse("svg url() reference is not a same-document fragment: \(reference)")
            }
        }
        return SVGSafetyResult(safe: true, reason: nil)
    }

    private static func hasSVGRoot(_ loweredSource: String) -> Bool {
        guard let at = loweredSource.range(of: "<svg") else { return false }
        guard at.upperBound < loweredSource.endIndex else { return false }
        switch loweredSource[at.upperBound] {
        case " ", "\t", "\n", "\r", ">": return true
        default: return false
        }
    }

    static func matches(pattern: String, options: NSRegularExpression.Options = [], in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }

    static func replacingMatches(pattern: String, in text: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }

    // MARK: Decoding (strict, untrusted text)

    public static func decode(data: Data) throws -> SkillHubShowcase {
        guard data.count <= maximumManifestBytes else {
            throw SkillHubShowcaseValidationError("showcase manifest exceeds \(maximumManifestBytes) bytes")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw SkillHubShowcaseValidationError("showcase manifest is not valid JSON")
        }
        let root = try plainObject(object, "showcase skills")
        let keys = root.keys.sorted()
        guard Set(keys) == ["editorPicks", "entries", "schemaVersion"], keys.count == 3 else {
            throw SkillHubShowcaseValidationError(
                "showcase skills root keys must be exactly editorPicks/entries/schemaVersion, got \(keys.joined(separator: ","))")
        }
        guard integerValue(root["schemaVersion"]) == schemaVersion else {
            throw SkillHubShowcaseValidationError("showcase schemaVersion must be \(schemaVersion)")
        }
        guard let rawPicks = root["editorPicks"] as? [Any] else {
            throw SkillHubShowcaseValidationError("editorPicks must be an array")
        }
        guard rawPicks.count <= maximumEditorPicks else {
            throw SkillHubShowcaseValidationError("editorPicks exceeds \(maximumEditorPicks)")
        }
        var picks: [String] = []
        for pick in rawPicks {
            guard let id = pick as? String, isSkillID(id) else {
                throw SkillHubShowcaseValidationError("editorPicks must be skill ids")
            }
            guard !picks.contains(id) else {
                throw SkillHubShowcaseValidationError("editorPicks must be unique")
            }
            picks.append(id)
        }
        let rawEntries = try plainObject(root["entries"], "entries")
        guard rawEntries.count <= maximumEntries else {
            throw SkillHubShowcaseValidationError("showcase entries exceed \(maximumEntries)")
        }
        var entries: [String: Editorial] = [:]
        entries.reserveCapacity(rawEntries.count)
        var mediaFiles = 0
        var seenMedia = Set<String>()
        for (id, raw) in rawEntries {
            guard isSkillID(id) else {
                throw SkillHubShowcaseValidationError("showcase entry id \(id.debugDescription) is not a skill id")
            }
            let record = try plainObject(raw, "showcase entry \(id)")
            let entryKeys = record.keys.sorted()
            guard entryKeys == ["cover", "examples", "gallery", "overview", "useCases"] else {
                throw SkillHubShowcaseValidationError(
                    "showcase entry \(id): keys must be exactly cover/examples/gallery/overview/useCases")
            }
            let overview = try localeText(record["overview"], "showcase \(id) overview", allowEmpty: false)
            guard let rawUseCases = record["useCases"] as? [Any] else {
                throw SkillHubShowcaseValidationError("showcase \(id): useCases must be an array")
            }
            var useCases: [LocaleText] = []
            for (index, item) in rawUseCases.enumerated() {
                useCases.append(try localeText(item, "showcase \(id) useCases[\(index)]", allowEmpty: false))
            }
            guard useCases.count <= maximumArrayItems else {
                throw SkillHubShowcaseValidationError("showcase \(id): useCases exceed \(maximumArrayItems)")
            }
            guard let rawExamples = record["examples"] as? [Any] else {
                throw SkillHubShowcaseValidationError("showcase \(id): examples must be an array")
            }
            var examples: [Example] = []
            for (index, item) in rawExamples.enumerated() {
                let example = try plainObject(item, "showcase \(id) examples[\(index)]")
                let exampleKeys = example.keys.sorted()
                guard exampleKeys == ["output", "prompt"] else {
                    throw SkillHubShowcaseValidationError(
                        "showcase \(id) examples[\(index)]: keys must be exactly prompt/output")
                }
                examples.append(Example(
                    prompt: try localeText(example["prompt"], "showcase \(id) examples[\(index)] prompt", allowEmpty: false),
                    output: try localeText(example["output"], "showcase \(id) examples[\(index)] output", allowEmpty: false)))
            }
            guard examples.count <= maximumArrayItems else {
                throw SkillHubShowcaseValidationError("showcase \(id): examples exceed \(maximumArrayItems)")
            }
            var cover: MediaRef?
            if let rawCover = record["cover"], !(rawCover is NSNull) {
                cover = try mediaRef(rawCover, "showcase \(id) cover")
            }
            guard let rawGallery = record["gallery"] as? [Any] else {
                throw SkillHubShowcaseValidationError("showcase \(id): gallery must be an array")
            }
            var gallery: [MediaRef] = []
            for (index, item) in rawGallery.enumerated() {
                gallery.append(try mediaRef(item, "showcase \(id) gallery[\(index)]"))
            }
            guard gallery.count <= maximumArrayItems else {
                throw SkillHubShowcaseValidationError("showcase \(id): gallery exceeds \(maximumArrayItems)")
            }
            for media in [cover].compactMap({ $0 }) + gallery {
                mediaFiles += 1
                seenMedia.insert(media.path)
            }
            entries[id] = Editorial(overview: overview, useCases: useCases, examples: examples,
                                    cover: cover, gallery: gallery)
        }
        guard mediaFiles <= maximumMediaFiles else {
            throw SkillHubShowcaseValidationError(
                "showcase references \(mediaFiles) media files, over the \(maximumMediaFiles) bound")
        }
        guard seenMedia.count <= maximumMediaFiles else {
            throw SkillHubShowcaseValidationError(
                "showcase references \(seenMedia.count) distinct media files, over the bound")
        }
        // A pick must have an editorial record; picks never invent entries.
        for pick in picks {
            guard entries[pick] != nil else {
                throw SkillHubShowcaseValidationError("editorPick \(pick) has no editorial record")
            }
        }
        return SkillHubShowcase(editorPicks: picks, entries: entries)
    }

    // MARK: Field validators

    private static func plainObject(_ value: Any?, _ label: String) throws -> [String: Any] {
        // JSON arrays bridge to [Any]; only a real dictionary passes.
        guard let candidate = value, !(candidate is [Any]), !(candidate is NSNull),
              let object = candidate as? [String: Any] else {
            throw SkillHubShowcaseValidationError("\(label): expected an object")
        }
        return object
    }

    private static func integerValue(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        let doubleValue = number.doubleValue
        guard doubleValue == doubleValue.rounded() else { return nil }
        return number.intValue
    }

    private static func localeText(_ value: Any?, _ label: String, allowEmpty: Bool) throws -> LocaleText {
        let record = try plainObject(value, "\(label): expected bilingual text")
        let keys = record.keys.sorted()
        guard keys == ["en", "zh-Hans"] else {
            throw SkillHubShowcaseValidationError("\(label): text keys must be exactly en and zh-Hans")
        }
        guard let en = record["en"] as? String, let zh = record["zh-Hans"] as? String else {
            throw SkillHubShowcaseValidationError("\(label): text values must be strings")
        }
        guard en.unicodeScalars.count <= maximumTextLength, zh.unicodeScalars.count <= maximumTextLength else {
            throw SkillHubShowcaseValidationError("\(label): text exceeds the bound")
        }
        if !allowEmpty {
            guard !en.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !zh.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SkillHubShowcaseValidationError("\(label): text must not be empty in either language")
            }
        }
        // Presentation text is rendered as text nodes only; markup is refused.
        guard !containsMarkup(en), !containsMarkup(zh) else {
            throw SkillHubShowcaseValidationError("\(label): text must not embed markup")
        }
        return LocaleText(en: en, zhHans: zh)
    }

    private static func optionalLocaleText(_ value: Any?, _ label: String) throws -> LocaleText? {
        guard let value, !(value is NSNull) else { return nil }
        return try localeText(value, label, allowEmpty: false)
    }

    /// Mirrors the web `/<[a-z!/]/i` markup probe (case-insensitive).
    static func containsMarkup(_ text: String) -> Bool {
        let lowered = text.lowercased()
        var index = lowered.startIndex
        while let angle = lowered[index...].firstIndex(of: "<") {
            let next = lowered.index(after: angle)
            guard next < lowered.endIndex else { return false }
            let following = lowered[next]
            if following == "!" || following == "/" { return true }
            if following.isLetter && following.isASCII { return true }
            index = next
        }
        return false
    }

    private static func mediaRef(_ value: Any?, _ label: String) throws -> MediaRef {
        let record = try plainObject(value, "\(label): media reference must be an object")
        let allowed = ["alt", "caption", "credit", "kind", "path"]
        let keys = record.keys.sorted()
        guard keys.allSatisfy({ allowed.contains($0) }) else {
            throw SkillHubShowcaseValidationError(
                "\(label): unexpected media field(s) \(keys.filter { !allowed.contains($0) }.joined(separator: ", "))")
        }
        guard let path = record["path"] as? String, isSafeMediaPath(path) else {
            throw SkillHubShowcaseValidationError(
                "\(label): media path must be a strict relative file under \(mediaRoot)")
        }
        guard let kindRaw = record["kind"] as? String, let kind = MediaKind(rawValue: kindRaw) else {
            throw SkillHubShowcaseValidationError("\(label): unknown media kind")
        }
        let credit = try localeText(record["credit"], "\(label) credit", allowEmpty: false)
        let alt = try optionalLocaleText(record["alt"], "\(label) alt")
        let caption = try optionalLocaleText(record["caption"], "\(label) caption")
        if kind != .illustration, caption == nil {
            throw SkillHubShowcaseValidationError("\(label): non-illustration media require a truthful caption")
        }
        return MediaRef(path: path, kind: kind, credit: credit, alt: alt, caption: caption)
    }

    /// `^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$` with the contract length bound.
    public static func isSkillID(_ candidate: String) -> Bool {
        guard !candidate.isEmpty, candidate.utf8.count <= maximumSkillIDLength else { return false }
        let scalars = Array(candidate.unicodeScalars)
        guard let first = scalars.first, first.value >= 97, first.value <= 122 else { return false }
        var previousWasHyphen = false
        for scalar in scalars.dropFirst() {
            let value = scalar.value
            let isLower = (97...122).contains(value)
            let isDigit = (48...57).contains(value)
            if isLower || isDigit {
                previousWasHyphen = false
            } else if value == 45 {
                if previousWasHyphen { return false }
                previousWasHyphen = true
            } else {
                return false
            }
        }
        return !previousWasHyphen
    }
}
