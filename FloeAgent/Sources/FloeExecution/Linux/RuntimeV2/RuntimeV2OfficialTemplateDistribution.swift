// FloeExecution — official software template distribution and registration.
//
// C5 wiring: the immutable installed-disk artifacts built and boot-verified by
// the `component-image-ci` cloud workflow (recipes owned by job D) are pinned
// here by exact digest, downloaded with the existing verified image install
// service, and registered through the existing Runtime v2 template store.
// Nothing in this file invents an artifact, a package or a digest:
//
//   * the distribution pin names the exact archive URL/SHA-512 and the
//     template image id/disk SHA-512 that the cloud run produced;
//   * the archive is verified against the pin before extraction (the same
//     `LinuxGuestImageInstallationService.importArchive` path every guest
//     image uses);
//   * the image manifest's own `template` block — itself written only from
//     the guest's stage-2 verification evidence — provides the real package
//     listing; a `verified=false` block, a recipe digest mismatch, missing
//     packages or a disk digest mismatch all fail closed and register
//     nothing;
//   * registration keeps the image's own disk as the template blob (the same
//     content-addressed bytes the image already stores), so several pinned
//     environments clone one immutable install and layer only their private
//     delta on top.
//
// No App flow may call this before the pinned artifact exists: with an empty
// distribution the status is an explicit `dependency-missing` report.

import Foundation
import FloeCore
import ZIPFoundation

// MARK: - Distribution pin

/// One immutable official template artifact, exactly as published by the
/// component-image-ci run. `recipeJSON` is the repository recipe the image was
/// qualified against; it is re-validated and its SHA-512 must match the
/// recipe digest recorded in the image's own manifest template block.
public struct RuntimeV2OfficialTemplateArtifact: Sendable, Equatable {
    public var templateID: String
    public var version: Int
    /// The guest image id inside the archive (…-dev-document for the
    /// non-default templates).
    public var imageID: String
    public var archiveURL: String
    public var archiveSHA512: String
    public var archiveBytes: Int64
    /// The verified `disk` artifact SHA-512 of that image: this is also the
    /// template's parent/base digest and the template disk's content digest.
    public var diskSHA512: String
    /// SHA-512 of the exact recipe file bytes (the same digest the image
    /// manifest records as `template.recipeSha512`).
    public var recipeSHA512: String
    /// The exact recipe file bytes, base64-encoded so the digest survives any
    /// Swift source formatting.
    public var recipeBase64: String
    /// The cloud qualification run whose boots installed and verified the
    /// template (never a placeholder).
    public var qualificationRunURL: String
    public var sourceRef: String

    public init(
        templateID: String, version: Int, imageID: String,
        archiveURL: String, archiveSHA512: String, archiveBytes: Int64,
        diskSHA512: String, recipeSHA512: String, recipeBase64: String,
        qualificationRunURL: String, sourceRef: String
    ) {
        self.templateID = templateID
        self.version = version
        self.imageID = imageID
        self.archiveURL = archiveURL
        self.archiveSHA512 = archiveSHA512
        self.archiveBytes = archiveBytes
        self.diskSHA512 = diskSHA512
        self.recipeSHA512 = recipeSHA512
        self.recipeBase64 = recipeBase64
        self.qualificationRunURL = qualificationRunURL
        self.sourceRef = sourceRef
    }

    /// The decoded recipe bytes.
    public var recipeData: Data? { Data(base64Encoded: recipeBase64) }
}

/// The compiled-in distribution pins. Empty until a cloud run really produced
/// the artifact and its digests were transcribed (with the evidence URL);
/// an empty catalog reports `dependency-missing` instead of offering a
/// download that cannot be trusted.
public enum RuntimeV2OfficialTemplateDistribution {
    public static let artifacts: [RuntimeV2OfficialTemplateArtifact] = RuntimeV2OfficialTemplatePinnedArtifacts.all

    public static func artifact(templateID: String) -> RuntimeV2OfficialTemplateArtifact? {
        artifacts.first { $0.templateID == templateID }
    }
}

