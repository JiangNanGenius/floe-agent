// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit
import Darwin
import FloeGameCore

public enum GameDistributionMode: String, Codable, Equatable, Sendable {
    /// Requires every declared corresponding-source/relink artifact.
    case distribution
    /// A private playback bundle may be produced without claiming
    /// distribution readiness. Never label this mode ready.
    case privatePlayback
}

public enum GameDistributionError: Error, Equatable, Sendable {
    case missingProfile(String)
    case missingNotice(String)
    case noticeHashMismatch(String)
    case missingHelperSource(String)
    case missingPairedSource(String)
    case pairedSourceMismatch(String)
    case destinationExists
    case invalidRelativePath(String)
    case invalidProfile(String)
    case io(String)
}

public struct GameBuildPairedSource: Codable, Equatable, Sendable {
    public let id: String
    public let role: String
    public let receipt: String
    public let sha256: String
    public let bytes: Int
    public let requiredForDistribution: Bool

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        role = try values.decode(String.self, forKey: .role)
        receipt = try values.decodeIfPresent(String.self, forKey: .receipt) ?? ""
        sha256 = try values.decode(String.self, forKey: .sha256)
        bytes = try values.decode(Int.self, forKey: .bytes)
        requiredForDistribution = try values.decodeIfPresent(Bool.self, forKey: .requiredForDistribution) ?? true
    }

    private enum CodingKeys: String, CodingKey { case id, role, receipt, sha256, bytes, requiredForDistribution }
}

public struct GameBuildRuntimePatch: Codable, Equatable, Sendable {
    public let path: String
    public let sha256: String
    public let bytes: Int
    public let role: String
}

public struct GameDistributionProfile: Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let distributionClass: String
    public let exportReadiness: String
    public let engineRuntimeProvidedByFloe: Bool
    public let embeddedNotices: [String]
    public let helperSources: [String]
    public let pairedSources: [GameBuildPairedSource]
    public let runtimePatches: [GameBuildRuntimePatch]
    public let conditionalReason: String?
    public let userContent: String?
    public let notes: [String]

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        displayName = try values.decodeIfPresent(String.self, forKey: .displayName) ?? id
        distributionClass = try values.decode(String.self, forKey: .distributionClass)
        exportReadiness = try values.decodeIfPresent(String.self, forKey: .exportReadiness) ?? "ready"
        engineRuntimeProvidedByFloe = try values.decodeIfPresent(Bool.self, forKey: .engineRuntimeProvidedByFloe) ?? false
        embeddedNotices = try values.decodeIfPresent([String].self, forKey: .embeddedNotices) ?? []
        helperSources = try values.decodeIfPresent([String].self, forKey: .helperSources)
            ?? ["Distribution/Floe/FloeGameBuildKit"]
        pairedSources = try values.decodeIfPresent([GameBuildPairedSource].self, forKey: .pairedSources) ?? []
        runtimePatches = try values.decodeIfPresent([GameBuildRuntimePatch].self, forKey: .runtimePatches) ?? []
        conditionalReason = try values.decodeIfPresent(String.self, forKey: .conditionalReason)
        userContent = try values.decodeIfPresent(String.self, forKey: .userContent)
        notes = try values.decodeIfPresent([String].self, forKey: .notes) ?? []
        guard !id.isEmpty, !helperSources.isEmpty,
              ["ready", "readyWithPairedSource", "conditional"].contains(exportReadiness) else {
            throw GameDistributionError.invalidProfile(id)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, distributionClass, exportReadiness, engineRuntimeProvidedByFloe
        case embeddedNotices, helperSources, pairedSources, runtimePatches, conditionalReason, userContent, notes
    }
}

struct GameDistributionProfileCatalogFile: Decodable, Sendable {
    let schemaVersion: Int
    let profiles: [GameDistributionProfile]
}

struct GameDistributionNoticeReceipt: Decodable, Sendable {
    let resource: String
    let sha256: String
    let bytes: Int
}

