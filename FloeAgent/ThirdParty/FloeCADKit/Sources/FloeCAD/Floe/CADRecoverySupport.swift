// SPDX-License-Identifier: MPL-2.0
// FloeCADKit — non-mutating recovery preview and restore-copy values.
//
// E33 (2026-10-31): an interactive open of a damaged `.floecad` package must be
// able to inspect the last verified `previous/` commit BEFORE anything is
// promoted. This file is deliberately free of package I/O and of the store's
// private types so the same pure builders can be exercised without a package:
//
//   * `CADRecoveryFacts` is the complete set of facts the store can prove from
//     the verified previous commit + the damaged package.
//   * `CADRecoveryReport.build(from:)` turns those facts into a structured,
//     localizable report. It never invents a field-level diff: when the damaged
//     current document cannot be verified, changes since the previous save are
//     reported as UNKNOWN and retained in the original package.
//   * `CADRecoveryFingerprint.make(...)` binds the preview to the exact bytes
//     it was built from, so a restore refuses a source that changed after the
//     user looked at the preview.
//   * `CADRecoveryCopyDestination.suggestedURL(...)` chooses a sibling
//     `<name> <suffix>.floecad` path that does not already exist.
//
// Nothing in this file writes to a package, creates a store, or touches a
// renderer/kernel/serializer. The store extension that gathers the facts lives
// next to the existing `FileCADDocumentStore` recovery code.

import Foundation
import CryptoKit

// MARK: - Damage

/// Why the CURRENT package could not be verified. The associated detail is a
/// diagnostic string (parser/integrity message) that belongs in a details
/// disclosure, never in the primary user copy.
public nonisolated enum CADRecoveryDamage: Sendable, Equatable {
    case missingManifest
    case unreadableManifest(detail: String)
    case unreadableDocument(detail: String)
    case failedIntegrity(detail: String)
    case unreadablePackage(detail: String)

    /// Stable identifier for host localization.
    public var code: String {
        switch self {
        case .missingManifest: return "missing_manifest"
        case .unreadableManifest: return "unreadable_manifest"
        case .unreadableDocument: return "unreadable_document"
        case .failedIntegrity: return "failed_integrity"
        case .unreadablePackage: return "unreadable_package"
        }
    }

    /// Parser/integrity detail; nil when there is none.
    public var diagnosticDetail: String? {
        switch self {
        case .missingManifest: return nil
        case .unreadableManifest(let detail),
             .unreadableDocument(let detail),
             .failedIntegrity(let detail),
             .unreadablePackage(let detail):
            return detail
        }
    }
}

// MARK: - Verified previous identity

public nonisolated struct CADRecoveryIdentity: Sendable, Equatable {
    public var name: String
    public var revision: Int
    public var contentSHA256: String
    /// Additive canonical model identity; nil when the previous manifest
    /// predates it or contains fields this build cannot canonicalize.
    public var modelSHA256: String?
    public var schemaVersion: Int
    public var createdAt: Date
    public var modifiedAt: Date
    public var unit: String?
    public var tolerance: Double?
    public var appBuild: String
}

// MARK: - Verified previous contents

/// Counts/presence read from the VERIFIED previous document record. Every count
/// here comes from decoded records whose bytes passed the package digest check.
public nonisolated struct CADRecoveryContents: Sendable, Equatable {
    public var bodies = 0
    public var sketches = 0
    public var planes = 0
    public var axes = 0
    public var images = 0
    public var symbols = 0
    public var features = 0
    public var variables = 0
    public var hasAssembly = false
    public var hasDrawings = false
    /// nil when drawing bytes exist but this build cannot decode the page list.
    public var drawingPageCount: Int?
    public var hasMaterials = false
    /// nil when material bytes exist but this build cannot decode the library.
    public var materialCount: Int?
    public var hasAnimation = false
    /// nil when animation bytes exist but this build cannot decode the clips.
    public var animationCount: Int?
    public var hasScripts = false
    public var hasSceneSettings = false
    public var hasPreviewImage = false
}

// MARK: - Report

public nonisolated enum CADRecoveryRowKind: String, Sendable, CaseIterable {
    /// Verified content that the new copy contains.
    case recovered
    /// Facts the damaged package cannot prove.
    case unknown
    /// Content that stays, byte for byte, in the damaged package.
    case retainedInOriginal
    /// A real omission detected in the damaged package.
    case unavailable
}