/// The pins themselves live in this separate, reviewable table so the
/// integration commit that adds a cloud-verified artifact is small and its
/// evidence (run URL, digests) is explicit.
public enum RuntimeV2OfficialTemplatePinnedArtifacts {
    // The basic template was published as an immutable component prerelease
    // after both TinyEMU boot checks and the corresponding-source audit. The
    // final archive digest differs from the image-build input because the
    // published manifest adds its release provenance; the disk bytes do not.
    public static let all: [RuntimeV2OfficialTemplateArtifact] = [
        RuntimeV2OfficialTemplateArtifact(
            templateID: "basic",
            version: 1,
            imageID: "floe-debian13-riscv64-202609202607-basic-r572a77382feb-b35928017233",
            archiveURL: "https://github.com/JiangNanGenius/floe-agent/releases/download/floe-linux-template-basic-20260923.1/floe-linux-guest-floe-debian13-riscv64-202609202607-basic-r572a77382feb-b35928017233.zip",
            archiveSHA512: "773ea79e613b73024f66269beaf3469c4d997a9ce60cc6666efec02163bd7e019817261a88fce96240dc30cf5f6afff2677f3efbe0d7fba2128bf57403ba8f30",
            archiveBytes: 547_070_503,
            diskSHA512: "34952a2d0cfc147a08a0f21eb4632e6e90560792084250f8d980a0da371ba47b9029e096972b2cfb92598ee0ce893ec6df338033c7a7d7bb9737a6aa0ad65039",
            recipeSHA512: "c66ac0502f050424dee5524698621b936929cc3d09a15c21e103374d5d0c9f460c2d1c72b5464d2a446d49d9b7b1c4c485d9515a05348106b51116284f3216e6",
            recipeBase64: "ewogICJzY2hlbWEiOiAxLAogICJuYW1lIjogImJhc2ljIiwKICAiZGVzY3JpcHRpb24iOiAiRmxvZSBiYXNpYyBMaW51eCBndWVzdDogdGhlIDEzIHVzZXItZmFjaW5nIHNoZWxsIGNvbW1hbmRzIGZyb20gdGhlIEJ1aWxkIDIyNSBmZWVkYmFjayByZXBvcnQgcGx1cyBQeXRob24gMyAocGlwL3ZlbnYvbnVtcHkpLCBOb2RlLmpzL25wbSBhbmQgSFRUUFMgdHJ1c3QuIFRoaXMgaXMgdGhlIHBhY2thZ2Ugc2V0IEZsb2VBZ2VudC9MaW51eEd1ZXN0L2ltYWdlL2d1ZXN0LXN0YWdlMS1pbnN0YWxsLnNoIGluc3RhbGxzIGZvciB0aGUgZGVmYXVsdCBpbWFnZTsgZXZlcnkgcmVxdWlyZW1lbnQgaXMgaW5kZXBlbmRlbnRseSByZS12ZXJpZmllZCBhZ2FpbnN0IHRoZSBsaXZlIGRwa2cgZGF0YWJhc2UgZHVyaW5nIGJvb3QgQiBvZiB0aGUgaW1hZ2UgYnVpbGQuIiwKICAicGFja2FnZXMiOiB7CiAgICAicHJvY3BzIjogbnVsbCwKICAgICJ1dGlsLWxpbnV4IjogbnVsbCwKICAgICJjb3JldXRpbHMiOiBudWxsLAogICAgImJhc2giOiBudWxsLAogICAgInpzaCI6IG51bGwsCiAgICAiemlwIjogbnVsbCwKICAgICJ1bnppcCI6IG51bGwsCiAgICAicDd6aXAtZnVsbCI6IG51bGwsCiAgICAieHotdXRpbHMiOiBudWxsLAogICAgImJ6aXAyIjogbnVsbCwKICAgICJzcWxpdGUzIjogbnVsbCwKICAgICJvcGVuc3NoLWNsaWVudCI6IG51bGwsCiAgICAicHl0aG9uMyI6IHsibWluX3ZlcnNpb24iOiAiMy4xMyJ9LAogICAgInB5dGhvbjMtcGlwIjogbnVsbCwKICAgICJweXRob24zLXZlbnYiOiBudWxsLAogICAgInB5dGhvbjMtbnVtcHkiOiBudWxsLAogICAgIm5vZGVqcyI6IG51bGwsCiAgICAibnBtIjogbnVsbCwKICAgICJjYS1jZXJ0aWZpY2F0ZXMiOiBudWxsCiAgfSwKICAicmVxdWlyZV9zb3VyY2VfbWFwcGluZyI6IHRydWUKfQo=",
            qualificationRunURL: "https://github.com/JiangNanGenius/floe-agent/actions/runs/35928017233",
            sourceRef: "706413fd816ee6c4197dd7e5184f6fc14fc2f762"
        ),
    ]
}

// MARK: - Status

/// The honest availability of one official template for the UI.
public struct RuntimeV2OfficialTemplateAvailability: Sendable, Equatable {
    public enum State: String, Sendable {
        /// A verified template version is registered locally.
        case verified
        /// The distribution names a pinned artifact that is not registered yet.
        case available
        /// A version exists locally but is not verified.
        case registeredNotVerified = "registered-not-verified"
        /// No verified artifact exists anywhere: explicit dependency report.
        case dependencyMissing = "dependency-missing"
    }

    public var templateID: String
    public var state: State
    public var version: Int?
    public var digest: String?
    public var imageID: String?
    public var archiveBytes: Int64?
    public var packageCount: Int?
    public var packageNames: [String]
    public var qualificationRunURL: String?
    public var reason: String?

