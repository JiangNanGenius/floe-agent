// SPDX-License-Identifier: MPL-2.0
//
// C08 retained Office recovery document exchange.
//
// The App host half (`OfficeRecoveryJournal` + `OfficeRecoveryArtifacts`) is
// the ONLY authority that decides whether a recovery path is an App-owned
// working copy or a module-verified output. This file receives its bounded,
// already-verified catalog over the trusted `floe.data/16` host channel,
// re-validates the fixed root shape, streams the exact bytes through the C07
// descriptor-relative copy, and writes bounded descriptive metadata.
//
// It deliberately never carries old task/run/workspace/root/native-generation/
// session identities, destination URIs, live grants, pending actions or
// credential references. The content is data: restore allocates fresh
// document UUIDs and app-owned files and never recreates a live recovery
// session.
import Foundation
import FloeAndroidDataExchange

// MARK: - Capture request (App host -> trusted Swift domain)

/// One bounded, non-secret description of a retained Office recovery file.
/// `root` + `relativePath` are consumed only by the rooted copy below; the
/// archive record stores a fresh package entry, never these source details.
public struct C08OfficeDraftCaptureRequest: Sendable, Equatable {
    public enum Root: String, Sendable, Equatable {
        case working
        case outputs
        /// A fresh App-owned document previously restored from a backup.
        /// Carrying it again keeps a later full backup from reintroducing a
        /// silent user-data gap.
        case restored
    }

    public struct Record: Sendable, Equatable {
        public var root: Root
        public var relativePath: String
        public var kind: C07OfficeDraftKind
        public var displayName: String
        public var format: String
        public var byteCount: Int64
        public var sha256: String
        public var createdAt: Date
        public var updatedAt: Date

        public init(root: Root, relativePath: String,
                    kind: C07OfficeDraftKind, displayName: String,
                    format: String, byteCount: Int64, sha256: String,
                    createdAt: Date, updatedAt: Date) {
            self.root = root
            self.relativePath = relativePath
            self.kind = kind
            self.displayName = displayName
            self.format = format
            self.byteCount = byteCount
            self.sha256 = sha256
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
    }

    public struct Omission: Sendable, Equatable {
        public var reason: String
        public var byteCount: Int64?
        public var sha256: String?

        public init(reason: String, byteCount: Int64? = nil,
                    sha256: String? = nil) {
            self.reason = reason
            self.byteCount = byteCount
            self.sha256 = sha256
        }
    }

    public static let format = "floe.office-drafts/1"
    public static let maximumRecords = C07OwnedDataLimits.maximumOfficeDrafts
    public static let maximumOmissions = C07OwnedDataLimits.maximumOfficeDrafts * 2

    public var records: [Record]
    public var omissions: [Omission]
    public var deduplicated: Int

    public init(records: [Record], omissions: [Omission] = [],
                deduplicated: Int = 0) {
        self.records = records
        self.omissions = omissions
        self.deduplicated = deduplicated
    }