struct GameDistributionNoticeReceipts: Decodable, Sendable {
    let schemaVersion: Int
    let records: [GameDistributionNoticeReceipt]
}

public struct GameDistributionPairedSourceResolution: Sendable {
    public let url: URL
    public let sha256: String
    public let bytes: Int
    public init(url: URL, sha256: String, bytes: Int) {
        self.url = url; self.sha256 = sha256; self.bytes = bytes
    }
}

/// The host resolves a logical paired-source id to the actual verified artifact
/// or to its artifact-service handle. It never returns a credential or a URL
/// with an access-bearing query string.
public protocol GameDistributionPairedSourceProvider: Sendable {
    func resolve(_ artifactID: String) async throws -> GameDistributionPairedSourceResolution?
}

public struct GameDistributionPairedSourceRecord: Codable, Equatable, Sendable {
    public let id: String
    public let role: String
    public let sha256: String
    public let bytes: Int
    public let requiredForDistribution: Bool
    public let resolved: Bool
    public let sourceFile: String?
}

public struct GameDistributionReceipt: Codable, Equatable, Sendable {
    public let profileID: String
    public let distributionReady: Bool
    public let conditionalReason: String?
    public let bundleURL: URL
    public let manifestSHA256: String
    public let files: [String: String]
    public let pairedSources: [GameDistributionPairedSourceRecord]
    public let appStoreApprovalClaimed: Bool
    public let writtenOfferCreated: Bool
}

public struct GameDistributionEnvironment: Sendable {
    public let resourceRoot: URL?
    public let pairedProvider: (any GameDistributionPairedSourceProvider)?
    public let mode: GameDistributionMode

    public init(resourceRoot: URL? = nil,
                pairedProvider: (any GameDistributionPairedSourceProvider)? = nil,
                mode: GameDistributionMode = .distribution) {
        self.resourceRoot = resourceRoot
        self.pairedProvider = pairedProvider
        self.mode = mode
    }
}

public enum GameDistributionProfileCatalog {
    public static func all(bundle: Bundle? = nil) throws -> [GameDistributionProfile] {
        let bundle = bundle ?? .module
        guard let url = GameBuildResourceLocator.url("distribution-profiles.v1", "json",
                                                     "Resources/Catalog", bundle: bundle) else {
            throw GameDistributionError.missingProfile("distribution-profiles.v1.json")
        }
        let catalog = try JSONDecoder().decode(GameDistributionProfileCatalogFile.self, from: Data(contentsOf: url))
        guard catalog.schemaVersion == 1 else { throw GameDistributionError.invalidProfile("schemaVersion") }
        return catalog.profiles
    }

    public static func profile(id: String, bundle: Bundle? = nil) throws -> GameDistributionProfile {
        guard let profile = try all(bundle: bundle).first(where: { $0.id == id }) else {
            throw GameDistributionError.missingProfile(id)
        }
        return profile
    }
}

