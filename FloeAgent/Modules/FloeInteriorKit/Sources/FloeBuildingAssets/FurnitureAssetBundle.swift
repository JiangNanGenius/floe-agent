// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeInteriorCore

/// An opened immutable version or private offline copy. It holds no live
/// library handle; verification and placement read only this directory.
public struct FurnitureAssetBundle: Sendable {
    public let rootURL: URL
    public let manifest: FurnitureAssetManifest
    public let manifestSHA256: String
    public let limits: FurnitureAssetLibraryLimits
    let manifestBytes: Data

    init(
        rootURL: URL,
        manifestBytes: Data,
        manifestSHA256: String,
        limits: FurnitureAssetLibraryLimits
    ) throws {
        let manifest: FurnitureAssetManifest
        do {
            manifest = try JSONDecoder().decode(FurnitureAssetManifest.self, from: manifestBytes)
            try manifest.validate(limits: limits)
        } catch {
            throw FurnitureAssetLibraryError.manifestCorrupt("the manifest could not be decoded")
        }
        self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        self.manifest = manifest
        self.manifestSHA256 = manifestSHA256
        self.manifestBytes = manifestBytes
        self.limits = limits
    }

    public init(rootURL: URL, limits: FurnitureAssetLibraryLimits = .standard) throws {
        let resolved = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let source: FurnitureAssetSourceAccess
        do {
            source = try FurnitureAssetSourceAccess(rootURL: resolved)
        } catch {
            throw FurnitureAssetLibraryError.manifestCorrupt("the version root is unavailable")
        }
        let bytes: Data
        do {
            bytes = try source.readFile("manifest.json", limit: limits.maximumManifestBytes, maxPathBytes: limits.maximumPathBytes)
            source.close()
        } catch {
            source.close()
            throw FurnitureAssetLibraryError.manifestCorrupt("the manifest is missing or unreadable")
        }
        try self.init(
            rootURL: resolved,
            manifestBytes: bytes,
            manifestSHA256: FurnitureAssetHashing.sha256Hex(bytes),
            limits: limits
        )
    }

    /// Re-reads the exact manifest and every declared byte. A successful result
    /// is a local read-back, not a claim that native geometry or rendering has
    /// been verified.
    public func verify() throws -> FurnitureAssetVerification {
        let source: FurnitureAssetSourceAccess
        do {
            source = try FurnitureAssetSourceAccess(rootURL: rootURL)
        } catch {
            throw FurnitureAssetLibraryError.manifestCorrupt("the version root is unavailable")
        }
        defer { source.close() }

        let currentManifestBytes: Data
        do {
            currentManifestBytes = try source.readFile(
                "manifest.json",
                limit: limits.maximumManifestBytes,
                maxPathBytes: limits.maximumPathBytes
            )
        } catch {
            throw FurnitureAssetLibraryError.manifestCorrupt("the manifest is missing or unreadable")
        }
        guard FurnitureAssetHashing.sha256Hex(currentManifestBytes) == manifestSHA256 else {
            throw FurnitureAssetLibraryError.manifestCorrupt("the manifest no longer matches its pinned hash")
        }
        do {
            let decoded = try JSONDecoder().decode(FurnitureAssetManifest.self, from: currentManifestBytes)
            guard decoded == manifest else {
                throw FurnitureAssetLibraryError.manifestCorrupt("the manifest changed after it was opened")
            }
        } catch let error as FurnitureAssetLibraryError {
            throw error
        } catch {
            throw FurnitureAssetLibraryError.manifestCorrupt("the manifest could not be decoded")
        }

        var seen = Set<String>()
        var fileCount = 0
        var dependencyCount = 0
        var totalBytes = 0
        for file in allFiles {
            guard seen.insert(file.relativePath).inserted else {
                throw FurnitureAssetLibraryError.manifestCorrupt("the manifest lists a file twice")
            }
            try verify(file, source: source)
            fileCount += 1
            totalBytes += file.byteCount
            if manifest.dependencies.contains(where: { $0.relativePath == file.relativePath }) {
                dependencyCount += 1
            }
        }
        return .init(
            assetID: manifest.assetID,
            version: manifest.version,
            manifestSHA256: manifestSHA256,
            verifiedFileCount: fileCount,
            verifiedDependencyCount: dependencyCount,
            totalBytes: totalBytes,
            admission: manifest.admission
        )
    }

    /// The stored OBJ URL for the native mesh importer. The original OBJ/MTL/
    /// texture layout is preserved below `files/`, so relative MTL references
    /// continue to resolve. Assets with unresolved dependencies are refused.
    public func mainFileURL() throws -> URL {
        _ = try verify()
        guard manifest.admission == .ready else {
            throw FurnitureAssetLibraryError.notAdmitted(
                assetID: manifest.assetID,
                version: manifest.version,
                issueCount: manifest.issues.count
            )
        }
        let url = rootURL.appendingPathComponent(manifest.mainFile.relativePath)
        guard FurnitureAssetFileSystem.contains(url, in: rootURL) else {
            throw FurnitureAssetLibraryError.manifestCorrupt("the main file path escapes the version root")
        }
        return url
    }

    public func placementInput(
        instanceID: UUID,
        roomID: UUID? = nil,
        pose: FurniturePose,
        sizing: FurnitureSizing,
        orientation: FurnitureSourceOrientation? = nil
    ) throws -> FurniturePlacementInput {
        _ = try verify()
        guard manifest.admission == .ready else {
            throw FurnitureAssetLibraryError.notAdmitted(
                assetID: manifest.assetID,
                version: manifest.version,
                issueCount: manifest.issues.count
            )
        }
        let input = FurniturePlacementInput(
            instanceID: instanceID,
            roomID: roomID,
            assetID: manifest.assetID,
            assetVersion: manifest.version,
            sourceSHA256: manifest.mainFile.sha256,
            dependencySHA256: manifest.dependencySHA256,
            sourceBounds: manifest.sourceBounds,
            orientation: orientation ?? manifest.sourceOrientation,
            sizing: sizing,
            pose: pose
        )
        _ = try FurniturePlacementPlanner.make(input)
        return input
    }

