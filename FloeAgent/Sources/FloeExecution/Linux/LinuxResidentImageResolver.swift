// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore

/// Only an installed, verified image from the caller's trusted catalog may
/// produce this read-only candidate. The mutable resident disk is not hashed.
public struct LinuxResidentImageCandidate: Codable, Equatable, Sendable {
    public let imageID: String
    public let diskSHA512: String
    public let diskBytes: Int64
    public let compatibleOrigins: [LinuxGuestCompatibleDiskOrigin]

    public init(imageID: String, diskSHA512: String, diskBytes: Int64,
                compatibleOrigins: [LinuxGuestCompatibleDiskOrigin] = []) {
        self.imageID = imageID
        self.diskSHA512 = diskSHA512
        self.diskBytes = diskBytes
        self.compatibleOrigins = compatibleOrigins
    }

    fileprivate func accepts(_ origin: LinuxGuestRuntimeDiskOrigin) -> Bool {
        if imageID == origin.imageID {
            return diskSHA512.lowercased() == origin.artifactSHA512.lowercased()
                && diskBytes == origin.artifactBytes
        }
        return compatibleOrigins.contains {
            $0.imageID == origin.imageID && $0.artifactSHA512.lowercased() == origin.artifactSHA512.lowercased()
                && $0.artifactBytes == origin.artifactBytes
        }
    }
}

/// Compile-time catalog metadata used ONLY to plan an exact trusted component repair.
/// It never represents installed/verified bytes and cannot return execution success.
public struct LinuxResidentImageRepairSource: Sendable {
    public let imageID: String
    public let compatibleOrigins: [LinuxGuestCompatibleDiskOrigin]
    public init(imageID: String, compatibleOrigins: [LinuxGuestCompatibleDiskOrigin]) {
        self.imageID = imageID; self.compatibleOrigins = compatibleOrigins
    }
    fileprivate func matches(_ origin: LinuxGuestRuntimeDiskOrigin) -> Bool {
        compatibleOrigins.contains {
            $0.imageID == origin.imageID && $0.artifactBytes == origin.artifactBytes
                && $0.artifactSHA512.lowercased() == origin.artifactSHA512.lowercased()
        }
    }
}

public enum LinuxResidentImageResolutionError: Error, Equatable, Sendable, LocalizedError {
    case storageUnavailable
    case missingDisk
    case invalidOrigin
    case unknownOrigin
    case sourceUnavailable(imageID: String)
    case originMismatch
    case ambiguousOrigin

    /// A repair may re-download this exact trusted image. Unknown/corrupt
    /// provenance never authorizes downloading the catalog default instead.
    public var recoverableImageID: String? {
        if case .sourceUnavailable(let id) = self { return id }
        return nil
    }

    /// This is an explicit new-environment action, not evidence that the
    /// retained mutable disk belongs to the current catalog default.
    public var permitsPreservingRebuild: Bool {
        switch self {
        case .invalidOrigin, .unknownOrigin, .originMismatch, .ambiguousOrigin, .missingDisk: true
        case .storageUnavailable, .sourceUnavailable: false
        }
    }

    public var errorDescription: String? {
        let zh = FloeL10n.isChinese
        switch self {
        case .storageUnavailable:
            return zh ? "无法读取当前运行环境，请稍后重试。" : "The current runtime could not be read. Try again."
        case .missingDisk:
            return zh ? "当前运行环境的磁盘缺失，已有记录已保留。" : "The current runtime disk is missing. Existing records were retained."
        case .invalidOrigin, .unknownOrigin, .originMismatch, .ambiguousOrigin:
            return zh ? "无法确认当前运行环境的来源，已有数据已保留。" : "The current runtime's origin could not be confirmed. Existing data was retained."
        case .sourceUnavailable:
            return zh ? "当前环境需要的运行组件不可用，请重新下载。" : "A verified runtime component for this environment is unavailable. Download it again."
        }
    }
}

/// A read-only selection, shared by descriptor/start/status/preparation.
/// No files, environment bindings, pins or rebuild flags are changed here.
public struct LinuxResidentImageResolver: Sendable {
    public typealias Lookup = @Sendable (String) async -> LinuxResidentImageCandidate?
    public typealias RepairLookup = @Sendable (String) async -> LinuxResidentImageRepairSource?
    private let root: URL
    private let defaultImageID: String
    private let trustedImageIDs: [String]
    private let lookup: Lookup
    private let repairLookup: RepairLookup

    public init(residentRoot: URL, defaultImageID: String, trustedImageIDs: [String],
                repairLookup: @escaping RepairLookup = { _ in nil },
                lookup: @escaping Lookup) {
        self.root = residentRoot.resolvingSymlinksInPath().standardizedFileURL
        self.defaultImageID = defaultImageID
        self.trustedImageIDs = trustedImageIDs
        self.lookup = lookup
        self.repairLookup = repairLookup
    }

