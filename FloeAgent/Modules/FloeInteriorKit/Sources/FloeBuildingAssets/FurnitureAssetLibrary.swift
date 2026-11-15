// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeInteriorCore

struct FurnitureAssetLibraryLayout: Sendable {
    let root: URL
    let assets: URL
    let locks: URL
    let staging: URL
}

struct FurnitureAssetImportAccumulator {
    let limits: FurnitureAssetLibraryLimits
    var totalBytes: Int
    var fileCount: Int
    var lowercasedStoredPaths: Set<String>
    var dependencyFiles: [String: FurnitureAssetFile] = [:]
    var dependencyData: [String: Data] = [:]
    var metadataFiles: [FurnitureAssetFile] = []
    var metadataData: [String: Data] = [:]
    var issues: [FurnitureAssetIssue] = []

    init(limits: FurnitureAssetLibraryLimits, mainSourceRelativePath: String, mainByteCount: Int) throws {
        let stored = try FurnitureAssetPathName.storedResourcePath(
            sourceRelativePath: mainSourceRelativePath,
            maxBytes: limits.maximumPathBytes
        )
        self.limits = limits
        self.totalBytes = mainByteCount
        self.fileCount = 1
        self.lowercasedStoredPaths = [stored.lowercased()]
    }

    mutating func addDependency(path: String, role: FurnitureAssetFileRole, data: Data) throws {
        guard dependencyFiles[path] == nil else { return }
        let stored = try FurnitureAssetPathName.storedResourcePath(
            sourceRelativePath: path,
            maxBytes: limits.maximumPathBytes
        )
        guard lowercasedStoredPaths.insert(stored.lowercased()).inserted else {
            issues.append(.init(
                kind: .caseCollision,
                sourceRelativePath: path,
                role: role,
                detail: "Another stored file differs only by case; the dependency was not admitted."
            ))
            return
        }
        guard fileCount < limits.maximumFiles else {
            throw FurnitureAssetLibraryError.budgetExceeded("the asset exceeds \(limits.maximumFiles) files")
        }
        guard totalBytes <= limits.maximumTotalBytes - data.count else {
            throw FurnitureAssetLibraryError.budgetExceeded("the asset exceeds \(limits.maximumTotalBytes) bytes")
        }
        fileCount += 1
        totalBytes += data.count
        let file = FurnitureAssetFile(
            relativePath: stored,
            sourceRelativePath: path,
            role: role,
            byteCount: data.count,
            sha256: FurnitureAssetHashing.sha256Hex(data)
        )
        dependencyFiles[path] = file
        dependencyData[path] = data
    }

    @discardableResult
    mutating func addMetadata(sourceRelativePath: String, role: FurnitureAssetFileRole, data: Data) throws -> FurnitureAssetFile {
        guard role == .license || role == .thumbnail else {
            throw FurnitureAssetLibraryError.invalidValue(field: "metadata role", reason: "only license and thumbnail files use metadata storage")
        }
        let name = try FurnitureAssetPathName.basename(sourceRelativePath, maxBytes: limits.maximumPathBytes)
        let kind = role == .license ? "license" : "thumbnail"
        let stored = try FurnitureAssetPathName.storedMetadataPath(
            kind: kind,
            basename: name,
            maxBytes: limits.maximumPathBytes
        )
        guard lowercasedStoredPaths.insert(stored.lowercased()).inserted else {
            throw FurnitureAssetLibraryError.invalidValue(field: "metadata path", reason: "the metadata file collides with another stored file")
        }
        guard fileCount < limits.maximumFiles else {
            throw FurnitureAssetLibraryError.budgetExceeded("the asset exceeds \(limits.maximumFiles) files")
        }
        guard totalBytes <= limits.maximumTotalBytes - data.count else {
            throw FurnitureAssetLibraryError.budgetExceeded("the asset exceeds \(limits.maximumTotalBytes) bytes")
        }
        fileCount += 1
        totalBytes += data.count
        let file = FurnitureAssetFile(
            relativePath: stored,
            sourceRelativePath: sourceRelativePath,
            role: role,
            byteCount: data.count,
            sha256: FurnitureAssetHashing.sha256Hex(data)
        )
        metadataFiles.append(file)
        metadataData[stored] = data
        return file
    }
}