public nonisolated enum CADRecoveryCategory: String, Sendable, CaseIterable {
    case bodies
    case sketches
    case planes
    case axes
    case features
    case variables
    case images
    case symbols
    case drawingPages
    case assembly
    case materials
    case animation
    case scripts
    case scene
    case previewImage
    case changesSincePrevious
    case namedVersions
    case otherItems
    case newerResources
    case missingDamagedPreview
}

public nonisolated struct CADRecoveryReportRow: Sendable, Equatable, Identifiable {
    public var kind: CADRecoveryRowKind
    public var category: CADRecoveryCategory
    /// nil for presence/limitation rows; non-nil for counted rows.
    public var count: Int?

    public var id: String { "\(kind.rawValue).\(category.rawValue)" }
}

/// Consequence of a fact that does not change what is in the copy (for
/// example: the previous save was written by a newer app and opens read-only,
/// or the previous manifest's informational counts disagree with its records).
public nonisolated enum CADRecoveryNotice: Sendable, Equatable {
    case previousWrittenByNewerSchema(previous: Int, supported: Int)
    case previousOpensReadOnly
    case manifestCountsDiffer(categories: [String])
    case unclaimedPreviousResources(count: Int)
    case noPreviewImage
    case unrecognizedFieldsPreserved
}

public nonisolated struct CADRecoveryReport: Sendable, Equatable {
    public var rows: [CADRecoveryReportRow]
    public var notices: [CADRecoveryNotice]

    /// Facts the store could prove about the damaged package and its verified
    /// previous commit. The builder is intentionally conservative:
    ///   * only categories actually decoded from the previous document are
    ///     listed as recovered;
    ///   * a category this build cannot decode is NOT called missing — it is
    ///     either reported with an unavailable count or as unknown;
    ///   * anything that can only live in the damaged package (newer document
    ///     bytes, named versions, extra resources) is listed as retained, never
    ///     as recovered.
    public static func build(from facts: CADRecoveryFacts) -> CADRecoveryReport {
        var rows: [CADRecoveryReportRow] = []

        func addRecovered(_ category: CADRecoveryCategory, count: Int? = nil) {
            rows.append(CADRecoveryReportRow(kind: .recovered, category: category, count: count))
        }

        // Bodies are always listed (0 is a real, verified fact for an empty
        // model); every other category is listed only when it exists.
        addRecovered(.bodies, count: facts.contents.bodies)
        if facts.contents.sketches > 0 { addRecovered(.sketches, count: facts.contents.sketches) }
        if facts.contents.planes > 0 { addRecovered(.planes, count: facts.contents.planes) }
        if facts.contents.axes > 0 { addRecovered(.axes, count: facts.contents.axes) }
        if facts.contents.features > 0 { addRecovered(.features, count: facts.contents.features) }
        if facts.contents.variables > 0 { addRecovered(.variables, count: facts.contents.variables) }
        if facts.contents.images > 0 { addRecovered(.images, count: facts.contents.images) }
        if facts.contents.symbols > 0 { addRecovered(.symbols, count: facts.contents.symbols) }
        // Optional payloads that decoded to an EMPTY collection add nothing to
        // the model; their presence is not a hidden loss. An undecodable
        // payload (nil count) is still listed so its limitation is visible.
        if facts.contents.hasDrawings,
           facts.contents.drawingPageCount.map({ $0 > 0 }) ?? true {
            addRecovered(.drawingPages, count: facts.contents.drawingPageCount)
        }
        if facts.contents.hasAssembly { addRecovered(.assembly) }
        if facts.contents.hasMaterials,
           facts.contents.materialCount.map({ $0 > 0 }) ?? true {
            addRecovered(.materials, count: facts.contents.materialCount)
        }
        if facts.contents.hasAnimation,
           facts.contents.animationCount.map({ $0 > 0 }) ?? true {
            addRecovered(.animation, count: facts.contents.animationCount)
        }
        if facts.contents.hasScripts { addRecovered(.scripts) }
        if facts.contents.hasSceneSettings { addRecovered(.scene) }
        if facts.contents.hasPreviewImage { addRecovered(.previewImage) }

        // The damaged current document was not verifiable. Anything written
        // after the previous save is therefore unknown at field level; those
        // bytes stay in the damaged package.
        rows.append(CADRecoveryReportRow(kind: .unknown,
                                         category: .changesSincePrevious,
                                         count: nil))

        if facts.namedVersionCountInDamagedPackage > 0 {
            rows.append(CADRecoveryReportRow(
                kind: .retainedInOriginal, category: .namedVersions,
                count: facts.namedVersionCountInDamagedPackage))
        }
        if facts.otherItemCountInDamagedPackage > 0 {
            rows.append(CADRecoveryReportRow(
                kind: .retainedInOriginal, category: .otherItems,
                count: facts.otherItemCountInDamagedPackage))
        }
        if facts.newerResourceCountInDamagedPackage > 0 {
            rows.append(CADRecoveryReportRow(
                kind: .retainedInOriginal, category: .newerResources,
                count: facts.newerResourceCountInDamagedPackage))
        }
        if facts.damagedPreviewMissing {
            rows.append(CADRecoveryReportRow(
                kind: .unavailable, category: .missingDamagedPreview, count: nil))
        }

        var notices: [CADRecoveryNotice] = []
        if facts.previous.schemaVersion > facts.supportedSchemaVersion {
            notices.append(.previousWrittenByNewerSchema(
                previous: facts.previous.schemaVersion,
                supported: facts.supportedSchemaVersion))
        } else if facts.previousHasOpaqueAssociations {
            notices.append(.previousOpensReadOnly)
        }
        var mismatched: [String] = []
        for (key, recorded) in facts.recordedManifestCounts.sorted(by: { $0.key < $1.key }) {
            guard let decoded = facts.decodedRecordCounts[key] else { continue }
            if recorded != decoded { mismatched.append(key) }
        }
        if !mismatched.isEmpty {
            notices.append(.manifestCountsDiffer(categories: mismatched))
        }
        if facts.unclaimedPreviousResourceCount > 0 {
            notices.append(.unclaimedPreviousResources(
                count: facts.unclaimedPreviousResourceCount))
        }
        if !facts.contents.hasPreviewImage {
            notices.append(.noPreviewImage)
        }
        if facts.previousHasUnrecognizedFields {
            notices.append(.unrecognizedFieldsPreserved)
        }

        return CADRecoveryReport(rows: rows, notices: notices)
    }
}

