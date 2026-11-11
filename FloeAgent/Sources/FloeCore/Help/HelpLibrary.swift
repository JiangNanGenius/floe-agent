// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Errors thrown by the offline help library. Every case is a deterministic
/// content/packaging fault, never a device or account condition.
public enum HelpLibraryError: Error, Equatable, LocalizedError {
    case missingFile(String)
    case oversizedFile(path: String, limit: Int)
    case malformedJSON(String)
    case invalidContentJSON(String)
    case invalidManifest(String)
    case invalidIndex(locale: String, reason: String)
    case invalidIdentifier(String)
    case duplicateIdentifier(String)
    case unknownArticle(String)
    case unknownSection(article: String, section: String)
    case versionMismatch(expected: String, found: String)
    case packageMismatch(expected: String, found: String)
    case resourceNotFound(String)
    case resourceDigestMismatch(path: String)
    case unlistedFile(String)
    case invalidResourcePath(String)
    case invalidOffset(Int)

    public var errorDescription: String? {
        switch self {
        case .missingFile(let path): return "Help package is missing file: \(path)"
        case .oversizedFile(let path, let limit): return "Help file exceeds \(limit) bytes: \(path)"
        case .malformedJSON(let path): return "Help file is not valid JSON: \(path)"
        case .invalidContentJSON(let reason): return "Help content.json is invalid: \(reason)"
        case .invalidManifest(let reason): return "Help manifest is invalid: \(reason)"
        case .invalidIndex(let locale, let reason): return "Help index for \(locale) is invalid: \(reason)"
        case .invalidIdentifier(let value): return "Help identifier is invalid: \(value)"
        case .duplicateIdentifier(let value): return "Help identifier is duplicated: \(value)"
        case .unknownArticle(let id): return "Unknown help article: \(id)"
        case .unknownSection(let article, let section): return "Unknown help section \(section) in article \(article)"
        case .versionMismatch(let expected, let found): return "Help reference version \(found) does not match package version \(expected)"
        case .packageMismatch(let expected, let found): return "Help reference package \(found) does not match \(expected)"
        case .resourceNotFound(let path): return "Help resource is missing: \(path)"
        case .resourceDigestMismatch(let path): return "Help resource digest mismatch: \(path)"
        case .unlistedFile(let path): return "Help file is not listed in the manifest: \(path)"
        case .invalidResourcePath(let path): return "Help resource path is unsafe: \(path)"
        case .invalidOffset(let offset): return "Help read offset is out of range: \(offset)"
        }
    }
}

/// Immutable offline projection of one installed help package for one
/// language. The value is a pure function of the package bytes; the digest
/// seam is injected by the caller (production uses `FloeDigest.sha256Hex`).
public struct HelpLibrarySnapshot: Sendable {
    /// Frozen identifier grammar shared with the help reference codec:
    /// lowercase ASCII letters/digits with `.`/`-` separators, 1...128 bytes.
    private static let identifierRegex = #"^[a-z0-9]+([.-][a-z0-9]+)*$"#

    /// Ids the native settings catalog can navigate to. Remote content may
    /// name these but can never invent new routes.
    private static let knownSettingIDs: Set<String> = [
        "general.hardwareReturn", "general.voiceOutput", "execution.memory",
    ]

    public let manifest: HelpPackageManifest
    public let index: HelpIndex

    private let files: [String: Data]
    private let digest: @Sendable (Data) -> String
    private let resourcesByPath: [String: HelpResourceDescriptor]
    private let articlesByID: [String: HelpArticle]
    private let searchEntries: [SearchEntry]

    public init(files: [String: Data], language: HelpLanguage,
                digest: @escaping @Sendable (Data) -> String) throws {
        let validated = try HelpLibrarySnapshot.validatedPackage(files: files, digest: digest)
        self.files = files
        self.digest = digest
        self.manifest = validated.manifest
        guard let indexData = files[validated.manifest.indexPaths[language.rawValue] ?? ""] else {
            throw HelpLibraryError.missingFile("help index for \(language.rawValue)")
        }
        self.index = try HelpLibrarySnapshot.decodeJSON(HelpIndex.self, from: indexData,
                                                        path: "help index \(language.rawValue)")
        guard self.index.locale == language else {
            throw HelpLibraryError.invalidIndex(locale: language.rawValue,
                                                reason: "locale mismatch \(self.index.locale.rawValue)")
        }
        var byPath: [String: HelpResourceDescriptor] = [:]
        byPath.reserveCapacity(validated.manifest.resources.count)
        for descriptor in validated.manifest.resources { byPath[descriptor.path] = descriptor }
        self.resourcesByPath = byPath
        var byID: [String: HelpArticle] = [:]
        byID.reserveCapacity(self.index.articles.count)
        for article in self.index.articles { byID[article.id] = article }
        self.articlesByID = byID
        self.searchEntries = HelpLibrarySnapshot.makeSearchEntries(index: self.index,
                                                                   version: validated.manifest.version)
    }

