// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Everything needed to build one small native library package from the
/// verified publisher archive. The library ZIP is the already-verified
/// per-library source; the App layer reads the exact original file from its
/// nested `originals/<source>.zip` entry. Core never opens a filesystem path
/// supplied by a model.
public struct ElectronicsRemotePartMaterial: Sendable {
    public let libraryID: String
    public let record: ElectronicsRemotePartSummary
    public let recordJSON: String
    public let recordSHA256: String
    public let source: ElectronicsRemoteCatalog.Source
    public let libraryArchiveURL: URL
    public let modelRecords: [ElectronicsRemoteModelRecord]
    /// Exact source-relative paths and bytes: the publisher's original file
    /// plus license evidence. No normalized geometry is invented here.
    public let originalFiles: [String: Data]

    public init(libraryID: String, record: ElectronicsRemotePartSummary, recordJSON: String,
                recordSHA256: String, source: ElectronicsRemoteCatalog.Source,
                libraryArchiveURL: URL, modelRecords: [ElectronicsRemoteModelRecord],
                originalFiles: [String: Data]) {
        self.libraryID = libraryID; self.record = record; self.recordJSON = recordJSON
        self.recordSHA256 = recordSHA256; self.source = source
        self.libraryArchiveURL = libraryArchiveURL; self.modelRecords = modelRecords
        self.originalFiles = originalFiles
    }

    public var originalsArchiveEntry: String { "originals/\(libraryID).zip" }
    public var recordPayloadPath: String { "provenance/record.json" }
}

public struct ElectronicsRemoteInstalledModel: Codable, Hashable, Sendable {
    public let modelID: String?
    public let fileName: String
    public let format: String
    public let gitBlobSHA1: String?
    public let sourcePath: String
    public let licenseSourceID: String?
}

public struct ElectronicsRemoteInstallResult: Codable, Hashable, Sendable {
    public let reference: EDALibraryReference
    public let snapshotSHA256: String
    public let libraryID: String
    public let sourceRecordID: String
    public let sourceRecordSHA256: String
    public let sourcePath: String
    public let partName: String
    public let partKind: EDALibraryPart.Kind
    public let catalogRevision: UInt64
    public let models: [ElectronicsRemoteInstalledModel]
    public let originalBytes: Int
    public let normalizedRecordBytes: Int
    public let noticeCount: Int
    public let semantics: String
}

public enum ElectronicsRemoteInstallError: Error, Equatable, LocalizedError, Sendable {
    case unsupported(String)
    case reviewRequired(String)
    case invalidRecord(String)
    case integrity(String)
    case budget(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unsupported(let detail): "This catalogue part is not supported for native installation: " + detail
        case .reviewRequired(let detail): "This catalogue part requires review before native installation: " + detail
        case .invalidRecord(let detail): "The normalized catalogue record is invalid: " + detail
        case .integrity(let detail): "The catalogue source failed integrity verification: " + detail
        case .budget(let detail): "The native library cannot accept this part: " + detail
        case .cancelled: "The catalogue installation was cancelled."
        }
    }
}

/// Converts one verified normalized publisher record into a small immutable
/// native library package. Raw originals, licenses, source status, conversion
/// notes and model references are retained; reviewRequired/unsupported records
/// never become installable.
public enum ElectronicsRemoteInstaller {
    public static let maximumOriginalBytes = 32 * 1_024 * 1_024
    public static let maximumOriginalFiles = 8
    public static let maximumModelReferences = 8