/// Complete, proof-based input to `CADRecoveryReport.build(from:)`.
public nonisolated struct CADRecoveryFacts: Sendable, Equatable {
    public var previous: CADRecoveryIdentity
    public var contents: CADRecoveryContents
    /// Informational counts recorded in the previous manifest.
    public var recordedManifestCounts: [String: Int]
    /// Counts decoded from the verified previous document record.
    public var decodedRecordCounts: [String: Int]
    public var supportedSchemaVersion: Int
    public var previousHasOpaqueAssociations: Bool
    public var previousHasUnrecognizedFields: Bool
    public var namedVersionCountInDamagedPackage: Int
    public var otherItemCountInDamagedPackage: Int
    public var newerResourceCountInDamagedPackage: Int
    public var damagedPreviewMissing: Bool
    public var unclaimedPreviousResourceCount: Int
}

// MARK: - Preview

/// Non-mutating inspection result for an interactive open. `previewImage` is
/// the previous commit's own verified viewport artifact (the same bytes the
/// existing native viewport persisted); no second renderer is introduced.
public nonisolated struct CADRecoveryPreview: Sendable, Equatable, Identifiable {
    public var id: String { sourceFingerprint }
    public var sourceURL: URL
    public var damage: CADRecoveryDamage
    public var previous: CADRecoveryIdentity
    public var contents: CADRecoveryContents
    public var report: CADRecoveryReport
    /// Digest of everything the preview was built from. Restore refuses when
    /// the recomputed value differs (changed source, never a stale apply).
    public var sourceFingerprint: String
    public var previewImage: Data?
    /// Unverified revision/date/counts claimed by the damaged package's
    /// manifest. Present for context only; never used as identity and never
    /// presented as the current document's verified contents.
    public var currentRevisionClaim: Int?
    public var currentModifiedAtClaim: Date?
    public var currentReportedCounts: [String: Int]?
    /// The previous save opens read-only in this build (newer schema or
    /// opaque association semantics).
    public var previousOpensReadOnly: Bool
}

public nonisolated enum CADRecoveryInspection: Sendable, Equatable {
    /// The current package verifies; no recovery is involved.
    case intact
    /// The current package cannot be verified. `preview` is non-nil only when
    /// a `previous/` commit was verified; nil means recovery is unavailable
    /// and nothing was changed.
    case damaged(damage: CADRecoveryDamage, preview: CADRecoveryPreview?)
}

public nonisolated struct CADRecoveryRestoreResult: Sendable, Equatable {
    public var packageURL: URL
    public var revision: Int
    public var contentSHA256: String
    public var modelSHA256: String?
    public var sourceURL: URL
    public var sourceFingerprint: String
    /// The same proof-based report the user reviewed. The source fingerprint
    /// matched, so this description still applies to the restored copy.
    public var report: CADRecoveryReport
}

