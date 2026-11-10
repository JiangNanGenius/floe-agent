// SPDX-License-Identifier: MPL-2.0
import Foundation

/// A resolved, immutable identity; callers cannot replace it with a model name.
public struct EDALibraryReference: Codable, Hashable, Sendable {
    public let packageID: String
    public let version: String
    public let packageSHA256: String
    public let partID: String
    public init(packageID: String, version: String, packageSHA256: String, partID: String) {
        self.packageID = packageID; self.version = version; self.packageSHA256 = packageSHA256; self.partID = partID
    }
    public var stableID: String { EDALibraryDigest.sha256(Data("\(packageID.utf8.count):\(packageID)\(version.utf8.count):\(version)\(packageSHA256)\(partID)".utf8)) }
}
public struct EDALibraryEntry: Codable, Hashable, Sendable, Identifiable {
    public let reference: EDALibraryReference
    public let part: EDALibraryPart
    public var id: String { reference.stableID }
    public init(reference: EDALibraryReference, part: EDALibraryPart) { self.reference = reference; self.part = part }
}
public struct EDALibraryCatalog: Codable, Hashable, Sendable {
    public let inventoryRevision: UInt64
    public let entries: [EDALibraryEntry]
    public let preferences: EDALibraryPreferences
    public init(inventoryRevision: UInt64, entries: [EDALibraryEntry], preferences: EDALibraryPreferences) {
        self.inventoryRevision = inventoryRevision; self.entries = entries; self.preferences = preferences
    }
    public func search(_ query: EDALibraryQuery, cancelled: @Sendable () -> Bool = { false }) throws -> EDALibraryCatalogPage {
        let matches = try EDALibrarySearch.ranked(entries, part: { $0.part }, query: query, cancelled: cancelled)
        guard query.offset <= matches.count else { throw EDAError.invalid("library page offset") }
        let end = min(matches.count, query.offset + query.limit)
        return .init(inventoryRevision: inventoryRevision, total: matches.count,
            nextOffset: end < matches.count ? end : nil, entries: Array(matches[query.offset..<end]))
    }
}
public struct EDALibraryCatalogPage: Codable, Hashable, Sendable {
    public let inventoryRevision: UInt64
    public let total: Int
    public let nextOffset: Int?
    public let entries: [EDALibraryEntry]
}
public struct EDALibraryPlacementSelection: Hashable, Sendable {
    public let snapshot: EDALibrarySnapshot
    public let unit: Int
    public let existingComponentID: UUID?
    public init(snapshot: EDALibrarySnapshot, unit: Int = 1, existingComponentID: UUID? = nil) {
        self.snapshot = snapshot; self.unit = unit; self.existingComponentID = existingComponentID
    }
}