    public init(
        templateID: String, state: State, version: Int? = nil, digest: String? = nil,
        imageID: String? = nil, archiveBytes: Int64? = nil, packageCount: Int? = nil,
        packageNames: [String] = [], qualificationRunURL: String? = nil, reason: String? = nil
    ) {
        self.templateID = templateID
        self.state = state
        self.version = version
        self.digest = digest
        self.imageID = imageID
        self.archiveBytes = archiveBytes
        self.packageCount = packageCount
        self.packageNames = packageNames
        self.qualificationRunURL = qualificationRunURL
        self.reason = reason
    }
}

/// Progress phases of a prepare job (download → verify/import → register).
public enum RuntimeV2OfficialTemplatePhase: Sendable, Equatable {
    case downloading(received: Int64, expected: Int64)
    case registering
}

// MARK: - Errors

public enum RuntimeV2OfficialTemplateError: Error, LocalizedError, Sendable {
    case noPublishedArtifact(templateID: String)
    case imageUnavailable(imageID: String, reason: String)
    case templateBlockMissing(imageID: String)
    case templateBlockUnverified(imageID: String, reason: String)
    case recipeDigestMismatch(expected: String, actual: String)
    case diskDigestMismatch(expected: String, actual: String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .noPublishedArtifact(let templateID):
            return "no cloud-verified \(templateID) template artifact is published for this build"
        case .imageUnavailable(let imageID, let reason):
            return "template image \(imageID) is unavailable: \(reason)"
        case .templateBlockMissing(let imageID):
            return "template image \(imageID) carries no template block"
        case .templateBlockUnverified(let imageID, let reason):
            return "template image \(imageID) was not verified in the guest: \(reason)"
        case .recipeDigestMismatch(let expected, let actual):
            return "template recipe digest mismatch: expected \(expected.prefix(16))…, image recorded \(actual.prefix(16))…"
        case .diskDigestMismatch(let expected, let actual):
            return "template disk digest mismatch: published \(expected.prefix(16))…, image has \(actual.prefix(16))…"
        case .cancelled:
            return "the template preparation was cancelled"
        }
    }
}

// MARK: - Manifest template block

/// The image manifest's `template` block plus the artifact identity the
/// registration needs. Parsed from the verified manifest JSON; every check is
/// repeated here because the block alone is not a trust anchor.
public struct RuntimeV2OfficialTemplateManifest: Sendable, Equatable {
    public struct Package: Sendable, Equatable {
        public var name: String
        public var version: String
        public var architecture: String
        public var source: String
    }

    public var imageID: String
    public var qualified: Bool
    public var qualificationRun: String?
    public var templateID: String
    public var verified: Bool
    public var reason: String?
    public var recipeSHA512: String
    public var missingPackages: [String]
    public var belowMinimum: [String]
    public var pypiFailures: [String]
    public var packages: [Package]
    public var diskSHA512: String