    /// Parses the optional `officeDrafts` object from `c07.backup.begin`.
    /// Returns nil when the field is absent (an ordinary backup from a build
    /// without the recovery surface). Malformed input is a typed refusal, not
    /// a silent empty list.
    public static func parse(_ value: Any?) throws -> C08OfficeDraftCaptureRequest? {
        guard let value else { return nil }
        guard let object = value as? [String: Any] else {
            throw C07DataExchangeError.invalidScope("officeDrafts")
        }
        guard c08String(object["format"], max: 64) == format else {
            throw C07DataExchangeError.invalidScope("officeDraftFormat")
        }
        let rawRecords: [Any]
        if let records = object["records"] as? [Any] {
            rawRecords = records
        } else if object["records"] == nil {
            rawRecords = []
        } else {
            throw C07DataExchangeError.invalidScope("officeDrafts")
        }
        guard rawRecords.count <= maximumRecords else {
            throw C07DataExchangeError.tooManyEntries
        }
        var records: [Record] = []
        records.reserveCapacity(rawRecords.count)
        for raw in rawRecords {
            guard let item = raw as? [String: Any],
                  let rootText = c08String(item["root"], max: 16),
                  let root = Root(rawValue: rootText),
                  let relativePath = c08String(item["relativePath"], max: 512),
                  let kindText = c08String(item["kind"], max: 24),
                  let kind = C07OfficeDraftKind(rawValue: kindText),
                  let displayName = c08DisplayName(item["displayName"]),
                  let format = c08String(item["format"], max: 8),
                  C07OwnedOfficeDraftRecord.allowedFormats.contains(
                    format.lowercased()),
                  let byteCount = c08Int64(item["bytes"]),
                  byteCount >= 1,
                  byteCount <= C07OwnedDataLimits.maximumOfficeDraftBytes,
                  let sha256 = c08String(item["sha256"], max: 64),
                  C08OfficeDraftExchange.isSHA256(sha256),
                  let created = c08Int64(item["createdAtMillis"]),
                  let updated = c08Int64(item["updatedAtMillis"]),
                  created >= 0, updated >= 0,
                  created <= 253_402_300_799_000,
                  updated <= 253_402_300_799_000 else {
                throw C07DataExchangeError.invalidScope("officeDraftRecord")
            }
            records.append(Record(
                root: root, relativePath: relativePath, kind: kind,
                displayName: displayName, format: format.lowercased(),
                byteCount: byteCount, sha256: sha256,
                createdAt: Date(timeIntervalSince1970: Double(created) / 1_000),
                updatedAt: Date(timeIntervalSince1970: Double(updated) / 1_000)))
        }
        var omissions: [Omission] = []
        if let rawOmissions = object["omissions"] as? [Any] {
            guard rawOmissions.count <= maximumOmissions else {
                throw C07DataExchangeError.tooManyEntries
            }
            for raw in rawOmissions {
                guard let item = raw as? [String: Any],
                      let reason = c08String(item["reason"], max: 96),
                      C08OfficeDraftExchange.allowedOmissionReasons.contains(reason) else {
                    throw C07DataExchangeError.invalidScope("officeDraftOmission")
                }
                let bytes = item["bytes"].flatMap { c08Int64($0) }
                if let bytes, bytes < 0
                    || bytes > C07OwnedDataLimits.maximumOfficeDraftBytes {
                    throw C07DataExchangeError.invalidScope("officeDraftOmission")
                }
                let sha = c08String(item["sha256"], max: 64)
                if let sha, !C08OfficeDraftExchange.isSHA256(sha) {
                    throw C07DataExchangeError.invalidScope("officeDraftOmission")
                }
                omissions.append(Omission(
                    reason: reason, byteCount: bytes, sha256: sha))
            }
        } else if object["omissions"] != nil {
            throw C07DataExchangeError.invalidScope("officeDraftOmission")
        }
        let deduplicated = c08Int64(object["deduplicated"]).flatMap {
            Int(exactly: $0)
        } ?? 0
        guard deduplicated >= 0, deduplicated <= maximumRecords * 2 else {
            throw C07DataExchangeError.invalidScope("officeDraftDedupe")
        }
        return C08OfficeDraftCaptureRequest(
            records: records, omissions: omissions,
            deduplicated: deduplicated)
    }
}

// MARK: - Capture

public enum C08OfficeDraftExchange {
    public static let allowedOmissionReasons: Set<String> = [
        "missing", "corrupt", "unreadable", "untrusted",
        "changedDuringCapture", "rootMissing",
    ]