    public func placementPlan(
        instanceID: UUID,
        roomID: UUID? = nil,
        pose: FurniturePose,
        sizing: FurnitureSizing,
        orientation: FurnitureSourceOrientation? = nil
    ) throws -> FurniturePlacementPlan {
        let input = try placementInput(
            instanceID: instanceID,
            roomID: roomID,
            pose: pose,
            sizing: sizing,
            orientation: orientation
        )
        return try FurniturePlacementPlanner.make(input)
    }

    public func pin() throws -> FurnitureAssetPin {
        _ = try verify()
        return try makePin()
    }

    func makePin() throws -> FurnitureAssetPin {
        guard manifest.admission == .ready else {
            throw FurnitureAssetLibraryError.notAdmitted(
                assetID: manifest.assetID,
                version: manifest.version,
                issueCount: manifest.issues.count
            )
        }
        return .init(
            assetID: manifest.assetID,
            version: manifest.version,
            manifestSHA256: manifestSHA256,
            sourceSHA256: manifest.mainFile.sha256,
            dependencySHA256: manifest.dependencySHA256
        )
    }

    var allFiles: [FurnitureAssetFile] {
        var files = [manifest.mainFile]
        files.append(contentsOf: manifest.dependencies)
        if let thumbnail = manifest.thumbnail { files.append(thumbnail) }
        if let licenseFile = manifest.licenseFile { files.append(licenseFile) }
        return files
    }

    private func verify(_ file: FurnitureAssetFile, source: FurnitureAssetSourceAccess) throws {
        let readLimit: Int
        if file.byteCount == Int.max {
            readLimit = Int.max
        } else {
            readLimit = file.byteCount + 1
        }
        let data: Data
        do {
            data = try source.readFile(file.relativePath, limit: readLimit, maxPathBytes: limits.maximumPathBytes)
        } catch {
            throw FurnitureAssetLibraryError.hashMismatch(file.relativePath)
        }
        guard data.count == file.byteCount,
              FurnitureAssetHashing.sha256Hex(data) == file.sha256 else {
            throw FurnitureAssetLibraryError.hashMismatch(file.relativePath)
        }
    }
}

struct FurnitureAssetStoredPin: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var pin: FurnitureAssetPin
}

/// A private project/offline copy. Opening it never consults or writes to the
/// source library; removing the library leaves this copy verifiable.
public struct FurnitureAssetOfflineCopy: Sendable {
    public let bundle: FurnitureAssetBundle
    public let pin: FurnitureAssetPin

    public init(rootURL: URL, limits: FurnitureAssetLibraryLimits = .standard) throws {
        let bundle = try FurnitureAssetBundle(rootURL: rootURL, limits: limits)
        let source: FurnitureAssetSourceAccess
        do {
            source = try FurnitureAssetSourceAccess(rootURL: bundle.rootURL)
        } catch {
            throw FurnitureAssetLibraryError.manifestCorrupt("the offline copy root is unavailable")
        }
        defer { source.close() }
        let pinBytes: Data
        do {
            pinBytes = try source.readFile("pin.json", limit: limits.maximumManifestBytes, maxPathBytes: limits.maximumPathBytes)
        } catch {
            throw FurnitureAssetLibraryError.manifestCorrupt("the offline copy has no readable pin")
        }
        let storedPin: FurnitureAssetStoredPin
        do {
            storedPin = try JSONDecoder().decode(FurnitureAssetStoredPin.self, from: pinBytes)
        } catch {
            throw FurnitureAssetLibraryError.manifestCorrupt("the offline copy pin could not be decoded")
        }
        guard storedPin.schemaVersion == 1,
              storedPin.pin.assetID == bundle.manifest.assetID,
              storedPin.pin.version == bundle.manifest.version,
              storedPin.pin.manifestSHA256 == bundle.manifestSHA256,
              storedPin.pin.sourceSHA256 == bundle.manifest.mainFile.sha256,
              storedPin.pin.dependencySHA256 == bundle.manifest.dependencySHA256 else {
            throw FurnitureAssetLibraryError.manifestCorrupt("the offline copy pin does not match its manifest")
        }
        self.bundle = bundle
        self.pin = storedPin.pin
    }

    public var rootURL: URL { bundle.rootURL }
    public var manifest: FurnitureAssetManifest { bundle.manifest }

    public func verify() throws -> FurnitureAssetVerification {
        try bundle.verify()
    }

    public func mainFileURL() throws -> URL {
        try bundle.mainFileURL()
    }

    public func placementInput(
        instanceID: UUID,
        roomID: UUID? = nil,
        pose: FurniturePose,
        sizing: FurnitureSizing,
        orientation: FurnitureSourceOrientation? = nil
    ) throws -> FurniturePlacementInput {
        try bundle.placementInput(
            instanceID: instanceID,
            roomID: roomID,
            pose: pose,
            sizing: sizing,
            orientation: orientation
        )
    }

    public func placementPlan(
        instanceID: UUID,
        roomID: UUID? = nil,
        pose: FurniturePose,
        sizing: FurnitureSizing,
        orientation: FurnitureSourceOrientation? = nil
    ) throws -> FurniturePlacementPlan {
        try bundle.placementPlan(
            instanceID: instanceID,
            roomID: roomID,
            pose: pose,
            sizing: sizing,
            orientation: orientation
        )
    }
}