    /// Parses `manifest.json` bytes. Loose JSON on purpose: unknown keys are
    /// ignored, but a missing/invalid template block is an explicit failure
    /// the caller maps to `templateBlockMissing`.
    public static func parse(_ data: Data, expectedImageID: String) throws -> RuntimeV2OfficialTemplateManifest {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RuntimeV2OfficialTemplateError.templateBlockMissing(imageID: expectedImageID)
        }
        guard let template = root["template"] as? [String: Any] else {
            throw RuntimeV2OfficialTemplateError.templateBlockMissing(imageID: expectedImageID)
        }
        let artifacts = root["artifacts"] as? [[String: Any]] ?? []
        let disk = artifacts.first { ($0["role"] as? String) == "disk" }
        let packages = (template["packages"] as? [[String: Any]] ?? []).compactMap { record -> Package? in
            guard let name = record["name"] as? String, let version = record["version"] as? String else { return nil }
            return Package(
                name: name, version: version,
                architecture: (record["arch"] as? String) ?? "unknown",
                source: (record["source"] as? String) ?? "unknown"
            )
        }
        return RuntimeV2OfficialTemplateManifest(
            imageID: (root["id"] as? String) ?? expectedImageID,
            qualified: (root["qualified"] as? Bool) ?? false,
            qualificationRun: root["qualificationRun"] as? String,
            templateID: (template["id"] as? String) ?? "",
            verified: (template["verified"] as? Bool) ?? false,
            reason: template["reason"] as? String,
            recipeSHA512: (template["recipeSha512"] as? String) ?? "",
            missingPackages: (template["missingPackages"] as? [String]) ?? [],
            belowMinimum: (template["belowMinimum"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String },
            pypiFailures: (template["pypiFailures"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String },
            packages: packages,
            diskSHA512: (disk?["sha512"] as? String) ?? ""
        )
    }

    /// Full fail-closed validation against a distribution pin.
    public func validate(against artifact: RuntimeV2OfficialTemplateArtifact) throws {
        guard qualified else {
            throw RuntimeV2OfficialTemplateError.templateBlockUnverified(
                imageID: imageID, reason: "the image manifest is not qualified"
            )
        }
        guard !(qualificationRun ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RuntimeV2OfficialTemplateError.templateBlockUnverified(
                imageID: imageID, reason: "the image manifest records no qualification run"
            )
        }
        guard templateID == artifact.templateID else {
            throw RuntimeV2OfficialTemplateError.templateBlockUnverified(
                imageID: imageID,
                reason: "the image template block is '\(templateID)', not '\(artifact.templateID)'"
            )
        }
        guard verified else {
            throw RuntimeV2OfficialTemplateError.templateBlockUnverified(
                imageID: imageID,
                reason: reason ?? "the guest stage-2 verification did not report a clean pass"
            )
        }
        guard missingPackages.isEmpty, belowMinimum.isEmpty, pypiFailures.isEmpty else {
            throw RuntimeV2OfficialTemplateError.templateBlockUnverified(
                imageID: imageID,
                reason: "the image records unmet requirements (missing=\(missingPackages.count), "
                    + "belowMinimum=\(belowMinimum.count), pypi=\(pypiFailures.count))"
            )
        }
        guard !packages.isEmpty else {
            throw RuntimeV2OfficialTemplateError.templateBlockUnverified(
                imageID: imageID, reason: "the installed package listing is empty"
            )
        }
        let recipeActual = recipeSHA512.lowercased()
        guard recipeActual == artifact.recipeSHA512.lowercased() else {
            throw RuntimeV2OfficialTemplateError.recipeDigestMismatch(
                expected: artifact.recipeSHA512, actual: recipeActual
            )
        }
        let diskActual = diskSHA512.lowercased()
        guard diskActual == artifact.diskSHA512.lowercased() else {
            throw RuntimeV2OfficialTemplateError.diskDigestMismatch(
                expected: artifact.diskSHA512, actual: diskActual
            )
        }
    }
}

// MARK: - Existing-service seams

/// The reuse/status half of the prepare job: the verified image store the App
/// already owns. Production wraps `LinuxGuestImageInstallationService`; tests
/// inject a scripted store. This is a seam, not a second image service.
///
/// Extraction is deliberately NOT delegated here: the shared importer enforces
/// a 4 GiB extracted-bytes cap, while a template disk is a sparse logical
/// image (the cloud build grows the ext4 root before installing packages).
/// `RuntimeV2TemplateArchiveStager` below stages the pinned archive with a
/// sparse disk write so the device stores only the real data, and the
/// verified image then enters the v2 store through the existing migration.
public protocol RuntimeV2OfficialTemplateImageAvailability: Sendable {
    /// The directory that holds installed images (`…/LinuxGuest/images`).
    var imagesRootDirectory: URL { get }
    func installedImageDirectory(imageID: String) async -> URL?
    func verificationFailure(imageID: String) async -> String?
    func removeImage(imageID: String) async throws
}

/// Production adapter over the one verified image installation service.
public struct LinuxGuestImageTemplateAvailabilityAdapter: RuntimeV2OfficialTemplateImageAvailability {
    private let service: LinuxGuestImageInstallationService

    public init(service: LinuxGuestImageInstallationService) {
        self.service = service
    }

    public var imagesRootDirectory: URL { service.imagesDirectory }

    public func installedImageDirectory(imageID: String) async -> URL? {
        let root = service.imagesDirectory.appendingPathComponent(imageID, isDirectory: true)
        let manifest = root.appendingPathComponent("manifest.json")
        return FileManager.default.fileExists(atPath: manifest.path) ? root : nil
    }

    public func verificationFailure(imageID: String) async -> String? {
        let status = await service.status(id: imageID)
        // Absence is not a verification failure: nil here means "nothing to
        // re-import", only an installed-but-damaged image reports a reason.
        guard status.installed else { return nil }
        return status.verificationFailure
    }

    public func removeImage(imageID: String) async throws {
        try await service.removeImage(id: imageID)
    }
}

// MARK: - Sparse archive staging

/// Stages a pinned template archive (manifest.json + boot files + a possibly
/// sparse logical disk) into a legacy-image layout that the existing verified
/// migration can ingest. The disk entry is written SPARSELY: zero chunks only
/// seek forward, so a 16 GiB logical ext4 image costs its real data, not 16 GiB
/// of device storage — and the shared importer's 4 GiB extracted-bytes cap
/// (which exists for full-byte archives) does not apply to a hole-preserving
/// logical image.
public enum RuntimeV2TemplateArchiveStager {
    public struct Limits: Sendable {
        public var maxEntries: Int
        public var maxManifestBytes: Int64
        public var maxBootFileBytes: Int64
        public var maxDiskLogicalBytes: Int64
        /// Physical bytes actually written across all entries.
        public var maxPhysicalBytes: Int64