    /// Copies the exact App-host verified recovery bytes into the C07 backup
    /// work root. Bounded omissions are appended for anything missing,
    /// corrupt, unreadable or changed during the copy; a source that changes
    /// mid-read never produces a mixed snapshot.
    static func capture(
        request: C08OfficeDraftCaptureRequest?,
        workingRoot: URL,
        outputsRoot: URL,
        restoredRoot: URL,
        workRoot: URL,
        omissions: inout C07OmissionCollector,
        counts: inout C07OwnedDataCounts,
        warnings: inout [String]
    ) throws -> C07SourceOfficeDraftSection? {
        guard let request else { return nil }
        for omission in request.omissions {
            omissions.add(C07DataOmission(
                scope: "officeDraft",
                subject: "recovery-omitted-\(omissions.items.count)",
                reason: omission.reason,
                byteCount: omission.byteCount,
                sha256: omission.sha256))
        }
        guard !request.records.isEmpty else { return nil }
        guard request.records.count <= C08OfficeDraftCaptureRequest.maximumRecords else {
            throw C07DataExchangeError.tooManyEntries
        }

        let stageRoot = workRoot.appendingPathComponent(
            C07OwnedDataLimits.officeDraftDirectory, isDirectory: true)
        try C07FileSystem.ensureDirectory(stageRoot)
        let workingAvailable = C07FileSystem.isDirectory(workingRoot)
        let outputsAvailable = C07FileSystem.isDirectory(outputsRoot)
        let restoredAvailable = C07FileSystem.isDirectory(restoredRoot)

        var copiedRecords: [C07OwnedOfficeDraftRecord] = []
        var contents: [String: URL] = [:]
        var seenContent = Set<String>()
        var deduplicated = request.deduplicated
        var totalBytes: Int64 = 0

        for (index, item) in request.records.enumerated() {
            try Task.checkCancellation()
            guard validatePath(item) else {
                omissions.add(C07DataOmission(
                    scope: "officeDraft",
                    subject: "recovery-\(index)",
                    reason: "untrusted"))
                continue
            }
            let prefix = "\(item.sha256)|\(item.byteCount)"
            if seenContent.contains(prefix) {
                deduplicated += 1
                continue
            }
            let root: URL
            switch item.root {
            case .working: root = workingRoot
            case .outputs: root = outputsRoot
            case .restored: root = restoredRoot
            }
            if (item.root == .working && !workingAvailable)
                || (item.root == .outputs && !outputsAvailable)
                || (item.root == .restored && !restoredAvailable) {
                omissions.add(C07DataOmission(
                    scope: "officeDraft",
                    subject: "recovery-\(index)",
                    reason: "rootMissing"))
                continue
            }
            if totalBytes + item.byteCount >
                C07OwnedDataLimits.maximumOfficeDraftTotalBytes {
                throw C07DataExchangeError.totalTooLarge
            }
            let format = item.format.lowercased()
            let entry = "\(C07OwnedDataLimits.officeDraftDirectory)/\(UUID().uuidString).\(format)"
            let stagedURL = workRoot.appendingPathComponent(entry)
            do {
                try C07FileSystem.ensureDirectory(
                    stagedURL.deletingLastPathComponent())
                let copied = try C07RootedFileIO.copyFile(
                    sourceRoot: root,
                    sourceRelativePath: item.relativePath,
                    destinationRoot: workRoot,
                    destinationRelativePath: entry,
                    expectedSize: item.byteCount,
                    maximum: C07OwnedDataLimits.maximumOfficeDraftBytes,
                    mode: 0o600,
                    createDestinationParents: true)
                guard copied.byteCount == item.byteCount,
                      copied.sha256 == item.sha256 else {
                    C07FileSystem.removeIfPresent(stagedURL)
                    omissions.add(C07DataOmission(
                        scope: "officeDraft",
                        subject: "recovery-\(index)",
                        reason: "changedDuringCapture",
                        byteCount: item.byteCount,
                        sha256: item.sha256))
                    warnings.append("officeDraftChangedDuringCapture")
                    continue
                }
            } catch let error as C07DataExchangeError {
                C07FileSystem.removeIfPresent(stagedURL)
                omissions.add(C07DataOmission(
                    scope: "officeDraft",
                    subject: "recovery-\(index)",
                    reason: omissionReason(error),
                    byteCount: item.byteCount,
                    sha256: item.sha256))
                warnings.append("officeDraftCaptureOmitted")
                continue
            }
            totalBytes += item.byteCount
            seenContent.insert(prefix)
            let record = C07OwnedOfficeDraftRecord(
                entry: entry, kind: item.kind,
                displayName: displayName(item.displayName), format: format,
                byteCount: item.byteCount, sha256: item.sha256,
                createdAt: item.createdAt, updatedAt: item.updatedAt)
            copiedRecords.append(record)
            contents[entry] = stagedURL
        }

        guard !copiedRecords.isEmpty else {
            counts.officeDrafts = 0
            counts.officeDraftBytes = 0
            return nil
        }
        let catalog = C07OfficeDraftCatalog(records: copiedRecords)
        try catalog.validate()
        let metadataURL = workRoot.appendingPathComponent(
            "office-drafts-index.json")
        let data = try catalog.encoded()
        _ = try C07RootedFileIO.writeFile(
            data, destinationRoot: workRoot,
            destinationRelativePath: "office-drafts-index.json",
            mode: 0o600,
            createDestinationParents: false)
        let digest = try C07Digest.file(metadataURL)
        let section = C07OwnedOfficeDraftSection(
            count: copiedRecords.count,
            byteCount: digest.byteCount,
            sha256: digest.sha256,
            deduplicated: deduplicated > 0 ? deduplicated : nil)
        counts.officeDrafts = copiedRecords.count
        counts.officeDraftBytes = catalog.contentBytes
        if deduplicated > 0 {
            warnings.append("officeDraftDeduplicated:\(deduplicated)")
        }
        return C07SourceOfficeDraftSection(
            section: section, catalog: catalog,
            metadataURL: metadataURL, contents: contents)
    }