    public static func install(material: ElectronicsRemotePartMaterial, into store: EDALibraryStore,
                               expectedInventoryRevision: UInt64? = nil,
                               cancelled: @escaping @Sendable () -> Bool = { false })
        async throws -> ElectronicsRemoteInstallResult {
        guard !cancelled(), !Task.isCancelled else { throw ElectronicsRemoteInstallError.cancelled }
        guard material.source.id == material.libraryID else {
            throw ElectronicsRemoteInstallError.invalidRecord("library identity differs from its catalogue source")
        }
        guard !material.record.library.isEmpty else {
            throw ElectronicsRemoteInstallError.invalidRecord("part has no logical library namespace")
        }
        guard material.record.status == "converted" else {
            throw ElectronicsRemoteInstallError.reviewRequired(
                "The publisher marked this record as \(material.record.status); the original is retained in the catalogue but no native geometry is claimed.")
        }
        let recordBytes = Data(material.recordJSON.utf8)
        guard recordBytes.count <= 32 * 1_024 * 1_024,
              ElectronicsRemoteDigest.sha256(recordBytes + Data([0x0A])) == material.record.sha256,
              material.recordSHA256 == material.record.sha256 else {
            throw ElectronicsRemoteInstallError.integrity("the normalized record line differs from its verified digest")
        }
        guard let object = try? JSONSerialization.jsonObject(with: recordBytes) as? [String: Any],
              object["kind"] as? String == material.record.kind,
              object["status"] as? String == material.record.status,
              let format = object["format"] as? String else {
            throw ElectronicsRemoteInstallError.invalidRecord("record shape/status is not the verified normalized form")
        }
        guard format == "kicad" else {
            throw ElectronicsRemoteInstallError.unsupported(
                "normalized \(format) records have no native geometry adapter yet; the original record remains available for download/read")
        }
        guard ["symbol", "footprint"].contains(material.record.kind) else {
            throw ElectronicsRemoteInstallError.unsupported(
                "\(material.record.kind) records need an explicit symbol/footprint association; search and install the symbol and footprint separately")
        }
        guard let sourceObject = object["source"] as? [String: Any],
              let sourcePath = sourceObject["path"] as? String,
              sourcePath == material.record.sourcePath else {
            throw ElectronicsRemoteInstallError.invalidRecord("source path differs from the verified search row")
        }
        guard let original = material.originalFiles[sourcePath], !original.isEmpty,
              original.count <= maximumOriginalBytes,
              material.originalFiles.count <= maximumOriginalFiles,
              material.originalFiles.values.reduce(0, { $0 + $1.count }) <= 8 * maximumOriginalBytes else {
            throw ElectronicsRemoteInstallError.integrity("the publisher original source is absent or oversized")
        }
        if let expected = sourceObject["sha256"] as? String,
           ElectronicsRemoteDigest.isSHA256(expected),
           ElectronicsRemoteDigest.sha256(original) != expected {
            throw ElectronicsRemoteInstallError.integrity("the original source file differs from its normalized source digest")
        }
        let extensionName = URL(fileURLWithPath: sourcePath).pathExtension.lowercased()
        let expectedExtension = material.record.kind == "symbol" ? "kicad_sym" : "kicad_mod"
        guard extensionName == expectedExtension else {
            throw ElectronicsRemoteInstallError.invalidRecord("original source is not a \(expectedExtension) file")
        }

        let modelReferences = try normalizedModelReferences(object, material: material)
        let issues = normalizedIssues(object)
        let licensePaths = material.originalFiles.keys.filter {
            let upper = $0.uppercased()
            return upper.contains("LICENSE") || upper.contains("COPYING")
        }.sorted()
        let licenseText = licensePaths.compactMap {
            String(data: material.originalFiles[$0]!, encoding: .utf8)
        }.joined(separator: "\n\n")
        var gatheredInputs = material.originalFiles
        gatheredInputs[sourcePath] = original
        let inputs = gatheredInputs

        let worker = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                guard !cancelled() else { throw ElectronicsRemoteInstallError.cancelled }
                let draft = try EDALibraryImport.inspect(files: inputs, title: material.record.name,
                    cancelled: { cancelled() || Task.isCancelled })
                guard let imported = draft.package else {
                    let reasons = draft.entries.flatMap(\.notices)
                        .filter { $0.severity == .blocking }
                        .prefix(8).map { $0.code + " (" + $0.path + "): " + $0.detail }.joined(separator: "; ")
                    throw ElectronicsRemoteInstallError.unsupported(
                        reasons.isEmpty ? "the original file produced no native symbol or footprint" : reasons)
                }
                let candidates = imported.parts.filter { $0.kind == .symbol || $0.kind == .footprint }
                guard let part = candidates.first(where: { $0.name == material.record.name }) ?? (candidates.count == 1 ? candidates[0] : nil) else {
                    throw ElectronicsRemoteInstallError.unsupported(
                        "the publisher source contains multiple native entries but no unique '\(material.record.name)' entry")
                }
                var package = imported
                var value = part
                let provenance = [
                    "FloeRemoteLibrary": material.libraryID,
                    "FloeRemoteRecordID": material.record.id,
                    "FloeRemoteRecordSHA256": material.record.sha256,
                    "FloeRemoteDataVersion": material.source.commit,
                    "FloeRemoteStatus": material.record.status,
                    "FloeRemoteSourcePath": sourcePath,
                    "FloeRemoteSourceCommit": material.source.commit,
                    "FloeRemoteSourceRepository": material.source.repository,
                    "FloeRemoteSourceLicense": material.source.license?.id ?? "",
                    "FloeRemoteSourceModifications": material.source.modifications ?? ""
                ]
                value.parameters.merge(provenance) { _, new in new }
                value.aliases = Array(Set(value.aliases + [material.libraryID, material.record.name, material.record.sourcePath])).sorted()
                var notices = value.notices
                notices.append(.init("remote_source_pinned", .information, path: sourcePath,
                    detail: "Exact publisher source retained. Repository \(material.source.repository) at commit \(material.source.commit); normalized status \(material.record.status)."))
                for issue in issues {
                    notices.append(.init("remote_conversion_note", .warning, path: sourcePath, detail: issue))
                }
                if !modelReferences.isEmpty, var footprint = value.footprint {
                    footprint.modelReferences = modelReferences
                    value.footprint = footprint
                }
                value.notices = notices
                guard !notices.contains(where: { $0.severity == .blocking }) else {
                    let reasons = notices.filter { $0.severity == .blocking }.prefix(8)
                        .map { $0.code + " (" + $0.path + "): " + $0.detail }.joined(separator: "; ")
                    throw ElectronicsRemoteInstallError.unsupported(reasons)
                }
                let partIndex = package.parts.firstIndex(where: { $0.id == value.id })!
                package.parts[partIndex] = value
                let packageID = "floe.remote." + material.libraryID + "." + material.record.kind + "." + String(material.record.sha256.prefix(16))
                package.id = packageID
                package.version = "1.0.0"
                package.title = material.record.name + " · " + material.libraryID
                var licenses = package.licenses
                if let sourceLicense = material.source.license {
                    if !licenses.contains(where: { $0.id == sourceLicense.id }) {
                        licenses.append(.init(id: sourceLicense.id, attribution: sourceLicense.attribution,
                            text: licenseText.isEmpty ? sourceLicense.attribution + ". Original source retained; see the catalogue license URL." : licenseText,
                            url: sourceLicense.url,
                            modifications: (material.source.modifications ?? "") + " Remote selected-part package; original file is unchanged."))
                    }
                }
                package.licenses = licenses
                let provenanceData = try JSONSerialization.data(withJSONObject: [
                    "libraryID": material.libraryID, "recordID": material.record.id,
                    "recordSHA256": material.record.sha256, "sourcePath": sourcePath,
                    "sourceCommit": material.source.commit, "sourceLicense": material.source.license?.id ?? "",
                    "models": modelReferences.map { reference -> [String: Any] in
                        ["modelID": reference.modelID ?? "", "path": reference.sourcePath,
                         "format": reference.format, "gitBlobSHA1": reference.gitBlobSHA1 ?? ""]
                    }
                ], options: [.sortedKeys])
                package.sourcePayloads["provenance/record.json"] = recordBytes
                package.sourcePayloads["provenance/install.json"] = provenanceData
                try package.validate()
                return (package, value.id)
        }
        let built: (package: EDALibraryPackage, partID: String)
        do {
            built = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                // A detached task does not inherit the parent's cancellation.
                // Cancel its handle explicitly, then always join below.
                worker.cancel()
            }
            try Task.checkCancellation()
        } catch {
            worker.cancel()
            _ = try? await worker.value
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
        guard !cancelled(), !Task.isCancelled else { throw ElectronicsRemoteInstallError.cancelled }
        let package = built.package, partID = built.partID

        let inventory = try await store.inventory()
        guard expectedInventoryRevision == nil || expectedInventoryRevision == inventory.revision else {
            throw EDAError.staleRevision(expected: expectedInventoryRevision!, actual: inventory.revision)
        }
        let packageBytes = try EDALibraryDigest.encoded(package)
        let packageSHA256 = EDALibraryDigest.sha256(packageBytes)
        do {
            _ = try await store.install(package, expectedInventoryRevision: expectedInventoryRevision,
                activate: true, deliveredContentSHA256: packageSHA256, cancelled: cancelled)
        } catch let error as EDAError {
            if case .invalid(let reason) = error, reason == "active library catalog budget" {
                throw ElectronicsRemoteInstallError.budget(
                    "the active library catalog would exceed 128 MiB of retained originals or 100,000 parts; the previous libraries remain active")
            }
            throw error
        }
        let catalog = try await store.catalog()
        guard let entry = catalog.entries.first(where: { $0.reference.packageID == package.id && $0.reference.partID == partID }) else {
            throw ElectronicsRemoteInstallError.integrity("the installed package did not read back from the native catalog")
        }
        let snapshot = try await store.snapshot(entry.reference)
        guard snapshot.packageSHA256 == entry.reference.packageSHA256,
              snapshot.part.id == partID,
              snapshot.part.footprint?.modelReferences == (modelReferences.isEmpty ? nil : modelReferences) else {
            throw ElectronicsRemoteInstallError.integrity("the installed native snapshot differs from the verified package")
        }
        return .init(reference: entry.reference, snapshotSHA256: try snapshot.sha256,
            libraryID: material.libraryID, sourceRecordID: material.record.id,
            sourceRecordSHA256: material.record.sha256, sourcePath: sourcePath,
            partName: snapshot.part.name, partKind: snapshot.part.kind,
            catalogRevision: catalog.inventoryRevision,
            models: modelReferences.map { .init(modelID: $0.modelID, fileName: $0.fileName,
                format: $0.format, gitBlobSHA1: $0.gitBlobSHA1, sourcePath: $0.sourcePath,
                licenseSourceID: $0.licenseSourceID) },
            originalBytes: inputs.values.reduce(0) { $0 + $1.count }, normalizedRecordBytes: recordBytes.count,
            noticeCount: snapshot.part.notices.count,
            semantics: "The selected normalized record was converted through the existing native KiCad import, installed with the exact publisher original and license, and read back as a native EDALibraryReference. Model references are metadata only; model bytes are downloaded separately and rendering is not claimed here.")
    }

    // MARK: - Normalized record extras

    private static func normalizedIssues(_ object: [String: Any]) -> [String] {
        guard let values = object["issues"] as? [Any], values.count <= 64 else { return [] }
        return values.prefix(64).compactMap { value in
            if let text = value as? String, text.utf8.count <= 512 { return text }
            if let dictionary = value as? [String: Any] {
                return String(decoding: (try? JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
            }
            return nil
        }
    }

    private static func normalizedModelReferences(_ object: [String: Any],
                                                  material: ElectronicsRemotePartMaterial) throws
        -> [EDAFootprintModelReference] {
        guard let raw = object["modelReferences"] else { return [] }
        guard let items = raw as? [[String: Any]], items.count <= maximumModelReferences else {
            throw ElectronicsRemoteInstallError.invalidRecord("footprint model reference list is invalid or oversized")
        }
        let source = material.source
        return try items.map { item in
            guard let file = item["file"] as? String, !file.isEmpty, file.utf8.count <= 2_048,
                  let relative = normalizeModelPath(file), ElectronicsRemoteValidation.safeRelativePath(relative) else {
                throw ElectronicsRemoteInstallError.invalidRecord("footprint model file path is invalid")
            }
            let fileName = relative.split(separator: "/").last.map(String.init) ?? relative
            let format = URL(fileURLWithPath: fileName).pathExtension.lowercased()
            guard !format.isEmpty, format.utf8.count <= 16 else {
                throw ElectronicsRemoteInstallError.invalidRecord("footprint model file has no format suffix")
            }
            let record = material.modelRecords.first { candidate in
                candidate.path == relative || candidate.path.hasSuffix("/" + relative) || relative.hasSuffix("/" + candidate.path)
            }
            // An unmatched reference remains retained and truthful; bytes are
            // unavailable and 3D status reports it rather than inventing one.
            let reference = EDAFootprintModelReference(modelID: record?.id, sourceID: record?.sourceID,
                sourcePath: relative, fileName: fileName, format: format,
                repository: record?.repository ?? source.repository, revision: record?.revision,
                gitBlobSHA1: record?.gitBlobSHA1, sha256: record?.sha256, byteCount: record?.byteCount,
                offsetMillimetres: vector(item["offset"]), rotationDegrees: vector(item["rotationDeg"]),
                scale: vector(item["scale"]), licenseSourceID: record?.licenseSourceID ?? source.id,
                licenseAttribution: source.license?.attribution)
            try reference.validate()
            return reference
        }
    }

    private static func normalizeModelPath(_ file: String) -> String? {
        var value = file.replacingOccurrences(of: "\\", with: "/")
        if value.hasPrefix("${"), let close = value.firstIndex(of: "}") {
            value = String(value[value.index(after: close)...])
        }
        while value.hasPrefix("/") { value.removeFirst() }
        if value.hasPrefix("3Dmodels/") { value.removeFirst("3Dmodels/".count) }
        return value.isEmpty ? nil : value
    }

    private static func vector(_ raw: Any?) -> [Double]? {
        guard let values = raw as? [Any], values.count == 3 else { return nil }
        var result: [Double] = []
        for value in values {
            let number: Double?
            if let value = value as? NSNumber { number = value.doubleValue }
            else if let value = value as? Double { number = value }
            else { number = nil }
            guard let number, number.isFinite else { return nil }
            result.append(number)
        }
        return result
    }
}