        public init(
            maxEntries: Int = 16,
            maxManifestBytes: Int64 = 2 << 20,
            maxBootFileBytes: Int64 = 256 << 20,
            maxDiskLogicalBytes: Int64 = LinuxGuestDiskLayout.maximumLogicalCapacityBytes,
            maxPhysicalBytes: Int64 = 8 << 30
        ) {
            self.maxEntries = maxEntries
            self.maxManifestBytes = maxManifestBytes
            self.maxBootFileBytes = maxBootFileBytes
            self.maxDiskLogicalBytes = maxDiskLogicalBytes
            self.maxPhysicalBytes = maxPhysicalBytes
        }
    }

    public enum StageError: Error, LocalizedError, Sendable {
        case unsupportedArchive(String)
        case missingEntry(String)
        case unsafeEntry(String)
        case entryTooLarge(String)
        case physicalLimitExceeded(Int64)

        public var errorDescription: String? {
            switch self {
            case .unsupportedArchive(let detail): return "template archive cannot be opened: \(detail)"
            case .missingEntry(let name): return "template archive has no \(name)"
            case .unsafeEntry(let name): return "template archive entry is not safe: \(name)"
            case .entryTooLarge(let detail): return "template archive entry is too large: \(detail)"
            case .physicalLimitExceeded(let limit): return "template archive exceeds the physical staging limit (\(limit) bytes)"
            }
        }
    }

    public static let diskEntryName = "disk.img"
    private static let allowedEntries: Set<String> = [
        "manifest.json", "bbl64.bin", "bios.bin", "kernel-riscv64.bin", "disk.img", "SHA512SUMS"
    ]