    // MARK: - Restore

    public struct RestoredManifest: Codable, Sendable, Equatable {
        public static let schema = "floe.office-restored/1"
        public var schema: String
        public var restoreID: UUID
        public var documents: [RestoredDocument]

        public init(restoreID: UUID, documents: [RestoredDocument]) {
            self.schema = Self.schema
            self.restoreID = restoreID
            self.documents = documents
        }
    }

    public struct RestoredDocument: Codable, Sendable, Equatable {
        public var documentID: UUID
        public var fileName: String
        public var displayName: String
        public var format: String
        public var kind: C07OfficeDraftKind
        public var byteCount: Int64
        public var sha256: String
        public var restoredAt: Date

        public init(documentID: UUID, fileName: String, displayName: String,
                    format: String, kind: C07OfficeDraftKind,
                    byteCount: Int64, sha256: String, restoredAt: Date) {
            self.documentID = documentID
            self.fileName = fileName
            self.displayName = displayName
            self.format = format
            self.kind = kind
            self.byteCount = byteCount
            self.sha256 = sha256
            self.restoredAt = restoredAt
        }
    }

    public struct RestoredCommit: Sendable, Equatable {
        public var count: Int
        public var roots: [URL]

        public init(count: Int, roots: [URL]) {
            self.count = count
            self.roots = roots
        }
    }