/// Builds a real source-accompanying export. Every declared notice is re-hashed,
/// the readable Floe MPL helper source is copied, user content is preserved
/// byte-for-byte, and paired corresponding-source artifacts are verified. A
/// distribution bundle fails closed when a required source is missing; a
/// private-playback bundle is explicitly conditional and never says ready.
public enum GameDistributionBundle {
    public static func build(profile: GameDistributionProfile,
                             engine: GameEngineID,
                             contentRoot: URL,
                             outputURL: URL,
                             environment: GameDistributionEnvironment,
                             fileManager: FileManager = .default) async throws -> GameDistributionReceipt {
        guard outputURL.isFileURL, !fileManager.fileExists(atPath: outputURL.path) else {
            throw GameDistributionError.destinationExists
        }
        let resourceRoot: URL
        if let provided = environment.resourceRoot {
            resourceRoot = provided
        } else {
            resourceRoot = try defaultResourceRoot()
        }
        let receipts = try noticeReceipts(at: resourceRoot)
        let staging = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".floe-distribution-" + UUID().uuidString.lowercased())
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: staging) }

        var notices: [String: String] = [:]
        for relative in profile.embeddedNotices {
            try validateRelative(relative)
            let source = resourceRoot.appendingPathComponent(relative)
            guard fileManager.fileExists(atPath: source.path) else {
                throw GameDistributionError.missingNotice(relative)
            }
            let digest = try sha256File(source)
            guard let receipt = receipts[relative], receipt == digest else {
                throw GameDistributionError.noticeHashMismatch(relative)
            }
            let suffix = relative.replacingOccurrences(of: "Distribution/Notices/", with: "")
            let destination = staging.appendingPathComponent("licenses/" + suffix)
            try copyFile(source, to: destination, fileManager: fileManager)
            notices["licenses/" + suffix] = digest
        }

        guard let helperRelative = profile.helperSources.first else {
            throw GameDistributionError.invalidProfile("no helper source")
        }
        try validateRelative(helperRelative)
        let helperSource = resourceRoot.appendingPathComponent(helperRelative)
        let helperDestination = staging.appendingPathComponent("sources/floe/FloeGameBuildKit")
        try copyTree(helperSource, to: helperDestination, fileManager: fileManager)
        guard fileManager.fileExists(atPath: helperDestination.appendingPathComponent("LICENSE").path),
              containsSwiftSource(helperDestination, fileManager: fileManager) else {
            throw GameDistributionError.missingHelperSource(helperRelative)
        }

        let contentDestination = staging.appendingPathComponent("content")
        try copyTree(contentRoot, to: contentDestination, fileManager: fileManager)
        let contentFiles = try relativeFiles(contentDestination, fileManager: fileManager)
        guard !contentFiles.isEmpty else { throw GameDistributionError.io("empty game content") }

        let userNotices = staging.appendingPathComponent("user-content-notices")
        for name in contentFiles where !name.contains("/") {
            guard name.hasPrefix("LICENSE") || name.hasPrefix("NOTICE") || name.hasPrefix("COPYING") else { continue }
            try copyFile(contentRoot.appendingPathComponent(name),
                         to: userNotices.appendingPathComponent(name), fileManager: fileManager)
        }

        var pairedRecords: [GameDistributionPairedSourceRecord] = []
        for source in profile.pairedSources {
            try Task.checkCancellation()
            var resolved = false
            var sourceFile: String?
            if let provider = environment.pairedProvider,
               let resolution = try await provider.resolve(source.id) {
                guard resolution.bytes == source.bytes,
                      resolution.sha256 == source.sha256,
                      try sha256File(resolution.url) == source.sha256,
                      try fileSize(resolution.url) == source.bytes else {
                    throw GameDistributionError.pairedSourceMismatch(source.id)
                }
                try Task.checkCancellation()
                let relative = "sources/third-party/" + source.id + "/" + resolution.url.lastPathComponent
                try validateRelative(relative)
                let destination = staging.appendingPathComponent(relative)
                try copyFile(resolution.url, to: destination, fileManager: fileManager)
                // The exported package must remain usable after the resource
                // cache is removed. Rehash the copied bytes before publication.
                guard try sha256File(destination) == source.sha256,
                      try fileSize(destination) == source.bytes else {
                    throw GameDistributionError.pairedSourceMismatch(source.id)
                }
                resolved = true
                sourceFile = relative
            }
            if !resolved && source.requiredForDistribution && environment.mode == .distribution {
                throw GameDistributionError.missingPairedSource(source.id)
            }
            pairedRecords.append(.init(id: source.id, role: source.role, sha256: source.sha256,
                                       bytes: source.bytes,
                                       requiredForDistribution: source.requiredForDistribution,
                                       resolved: resolved, sourceFile: sourceFile))
        }
        let allPaired = pairedRecords.allSatisfy { $0.resolved || !$0.requiredForDistribution }
        let ready = environment.mode == .distribution
            && profile.exportReadiness != "conditional"
            && allPaired

        let profileRecord: [String: Any] = [
            "profileID": profile.id,
            "primaryLicense": "MPL-2.0",
            "distributionClass": profile.distributionClass,
            "exportReadiness": profile.exportReadiness,
            "engineRuntimeProvidedByFloe": profile.engineRuntimeProvidedByFloe,
            "conditionalReason": profile.conditionalReason ?? NSNull(),
            "distributionReady": ready,
            "mode": environment.mode.rawValue,
            "pairedSources": pairedRecords.map(encodePaired),
            "userContent": profile.userContent ?? "Original terms; not relicensed.",
            "appStoreApprovalClaimed": false,
            "writtenOfferCreated": false,
        ]
        let profileData = try JSONSerialization.data(withJSONObject: profileRecord,
                                                     options: [.prettyPrinted, .sortedKeys])
        try write(profileData, to: staging.appendingPathComponent("distribution-profile.json"),
                  fileManager: fileManager)
        let pairedData = try JSONSerialization.data(
            withJSONObject: ["schemaVersion": 1, "pairedSources": pairedRecords.map(encodePaired)],
            options: [.prettyPrinted, .sortedKeys])
        try write(pairedData, to: staging.appendingPathComponent("PAIRED-SOURCE.json"),
                  fileManager: fileManager)
        let sourceText = """
        Floe authored source remains MPL-2.0. Original game files retain their own terms.
        Readable Floe helper source: sources/floe/FloeGameBuildKit (MPL-2.0).
        Upstream engine/runtime notices: licenses/.
        User project notices are preserved separately under user-content-notices/.
        Paired corresponding-source/relink artifacts: PAIRED-SOURCE.json.
        This bundle does not claim App Store approval, legal clearance or a written offer.

        """
        try write(Data(sourceText.utf8), to: staging.appendingPathComponent("SOURCE-AND-LICENSES.txt"),
                  fileManager: fileManager)

        var files = try hashFiles(staging, fileManager: fileManager)
        files["distribution-profile.json"] = try sha256File(staging.appendingPathComponent("distribution-profile.json"))
        files["PAIRED-SOURCE.json"] = try sha256File(staging.appendingPathComponent("PAIRED-SOURCE.json"))
        files["SOURCE-AND-LICENSES.txt"] = try sha256File(staging.appendingPathComponent("SOURCE-AND-LICENSES.txt"))
        let manifest: [String: Any] = [
            "schemaVersion": 1,
            "profileID": profile.id,
            "engine": engine.rawValue,
            "distributionReady": ready,
            "conditionalReason": profile.conditionalReason ?? NSNull(),
            "fileCount": files.count,
            "files": files,
            "appStoreApprovalClaimed": false,
            "writtenOfferCreated": false,
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest,
                                                      options: [.prettyPrinted, .sortedKeys])
        try write(manifestData, to: staging.appendingPathComponent("bundle-manifest.json"),
                  fileManager: fileManager)
        guard renameatx_np(AT_FDCWD, staging.path, AT_FDCWD, outputURL.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw GameDistributionError.destinationExists }
            throw GameDistributionError.io("publish distribution bundle")
        }
        let manifestDigest = GameDigest.sha256(manifestData)
        return .init(profileID: profile.id, distributionReady: ready,
                     conditionalReason: profile.conditionalReason,
                     bundleURL: outputURL, manifestSHA256: manifestDigest,
                     files: files, pairedSources: pairedRecords,
                     appStoreApprovalClaimed: false, writtenOfferCreated: false)
    }

    private static func encodePaired(_ value: GameDistributionPairedSourceRecord) -> [String: Any] {
        var object: [String: Any] = [
            "id": value.id, "role": value.role, "sha256": value.sha256,
            "bytes": value.bytes, "requiredForDistribution": value.requiredForDistribution,
            "resolved": value.resolved,
        ]
        if let sourceFile = value.sourceFile { object["sourceFile"] = sourceFile }
        return object
    }

    private static func defaultResourceRoot() throws -> URL {
        let candidates: [(String, Int)] = [
            ("Resources/Distribution/Notices", 3),
            ("Distribution/Notices", 3),
            ("", 1),
        ]
        for (subdirectory, levels) in candidates {
            guard let url = GameBuildResourceLocator.url("RESOURCE-RECEIPTS", "json", subdirectory) else {
                continue
            }
            var root = url.deletingLastPathComponent()
            for _ in 1..<levels { root = root.deletingLastPathComponent() }
            return root
        }
        throw GameDistributionError.io("missing distribution receipts")
    }

    private static func noticeReceipts(at resourceRoot: URL) throws -> [String: String] {
        let url = resourceRoot.appendingPathComponent("Distribution/Notices/RESOURCE-RECEIPTS.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw GameDistributionError.io("missing distribution receipts")
        }
        let receipts = try JSONDecoder().decode(GameDistributionNoticeReceipts.self,
                                                from: Data(contentsOf: url))
        guard receipts.schemaVersion == 1 else { throw GameDistributionError.io("receipts schema") }
        return Dictionary(uniqueKeysWithValues: receipts.records.map { ($0.resource, $0.sha256) })
    }

    private static func validateRelative(_ value: String) throws {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("\\"),
              !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw GameDistributionError.invalidRelativePath(value)
        }
    }

    private static func copyFile(_ source: URL, to destination: URL, fileManager: FileManager) throws {
        guard !isSymlink(source) else { throw GameDistributionError.io("symlink: \(source.lastPathComponent)") }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            throw GameDistributionError.destinationExists
        }
        try fileManager.copyItem(at: source, to: destination)
    }

    private static func copyTree(_ source: URL, to destination: URL, fileManager: FileManager) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw GameDistributionError.io("missing directory: \(source.lastPathComponent)")
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let children = try fileManager.contentsOfDirectory(at: source,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [])
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { throw GameDistributionError.io("symlink: \(child.lastPathComponent)") }
            let target = destination.appendingPathComponent(child.lastPathComponent)
            if values.isDirectory == true {
                try copyTree(child, to: target, fileManager: fileManager)
            } else {
                try copyFile(child, to: target, fileManager: fileManager)
            }
        }
    }

    private static func relativeFiles(_ root: URL, fileManager: FileManager) throws -> [String] {
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        var files: [String] = []
        let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { throw GameDistributionError.io("symlink: \(url.lastPathComponent)") }
            if values.isDirectory != true {
                files.append(try relativePath(url, under: root))
            }
        }
        return files.sorted()
    }

    private static func hashFiles(_ root: URL, fileManager: FileManager) throws -> [String: String] {
        var result: [String: String] = [:]
        let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true { continue }
            let relative = try relativePath(url, under: root)
            result[relative] = try sha256File(url)
        }
        return result
    }

    /// Foundation enumeration may resolve /var to /private/var on macOS.
    /// Compare canonical path components rather than replacing a string prefix;
    /// manifests and user-notice copying must always receive relative paths.
    private static func relativePath(_ url: URL, under root: URL) throws -> String {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let file = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard file.count > base.count, file.prefix(base.count).elementsEqual(base) else {
            throw GameDistributionError.io("file outside distribution root")
        }
        let result = file.dropFirst(base.count).joined(separator: "/")
        try validateRelative(result)
        return result
    }

    private static func containsSwiftSource(_ root: URL, fileManager: FileManager) -> Bool {
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return false
        }
        while let url = enumerator.nextObject() as? URL {
            if url.pathExtension.lowercased() == "swift" { return true }
        }
        return false
    }

    private static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private static func fileSize(_ url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return values.fileSize ?? 0
    }

    private static func sha256File(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func write(_ data: Data, to url: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }
}