public actor FurnitureAssetLibrary {
    public nonisolated let rootURL: URL
    public nonisolated let limits: FurnitureAssetLibraryLimits

    public init(rootURL: URL, limits: FurnitureAssetLibraryLimits = .standard) {
        self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        self.limits = limits
    }

    public func list() async throws -> [FurnitureAssetSummary] {
        try allSummaries()
    }

    public func versions(for assetID: String) async throws -> [FurnitureAssetSummary] {
        try FurnitureAssetValidation.validateAssetID(assetID)
        guard let layout = try existingLayout() else { return [] }
        let directory = assetDirectory(in: layout, assetID: assetID)
        return try summaries(in: directory)
    }

    public func search(
        query: String,
        category: String? = nil,
        limit: Int = 50
    ) async throws -> [FurnitureAssetSummary] {
        guard (1...500).contains(limit) else {
            throw FurnitureAssetLibraryError.invalidValue(field: "search limit", reason: "must be 1...500")
        }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = try allSummaries()
        var result: [FurnitureAssetSummary] = []
        for summary in all {
            if let category {
                guard let actual = summary.category,
                      actual.localizedCaseInsensitiveCompare(category) == .orderedSame else { continue }
            }
            if !trimmedQuery.isEmpty {
                let fields = [
                    summary.name,
                    summary.assetID,
                    summary.version,
                    summary.category ?? "",
                    summary.licenseIdentifier
                ]
                guard fields.contains(where: { $0.localizedCaseInsensitiveContains(trimmedQuery) }) else { continue }
            }
            result.append(summary)
            if result.count == limit { break }
        }
        return result
    }

    /// Imports one OBJ and its MTL/texture closure from a user-selected source
    /// root. Missing or unsafe dependencies are recorded as `needsRepair` and
    /// are never invented; malformed source geometry throws and publishes
    /// nothing.
    public func importOBJ(
        sourceRootURL: URL,
        relativePath: String,
        assetID: String,
        version: String,
        name: String,
        category: String? = nil,
        provenance: FurnitureAssetProvenance,
        declaredDimensions: FurnitureDeclaredDimensions? = nil,
        sourceBoundsUnit: FurnitureLengthUnit? = nil,
        sourceOrientation: FurnitureSourceOrientation,
        thumbnailRelativePath: String? = nil,
        licenseFileRelativePath: String? = nil,
        onPhase: FurnitureAssetPhaseObserver? = nil
    ) async throws -> FurnitureAssetVersion {
        try limits.validate()
        try observe(.validatingSource, onPhase)
        try FurnitureAssetValidation.validateAssetID(assetID)
        try FurnitureAssetValidation.validateVersion(version)
        try FurnitureAssetValidation.validateName(name)
        try FurnitureAssetValidation.validateCategory(category)
        try FurnitureAssetValidation.validateProvenance(provenance)
        if let dimensions = declaredDimensions {
            try FurnitureAssetValidation.validateDeclaredDimensions(dimensions)
        }
        if provenance.license.evidence == .licenseFile, licenseFileRelativePath == nil {
            throw FurnitureAssetLibraryError.invalidLicenseFile("license-file evidence was declared but no license file was supplied")
        }

        guard let layout = try prepareLayout(create: true) else {
            throw FurnitureAssetLibraryError.io("the furniture asset library layout is unavailable")
        }
        let sourceRoot = sourceRootURL.standardizedFileURL.resolvingSymlinksInPath()
        let source: FurnitureAssetSourceAccess
        do {
            source = try FurnitureAssetSourceAccess(rootURL: sourceRoot)
        } catch {
            throw FurnitureAssetLibraryError.sourceRootUnavailable
        }
        defer { source.close() }

        let mainRelative: String
        do {
            mainRelative = try FurnitureAssetPathName.normalise(relativePath, maxBytes: limits.maximumPathBytes)
        } catch {
            throw FurnitureAssetLibraryError.sourceFileUnsafe("the main OBJ path is not a safe relative path")
        }
        guard (mainRelative as NSString).pathExtension.lowercased() == "obj" else {
            throw FurnitureAssetLibraryError.unsupportedFormat((mainRelative as NSString).pathExtension)
        }

        let mainData: Data
        do {
            mainData = try source.readFile(
                mainRelative,
                limit: limits.maximumMainFileBytes,
                maxPathBytes: limits.maximumPathBytes
            )
        } catch {
            throw mapMainReadError(error, path: mainRelative)
        }
        guard !mainData.isEmpty else {
            throw FurnitureAssetLibraryError.invalidOBJ("the OBJ is empty")
        }
        let mainHash = FurnitureAssetHashing.sha256Hex(mainData)

        try observe(.parsingSource, onPhase)
        let parsed = try FurnitureOBJParser.parse(mainData, limits: limits)
        try FurnitureAssetValidation.validatePlacementGeometry(
            assetID: assetID,
            version: version,
            sourceSHA256: mainHash,
            bounds: parsed.bounds,
            orientation: sourceOrientation
        )

        try observe(.resolvingDependencies, onPhase)
        var accumulator = try FurnitureAssetImportAccumulator(
            limits: limits,
            mainSourceRelativePath: mainRelative,
            mainByteCount: mainData.count
        )
        let mainDirectory = FurnitureAssetPathName.parentDirectory(mainRelative)
        var processed = Set<String>()
        var materialLibraries: [String] = []
        for argument in parsed.materialLibraries {
            let candidates: [String]
            if argument.contains("\"") || argument.contains("'") {
                do {
                    candidates = try FurnitureOBJParser.quotedTokens(argument)
                } catch {
                    throw FurnitureAssetLibraryError.invalidOBJ("an mtllib reference has an unterminated quote")
                }
            } else if let fullReference = try? FurnitureAssetPathName.resolve(
                argument,
                relativeTo: mainDirectory,
                maxBytes: limits.maximumPathBytes
            ) {
                switch source.probe(fullReference, maxPathBytes: limits.maximumPathBytes) {
                case .regularFile(_):
                    candidates = [argument]
                case .missing:
                    candidates = argument.split(whereSeparator: \.isWhitespace).map { String($0) }
                case .unsafe, .notRegular, .unreadable:
                    candidates = [argument]
                }
            } else {
                candidates = [argument]
            }
            for candidate in candidates {
                let resolved: String
                do {
                    resolved = try FurnitureAssetPathName.resolve(
                        candidate,
                        relativeTo: mainDirectory,
                        maxBytes: limits.maximumPathBytes
                    )
                } catch {
                    accumulator.issues.append(.init(
                        kind: .unsafeReference,
                        sourceRelativePath: FurnitureAssetPathName.redactedReference(candidate),
                        role: .materialLibrary,
                        detail: "The material library path is absolute, traverses outside the selected root, or is not a safe relative path."
                    ))
                    continue
                }
                guard processed.insert(resolved).inserted else { continue }
                materialLibraries.append(resolved)
            }
        }

        var texturePaths: [String] = []
        while !materialLibraries.isEmpty {
            try Task.checkCancellation()
            let path = materialLibraries.removeFirst()
            let loaded = loadDependency(path: path, source: source)
            switch loaded {
            case .data(let data):
                try accumulator.addDependency(path: path, role: .materialLibrary, data: data)
                let mtl = FurnitureMTLParser.parse(data, sourceRelativePath: path, limits: limits)
                accumulator.issues.append(contentsOf: mtl.issues)
                let directory = FurnitureAssetPathName.parentDirectory(path)
                for reference in mtl.textureReferences {
                    let resolved: String
                    do {
                        resolved = try FurnitureAssetPathName.resolve(
                            reference.path,
                            relativeTo: directory,
                            maxBytes: limits.maximumPathBytes
                        )
                    } catch {
                        accumulator.issues.append(.init(
                            kind: .unsafeReference,
                            sourceRelativePath: FurnitureAssetPathName.redactedReference(reference.path),
                            role: .texture,
                            detail: "The texture path is absolute, traverses outside the selected root, or is not a safe relative path."
                        ))
                        continue
                    }
                    if !processed.contains(resolved) {
                        _ = processed.insert(resolved)
                        texturePaths.append(resolved)
                    }
                }
            case .failure(let kind, let detail):
                accumulator.issues.append(.init(
                    kind: kind,
                    sourceRelativePath: path,
                    role: .materialLibrary,
                    detail: detail
                ))
            }
        }

        while !texturePaths.isEmpty {
            try Task.checkCancellation()
            let path = texturePaths.removeFirst()
            let loaded = loadDependency(path: path, source: source)
            switch loaded {
            case .data(let data):
                try accumulator.addDependency(path: path, role: .texture, data: data)
            case .failure(let kind, let detail):
                accumulator.issues.append(.init(
                    kind: kind,
                    sourceRelativePath: path,
                    role: .texture,
                    detail: detail
                ))
            }
        }

        var licenseFile: FurnitureAssetFile?
        if let licenseFileRelativePath {
            let loaded = try readMetadata(
                licenseFileRelativePath,
                field: "license evidence",
                source: source,
                invalidError: { reason in FurnitureAssetLibraryError.invalidLicenseFile(reason) }
            )
            licenseFile = try accumulator.addMetadata(
                sourceRelativePath: loaded.path,
                role: .license,
                data: loaded.data
            )
        }
        var thumbnail: FurnitureAssetFile?
        if let thumbnailRelativePath {
            let loaded = try readMetadata(
                thumbnailRelativePath,
                field: "thumbnail",
                source: source,
                invalidError: { reason in FurnitureAssetLibraryError.invalidThumbnail(reason) }
            )
            thumbnail = try accumulator.addMetadata(
                sourceRelativePath: loaded.path,
                role: .thumbnail,
                data: loaded.data
            )
        }

        let dependencies = accumulator.dependencyFiles.values.sorted {
            $0.sourceRelativePath < $1.sourceRelativePath
        }
        let sortedIssues = accumulator.issues.sorted { lhs, rhs in
            if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }
            let leftPath = lhs.sourceRelativePath ?? ""
            let rightPath = rhs.sourceRelativePath ?? ""
            if leftPath != rightPath { return leftPath < rightPath }
            return lhs.detail < rhs.detail
        }
        let mainFile = FurnitureAssetFile(
            relativePath: try FurnitureAssetPathName.storedResourcePath(
                sourceRelativePath: mainRelative,
                maxBytes: limits.maximumPathBytes
            ),
            sourceRelativePath: mainRelative,
            role: .mainModel,
            byteCount: mainData.count,
            sha256: mainHash
        )
        let manifest = FurnitureAssetManifest(
            assetID: assetID,
            version: version,
            name: name,
            category: category,
            format: .obj,
            provenance: provenance,
            sourceBounds: parsed.bounds,
            sourceBoundsUnit: sourceBoundsUnit,
            sourceOrientation: sourceOrientation,
            declaredDimensions: declaredDimensions,
            mainFile: mainFile,
            dependencies: dependencies,
            thumbnail: thumbnail,
            licenseFile: licenseFile,
            issues: sortedIssues
        )
        try manifest.validate(limits: limits)
        let manifestData = try FurnitureAssetHashing.canonicalJSON(manifest)
        guard manifestData.count <= limits.maximumManifestBytes else {
            throw FurnitureAssetLibraryError.budgetExceeded("the manifest exceeds \(limits.maximumManifestBytes) bytes")
        }

        let assetRoot = assetDirectory(in: layout, assetID: assetID)
        let versionsRoot = assetRoot.appendingPathComponent("versions", isDirectory: true)
        try FurnitureAssetFileSystem.ensureDirectory(assetRoot)
        try FurnitureAssetFileSystem.ensureDirectory(versionsRoot)
        let versionRoot = versionDirectory(in: layout, assetID: assetID, version: version)

        let lock = try FurnitureAssetFileLock(url: lockURL(in: layout, assetID: assetID))
        try await acquire(lock)
        defer { lock.release() }

        if (try versionExists(at: versionRoot)) {
            let existing = try readBundle(
                at: versionRoot,
                expectedAssetID: assetID,
                expectedVersion: version
            )
            guard existing.manifest == manifest else {
                throw FurnitureAssetLibraryError.versionConflict(assetID: assetID, version: version)
            }
            _ = try existing.verify()
            return .init(manifest: existing.manifest, manifestSHA256: existing.manifestSHA256)
        }

        try observe(.stagingFiles, onPhase)
        let staging = layout.staging.appendingPathComponent(
            UUID().uuidString.lowercased() + ".part",
            isDirectory: true
        )
        try FurnitureAssetFileSystem.ensureDirectory(layout.staging)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        } catch {
            throw FurnitureAssetLibraryError.io("an import staging directory could not be created")
        }
        defer { FurnitureAssetFileSystem.removeIfPresent(staging) }

        try writeStagedFile(mainData, relativePath: manifest.mainFile.relativePath, in: staging)
        for (path, data) in accumulator.dependencyData {
            try Task.checkCancellation()
            try writeStagedFile(data, relativePath: "files/" + path, in: staging)
        }
        for (path, data) in accumulator.metadataData {
            try Task.checkCancellation()
            try writeStagedFile(data, relativePath: path, in: staging)
        }
        try writeStagedFile(manifestData, relativePath: "manifest.json", in: staging)

        try observe(.verifyingStaging, onPhase)
        let stagedBundle = try FurnitureAssetBundle(
            rootURL: staging,
            manifestBytes: manifestData,
            manifestSHA256: FurnitureAssetHashing.sha256Hex(manifestData),
            limits: limits
        )
        _ = try stagedBundle.verify()

        try Task.checkCancellation()
        try observe(.committing, onPhase)
        if (try versionExists(at: versionRoot)) {
            let existing = try readBundle(
                at: versionRoot,
                expectedAssetID: assetID,
                expectedVersion: version
            )
            guard existing.manifest == manifest else {
                throw FurnitureAssetLibraryError.versionConflict(assetID: assetID, version: version)
            }
            _ = try existing.verify()
            return .init(manifest: existing.manifest, manifestSHA256: existing.manifestSHA256)
        }

        do {
            try FileManager.default.moveItem(at: staging, to: versionRoot)
        } catch {
            if (try versionExists(at: versionRoot)) {
                let existing = try readBundle(
                    at: versionRoot,
                    expectedAssetID: assetID,
                    expectedVersion: version
                )
                guard existing.manifest == manifest else {
                    throw FurnitureAssetLibraryError.versionConflict(assetID: assetID, version: version)
                }
                _ = try existing.verify()
                return .init(manifest: existing.manifest, manifestSHA256: existing.manifestSHA256)
            }
            throw FurnitureAssetLibraryError.io("the immutable furniture asset version could not be published")
        }

        let published = try readBundle(
            at: versionRoot,
            expectedAssetID: assetID,
            expectedVersion: version
        )
        _ = try published.verify()
        return .init(manifest: published.manifest, manifestSHA256: published.manifestSHA256)
    }

    public func open(
        assetID: String,
        version: String,
        verifyFiles: Bool = true
    ) async throws -> FurnitureAssetBundle {
        try FurnitureAssetValidation.validateAssetID(assetID)
        try FurnitureAssetValidation.validateVersion(version)
        guard let layout = try existingLayout() else {
            throw FurnitureAssetLibraryError.notFound(assetID: assetID, version: version)
        }
        let assetRoot = assetDirectory(in: layout, assetID: assetID)
        let versionsRoot = assetRoot.appendingPathComponent("versions", isDirectory: true)
        guard FurnitureAssetFileSystem.isDirectoryNotSymlink(assetRoot),
              FurnitureAssetFileSystem.isDirectoryNotSymlink(versionsRoot) else {
            throw FurnitureAssetLibraryError.notFound(assetID: assetID, version: version)
        }
        let directory = versionDirectory(in: layout, assetID: assetID, version: version)
        guard (try versionExists(at: directory)) else {
            throw FurnitureAssetLibraryError.notFound(assetID: assetID, version: version)
        }
        let bundle = try readBundle(at: directory, expectedAssetID: assetID, expectedVersion: version)
        if verifyFiles { _ = try bundle.verify() }
        return bundle
    }

    public func open(pin: FurnitureAssetPin) async throws -> FurnitureAssetBundle {
        try FurnitureAssetValidation.validateAssetID(pin.assetID)
        try FurnitureAssetValidation.validateVersion(pin.version)
        guard FurnitureAssetHashing.isSHA256Hex(pin.manifestSHA256),
              FurnitureAssetHashing.isSHA256Hex(pin.sourceSHA256),
              pin.dependencySHA256.allSatisfy({ FurnitureAssetHashing.isSHA256Hex($0.value) }) else {
            throw FurnitureAssetLibraryError.invalidValue(field: "asset pin", reason: "the pin hashes are malformed")
        }
        guard let layout = try existingLayout() else {
            throw FurnitureAssetLibraryError.notFound(assetID: pin.assetID, version: pin.version)
        }
        let assetRoot = assetDirectory(in: layout, assetID: pin.assetID)
        let versionsRoot = assetRoot.appendingPathComponent("versions", isDirectory: true)
        guard FurnitureAssetFileSystem.isDirectoryNotSymlink(assetRoot),
              FurnitureAssetFileSystem.isDirectoryNotSymlink(versionsRoot) else {
            throw FurnitureAssetLibraryError.notFound(assetID: pin.assetID, version: pin.version)
        }
        let directory = versionDirectory(in: layout, assetID: pin.assetID, version: pin.version)
        guard (try versionExists(at: directory)) else {
            throw FurnitureAssetLibraryError.notFound(assetID: pin.assetID, version: pin.version)
        }
        let bundle = try readBundle(at: directory, expectedAssetID: pin.assetID, expectedVersion: pin.version)
        guard bundle.manifestSHA256 == pin.manifestSHA256 else {
            throw FurnitureAssetLibraryError.hashMismatch("manifest.json")
        }
        guard bundle.manifest.admission == .ready else {
            throw FurnitureAssetLibraryError.notAdmitted(
                assetID: pin.assetID,
                version: pin.version,
                issueCount: bundle.manifest.issues.count
            )
        }
        _ = try bundle.verify()
        guard pin.sourceSHA256 == bundle.manifest.mainFile.sha256,
              pin.dependencySHA256 == bundle.manifest.dependencySHA256 else {
            throw FurnitureAssetLibraryError.hashMismatch("the pinned dependency map")
        }
        return bundle
    }

    public func pin(assetID: String, version: String) async throws -> FurnitureAssetPin {
        let bundle = try await open(assetID: assetID, version: version, verifyFiles: true)
        return try bundle.makePin()
    }

    public func compare(
        assetID: String,
        from: String,
        to: String,
        verifyFiles: Bool = true
    ) async throws -> FurnitureAssetVersionDifference {
        guard from != to else {
            throw FurnitureAssetLibraryError.invalidValue(field: "version comparison", reason: "choose two different versions")
        }
        let fromBundle = try await open(assetID: assetID, version: from, verifyFiles: verifyFiles)
        let toBundle = try await open(assetID: assetID, version: to, verifyFiles: verifyFiles)
        let fromManifest = fromBundle.manifest
        let toManifest = toBundle.manifest
        let fromDependencies = Dictionary(uniqueKeysWithValues: fromManifest.dependencies.map { ($0.sourceRelativePath, $0) })
        let toDependencies = Dictionary(uniqueKeysWithValues: toManifest.dependencies.map { ($0.sourceRelativePath, $0) })
        let keys = Set(fromDependencies.keys).union(toDependencies.keys).sorted()
        var differences: [FurnitureAssetDependencyDifference] = []
        for key in keys {
            switch (fromDependencies[key], toDependencies[key]) {
            case let (old?, new?):
                if old.role != new.role {
                    differences.append(.init(
                        sourceRelativePath: key,
                        change: .roleChanged,
                        fromSHA256: old.sha256,
                        toSHA256: new.sha256,
                        fromRole: old.role,
                        toRole: new.role
                    ))
                } else if old.sha256 != new.sha256 || old.byteCount != new.byteCount {
                    differences.append(.init(
                        sourceRelativePath: key,
                        change: .contentChanged,
                        fromSHA256: old.sha256,
                        toSHA256: new.sha256,
                        fromRole: old.role,
                        toRole: new.role
                    ))
                }
            case let (old?, nil):
                differences.append(.init(
                    sourceRelativePath: key,
                    change: .removed,
                    fromSHA256: old.sha256,
                    fromRole: old.role
                ))
            case let (nil, new?):
                differences.append(.init(
                    sourceRelativePath: key,
                    change: .added,
                    toSHA256: new.sha256,
                    toRole: new.role
                ))
            case (nil, nil):
                continue
            }
        }
        return .init(
            assetID: assetID,
            fromVersion: from,
            toVersion: to,
            fromManifestSHA256: fromBundle.manifestSHA256,
            toManifestSHA256: toBundle.manifestSHA256,
            mainFileChanged: fromManifest.mainFile.sha256 != toManifest.mainFile.sha256,
            fromMainFileSHA256: fromManifest.mainFile.sha256,
            toMainFileSHA256: toManifest.mainFile.sha256,
            dependencyDifferences: differences,
            nameChanged: fromManifest.name != toManifest.name,
            categoryChanged: fromManifest.category != toManifest.category,
            declaredDimensionsChanged: fromManifest.declaredDimensions != toManifest.declaredDimensions,
            sourceBoundsChanged: fromManifest.sourceBounds != toManifest.sourceBounds,
            sourceOrientationChanged: fromManifest.sourceOrientation != toManifest.sourceOrientation,
            provenanceChanged: fromManifest.provenance != toManifest.provenance,
            thumbnailChanged: fromManifest.thumbnail != toManifest.thumbnail,
            licenseChanged: fromManifest.licenseFile != toManifest.licenseFile,
            admissionChanged: fromManifest.admission != toManifest.admission
        )
    }

    /// Copies the exact pinned version into a private project directory. The
    /// copy has its own manifest, files and pin; it never writes back to the
    /// library and remains readable after the library is removed.
    public func makeOfflineCopy(
        pin: FurnitureAssetPin,
        to destinationURL: URL,
        onPhase: FurnitureAssetPhaseObserver? = nil
    ) async throws -> FurnitureAssetOfflineCopy {
        try limits.validate()
        try Task.checkCancellation()
        let sourceBundle = try await open(pin: pin)
        let leaf = destinationURL.lastPathComponent
        let normalisedLeaf = try? FurnitureAssetPathName.normalise(leaf, maxBytes: limits.maximumPathBytes)
        guard !leaf.isEmpty, leaf != ".", leaf != "..",
              let normalisedLeaf, normalisedLeaf == leaf,
              !leaf.contains("/") else {
            throw FurnitureAssetLibraryError.invalidValue(field: "offline destination", reason: "the destination must end in one safe directory name")
        }
        let requestedParent = destinationURL.deletingLastPathComponent().standardizedFileURL
        let parent = requestedParent.resolvingSymlinksInPath()
        let destination = parent.appendingPathComponent(leaf, isDirectory: true)
        if FurnitureAssetFileSystem.isSymbolicLink(destination) {
            throw FurnitureAssetLibraryError.destinationExists(destination)
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            throw FurnitureAssetLibraryError.destinationExists(destination)
        }
        try FurnitureAssetFileSystem.ensureDirectoryTree(parent)
        let staging = parent.appendingPathComponent(
            ".floe-asset-" + UUID().uuidString.lowercased() + ".part",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        } catch {
            throw FurnitureAssetLibraryError.io("the offline copy staging directory could not be created")
        }
        defer { FurnitureAssetFileSystem.removeIfPresent(staging) }

        try observe(.stagingFiles, onPhase)
        let source: FurnitureAssetSourceAccess
        do {
            source = try FurnitureAssetSourceAccess(rootURL: sourceBundle.rootURL)
        } catch {
            throw FurnitureAssetLibraryError.manifestCorrupt("the pinned version root is unavailable")
        }
        defer { source.close() }
        try writeStagedFile(sourceBundle.manifestBytes, relativePath: "manifest.json", in: staging)
        for file in sourceBundle.allFiles {
            try Task.checkCancellation()
            let data: Data
            do {
                data = try source.readFile(
                    file.relativePath,
                    limit: file.byteCount + 1,
                    maxPathBytes: limits.maximumPathBytes
                )
            } catch {
                throw FurnitureAssetLibraryError.hashMismatch(file.relativePath)
            }
            guard data.count == file.byteCount,
                  FurnitureAssetHashing.sha256Hex(data) == file.sha256 else {
                throw FurnitureAssetLibraryError.hashMismatch(file.relativePath)
            }
            try writeStagedFile(data, relativePath: file.relativePath, in: staging)
        }
        let storedPin = FurnitureAssetStoredPin(schemaVersion: 1, pin: pin)
        try writeStagedFile(
            try FurnitureAssetHashing.canonicalJSON(storedPin),
            relativePath: "pin.json",
            in: staging
        )

        try observe(.verifyingStaging, onPhase)
        let stagedCopy = try FurnitureAssetOfflineCopy(rootURL: staging, limits: limits)
        _ = try stagedCopy.verify()
        try Task.checkCancellation()
        try observe(.committing, onPhase)
        if FurnitureAssetFileSystem.isSymbolicLink(destination) || FileManager.default.fileExists(atPath: destination.path) {
            throw FurnitureAssetLibraryError.destinationExists(destination)
        }
        do {
            try FileManager.default.moveItem(at: staging, to: destination)
        } catch {
            if FileManager.default.fileExists(atPath: destination.path) {
                throw FurnitureAssetLibraryError.destinationExists(destination)
            }
            throw FurnitureAssetLibraryError.io("the offline furniture asset copy could not be published")
        }
        let copy = try FurnitureAssetOfflineCopy(rootURL: destination, limits: limits)
        _ = try copy.verify()
        return copy
    }

    // MARK: - Layout and reads

    private func prepareLayout(create: Bool) throws -> FurnitureAssetLibraryLayout? {
        try limits.validate()
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: rootURL.path) {
            guard create else { return nil }
            do {
                try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            } catch {
                guard fileManager.fileExists(atPath: rootURL.path) else {
                    throw FurnitureAssetLibraryError.io("the furniture asset library root could not be created")
                }
            }
        }
        try FurnitureAssetFileSystem.ensureDirectory(rootURL)
        let assets = rootURL.appendingPathComponent("assets", isDirectory: true)
        if !fileManager.fileExists(atPath: assets.path) {
            guard create else { return nil }
            try FurnitureAssetFileSystem.ensureDirectory(assets)
        } else {
            try FurnitureAssetFileSystem.ensureDirectory(assets)
        }
        let locks = rootURL.appendingPathComponent(".locks", isDirectory: true)
        let staging = rootURL.appendingPathComponent(".staging", isDirectory: true)
        if create {
            try FurnitureAssetFileSystem.ensureDirectory(locks)
            try FurnitureAssetFileSystem.ensureDirectory(staging)
        }
        return .init(root: rootURL, assets: assets, locks: locks, staging: staging)
    }

    private func existingLayout() throws -> FurnitureAssetLibraryLayout? {
        try prepareLayout(create: false)
    }

    private func assetDirectory(in layout: FurnitureAssetLibraryLayout, assetID: String) -> URL {
        layout.assets.appendingPathComponent(FurnitureAssetHashing.sha256Hex(assetID), isDirectory: true)
    }

    private func versionDirectory(in layout: FurnitureAssetLibraryLayout, assetID: String, version: String) -> URL {
        assetDirectory(in: layout, assetID: assetID)
            .appendingPathComponent("versions", isDirectory: true)
            .appendingPathComponent(FurnitureAssetHashing.sha256Hex(version), isDirectory: true)
    }

    private func lockURL(in layout: FurnitureAssetLibraryLayout, assetID: String) -> URL {
        layout.locks.appendingPathComponent(FurnitureAssetHashing.sha256Hex(assetID) + ".lock", isDirectory: false)
    }

    private func allSummaries() throws -> [FurnitureAssetSummary] {
        guard let layout = try existingLayout() else { return [] }
        let fileManager = FileManager.default
        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: layout.assets.path)
        } catch {
            throw FurnitureAssetLibraryError.io("the furniture asset directory could not be listed")
        }
        var result: [FurnitureAssetSummary] = []
        for name in names.sorted() where FurnitureAssetHashing.isSHA256Hex(name) {
            result.append(contentsOf: try summaries(in: layout.assets.appendingPathComponent(name, isDirectory: true)))
        }
        return result.sorted { Self.summaryOrder($0, $1) }
    }

    private func summaries(in assetDirectory: URL) throws -> [FurnitureAssetSummary] {
        guard FurnitureAssetFileSystem.isDirectoryNotSymlink(assetDirectory) else { return [] }
        let versionsDirectory = assetDirectory.appendingPathComponent("versions", isDirectory: true)
        guard FurnitureAssetFileSystem.isDirectoryNotSymlink(versionsDirectory) else { return [] }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: versionsDirectory.path)
        } catch {
            throw FurnitureAssetLibraryError.io("the furniture asset versions could not be listed")
        }
        var result: [FurnitureAssetSummary] = []
        for name in names.sorted() where FurnitureAssetHashing.isSHA256Hex(name) {
            let directory = versionsDirectory.appendingPathComponent(name, isDirectory: true)
            guard FurnitureAssetFileSystem.isDirectoryNotSymlink(directory) else { continue }
            let bundle = try readBundle(at: directory, expectedAssetID: nil, expectedVersion: nil)
            guard FurnitureAssetHashing.sha256Hex(bundle.manifest.assetID) == assetDirectory.lastPathComponent,
                  FurnitureAssetHashing.sha256Hex(bundle.manifest.version) == name else {
                throw FurnitureAssetLibraryError.manifestCorrupt("a version directory does not match its manifest identity")
            }
            result.append(.init(manifest: bundle.manifest))
        }
        return result.sorted { Self.summaryOrder($0, $1) }
    }

    private static func summaryOrder(_ lhs: FurnitureAssetSummary, _ rhs: FurnitureAssetSummary) -> Bool {
        let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        if lhs.assetID != rhs.assetID { return lhs.assetID < rhs.assetID }
        return lhs.version.localizedStandardCompare(rhs.version) == .orderedAscending
    }

    private func readBundle(
        at directory: URL,
        expectedAssetID: String?,
        expectedVersion: String?
    ) throws -> FurnitureAssetBundle {
        let source: FurnitureAssetSourceAccess
        do {
            source = try FurnitureAssetSourceAccess(rootURL: directory)
        } catch {
            throw FurnitureAssetLibraryError.manifestCorrupt("the version root is unavailable")
        }
        defer { source.close() }
        let manifestBytes: Data
        do {
            manifestBytes = try source.readFile(
                "manifest.json",
                limit: limits.maximumManifestBytes,
                maxPathBytes: limits.maximumPathBytes
            )
        } catch {
            throw FurnitureAssetLibraryError.manifestCorrupt("the version manifest is missing or unreadable")
        }
        let bundle = try FurnitureAssetBundle(
            rootURL: directory,
            manifestBytes: manifestBytes,
            manifestSHA256: FurnitureAssetHashing.sha256Hex(manifestBytes),
            limits: limits
        )
        if let expectedAssetID, bundle.manifest.assetID != expectedAssetID {
            throw FurnitureAssetLibraryError.manifestCorrupt("the version does not belong to the requested asset")
        }
        if let expectedVersion, bundle.manifest.version != expectedVersion {
            throw FurnitureAssetLibraryError.manifestCorrupt("the version does not match the requested version")
        }
        return bundle
    }

    private func versionExists(at directory: URL) throws -> Bool {
        let fileManager = FileManager.default
        if FurnitureAssetFileSystem.isSymbolicLink(directory) {
            throw FurnitureAssetLibraryError.manifestCorrupt("a version path is a symbolic link")
        }
        guard fileManager.fileExists(atPath: directory.path) else { return false }
        guard FurnitureAssetFileSystem.isDirectoryNotSymlink(directory) else {
            throw FurnitureAssetLibraryError.manifestCorrupt("a version path is not a real directory")
        }
        return true
    }

    private func writeStagedFile(_ data: Data, relativePath: String, in root: URL) throws {
        let url = root.appendingPathComponent(relativePath)
        guard FurnitureAssetFileSystem.contains(url, in: root) else {
            throw FurnitureAssetLibraryError.io("a staged path escapes its version root")
        }
        try FurnitureAssetFileSystem.ensureParentDirectory(for: url, inside: root)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw FurnitureAssetLibraryError.io("a staged furniture asset file could not be written")
        }
    }

    private func observe(_ phase: FurnitureAssetImportPhase, _ observer: FurnitureAssetPhaseObserver?) throws {
        try Task.checkCancellation()
        try observer?(phase)
    }

    private func acquire(_ lock: FurnitureAssetFileLock) async throws {
        let start = Date()
        while true {
            if try lock.tryAcquire() { return }
            if Date().timeIntervalSince(start) >= limits.lockTimeoutSeconds {
                throw FurnitureAssetLibraryError.lockTimedOut
            }
            try await Task.sleep(nanoseconds: UInt64(limits.lockRetryMilliseconds) * 1_000_000)
            try Task.checkCancellation()
        }
    }

    private func mapMainReadError(_ error: Error, path: String) -> FurnitureAssetLibraryError {
        guard let sourceError = error as? FurnitureAssetSourceAccessError else {
            return .io("the main OBJ could not be read")
        }
        switch sourceError {
        case .missing:
            return .sourceFileMissing(path)
        case .unsafe, .notRegular:
            return .sourceFileUnsafe(path)
        case .unreadable, .io:
            return .io("the main OBJ could not be read")
        case .tooLarge(let limit):
            return .sourceFileTooLarge(path, limit: limit)
        }
    }

    private enum DependencyLoad {
        case data(Data)
        case failure(FurnitureAssetIssueKind, String)
    }

    private func loadDependency(
        path: String,
        source: FurnitureAssetSourceAccess
    ) -> DependencyLoad {
        switch source.probe(path, maxPathBytes: limits.maximumPathBytes) {
        case .missing:
            return .failure(.missingDependency, "A referenced dependency is missing under the selected source root.")
        case .unsafe:
            return .failure(.unsafeReference, "A referenced dependency is a symbolic link or escapes the selected source root.")
        case .notRegular:
            return .failure(.unreadableDependency, "A referenced dependency is not a regular file.")
        case .unreadable:
            return .failure(.unreadableDependency, "A referenced dependency is not readable.")
        case .regularFile(let byteCount):
            guard byteCount > 0 else {
                return .failure(.unreadableDependency, "A referenced dependency is empty.")
            }
            guard byteCount <= limits.maximumDependencyBytes else {
                return .failure(.dependencyTooLarge, "A referenced dependency exceeds the per-file byte limit.")
            }
            do {
                return .data(try source.readFile(
                    path,
                    limit: limits.maximumDependencyBytes,
                    maxPathBytes: limits.maximumPathBytes
                ))
            } catch {
                return .failure(.unreadableDependency, "A referenced dependency could not be read without changing during import.")
            }
        }
    }

    private func readMetadata(
        _ relativePath: String,
        field: String,
        source: FurnitureAssetSourceAccess,
        invalidError: (String) -> FurnitureAssetLibraryError
    ) throws -> (path: String, data: Data) {
        let path: String
        do {
            path = try FurnitureAssetPathName.normalise(relativePath, maxBytes: limits.maximumPathBytes)
        } catch {
            throw invalidError("The \(field) path is not a safe relative path.")
        }
        switch source.probe(path, maxPathBytes: limits.maximumPathBytes) {
        case .regularFile(let byteCount):
            guard byteCount > 0 else {
                throw invalidError("The \(field) file is empty.")
            }
            guard byteCount <= limits.maximumMetadataBytes else {
                throw invalidError("The \(field) file exceeds the metadata byte limit.")
            }
            do {
                return (path, try source.readFile(
                    path,
                    limit: limits.maximumMetadataBytes,
                    maxPathBytes: limits.maximumPathBytes
                ))
            } catch {
                throw invalidError("The \(field) file could not be read.")
            }
        case .missing, .unsafe, .notRegular, .unreadable:
            throw invalidError("The \(field) path is not a readable regular file under the selected source root.")
        }
    }
}