    public func resolve(requireExistingDisk: Bool = false) async throws -> String {
        try Task.checkCancellation()
        // Reject symlinks or non-directory nodes below the caller-owned root.
        var cursor = root
        for part in [nil, LinuxResidentDiskStorage.containerDirectoryName, "disks", LinuxResidentDiskStorage.environmentID] as [String?] {
            if let part { cursor.appendPathComponent(part, isDirectory: true) }
            if let attributes = try attributes(at: cursor), attributes[.type] as? FileAttributeType != .typeDirectory {
                throw LinuxResidentImageResolutionError.storageUnavailable
            }
        }
        let directory = LinuxResidentDiskStorage.directory(in: root)
        let disk = directory.appendingPathComponent(LinuxResidentDiskStorage.diskFileName)
        let sidecar = directory.appendingPathComponent(LinuxResidentDiskStorage.originFileName)
        let diskAttributes = try attributes(at: disk)
        let originAttributes = try attributes(at: sidecar)
        guard let diskAttributes else {
            guard originAttributes == nil else { throw LinuxResidentImageResolutionError.missingDisk }
            guard !requireExistingDisk else { throw LinuxResidentImageResolutionError.missingDisk }
            // No disk AND no origin evidence: first creation may prepare the
            // configured default through the existing download job.
            guard trustedImageIDs.contains(defaultImageID) else {
                throw LinuxResidentImageResolutionError.sourceUnavailable(imageID: defaultImageID)
            }
            return defaultImageID
        }
        guard diskAttributes[.type] as? FileAttributeType == .typeRegular,
              let diskBytes = (diskAttributes[.size] as? NSNumber)?.int64Value,
              diskBytes > 0,
              let originAttributes,
              originAttributes[.type] as? FileAttributeType == .typeRegular,
              let originBytes = (originAttributes[.size] as? NSNumber)?.int64Value,
              originBytes > 0, originBytes <= 16 * 1024 else {
            throw LinuxResidentImageResolutionError.invalidOrigin
        }
        let origin: LinuxGuestRuntimeDiskOrigin
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let handle = try FileHandle(forReadingFrom: sidecar)
            defer { try? handle.close() }
            let bytes = try handle.read(upToCount: 16 * 1024 + 1) ?? Data()
            guard bytes.count <= 16 * 1024 else { throw LinuxResidentImageResolutionError.invalidOrigin }
            origin = try decoder.decode(LinuxGuestRuntimeDiskOrigin.self, from: bytes)
        } catch {
            throw LinuxResidentImageResolutionError.invalidOrigin
        }
        let digest = origin.artifactSHA512
        guard (1...LinuxGuestRuntimeDiskOrigin.currentVersion).contains(origin.version),
              !origin.imageID.isEmpty, origin.imageID.utf8.count <= 240,
              !origin.imageID.contains("/"), !origin.imageID.contains("\\"),
              !origin.imageID.contains("\0"), origin.imageID != ".", origin.imageID != "..",
              digest.count == 128, digest.allSatisfy(\.isHexDigit),
              origin.artifactBytes > 0, diskBytes >= origin.artifactBytes else {
            throw LinuxResidentImageResolutionError.invalidOrigin
        }
        if trustedImageIDs.contains(origin.imageID) {
            // An exact catalog binding must not be replaced by a newer image
            // merely because the original source is absent or damaged.
            guard let image = await lookup(origin.imageID) else {
                throw LinuxResidentImageResolutionError.sourceUnavailable(imageID: origin.imageID)
            }
            try Task.checkCancellation()
            guard image.imageID == origin.imageID, image.accepts(origin) else {
                throw LinuxResidentImageResolutionError.originMismatch
            }
            return image.imageID
        }
        // Existing v1 origins may be an exact predecessor declared by the
        // installed v2 manifest. Read only those already trusted images; an
        // arbitrary origin never becomes a catalog/default selection.
        var matching: [String] = []
        for id in trustedImageIDs {
            try Task.checkCancellation()
            if let image = await lookup(id), image.imageID == id, image.accepts(origin) {
                matching.append(id)
            }
        }
        try Task.checkCancellation()
        guard matching.count <= 1 else { throw LinuxResidentImageResolutionError.ambiguousOrigin }
        if let selected = matching.first { return selected }
        // A migrated/backup-restored view may be absent even though the pinned catalog
        // explicitly declares this exact predecessor. Metadata can select only the
        // repair download ID; it NEVER makes the current disk runnable.
        var repairs: [String] = []
        for id in trustedImageIDs {
            try Task.checkCancellation()
            if let metadata = await repairLookup(id), metadata.imageID == id, metadata.matches(origin) {
                repairs.append(id)
            }
        }
        try Task.checkCancellation()
        guard repairs.count <= 1 else { throw LinuxResidentImageResolutionError.ambiguousOrigin }
        if let repair = repairs.first { throw LinuxResidentImageResolutionError.sourceUnavailable(imageID: repair) }
        throw LinuxResidentImageResolutionError.unknownOrigin
    }

    private func attributes(at url: URL) throws -> [FileAttributeKey: Any]? {
        do { return try FileManager.default.attributesOfItem(atPath: url.path) }
        catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) {
                return nil
            }
            throw LinuxResidentImageResolutionError.storageUnavailable
        }
    }
}