// MARK: - Errors

public nonisolated enum CADRecoveryError: Error, LocalizedError, Sendable, Equatable {
    /// No verified `previous/` commit exists (or it failed verification).
    case noVerifiedPrevious
    /// The preview does not describe this package path.
    case sourceMismatch
    /// The package changed after the preview was created.
    case sourceChanged
    case destinationExists(URL)
    case destinationParentMissing(URL)
    case destinationInsideSource
    /// The copy must stay beside the damaged package (same workspace or
    /// container folder, same volume).
    case destinationOutsideSource
    /// The destination is not a `.floecad` package path. A recovered copy is
    /// always a package, never a renamed or re-extensioned arbitrary item.
    case destinationNotPackage(URL)
    /// The verified `previous/` tree contains a symbolic link. A byte copy
    /// would reproduce the link, so the copy could point outside itself.
    case sourceNotContained
    case copyFailed(String)
    case verificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noVerifiedPrevious:
            return "The last saved version of this CAD document could not be verified."
        case .sourceMismatch:
            return "The recovery preview does not belong to this CAD package."
        case .sourceChanged:
            return "The CAD package changed after the recovery preview was created."
        case .destinationExists(let url):
            return "A recovered copy already exists at \(url.lastPathComponent)."
        case .destinationParentMissing(let url):
            return "The destination folder \(url.lastPathComponent) does not exist."
        case .destinationInsideSource:
            return "The recovered copy must be created outside the damaged package."
        case .destinationOutsideSource:
            return "The recovered copy must be created in the same folder as the damaged package."
        case .destinationNotPackage:
            return "The recovered copy must keep the .floecad package extension."
        case .sourceNotContained:
            return "The last saved version contains a link outside the document, so it cannot be copied."
        case .copyFailed(let detail):
            return "The recovered copy could not be created: \(detail)"
        case .verificationFailed(let detail):
            return "The recovered copy failed verification: \(detail)"
        }
    }
}

// MARK: - Copy destination