    /// Extracts `archiveURL` into `<root>/<imageID>/`. Any pre-existing
    /// destination is removed first; a failure removes the partial staging.
    @discardableResult
    public static func stage(
        archiveURL: URL, imageID: String, into root: URL,
        limits: Limits = Limits(),
        fileManager: FileManager = .default,
        onProgress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) throws -> URL {
        let destination = root.appendingPathComponent(imageID, isDirectory: true)
        let archive: Archive
        do {
            archive = try Archive(url: archiveURL, accessMode: .read)
        } catch {
            throw StageError.unsupportedArchive(error.localizedDescription)
        }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        var entries = 0
        var physicalBytes: Int64 = 0
        var sawDisk = false
        do {
            for entry in archive {
                entries += 1
                guard entries <= limits.maxEntries else {
                    throw StageError.entryTooLarge("more than \(limits.maxEntries) entries")
                }
                guard allowedEntries.contains(entry.path),
                      !entry.path.contains("/"), !entry.path.contains("..") else {
                    throw StageError.unsafeEntry(entry.path)
                }
                switch entry.type {
                case .directory:
                    continue
                case .symlink:
                    throw StageError.unsafeEntry("symlink \(entry.path)")
                case .file:
                    break
                }
                let uncompressed = Int64(entry.uncompressedSize)
                let target = destination.appendingPathComponent(entry.path, isDirectory: false)
                if entry.path == diskEntryName {
                    guard uncompressed <= limits.maxDiskLogicalBytes else {
                        throw StageError.entryTooLarge(
                            "\(entry.path) declares \(uncompressed) bytes (limit \(limits.maxDiskLogicalBytes))"
                        )
                    }
                    physicalBytes += try writeSparseEntry(
                        entry, archive: archive, to: target,
                        limits: limits, physicalSoFar: physicalBytes, onProgress: onProgress
                    )
                    sawDisk = true
                } else {
                    let cap = entry.path == "manifest.json" ? limits.maxManifestBytes : limits.maxBootFileBytes
                    guard uncompressed <= cap else {
                        throw StageError.entryTooLarge("\(entry.path) declares \(uncompressed) bytes (limit \(cap))")
                    }
                    physicalBytes += uncompressed
                    guard physicalBytes <= limits.maxPhysicalBytes else {
                        throw StageError.physicalLimitExceeded(limits.maxPhysicalBytes)
                    }
                    try fileManager.createDirectory(
                        at: target.deletingLastPathComponent(), withIntermediateDirectories: true
                    )
                    _ = try archive.extract(entry, to: target)
                }
            }
            for required in ["manifest.json"] where !fileManager.fileExists(
                atPath: destination.appendingPathComponent(required).path
            ) {
                throw StageError.missingEntry(required)
            }
            // The BIOS name is bbl64.bin in the cloud archive; bios.bin is the
            // historical/legacy spelling. Exactly one must be present.
            let hasBios = fileManager.fileExists(atPath: destination.appendingPathComponent("bbl64.bin").path)
                || fileManager.fileExists(atPath: destination.appendingPathComponent("bios.bin").path)
            guard hasBios else { throw StageError.missingEntry("bbl64.bin") }
            guard sawDisk else { throw StageError.missingEntry(diskEntryName) }
            return destination
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    /// Streams one disk entry with hole preservation; returns the physical
    /// bytes actually written.
    private static func writeSparseEntry(
        _ entry: Entry, archive: Archive, to target: URL,
        limits: Limits, physicalSoFar: Int64,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) throws -> Int64 {
        FileManager.default.createFile(atPath: target.path, contents: nil)
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: target)
        } catch {
            throw StageError.unsupportedArchive("cannot open \(target.lastPathComponent) for writing: \(error.localizedDescription)")
        }
        defer { try? handle.close() }
        var offset: Int64 = 0
        var written: Int64 = 0
        var failure: Error?
        _ = try archive.extract(entry) { chunk in
            guard failure == nil else { return }
            do {
                let isZero = chunk.allSatisfy { $0 == 0 }
                if isZero {
                    // A hole: reserve the logical range without writing bytes.
                    try handle.seek(toOffset: UInt64(offset + Int64(chunk.count)))
                } else {
                    try handle.write(contentsOf: chunk)
                    written += Int64(chunk.count)
                    guard physicalSoFar + written <= limits.maxPhysicalBytes else {
                        throw StageError.physicalLimitExceeded(limits.maxPhysicalBytes)
                    }
                }
                offset += Int64(chunk.count)
                onProgress?(offset, Int64(entry.uncompressedSize))
            } catch {
                failure = error
            }
        }
        if let failure { throw failure }
        // The sparse file must keep its declared logical length.
        try handle.truncate(atOffset: UInt64(entry.uncompressedSize))
        return written
    }
}

// MARK: - Service

/// Downloads, verifies and registers the pinned official template artifacts
/// through the existing image store and template store. One prepare job runs
/// at a time per template; a cancelled or failed job registers nothing.
public actor RuntimeV2OfficialTemplateService {
    private let store: RuntimeV2Store
    private let importer: any RuntimeV2OfficialTemplateImageAvailability
    private let downloader: any LinuxGuestImageDownloading
    private let artifacts: [RuntimeV2OfficialTemplateArtifact]
    private let templatesDirectory: URL?
    private var jobsInFlight: [String: Task<RuntimeV2TemplateStore.Registration, Error>] = [:]

    public init(
        store: RuntimeV2Store,
        importer: any RuntimeV2OfficialTemplateImageAvailability,
        downloader: any LinuxGuestImageDownloading,
        artifacts: [RuntimeV2OfficialTemplateArtifact] = RuntimeV2OfficialTemplateDistribution.artifacts,
        templatesDirectory: URL? = nil
    ) {
        self.store = store
        self.importer = importer
        self.downloader = downloader
        self.artifacts = artifacts
        self.templatesDirectory = templatesDirectory
    }

    // MARK: status

    /// Honest combined status for every official template id.
    public func availability() async throws -> [RuntimeV2OfficialTemplateAvailability] {
        var result: [RuntimeV2OfficialTemplateAvailability] = []
        for templateID in RuntimeV2TemplateCatalog.officialTemplateIDs {
            let artifact = artifacts.first { $0.templateID == templateID }
            if let verified = try await store.templates.latestVerified(templateID: templateID) {
                let packages = try await store.templates.packages(
                    templateID: templateID, version: verified.version
                )
                result.append(RuntimeV2OfficialTemplateAvailability(
                    templateID: templateID, state: .verified,
                    version: verified.version, digest: verified.digest,
                    imageID: artifact?.imageID,
                    archiveBytes: artifact?.archiveBytes,
                    packageCount: packages.count,
                    packageNames: packages.map(\.name).sorted(),
                    qualificationRunURL: artifact?.qualificationRunURL
                ))
                continue
            }
            if let latest = try await store.registry.latestTemplate(templateID: templateID) {
                result.append(RuntimeV2OfficialTemplateAvailability(
                    templateID: templateID, state: .registeredNotVerified,
                    version: latest.version, digest: latest.digest.isEmpty ? nil : latest.digest,
                    imageID: artifact?.imageID,
                    reason: latest.reason ?? "the registered version has not been verified"
                ))
                continue
            }
            if let artifact {
                result.append(RuntimeV2OfficialTemplateAvailability(
                    templateID: templateID, state: .available,
                    imageID: artifact.imageID, archiveBytes: artifact.archiveBytes,
                    qualificationRunURL: artifact.qualificationRunURL,
                    reason: "verified cloud artifact published; download and register to use it"
                ))
            } else {
                result.append(RuntimeV2OfficialTemplateAvailability(
                    templateID: templateID, state: .dependencyMissing,
                    reason: "no cloud-verified template artifact is published; recipes are "
                        + "\(RuntimeV2TemplateCatalog.recipesRelativeDirectory)/\(templateID).json and the image owner is "
                        + RuntimeV2TemplateCatalog.dependencyOwner
                ))
            }
        }
        return result
    }

    /// The verified registration of one template, or nil.
    public func registered(templateID: String) async throws -> RuntimeV2TemplateStore.Registration? {
        guard let row = try await store.templates.latestVerified(templateID: templateID) else { return nil }
        let packages = try await store.templates.packages(templateID: templateID, version: row.version)
        return RuntimeV2TemplateStore.Registration(
            pin: RuntimeV2TemplatePin(templateID: row.templateID, version: row.version, digest: row.digest),
            parent: RuntimeV2TemplateStore.ParentSource(
                kind: RuntimeV2TemplateStore.ParentSource.Kind(rawValue: row.parentKind) ?? .baseImage,
                id: row.parentID, version: row.parentVersion, digest: row.parentDigest
            ),
            packages: packages, missingPackages: [],
            logicalBytes: row.logicalBytes,
            allocatedBytes: row.allocatedBytes > 0 ? row.allocatedBytes : nil,
            downloadBytes: row.downloadBytes,
            buildMode: RuntimeV2TemplateStore.CloneMode(rawValue: row.buildMode ?? "") ?? .imported,
            diskDigest: row.diskDigest ?? "",
            referenceCount: try await store.templates.referenceCount(templateID: row.templateID, version: row.version),
            privateStateExcluded: RuntimeV2TemplateStore.excludedPrivateState,
            provenance: nil
        )
    }

    // MARK: prepare

    /// Downloads (when needed) and registers the pinned artifact. Concurrent
    /// callers for the same template share one job; a cancellation or any
    /// failure registers nothing and leaves the previous state untouched.
    @discardableResult
    public func prepare(
        templateID: String,
        onProgress: @escaping @Sendable (RuntimeV2OfficialTemplatePhase) -> Void = { _ in }
    ) async throws -> RuntimeV2TemplateStore.Registration {
        if let existing = jobsInFlight[templateID] {
            return try await existing.value
        }
        let task = Task<RuntimeV2TemplateStore.Registration, Error> { [self] in
            defer { jobsInFlight[templateID] = nil }
            return try await performPrepare(templateID: templateID, onProgress: onProgress)
        }
        jobsInFlight[templateID] = task
        return try await task.value
    }

    /// Cancels an in-flight prepare; the underlying archive download stops at
    /// the next cancellation check and nothing is registered.
    public func cancelPrepare(templateID: String) {
        jobsInFlight[templateID]?.cancel()
    }

    private func performPrepare(
        templateID: String,
        onProgress: @escaping @Sendable (RuntimeV2OfficialTemplatePhase) -> Void
    ) async throws -> RuntimeV2TemplateStore.Registration {
        guard let artifact = artifacts.first(where: { $0.templateID == templateID }) else {
            throw RuntimeV2OfficialTemplateError.noPublishedArtifact(templateID: templateID)
        }
        // Already registered at this exact version: nothing to download or
        // re-import. (A newer artifact version would carry a higher version.)
        if let verified = try await store.templates.latestVerified(templateID: templateID),
           verified.version >= artifact.version {
            guard let existing = try await registered(templateID: templateID) else {
                throw RuntimeV2OfficialTemplateError.templateBlockUnverified(
                    imageID: artifact.imageID, reason: "the registered version cannot be read back"
                )
            }
            return existing
        }
        // Verify the pinned recipe bytes first: the image's block must match
        // exactly this recipe, so a mismatched artifact never registers.
        let recipe = try Self.recipe(from: artifact)
        let fileManager = FileManager.default
        let staging = store.layout.runtimeTmpDirectory
            .appendingPathComponent("template-download-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        try Task.checkCancellation()
        let imageDirectory: URL
        var stagedRoot: URL?
        if let existing = await importer.installedImageDirectory(imageID: artifact.imageID),
           await importer.verificationFailure(imageID: artifact.imageID) == nil {
            // The verified image is already installed (previous prepare or a
            // user import): reuse it, the migration below is idempotent.
            imageDirectory = existing
        } else {
            if let failure = await importer.verificationFailure(imageID: artifact.imageID) {
                // A damaged install is replaced from the pinned bytes; the
                // broken copy is removed before the retry so nothing partial
                // can be verified.
                _ = failure
                try await importer.removeImage(imageID: artifact.imageID)
            }
            guard let url = URL(string: artifact.archiveURL) else {
                throw RuntimeV2OfficialTemplateError.imageUnavailable(
                    imageID: artifact.imageID, reason: "the pinned archive URL is invalid"
                )
            }
            let archive = staging.appendingPathComponent("template.zip")
            onProgress(.downloading(received: 0, expected: artifact.archiveBytes))
            do {
                try await downloader.download(url, to: archive, maxBytes: artifact.archiveBytes + (64 << 20)) { received, expected in
                    onProgress(.downloading(received: received, expected: expected > 0 ? expected : artifact.archiveBytes))
                }
            } catch let transfer {
                if case .cancelled = transfer {
                    throw RuntimeV2OfficialTemplateError.cancelled
                }
                throw RuntimeV2OfficialTemplateError.imageUnavailable(
                    imageID: artifact.imageID, reason: String(describing: transfer)
                )
            }
            try Task.checkCancellation()
            let actual = try FloeDigest.sha512Hex(ofFileAt: archive)
            guard actual.lowercased() == artifact.archiveSHA512.lowercased() else {
                throw LinuxGuestImageInstallError.archiveDigestMismatch(
                    expected: artifact.archiveSHA512, actual: actual
                )
            }
            // Sparse staging: the disk entry is written with holes preserved,
            // so a grown logical ext4 image does not cost its full size on the
            // device and the shared importer's flat extracted-bytes cap does
            // not reject it. The verified migration then ingests the exact
            // digest-bearing bytes.
            let staged = staging.appendingPathComponent("image-root", isDirectory: true)
            _ = try RuntimeV2TemplateArchiveStager.stage(
                archiveURL: archive, imageID: artifact.imageID, into: staged
            )
            stagedRoot = staged
            imageDirectory = staged.appendingPathComponent(artifact.imageID, isDirectory: true)
        }

        try Task.checkCancellation()
        // Parse and validate the image's own template block (never trust the
        // archive listing alone).
        let manifestData = try Data(contentsOf: imageDirectory.appendingPathComponent("manifest.json"))
        let manifest = try RuntimeV2OfficialTemplateManifest.parse(manifestData, expectedImageID: artifact.imageID)
        try manifest.validate(against: artifact)

        try Task.checkCancellation()
        // The verified image moves into the Runtime v2 content-addressed store
        // through the existing migration, so the boot path resolves the same
        // bytes the template registers.
        let legacyRoot = stagedRoot ?? importer.imagesRootDirectory
        _ = try await store.images.migrateLegacyImage(
            imageID: artifact.imageID, legacyImagesRoot: legacyRoot
        )
        guard try await store.images.isImageVerified(imageID: artifact.imageID),
              let expandedManifest = try await store.images.manifest(imageID: artifact.imageID),
              let ref = expandedManifest.artifacts["rootfs"] ?? expandedManifest.artifacts["disk"] else {
            throw RuntimeV2OfficialTemplateError.imageUnavailable(
                imageID: artifact.imageID, reason: "the v2 image store did not verify the migrated image"
            )
        }
        guard ref.sha512.lowercased() == artifact.diskSHA512.lowercased() else {
            throw RuntimeV2OfficialTemplateError.diskDigestMismatch(
                expected: artifact.diskSHA512, actual: ref.sha512
            )
        }
        let expanded = try await store.images.ensureExpanded(imageID: artifact.imageID)
        let diskURL = expanded.appendingPathComponent(ref.expandedPath)
        guard fileManager.fileExists(atPath: diskURL.path) else {
            throw RuntimeV2OfficialTemplateError.imageUnavailable(
                imageID: artifact.imageID, reason: "the expanded disk is missing"
            )
        }

        try Task.checkCancellation()
        onProgress(.registering)
        let packages = manifest.packages.map {
            RuntimeV2TemplateStore.InstalledSoftware(
                name: $0.name, version: $0.version, architecture: $0.architecture,
                source: $0.source, installState: "installed"
            )
        }
        let provenance = "cloud-template-qualification \(artifact.qualificationRunURL) "
            + "image=\(artifact.imageID) recipe=\(artifact.recipeSHA512)"
        return try await store.templates.registerOfficialTemplate(
            RuntimeV2TemplateStore.OfficialTemplateArtifact(
                templateID: artifact.templateID, version: artifact.version,
                recipe: recipe,
                parent: RuntimeV2TemplateStore.ParentSource(
                    kind: .baseImage, id: artifact.imageID, version: nil,
                    digest: ref.sha512.lowercased()
                ),
                architecture: "riscv64", diskURL: diskURL,
                packages: packages, downloadBytes: artifact.archiveBytes,
                missingPackages: [], installVerified: true,
                provenance: provenance
            )
        )
    }

    /// Decodes the pinned recipe and checks its digest against the pin.
    static func recipe(from artifact: RuntimeV2OfficialTemplateArtifact) throws -> RuntimeV2TemplateRecipe {
        guard let data = artifact.recipeData else {
            throw RuntimeV2OfficialTemplateError.recipeDigestMismatch(
                expected: artifact.recipeSHA512, actual: "not valid base64"
            )
        }
        let digest = FloeDigest.sha512Hex(data)
        guard digest == artifact.recipeSHA512.lowercased() else {
            throw RuntimeV2OfficialTemplateError.recipeDigestMismatch(
                expected: artifact.recipeSHA512, actual: digest
            )
        }
        let recipe: RuntimeV2TemplateRecipe
        do {
            recipe = try JSONDecoder().decode(RuntimeV2TemplateRecipe.self, from: data)
            try recipe.validate()
        } catch {
            throw RuntimeV2OfficialTemplateError.templateBlockUnverified(
                imageID: artifact.imageID, reason: "the pinned recipe does not decode: \(error.localizedDescription)"
            )
        }
        guard recipe.name == artifact.templateID else {
            throw RuntimeV2OfficialTemplateError.templateBlockUnverified(
                imageID: artifact.imageID, reason: "recipe \(recipe.name) does not match template \(artifact.templateID)"
            )
        }
        return recipe
    }
}