    /// Creates ONLY new App-owned files and identities. Any failure removes
    /// the one restore directory this call created; an existing directory is
    /// a collision, never an overwrite.
    public static func commitRestoredDocuments(
        entries: [C07OfficeDraftPlanEntry],
        staged: C07StagedOfficeDraftSection?,
        restoreRoot: URL,
        restoreID: UUID
    ) throws -> RestoredCommit {
        guard !entries.isEmpty else { return RestoredCommit(count: 0, roots: []) }
        guard let staged else {
            throw C07DataExchangeError.invalidManifest("officeDraftSectionMissing")
        }
        try staged.section.validate()
        try staged.catalog.validate()
        guard staged.catalog.records.count == staged.section.count,
              entries.count == staged.catalog.records.count else {
            throw C07DataExchangeError.invalidManifest("officeDraftCount")
        }
        let byEntry = Dictionary(
            uniqueKeysWithValues: staged.catalog.records.map { ($0.entry, $0) })
        var manifestRecords: [RestoredDocument] = []
        var manifestEntries = Set<String>()
        manifestRecords.reserveCapacity(entries.count)
        if FileManager.default.fileExists(atPath: restoreRoot.path) {
            throw C07DataExchangeError.artifactCollision("officeDraftRoot")
        }
        return try C07RootedFileIO.withExclusiveDirectory(at: restoreRoot) { directory in
            let now = Date()
            var seen = Set<UUID>()
            for entry in entries {
                try entry.validate()
                guard manifestEntries.insert(entry.sourceEntry).inserted,
                      seen.insert(entry.documentID).inserted,
                      let record = byEntry[entry.sourceEntry],
                      record.sha256 == entry.sha256,
                      record.byteCount == entry.byteCount,
                      record.format == entry.format,
                      record.kind == entry.kind,
                      record.displayName == entry.displayName,
                      let sourceURL = staged.contents[entry.sourceEntry] else {
                    throw C07DataExchangeError.invalidManifest("officeDraftPlan")
                }
                let fileName = "\(entry.documentID.uuidString).\(entry.format)"
                let copied = try C07RootedFileIO.copyFile(
                    sourceRoot: sourceURL.deletingLastPathComponent(),
                    sourceRelativePath: sourceURL.lastPathComponent,
                    destinationRoot: restoreRoot,
                    destinationRelativePath: fileName,
                    expectedSize: entry.byteCount,
                    maximum: C07OwnedDataLimits.maximumOfficeDraftBytes,
                    mode: 0o600,
                    createDestinationParents: false,
                    destinationDirectory: directory)
                guard copied.byteCount == entry.byteCount,
                      copied.sha256 == entry.sha256 else {
                    throw C07DataExchangeError.hashMismatch(fileName)
                }
                manifestRecords.append(RestoredDocument(
                    documentID: entry.documentID, fileName: fileName,
                    displayName: entry.displayName, format: entry.format,
                    kind: entry.kind, byteCount: entry.byteCount,
                    sha256: entry.sha256, restoredAt: now))
            }
            let manifest = RestoredManifest(
                restoreID: restoreID, documents: manifestRecords)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(manifest)
            guard Int64(data.count) <= C07OwnedDataLimits.maximumOfficeDraftSectionBytes else {
                throw C07DataExchangeError.entryTooLarge("officeDraftManifest")
            }
            _ = try C07RootedFileIO.writeFile(
                data, destinationRoot: restoreRoot,
                destinationRelativePath: "manifest.json",
                mode: 0o600,
                createDestinationParents: false,
                destinationDirectory: directory)
            return RestoredCommit(count: manifestRecords.count,
                                  roots: [restoreRoot])
        }
    }

    /// Written only after the owned-data commit transaction succeeded, so a
    /// consumer never lists documents from a restore that is still pending
    /// rollback. A failure here aborts the restore and the exact plan
    /// rollback removes the whole new directory.
    public static func markRestoreCommitted(restoreRoot: URL,
                                            restoreID: UUID) throws {
        let payload = Data(
            "{\"restoreID\":\"\(restoreID.uuidString)\"}".utf8)
        _ = try C07RootedFileIO.writeFile(
            payload, destinationRoot: restoreRoot,
            destinationRelativePath: "complete.json",
            mode: 0o600,
            expectedSHA256: nil,
            createDestinationParents: false)
    }

    // MARK: - Validation helpers

    /// One bounded user-facing name; a local path separator never reaches
    /// the archive metadata even if a host supplied one.
    static func displayName(_ raw: String) -> String {
        let leaf = raw
            .split(separator: "/", omittingEmptySubsequences: false)
            .last
            .map(String.init) ?? raw
        let last = leaf
            .split(separator: "\\", omittingEmptySubsequences: false)
            .last
            .map(String.init) ?? leaf
        let filtered = last.filter { character in
            character.unicodeScalars.allSatisfy {
                $0.value >= 0x20 && $0.value != 0x7F
                    && !CharacterSet.controlCharacters.contains($0)
            }
        }
        let trimmed = filtered.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix(".") else {
            return "Office document"
        }
        return C07OwnedOfficeDraftRecord.boundedName(trimmed)
    }