    // MARK: - Lookup

    public func article(id: String) -> HelpArticle? { articlesByID[id] }

    public func reference(articleID: String, sectionID: String? = nil) throws -> HelpReference {
        guard let article = articlesByID[articleID] else {
            throw HelpLibraryError.unknownArticle(articleID)
        }
        if let sectionID {
            guard article.sections.contains(where: { $0.id == sectionID }) else {
                throw HelpLibraryError.unknownSection(article: articleID, section: sectionID)
            }
        }
        return HelpReference(version: manifest.version, language: index.locale,
                             articleID: articleID, sectionID: sectionID)
    }

    // MARK: - Search

    public func search(_ query: String, limit: Int = 12) -> [HelpSearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, limit > 0 else { return [] }
        let tokens = HelpLibrarySnapshot.searchTokens(from: trimmed)
        guard !tokens.isEmpty else { return [] }

        var bestByID: [String: HelpSearchHit] = [:]
        for entry in searchEntries {
            guard let score = entry.score(for: tokens, rawQuery: trimmed) else { continue }
            let reference = HelpReference(version: manifest.version, language: index.locale,
                                          articleID: entry.articleID, sectionID: entry.sectionID)
            let hit = HelpSearchHit(reference: reference, articleTitle: entry.articleTitle,
                                    sectionTitle: entry.sectionTitle,
                                    snippet: entry.snippet(for: tokens),
                                    score: score, settingIDs: entry.settingIDs)
            if let existing = bestByID[reference.id], existing.score >= score { continue }
            bestByID[reference.id] = hit
        }
        let ranked = bestByID.values.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.articleTitle != rhs.articleTitle { return lhs.articleTitle < rhs.articleTitle }
            return (lhs.sectionTitle ?? "") < (rhs.sectionTitle ?? "")
        }
        return Array(ranked.prefix(limit))
    }

    // MARK: - Reading

    public func read(_ reference: HelpReference, offset: Int = 0,
                     maximumCharacters: Int = 6000) throws -> HelpReadResult {
        guard reference.packageID == manifest.id else {
            throw HelpLibraryError.packageMismatch(expected: manifest.id, found: reference.packageID)
        }
        guard reference.version == manifest.version else {
            throw HelpLibraryError.versionMismatch(expected: manifest.version, found: reference.version)
        }
        guard reference.language == index.locale else {
            throw HelpLibraryError.invalidIndex(locale: index.locale.rawValue,
                                                reason: "reference language \(reference.language.rawValue)")
        }
        let resolved = try self.reference(articleID: reference.articleID, sectionID: reference.sectionID)
        let article = articlesByID[resolved.articleID]
        let section = resolved.sectionID.flatMap { id in article?.sections.first(where: { $0.id == id }) }

        let body: String
        let sectionTitle: String?
        if let section {
            sectionTitle = section.title
            body = HelpLibrarySnapshot.readingText(title: section.title, body: section.text)
        } else if let article {
            sectionTitle = nil
            var parts: [String] = [article.title]
            for item in article.sections {
                parts.append(HelpLibrarySnapshot.readingText(title: item.title, body: item.text))
            }
            body = parts.joined(separator: "\n\n")
        } else {
            throw HelpLibraryError.unknownArticle(resolved.articleID)
        }

        let characters = Array(body)
        guard offset >= 0, offset <= characters.count else {
            throw HelpLibraryError.invalidOffset(offset)
        }
        let page = max(1, maximumCharacters)
        let end = min(characters.count, offset + page)
        let text = String(characters[offset..<end])
        let nextOffset = end < characters.count ? end : nil
        return HelpReadResult(reference: resolved, articleTitle: article?.title ?? resolved.articleID,
                              sectionTitle: sectionTitle, text: text,
                              settingIDs: article?.settingIDs ?? [],
                              sourceRevision: manifest.sourceRevision,
                              isTruncated: nextOffset != nil, nextOffset: nextOffset)
    }

    // MARK: - Resources

    public func resource(at path: String) throws -> (data: Data, mimeType: String) {
        let normalized = try HelpLibrarySnapshot.validatedResourcePath(path)
        guard let descriptor = resourcesByPath[normalized] else {
            throw HelpLibraryError.resourceNotFound(normalized)
        }
        guard let data = files[normalized] else {
            throw HelpLibraryError.missingFile(normalized)
        }
        guard data.count == descriptor.byteCount, digest(data) == descriptor.sha256.lowercased() else {
            throw HelpLibraryError.resourceDigestMismatch(path: normalized)
        }
        return (data, descriptor.mimeType)
    }

    // MARK: - Validation

    public static func validatePackage(files: [String: Data],
                                       digest: @Sendable (Data) -> String) throws {
        _ = try validatedPackage(files: files, digest: digest)
    }

    /// Validates both locales, every reference and every asset, and returns
    /// the decoded manifest. Shared by the initializer and `validatePackage`.
    private static func validatedPackage(files: [String: Data],
                                         digest: @Sendable (Data) -> String) throws -> (manifest: HelpPackageManifest, decodedIndexes: [HelpLanguage: HelpIndex]) {
        guard let contentData = files["content.json"] else {
            throw HelpLibraryError.missingFile("content.json")
        }
        guard contentData.count <= HelpBundleMetadata.maximumManifestBytes else {
            throw HelpLibraryError.oversizedFile(path: "content.json",
                                                 limit: HelpBundleMetadata.maximumManifestBytes)
        }
        let contentObject = try decodeJSONObject(contentData, path: "content.json")
        guard contentObject["schemaVersion"] as? Int == 1 else {
            throw HelpLibraryError.invalidContentJSON("schemaVersion must be 1")
        }
        guard contentObject["id"] as? String == HelpBundleMetadata.packageID else {
            throw HelpLibraryError.invalidContentJSON("id must be \(HelpBundleMetadata.packageID)")
        }
        guard let version = contentObject["version"] as? String, !version.isEmpty else {
            throw HelpLibraryError.invalidContentJSON("version is required")
        }
        guard contentObject["kind"] as? String == "help" else {
            throw HelpLibraryError.invalidContentJSON("kind must be help")
        }
        guard contentObject["helpManifest"] as? String == HelpBundleMetadata.manifestPath else {
            throw HelpLibraryError.invalidContentJSON("helpManifest must be \(HelpBundleMetadata.manifestPath)")
        }
        guard let documents = contentObject["documents"] as? [String: String],
              documents[HelpLanguage.english.rawValue] != nil,
              documents[HelpLanguage.simplifiedChinese.rawValue] != nil else {
            throw HelpLibraryError.invalidContentJSON("documents must map en and zh-Hans")
        }

        guard let manifestData = files[HelpBundleMetadata.manifestPath] else {
            throw HelpLibraryError.missingFile(HelpBundleMetadata.manifestPath)
        }
        guard manifestData.count <= HelpBundleMetadata.maximumManifestBytes else {
            throw HelpLibraryError.oversizedFile(path: HelpBundleMetadata.manifestPath,
                                                 limit: HelpBundleMetadata.maximumManifestBytes)
        }
        let manifest = try decodeJSON(HelpPackageManifest.self, from: manifestData,
                                      path: HelpBundleMetadata.manifestPath)
        guard manifest.schemaVersion == 1 else {
            throw HelpLibraryError.invalidManifest("schemaVersion must be 1")
        }
        guard manifest.id == HelpBundleMetadata.packageID else {
            throw HelpLibraryError.invalidManifest("id must be \(HelpBundleMetadata.packageID)")
        }
        guard manifest.version == version else {
            throw HelpLibraryError.invalidManifest("manifest version \(manifest.version) does not match content.json \(version)")
        }
        // The signed entry copies sourceRevision from content.json, so the
        // manifest must carry exactly the same value (or both be empty).
        guard contentObject["sourceRevision"] as? String == manifest.sourceRevision else {
            throw HelpLibraryError.invalidContentJSON("sourceRevision must match the manifest")
        }
        try validateSourceRevision(manifest.sourceRevision)

        var decodedIndexes: [HelpLanguage: HelpIndex] = [:]
        for language in HelpLanguage.allCases {
            guard let indexPath = manifest.indexPaths[language.rawValue] else {
                throw HelpLibraryError.invalidManifest("indexPaths missing \(language.rawValue)")
            }
            try validateRelativePath(indexPath)
            guard let indexData = files[indexPath] else {
                throw HelpLibraryError.missingFile(indexPath)
            }
            guard indexData.count <= HelpBundleMetadata.maximumFileBytes else {
                throw HelpLibraryError.oversizedFile(path: indexPath,
                                                     limit: HelpBundleMetadata.maximumFileBytes)
            }
            let index = try decodeJSON(HelpIndex.self, from: indexData, path: indexPath)
            guard index.schemaVersion == 1 else {
                throw HelpLibraryError.invalidIndex(locale: language.rawValue,
                                                    reason: "schemaVersion must be 1")
            }
            guard index.locale == language else {
                throw HelpLibraryError.invalidIndex(locale: language.rawValue,
                                                    reason: "declares locale \(index.locale.rawValue)")
            }
            decodedIndexes[language] = index
        }

        // Resources: listed, bounded, digest-verified, and exhaustive.
        var resourcePaths = Set<String>()
        resourcePaths.reserveCapacity(manifest.resources.count)
        for descriptor in manifest.resources {
            try validateRelativePath(descriptor.path)
            guard resourcePaths.insert(descriptor.path).inserted else {
                throw HelpLibraryError.duplicateIdentifier("resource \(descriptor.path)")
            }
            guard descriptor.path != "content.json",
                  descriptor.path != HelpBundleMetadata.manifestPath else {
                throw HelpLibraryError.invalidResourcePath(descriptor.path)
            }
            guard let data = files[descriptor.path] else {
                throw HelpLibraryError.missingFile(descriptor.path)
            }
            guard data.count <= HelpBundleMetadata.maximumFileBytes else {
                throw HelpLibraryError.oversizedFile(path: descriptor.path,
                                                     limit: HelpBundleMetadata.maximumFileBytes)
            }
            guard data.count == descriptor.byteCount else {
                throw HelpLibraryError.resourceDigestMismatch(path: descriptor.path)
            }
            guard digest(data) == descriptor.sha256.lowercased() else {
                throw HelpLibraryError.resourceDigestMismatch(path: descriptor.path)
            }
        }
        for (path, data) in files where path != "content.json"
            && path != HelpBundleMetadata.manifestPath {
            guard resourcePaths.contains(path) else {
                throw HelpLibraryError.unlistedFile(path)
            }
            _ = data
        }

        // Index semantics, per locale and cross-locale identity. Major
        // (level-2) chapter identities must match across locales; deeper
        // subsection sets may legitimately differ between languages.
        var identityByLocale: [HelpLanguage: (articles: Set<String>, chapters: [String: Set<String>])] = [:]
        for (language, index) in decodedIndexes {
            identityByLocale[language] = try validatedIndexSemantics(index, manifest: manifest,
                                                                     documents: documents)
        }
        guard let english = identityByLocale[.english],
              let chinese = identityByLocale[.simplifiedChinese] else {
            throw HelpLibraryError.invalidManifest("both locales are required")
        }
        guard english.articles == chinese.articles else {
            throw HelpLibraryError.invalidManifest("article identities differ between locales")
        }
        for articleID in english.articles {
            guard english.chapters[articleID] == chinese.chapters[articleID] else {
                throw HelpLibraryError.invalidManifest("chapter identities differ for \(articleID)")
            }
        }
        return (manifest, decodedIndexes)
    }

    private static func validatedIndexSemantics(
        _ index: HelpIndex,
        manifest: HelpPackageManifest,
        documents: [String: String]
    ) throws -> (articles: Set<String>, chapters: [String: Set<String>]) {
        var articleIDs = Set<String>()
        var sectionIDs: [String: Set<String>] = [:]
        var chapterIDs: [String: Set<String>] = [:]
        var htmlPaths = Set<String>()
        for article in index.articles {
            try validateIdentifier(article.id)
            guard articleIDs.insert(article.id).inserted else {
                throw HelpLibraryError.duplicateIdentifier("article \(article.id)")
            }
            try validateRelativePath(article.htmlPath)
            guard manifest.resources.contains(where: { $0.path == article.htmlPath }) else {
                throw HelpLibraryError.missingFile("article html \(article.htmlPath)")
            }
            htmlPaths.insert(article.htmlPath)
            var seen = Set<String>()
            var chapters = Set<String>()
            for section in article.sections {
                try validateIdentifier(section.id)
                guard seen.insert(section.id).inserted else {
                    throw HelpLibraryError.duplicateIdentifier("section \(article.id)#\(section.id)")
                }
                guard section.level >= 1, section.level <= 6 else {
                    throw HelpLibraryError.invalidIndex(locale: index.locale.rawValue,
                                                        reason: "bad level in \(section.id)")
                }
                if section.level == 2 { chapters.insert(section.id) }
                if let parentID = section.parentID {
                    guard seen.contains(parentID) else {
                        throw HelpLibraryError.invalidIndex(locale: index.locale.rawValue,
                                                            reason: "unknown parent \(parentID)")
                    }
                }
            }
            sectionIDs[article.id] = seen
            chapterIDs[article.id] = chapters
            for settingID in article.settingIDs {
                guard knownSettingIDs.contains(settingID) else {
                    throw HelpLibraryError.invalidIdentifier("setting \(settingID)")
                }
            }
        }
        guard let legacyPath = documents[index.locale.rawValue] else {
            throw HelpLibraryError.invalidIndex(locale: index.locale.rawValue,
                                                reason: "missing legacy document projection")
        }
        guard manifest.resources.contains(where: { $0.path == legacyPath }) else {
            throw HelpLibraryError.missingFile("legacy document \(legacyPath)")
        }
        var categoryIDs = Set<String>()
        for category in index.categories {
            try validateIdentifier(category.id)
            guard categoryIDs.insert(category.id).inserted else {
                throw HelpLibraryError.duplicateIdentifier("category \(category.id)")
            }
            for entry in category.entries {
                guard articleIDs.contains(entry.articleID) else {
                    throw HelpLibraryError.unknownArticle(entry.articleID)
                }
                if let sectionID = entry.sectionID {
                    guard sectionIDs[entry.articleID]?.contains(sectionID) == true else {
                        throw HelpLibraryError.unknownSection(article: entry.articleID, section: sectionID)
                    }
                }
            }
        }
        return (articleIDs, chapterIDs)
    }

    // MARK: - Helpers

    static func validateIdentifier(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 128,
              value.range(of: identifierRegex, options: .regularExpression) != nil else {
            throw HelpLibraryError.invalidIdentifier(value)
        }
    }

    static func validateRelativePath(_ path: String) throws {
        guard !path.isEmpty, path.utf8.count <= 512,
              !path.hasPrefix("/"), !path.hasPrefix("\\"),
              !path.contains(".."), !path.contains("\\"),
              !path.hasSuffix("/") else {
            throw HelpLibraryError.invalidResourcePath(path)
        }
    }

    private static func validatedResourcePath(_ path: String) throws -> String {
        var normalized = path
        while normalized.hasPrefix("/") { normalized.removeFirst() }
        try validateRelativePath(normalized)
        return normalized
    }

    static func validateSourceRevision(_ value: String) throws {
        guard value.isEmpty || (value.utf8.count == 40 && value.allSatisfy({ $0.isASCII && ($0.isNumber || ($0 >= "a" && $0 <= "f")) })) else {
            throw HelpLibraryError.invalidManifest("sourceRevision must be empty or 40 lowercase hex characters")
        }
    }

    static func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data, path: String) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw HelpLibraryError.malformedJSON(path)
        }
    }

    private static func decodeJSONObject(_ data: Data, path: String) throws -> [String: Any] {
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw HelpLibraryError.malformedJSON(path)
            }
            return object
        } catch let error as HelpLibraryError {
            throw error
        } catch {
            throw HelpLibraryError.malformedJSON(path)
        }
    }

    private static func readingText(title: String, body: String) -> String {
        body.isEmpty ? title : title + "\n" + body
    }

    // MARK: - Search implementation

    private struct SearchEntry: Sendable {
        let articleID: String
        let sectionID: String?
        let articleTitle: String
        let sectionTitle: String?
        let normalizedTitle: String
        let normalizedSectionTitle: String
        let normalizedAliases: [String]
        let normalizedKeywords: [String]
        let normalizedText: String
        let rawText: String
        let settingIDs: [String]

        func score(for tokens: [String], rawQuery: String) -> Int? {
            var score = 0
            var matched = 0
            for token in tokens {
                var tokenScore = 0
                if normalizedTitle.contains(token) { tokenScore = 40 }
                if normalizedSectionTitle.contains(token) { tokenScore = max(tokenScore, 32) }
                if normalizedAliases.contains(where: { $0.contains(token) }) { tokenScore = max(tokenScore, 30) }
                if normalizedKeywords.contains(token) { tokenScore = max(tokenScore, 28) }
                if tokenScore == 0, normalizedText.contains(token) { tokenScore = 12 }
                guard tokenScore > 0 else { return nil }
                matched += 1
                score += tokenScore
            }
            // A contiguous whole-query hit inside aliases/titles beats scattered tokens.
            let whole = HelpLibrarySnapshot.normalizeSearchText(rawQuery)
            if !whole.isEmpty {
                if normalizedTitle.contains(whole) || normalizedSectionTitle.contains(whole)
                    || normalizedAliases.contains(where: { $0.contains(whole) }) {
                    score += 25
                }
            }
            if sectionID == nil { score -= 4 } // Section hits outrank whole-article hits.
            return matched == tokens.count ? score : nil
        }

        func snippet(for tokens: [String]) -> String {
            let normalized = HelpLibrarySnapshot.normalizeSearchText(rawText)
            var anchor = 0
            for token in tokens {
                if let range = normalized.range(of: token) {
                    anchor = normalized.distance(from: normalized.startIndex, to: range.lowerBound)
                    break
                }
            }
            let characters = Array(rawText)
            guard !characters.isEmpty else { return "" }
            let lower = max(0, anchor - 60)
            let upper = min(characters.count, anchor + 140)
            var text = String(characters[lower..<upper]).replacingOccurrences(of: "\n", with: " ")
            if lower > 0 { text = "…" + text }
            if upper < characters.count { text += "…" }
            return text
        }
    }

    private static func makeSearchEntries(index: HelpIndex, version: String) -> [SearchEntry] {
        var entries: [SearchEntry] = []
        entries.reserveCapacity(index.articles.count * 4)
        for article in index.articles {
            let articleTitle = normalizeSearchText(article.title)
            let keywords = article.keywords.map(normalizeSearchText)
            for section in article.sections {
                entries.append(SearchEntry(
                    articleID: article.id, sectionID: section.id,
                    articleTitle: article.title, sectionTitle: section.title,
                    normalizedTitle: articleTitle,
                    normalizedSectionTitle: normalizeSearchText(section.title),
                    normalizedAliases: section.aliases.map(normalizeSearchText),
                    normalizedKeywords: keywords,
                    normalizedText: normalizeSearchText(section.text),
                    rawText: section.text, settingIDs: article.settingIDs))
            }
            entries.append(SearchEntry(
                articleID: article.id, sectionID: nil,
                articleTitle: article.title, sectionTitle: nil,
                normalizedTitle: articleTitle,
                normalizedSectionTitle: "",
                normalizedAliases: [],
                normalizedKeywords: keywords,
                normalizedText: normalizeSearchText(article.summary),
                rawText: article.summary, settingIDs: article.settingIDs))
        }
        return entries
    }

    /// Case-insensitive, width-normalized search text. CJK text keeps its
    /// characters (no space tokenization); punctuation becomes spaces.
    static func normalizeSearchText(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\u{3000}": scalars.append(" ")
            case "\u{FF01}"..."\u{FF5E}":
                scalars.append(Unicode.Scalar(scalar.value - 0xFEE0)!)
            default: scalars.append(scalar)
            }
        }
        let mapped = String(String.UnicodeScalarView(scalars)).lowercased()
        var result = String.UnicodeScalarView()
        for scalar in mapped.unicodeScalars {
            let isAlnum = CharacterSet.alphanumerics.contains(scalar)
            let isCJK = (scalar.value >= 0x4E00 && scalar.value <= 0x9FFF)
                || (scalar.value >= 0x3400 && scalar.value <= 0x4DBF)
                || (scalar.value >= 0x3040 && scalar.value <= 0x30FF)
                || (scalar.value >= 0xAC00 && scalar.value <= 0xD7AF)
            if isAlnum || isCJK {
                result.append(scalar)
            } else if result.last != " " {
                result.append(" ")
            }
        }
        while result.last == " " { result.removeLast() }
        return String(String.UnicodeScalarView(result))
    }

    static func searchTokens(from query: String) -> [String] {
        normalizeSearchText(query).split(separator: " ").map(String.init)
    }
}