public nonisolated enum CADRecoveryCopyDestination {
    /// A sibling `<base> <suffix>.floecad` path that does not exist. The
    /// damaged package's directory and extension are preserved so the copy is
    /// owned by the same workspace/container. The caller passes a localized
    /// suffix ("Recovered" / "恢复副本"); an empty suffix falls back to
    /// "Recovered".
    public static func suggestedURL(for packageURL: URL,
                                    suffix: String,
                                    fileManager: FileManager = .default) -> URL {
        let parent = packageURL.deletingLastPathComponent()
        let pathExtension = packageURL.pathExtension.isEmpty
            ? "floecad" : packageURL.pathExtension
        let stem = packageURL.deletingPathExtension().lastPathComponent
        let cleanSuffix = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = cleanSuffix.isEmpty ? "Recovered" : cleanSuffix
        // Keep the base name well inside common 255-byte file-name limits.
        let base = String(stem.prefix(120))
        for index in 1...999 {
            let name = index == 1
                ? "\(base) \(label).\(pathExtension)"
                : "\(base) \(label) \(index).\(pathExtension)"
            let candidate = parent.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return parent.appendingPathComponent(
            "\(base) \(label) \(UUID().uuidString.prefix(8)).\(pathExtension)")
    }
}

// MARK: - Source fingerprint

public nonisolated enum CADRecoveryFingerprint {
    /// Deterministic digest of the exact facts a preview displayed. Restore
    /// recomputes it under the package gate and refuses on any difference.
    ///
    /// `damagedAuxiliaryItems` / `damagedBlobItems` map a relative item name to
    /// a size (directories use -1); they make the report's "retained in the
    /// damaged package" counts part of the preview identity without hashing
    /// blobs this build cannot attribute.
    public static func make(currentManifestSHA256: String?,
                            currentDocumentSHA256: String?,
                            previousManifestSHA256: String,
                            previousDocumentSHA256: String,
                            previousThumbnailSHA256: String?,
                            previousBlobs: [String: String],
                            previousExtraFiles: [String: String],
                            damagedVersionNames: [String],
                            damagedAuxiliaryItems: [String: Int],
                            damagedBlobItems: [String: Int]) -> String {
        var hasher = SHA256()
        // Length-prefixed writes avoid ambiguous concatenations.
        func add(_ value: String) {
            let data = Data(value.utf8)
            hasher.update(data: Data("\(data.count):".utf8))
            hasher.update(data: data)
        }
        add("floe.cad.recovery.preview.v1")
        add(currentManifestSHA256 ?? "-")
        add(currentDocumentSHA256 ?? "-")
        add(previousManifestSHA256)
        add(previousDocumentSHA256)
        add(previousThumbnailSHA256 ?? "-")
        add("blobs:\(previousBlobs.count)")
        for (path, digest) in previousBlobs.sorted(by: { $0.key < $1.key }) {
            add(path)
            add(digest)
        }
        add("extras:\(previousExtraFiles.count)")
        for (path, digest) in previousExtraFiles.sorted(by: { $0.key < $1.key }) {
            add(path)
            add(digest)
        }
        add("versions:\(damagedVersionNames.count)")
        for name in damagedVersionNames.sorted() { add(name) }
        add("aux:\(damagedAuxiliaryItems.count)")
        for (name, size) in damagedAuxiliaryItems.sorted(by: { $0.key < $1.key }) {
            add(name)
            add(String(size))
        }
        add("blobs-current:\(damagedBlobItems.count)")
        for (path, size) in damagedBlobItems.sorted(by: { $0.key < $1.key }) {
            add(path)
            add(String(size))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Presentation fence

/// Binds one interactive recovery presentation (a preview followed by at most
/// one restore) to the exact source package and generation it started from.
///
/// A view calls ``begin(sourceURL:)`` for every load. The returned ticket is
/// the ONLY credential that may present the inspection result or adopt the
/// atomic copy. Starting a new load, retargeting the view or invalidating it
/// advances ``generation``, so a late result from an older load can never
/// present a stale sheet or replace the document another presentation is now
/// showing. The fence also owns the one-way switch from the damaged source to
/// the recovered copy, so all host save/export/close paths can resolve the
/// document that is ACTUALLY open.
public nonisolated struct CADRecoveryPresentationFence: Equatable, Sendable {
    public struct Ticket: Equatable, Sendable {
        public let generation: Int
        public let sourceURL: URL

        init(generation: Int, sourceURL: URL) {
            self.generation = generation
            self.sourceURL = sourceURL
        }
    }

    public private(set) var generation = 0
    /// The damaged package this presentation was opened for. It stays the
    /// origin after a copy is adopted (the copy is a new standalone package;
    /// the original is never rebound or deleted).
    public private(set) var originURL: URL?
    /// The recovered copy currently presented; nil while the damaged package
    /// is shown.
    public private(set) var activeCopyURL: URL?

    private var adoptable: Ticket?

    public init() {}

    /// The file currently visible to the user: the adopted copy once a restore
    /// succeeded, otherwise the damaged origin. Never falls back to a stale
    /// copy after the presentation is retargeted.
    public var visibleURL: URL? { activeCopyURL ?? originURL }

    public var isShowingRecoveredCopy: Bool { activeCopyURL != nil }

    /// Start a new load for `sourceURL` and invalidate every older ticket.
    /// Loading the adopted copy again keeps the adopted state; any other
    /// source is a retarget and drops it.
    @discardableResult
    public mutating func begin(sourceURL: URL) -> Ticket {
        let source = sourceURL.standardizedFileURL
        if let copy = activeCopyURL {
            if source != copy {
                activeCopyURL = nil
                originURL = source
            }
        } else {
            originURL = source
        }
        generation &+= 1
        let ticket = Ticket(generation: generation, sourceURL: source)
        adoptable = ticket
        return ticket
    }

    /// The presentation is going away (navigation, dismissal, external
    /// retarget): every in-flight inspection/restore is stale.
    public mutating func invalidate() {
        generation &+= 1
        originURL = nil
        activeCopyURL = nil
        adoptable = nil
    }

    /// True only for the newest ticket of the current presentation.
    public func accepts(_ ticket: Ticket) -> Bool {
        adoptable == ticket && generation == ticket.generation
    }

    /// Adopt the copy created for `ticket`. Refused for a stale ticket, a
    /// result produced for a different package, or a second copy for the same
    /// presentation. Returns the now-active copy URL on success.
    @discardableResult
    public mutating func adopt(_ ticket: Ticket,
                               copyURL: URL,
                               resultSourceURL: URL) -> URL? {
        let copy = copyURL.standardizedFileURL
        let resultSource = resultSourceURL.standardizedFileURL
        guard accepts(ticket),
              originURL == ticket.sourceURL,
              resultSource == ticket.sourceURL,
              copy != ticket.sourceURL,
              activeCopyURL == nil else { return nil }
        activeCopyURL = copy
        adoptable = nil
        return copy
    }
}