    static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.unicodeScalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57)
                || ($0.value >= 97 && $0.value <= 102)
        }
    }

    private static func validatePath(
        _ item: C08OfficeDraftCaptureRequest.Record
    ) -> Bool {
        guard !item.relativePath.isEmpty,
              item.relativePath.utf8.count <= 512,
              !item.relativePath.hasPrefix("/"),
              !item.relativePath.contains("\\"),
              !item.relativePath.unicodeScalars.contains(where: {
                  $0.value < 32 || $0.value == 127
                      || CharacterSet.controlCharacters.contains($0)
              }) else { return false }
        let parts = item.relativePath.split(
            separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              !parts[0].isEmpty, parts[0] != ".", parts[0] != "..",
              !parts[1].isEmpty else { return false }
        switch item.root {
        case .working:
            guard UUID(uuidString: String(parts[0])) != nil,
                  parts[0].count == 36,
                  parts[1] == "document.\(item.format.lowercased())" else { return false }
        case .restored:
            guard UUID(uuidString: String(parts[0])) != nil,
                  parts[0].count == 36 else { return false }
            let leaf = String(parts[1])
            let pieces = leaf.split(separator: ".", maxSplits: 1,
                                    omittingEmptySubsequences: false)
            guard pieces.count == 2,
                  let documentID = UUID(uuidString: String(pieces[0])),
                  documentID.uuidString.lowercased()
                    == String(pieces[0]).lowercased(),
                  String(pieces[1]) == item.format.lowercased() else { return false }
        case .outputs:
            let generation = String(parts[0])
            guard !generation.isEmpty,
                  generation.allSatisfy({ $0.isNumber }),
                  generation.first != "0",
                  generation.count <= 19,
                  UInt64(generation) != nil else { return false }
            let leaf = String(parts[1])
            let suffix = ".\(item.format.lowercased())"
            guard leaf.hasSuffix(suffix) else { return false }
            let stem = String(leaf.dropLast(suffix.count))
            let pieces = stem.split(separator: "-", omittingEmptySubsequences: false)
            guard pieces.count >= 2,
                  let operation = pieces.first,
                  !operation.isEmpty,
                  operation.count <= 64,
                  operation.unicodeScalars.allSatisfy({
                      ($0.value >= 48 && $0.value <= 57)
                          || ($0.value >= 65 && $0.value <= 90)
                          || ($0.value >= 97 && $0.value <= 122)
                          || $0.value == 95 || $0.value == 45
                  }),
                  pieces.dropFirst().allSatisfy({ piece in
                      !piece.isEmpty && piece.allSatisfy(\.isNumber)
                  }) else { return false }
        }
        return true
    }

    private static func omissionReason(_ error: C07DataExchangeError) -> String {
        switch error {
        case .symlinkUnsupported, .specialFileUnsupported, .unsafePath:
            return "untrusted"
        case .sizeMismatch:
            return "changedDuringCapture"
        case .storageUnavailable(let reason):
            return reason.hasSuffix(":2") ? "missing" : "unreadable"
        default:
            return "unreadable"
        }
    }
}

// MARK: - Bounded JSON helpers

private func c08String(_ value: Any?, max: Int) -> String? {
    guard let text = value as? String, !text.isEmpty,
          text.utf8.count <= max else { return nil }
    return text
}

private func c08Int64(_ value: Any?) -> Int64? {
    guard let number = value as? NSNumber else { return nil }
    let double = number.doubleValue
    guard double.isFinite, double.rounded(.towardZero) == double,
          double >= Double(Int64.min), double <= Double(Int64.max) else {
        return nil
    }
    return number.int64Value
}

private func c08DisplayName(_ value: Any?) -> String? {
    guard let raw = value as? String else { return nil }
    let filtered = raw.filter { character in
        character.unicodeScalars.allSatisfy {
            $0.value >= 0x20 && $0.value != 0x7F
                && !CharacterSet.controlCharacters.contains($0)
        }
    }
    let trimmed = String(filtered.prefix(
        C07OwnedDataLimits.maximumOfficeDraftDisplayNameBytes))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          !trimmed.contains("/"), !trimmed.contains("\\"),
          !trimmed.hasPrefix(".") else { return nil }
    return trimmed
}
