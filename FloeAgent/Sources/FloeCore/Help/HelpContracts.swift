// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Public product help is declarative content. These values confer no tool or settings authority.
public enum HelpLanguage: String, Codable, CaseIterable, Sendable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    public init(preference: String) {
        self = preference.lowercased().hasPrefix("zh") ? .simplifiedChinese : .english
    }
}

public enum HelpBundleMetadata {
    public static let packageID = "floe.help.quickstart"
    public static let bundledVersion = "1.2.0"
    public static let manifestPath = "help/manifest.json"
    public static let maximumFileBytes = 1_048_576
    public static let maximumManifestBytes = 262_144
}

public struct HelpResourceDescriptor: Codable, Equatable, Sendable {
    public var path: String
    public var mimeType: String
    public var byteCount: Int
    public var sha256: String
    public init(path: String, mimeType: String, byteCount: Int, sha256: String) {
        self.path = path; self.mimeType = mimeType; self.byteCount = byteCount; self.sha256 = sha256
    }
}

public struct HelpPackageManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var id: String
    public var version: String
    public var sourceRevision: String
    public var title: [String: String]
    public var indexPaths: [String: String]
    public var resources: [HelpResourceDescriptor]
    public init(schemaVersion: Int = 1, id: String = HelpBundleMetadata.packageID,
                version: String = HelpBundleMetadata.bundledVersion, sourceRevision: String,
                title: [String: String], indexPaths: [String: String], resources: [HelpResourceDescriptor]) {
        self.schemaVersion = schemaVersion; self.id = id; self.version = version
        self.sourceRevision = sourceRevision; self.title = title
        self.indexPaths = indexPaths; self.resources = resources
    }
}

public struct HelpCategoryEntry: Codable, Equatable, Sendable, Identifiable {
    public var articleID: String
    public var sectionID: String?
    public var title: String
    public var summary: String
    public var id: String { articleID + "#" + (sectionID ?? "") }
    public init(articleID: String, sectionID: String? = nil, title: String, summary: String = "") {
        self.articleID = articleID; self.sectionID = sectionID; self.title = title; self.summary = summary
    }
}

public struct HelpCategory: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var entries: [HelpCategoryEntry]
    public init(id: String, title: String, entries: [HelpCategoryEntry]) {
        self.id = id; self.title = title; self.entries = entries
    }
}

public struct HelpSection: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var parentID: String?
    public var title: String
    public var level: Int
    public var text: String
    public var aliases: [String]
    public init(id: String, parentID: String? = nil, title: String, level: Int, text: String, aliases: [String] = []) {
        self.id = id; self.parentID = parentID; self.title = title
        self.level = level; self.text = text; self.aliases = aliases
    }
}

public struct HelpArticle: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var summary: String
    public var htmlPath: String
    public var sections: [HelpSection]
    public var keywords: [String]
    public var settingIDs: [String]
    public init(id: String, title: String, summary: String, htmlPath: String,
                sections: [HelpSection], keywords: [String] = [], settingIDs: [String] = []) {
        self.id = id; self.title = title; self.summary = summary; self.htmlPath = htmlPath
        self.sections = sections; self.keywords = keywords; self.settingIDs = settingIDs
    }
}

public struct HelpIndex: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var locale: HelpLanguage
    public var categories: [HelpCategory]
    public var articles: [HelpArticle]
    public init(schemaVersion: Int = 1, locale: HelpLanguage, categories: [HelpCategory], articles: [HelpArticle]) {
        self.schemaVersion = schemaVersion; self.locale = locale
        self.categories = categories; self.articles = articles
    }
}

public struct HelpReference: Codable, Hashable, Sendable, Identifiable {
    public var packageID: String
    public var version: String
    public var language: HelpLanguage
    public var articleID: String
    public var sectionID: String?
    public var id: String { [packageID, version, language.rawValue, articleID, sectionID ?? ""].joined(separator: ":") }
    public init(packageID: String = HelpBundleMetadata.packageID, version: String,
                language: HelpLanguage, articleID: String, sectionID: String? = nil) {
        self.packageID = packageID; self.version = version; self.language = language
        self.articleID = articleID; self.sectionID = sectionID
    }
}

public struct HelpSearchHit: Codable, Equatable, Sendable, Identifiable {
    public var reference: HelpReference
    public var articleTitle: String
    public var sectionTitle: String?
    public var snippet: String
    public var score: Int
    public var settingIDs: [String]
    public var id: String { reference.id }
    public init(reference: HelpReference, articleTitle: String, sectionTitle: String?,
                snippet: String, score: Int, settingIDs: [String]) {
        self.reference = reference; self.articleTitle = articleTitle; self.sectionTitle = sectionTitle
        self.snippet = snippet; self.score = score; self.settingIDs = settingIDs
    }
}

public struct HelpReadResult: Codable, Equatable, Sendable {
    public var reference: HelpReference
    public var articleTitle: String
    public var sectionTitle: String?
    public var text: String
    public var settingIDs: [String]
    public var sourceRevision: String
    public var isTruncated: Bool
    public var nextOffset: Int?
    public init(reference: HelpReference, articleTitle: String, sectionTitle: String?, text: String,
                settingIDs: [String], sourceRevision: String, isTruncated: Bool, nextOffset: Int?) {
        self.reference = reference; self.articleTitle = articleTitle; self.sectionTitle = sectionTitle
        self.text = text; self.settingIDs = settingIDs; self.sourceRevision = sourceRevision
        self.isTruncated = isTruncated; self.nextOffset = nextOffset
    }
}
