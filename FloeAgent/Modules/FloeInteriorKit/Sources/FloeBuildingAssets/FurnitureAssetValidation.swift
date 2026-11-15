// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeInteriorCore

enum FurnitureAssetValidation {
    static func validateAssetID(_ value: String) throws {
        try validateText(value, field: "asset id", minimum: 1, maximum: 512)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == value else {
            throw FurnitureAssetLibraryError.invalidValue(field: "asset id", reason: "leading or trailing whitespace is not allowed")
        }
    }

    static func validateVersion(_ value: String) throws {
        try validateText(value, field: "version", minimum: 1, maximum: 128)
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw FurnitureAssetLibraryError.invalidValue(field: "version", reason: "leading or trailing whitespace is not allowed")
        }
        guard !value.hasPrefix(".") else {
            throw FurnitureAssetLibraryError.invalidValue(field: "version", reason: "a leading dot is not allowed")
        }
        guard !value.contains("/"), !value.contains("\\"), !value.contains(":") else {
            throw FurnitureAssetLibraryError.invalidValue(field: "version", reason: "path separators are not allowed")
        }
        guard value != ".", value != ".." else {
            throw FurnitureAssetLibraryError.invalidValue(field: "version", reason: "the version is a path traversal component")
        }
    }

    static func validateName(_ value: String) throws {
        try validateText(value, field: "name", minimum: 1, maximum: 200)
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw FurnitureAssetLibraryError.invalidValue(field: "name", reason: "leading or trailing whitespace is not allowed")
        }
    }

    static func validateCategory(_ value: String?) throws {
        guard let value else { return }
        try validateText(value, field: "category", minimum: 1, maximum: 100)
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw FurnitureAssetLibraryError.invalidValue(field: "category", reason: "leading or trailing whitespace is not allowed")
        }
    }

    static func validateText(
        _ value: String,
        field: String,
        minimum: Int,
        maximum: Int,
        allowNewlines: Bool = false
    ) throws {
        guard value.utf8.count >= minimum, value.utf8.count <= maximum else {
            throw FurnitureAssetLibraryError.invalidValue(field: field, reason: "length must be \(minimum)...\(maximum) bytes")
        }
        guard !value.unicodeScalars.contains(where: { scalar in
            if scalar.value == 0x7F { return true }
            if scalar.value < 0x20 { return !allowNewlines || (scalar.value != 0x09 && scalar.value != 0x0A && scalar.value != 0x0D) }
            return false
        }) else {
            throw FurnitureAssetLibraryError.invalidValue(field: field, reason: "control characters are not allowed")
        }
    }

    static func validateProvenance(_ provenance: FurnitureAssetProvenance) throws {
        try validateText(provenance.source, field: "provenance source", minimum: 1, maximum: 1_000)
        if let reference = provenance.sourceReference {
            try validateText(reference, field: "provenance reference", minimum: 0, maximum: 2_000)
        }
        try validateText(provenance.license.identifier, field: "license identifier", minimum: 1, maximum: 200)
        try validateText(provenance.license.basis, field: "license basis", minimum: 1, maximum: 2_000)
        if let attribution = provenance.attribution {
            if let author = attribution.author {
                try validateText(author, field: "attribution author", minimum: 0, maximum: 300)
            }
            if let title = attribution.title {
                try validateText(title, field: "attribution title", minimum: 0, maximum: 300)
            }
            if let sourceURL = attribution.sourceURL {
                try validateText(sourceURL, field: "attribution URL", minimum: 0, maximum: 2_000)
            }
            if let notice = attribution.notice {
                try validateText(notice, field: "attribution notice", minimum: 0, maximum: 2_000)
            }
        }
    }

    static func validateDeclaredDimensions(_ dimensions: FurnitureDeclaredDimensions) throws {
        guard [dimensions.width, dimensions.depth, dimensions.height].allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 1e9 }) else {
            throw FurnitureAssetLibraryError.invalidValue(field: "declared dimensions", reason: "all dimensions must be finite and positive")
        }
        let millimetres = dimensions.millimetres
        guard [millimetres.widthMM, millimetres.depthMM, millimetres.heightMM].allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 1e9 }) else {
            throw FurnitureAssetLibraryError.invalidValue(field: "declared dimensions", reason: "converted dimensions exceed the supported range")
        }
    }

    static func validateSourceBounds(_ bounds: FurnitureSourceBounds) throws {
        let values = bounds.minimum.values + bounds.maximum.values
        guard values.allSatisfy({ $0.isFinite && abs($0) <= 1e9 }) else {
            throw FurnitureAssetLibraryError.invalidValue(field: "source bounds", reason: "coordinates must be finite and within the supported range")
        }
        let extent = bounds.extent
        guard extent.values.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw FurnitureAssetLibraryError.invalidValue(field: "source bounds", reason: "all three extents must be positive")
        }
    }

    static func validateSourceOrientation(_ orientation: FurnitureSourceOrientation) throws {
        switch orientation {
        case .cadYUp:
            return
        case .rotation3x3(let matrix):
            guard matrix.count == 9, matrix.allSatisfy(\.isFinite) else {
                throw FurnitureAssetLibraryError.invalidValue(field: "source orientation", reason: "the rotation must contain nine finite values")
            }
        }
    }

    /// Reuses the actual Core planner for the orthonormal/rotation and bounds
    /// checks. It is not a native geometry import or a rendering claim.
    static func validatePlacementGeometry(
        assetID: String,
        version: String,
        sourceSHA256: String,
        bounds: FurnitureSourceBounds,
        orientation: FurnitureSourceOrientation
    ) throws {
        let input = FurniturePlacementInput(
            instanceID: UUID(),
            roomID: nil,
            assetID: assetID,
            assetVersion: version,
            sourceSHA256: sourceSHA256,
            dependencySHA256: [:],
            sourceBounds: bounds,
            orientation: orientation,
            sizing: .sourceUnits(millimetresPerUnit: 1),
            pose: .init(
                planXMM: 0,
                planYMM: 0,
                floorElevationMM: 0,
                elevationAboveFloorMM: 0,
                yawDegrees: 0,
                anchor: .bottomCenter
            )
        )
        do {
            _ = try FurniturePlacementPlanner.make(input)
        } catch {
            throw FurnitureAssetLibraryError.invalidValue(
                field: "source geometry",
                reason: "the bounds or orientation are not a valid placement basis"
            )
        }
    }

    static func validateFile(
        _ file: FurnitureAssetFile,
        expectedRole: FurnitureAssetFileRole,
        limits: FurnitureAssetLibraryLimits
    ) throws {
        guard file.role == expectedRole else {
            throw FurnitureAssetLibraryError.invalidValue(field: "file role", reason: "a file has the wrong role for its position")
        }
        guard file.byteCount > 0, file.byteCount <= limits.maximumTotalBytes else {
            throw FurnitureAssetLibraryError.invalidValue(field: "file size", reason: "the byte count is outside the library budget")
        }
        guard FurnitureAssetHashing.isSHA256Hex(file.sha256) else {
            throw FurnitureAssetLibraryError.invalidValue(field: "file hash", reason: "the SHA-256 must be 64 lowercase hexadecimal characters")
        }
        let source = try FurnitureAssetPathName.normalise(file.sourceRelativePath, maxBytes: limits.maximumPathBytes)
        let stored = try FurnitureAssetPathName.normalise(file.relativePath, maxBytes: limits.maximumPathBytes)
        switch expectedRole {
        case .mainModel, .materialLibrary, .texture, .other:
            let expectedStored = try FurnitureAssetPathName.storedResourcePath(sourceRelativePath: source, maxBytes: limits.maximumPathBytes)
            guard stored == expectedStored else {
                throw FurnitureAssetLibraryError.invalidValue(field: "stored path", reason: "a resource path does not preserve its source layout")
            }
        case .license:
            guard stored.hasPrefix("metadata/license/") else {
                throw FurnitureAssetLibraryError.invalidValue(field: "stored path", reason: "license evidence must be stored under metadata/license")
            }
            let storedName = try FurnitureAssetPathName.basename(stored, maxBytes: limits.maximumPathBytes)
            let sourceName = try FurnitureAssetPathName.basename(source, maxBytes: limits.maximumPathBytes)
            guard storedName == sourceName else {
                throw FurnitureAssetLibraryError.invalidValue(field: "stored path", reason: "the license file name changed")
            }
        case .thumbnail:
            guard stored.hasPrefix("metadata/thumbnail/") else {
                throw FurnitureAssetLibraryError.invalidValue(field: "stored path", reason: "a thumbnail must be stored under metadata/thumbnail")
            }
            let storedName = try FurnitureAssetPathName.basename(stored, maxBytes: limits.maximumPathBytes)
            let sourceName = try FurnitureAssetPathName.basename(source, maxBytes: limits.maximumPathBytes)
            guard storedName == sourceName else {
                throw FurnitureAssetLibraryError.invalidValue(field: "stored path", reason: "the thumbnail file name changed")
            }
        }
        let perFileLimit: Int
        switch expectedRole {
        case .mainModel: perFileLimit = limits.maximumMainFileBytes
        case .materialLibrary, .texture, .other: perFileLimit = limits.maximumDependencyBytes
        case .license, .thumbnail: perFileLimit = limits.maximumMetadataBytes
        }
        guard file.byteCount <= perFileLimit else {
            throw FurnitureAssetLibraryError.invalidValue(field: "file size", reason: "a file exceeds its role-specific limit")
        }
    }

    static func validateIssue(_ issue: FurnitureAssetIssue, limits: FurnitureAssetLibraryLimits) throws {
        try validateText(issue.detail, field: "issue detail", minimum: 1, maximum: 2_000, allowNewlines: false)
        if let path = issue.sourceRelativePath {
            try validateText(path, field: "issue path", minimum: 0, maximum: limits.maximumPathBytes)
            guard !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
                throw FurnitureAssetLibraryError.invalidValue(field: "issue path", reason: "control characters are not allowed")
            }
        }
    }

    static func validateManifest(_ manifest: FurnitureAssetManifest, limits: FurnitureAssetLibraryLimits) throws {
        guard manifest.schemaVersion == 1 else {
            throw FurnitureAssetLibraryError.invalidValue(field: "schema version", reason: "only manifest schema 1 is supported")
        }
        try validateAssetID(manifest.assetID)
        try validateVersion(manifest.version)
        try validateName(manifest.name)
        try validateCategory(manifest.category)
        guard manifest.format == .obj else {
            throw FurnitureAssetLibraryError.invalidValue(field: "format", reason: "only OBJ assets are admitted by this implementation")
        }
        try validateProvenance(manifest.provenance)
        try validateSourceBounds(manifest.sourceBounds)
        try validateSourceOrientation(manifest.sourceOrientation)
        if let dimensions = manifest.declaredDimensions {
            try validateDeclaredDimensions(dimensions)
        }
        try validateFile(manifest.mainFile, expectedRole: .mainModel, limits: limits)
        guard manifest.mainFile.role == .mainModel else {
            throw FurnitureAssetLibraryError.invalidValue(field: "main file", reason: "the main file must use the main model role")
        }
        try validatePlacementGeometry(
            assetID: manifest.assetID,
            version: manifest.version,
            sourceSHA256: manifest.mainFile.sha256,
            bounds: manifest.sourceBounds,
            orientation: manifest.sourceOrientation
        )
        guard manifest.dependencies.count <= max(0, limits.maximumFiles - 1) else {
            throw FurnitureAssetLibraryError.invalidValue(field: "dependencies", reason: "the dependency count exceeds the file budget")
        }

        var storedPaths = Set<String>()
        storedPaths.insert(manifest.mainFile.relativePath)
        for dependency in manifest.dependencies {
            guard dependency.role != .mainModel, dependency.role != .license, dependency.role != .thumbnail else {
                throw FurnitureAssetLibraryError.invalidValue(field: "dependency role", reason: "a dependency uses a non-dependency role")
            }
            try validateFile(dependency, expectedRole: dependency.role, limits: limits)
            guard storedPaths.insert(dependency.relativePath).inserted else {
                throw FurnitureAssetLibraryError.invalidValue(field: "stored path", reason: "two files share one stored path")
            }
        }
        if let thumbnail = manifest.thumbnail {
            try validateFile(thumbnail, expectedRole: .thumbnail, limits: limits)
            guard storedPaths.insert(thumbnail.relativePath).inserted else {
                throw FurnitureAssetLibraryError.invalidValue(field: "stored path", reason: "the thumbnail shares a stored path")
            }
        }
        if let licenseFile = manifest.licenseFile {
            try validateFile(licenseFile, expectedRole: .license, limits: limits)
            guard storedPaths.insert(licenseFile.relativePath).inserted else {
                throw FurnitureAssetLibraryError.invalidValue(field: "stored path", reason: "the license file shares a stored path")
            }
        }
        if manifest.provenance.license.evidence == .licenseFile, manifest.licenseFile == nil {
            throw FurnitureAssetLibraryError.invalidValue(field: "license evidence", reason: "license-file evidence was declared without a license file")
        }
        let totalFileCount = 1 + manifest.dependencies.count
            + (manifest.thumbnail == nil ? 0 : 1)
            + (manifest.licenseFile == nil ? 0 : 1)
        guard totalFileCount <= limits.maximumFiles else {
            throw FurnitureAssetLibraryError.invalidValue(field: "file count", reason: "the manifest exceeds the library file budget")
        }
        var allDeclaredFiles = [manifest.mainFile]
        allDeclaredFiles.append(contentsOf: manifest.dependencies)
        if let thumbnail = manifest.thumbnail { allDeclaredFiles.append(thumbnail) }
        if let licenseFile = manifest.licenseFile { allDeclaredFiles.append(licenseFile) }
        let totalByteCount = allDeclaredFiles.reduce(0) { $0 + $1.byteCount }
        guard totalByteCount <= limits.maximumTotalBytes else {
            throw FurnitureAssetLibraryError.invalidValue(field: "byte count", reason: "the manifest exceeds the library byte budget")
        }
        guard manifest.issues.count <= 4_096 else {
            throw FurnitureAssetLibraryError.invalidValue(field: "issues", reason: "the issue count exceeds the supported range")
        }
        for issue in manifest.issues {
            try validateIssue(issue, limits: limits)
        }
        if manifest.admission == .ready {
            guard manifest.issues.isEmpty else {
                throw FurnitureAssetLibraryError.invalidValue(field: "admission", reason: "a ready asset cannot carry issues")
            }
        }
    }
}

extension FurnitureAssetManifest {
    public func validate(limits: FurnitureAssetLibraryLimits = .standard) throws {
        try FurnitureAssetValidation.validateManifest(self, limits: limits)
    }
}
