// SPDX-License-Identifier: MPL-2.0
#if os(iOS)
import Foundation
import FloeCAD
import FloeInteriorCore

public extension FloeBuildingCADSession {
    /// Import a pinned furniture asset through the real public mesh importer
    /// (`CADMeshImportService.parseOffMain` + `apply`), then place the imported
    /// bodies as assembly instances using the Core placement plan.
    ///
    /// The Core plan still expresses its exact declared semantics. The native
    /// assembly accepts one uniform scale, so a catalog fit is accepted only
    /// when the actual native dimensions are within `maximumSizingErrorMM` of
    /// the plan. The binding records that approximation and the real measured
    /// bounds; it is never labelled a strict three-axis fit.
    func importFurniture(assetURL: URL,
                         resources: FloeBuildingCADFurnitureResources? = nil,
                         input: FurniturePlacementInput,
                         plan: FurniturePlacementPlan? = nil,
                         maximumSizingErrorMM: Double = 0.1) async throws
        -> FloeBuildingCADFurnitureBinding {
        guard !document.isClosed else { throw FloeBuildingCADError.documentClosed }
        guard !document.isReadOnly else { throw FloeBuildingCADError.readOnly }
        guard maximumSizingErrorMM.isFinite, maximumSizingErrorMM >= 0 else {
            throw FloeBuildingCADError.invalidInput("maximumSizingErrorMM must be finite and nonnegative.")
        }
        let resolvedPlan: FurniturePlacementPlan
        if let plan {
            resolvedPlan = plan
        } else {
            resolvedPlan = try FurniturePlacementPlanner.make(input)
        }
        try resolvedPlan.validateDerivedSnapshot(for: input)
        guard manifest.furniture(instanceID: input.instanceID) == nil else {
            throw FloeBuildingCADError.duplicateBinding("furniture instance \(input.instanceID.uuidString)")
        }
        let files = try await FloeBuildingCADFurnitureFiles.read(
            primary: assetURL, resources: resources, pinned: input.dependencySHA256)
        guard files.primaryHash == input.sourceSHA256.lowercased() else {
            throw FloeBuildingCADError.assetHashMismatch(assetURL.lastPathComponent)
        }
        let importScale: Double
        switch input.sizing {
        case let .sourceUnits(millimetresPerUnit):
            importScale = millimetresPerUnit
        case .catalogDimensions:
            // Parse in the source's own numeric units; the catalog fit is the
            // explicit sizing basis. This is not a claimed source unit.
            importScale = 1
        }
        guard let uniform = FloeBuildingCADGeometry.uniformPlacement(
            fromColumnMajor: resolvedPlan.nativeMatrixColumnMajor,
            importUnitScale: importScale,
            maximumRelativeSpread: 0.005) else {
            throw FloeBuildingCADError.unsupportedFurnitureFit(
                "The plan's per-axis scale cannot be represented by the native uniform instance placement.")
        }
        guard uniform.scale.isFinite, uniform.scale > 0 else {
            throw FloeBuildingCADError.unsupportedFurnitureFit("The native placement scale is not positive.")
        }
        let cancellation = MeshImportCancellation()
        let importPlan: CADMeshImportPlan
        do {
            importPlan = try await CADMeshImportService.parseOffMain(
                data: files.primary,
                fileName: files.parserFileName,
                siblings: files.siblings,
                unitScale: importScale,
                requireExplicitUnits: true,
                limits: .standard,
                cancellation: cancellation)
        } catch is CancellationError {
            throw FloeBuildingCADError.cancelled
        } catch let error as CADDocumentError where error.code == "cancelled" {
            throw FloeBuildingCADError.cancelled
        } catch {
            throw FloeBuildingCADError.invalidInput(
                "The furniture asset could not be imported: \(error.localizedDescription)")
        }

        return try await withMutationRollback { lease in
            let applied: CADCommandOutcome
            do {
                applied = try withOwnedWrite(lease) {
                    try CADMeshImportService.apply(importPlan, to: document, cancellation: cancellation)
                }
            } catch {
                throw FloeBuildingCADError.invalidNativeState(
                    "The furniture mesh apply failed: \(error.localizedDescription)")
            }
            guard applied.isOK,
                  let payload = FloeBuildingCADGeometry.object(applied),
                  let imported = payload["imported"] as? [[String: Any]] else {
                throw FloeBuildingCADError.invalidNativeState(
                    applied.message ?? "The native mesh import did not produce bodies.")
            }
            let bodyIDs = imported.compactMap { FloeBuildingCADGeometry.uuid($0["bodyID"]) }
            let names = imported.map { FloeBuildingCADGeometry.string($0["name"]) ?? "Furniture part" }
            guard !bodyIDs.isEmpty, bodyIDs.count == imported.count else {
                throw FloeBuildingCADError.invalidNativeState("The native mesh import returned incomplete body ids.")
            }
            try testMutationCheckpoint("furniture.afterApply")

            var bodyBounds: [FloeBuildingCADBounds] = []
            var sourceCorners: [[Double]] = []
            for bodyID in bodyIDs {
                let measured = try measureNativeBody(bodyID)
                guard measured.analyticBRep == false else {
                    throw FloeBuildingCADError.invalidNativeState(
                        "The imported furniture body unexpectedly claims an analytic B-rep.")
                }
                bodyBounds.append(FloeBuildingCADBounds(
                    minimum: measured.boundsMinimum, maximum: measured.boundsMaximum))
                sourceCorners.append(contentsOf: FloeBuildingCADGeometry.corners(
                    minimum: measured.boundsMinimum, maximum: measured.boundsMaximum))
            }
            guard let importedBounds = FloeBuildingCADGeometry.bounds(of: sourceCorners) else {
                throw FloeBuildingCADError.invalidNativeState("The imported furniture has no finite bounds.")
            }
            // The importer keeps the model in SOURCE axes. The placement
            // matrix applies the declared source orientation afterwards, so
            // the body-local bounds are compared directly with the pinned
            // source bounds at the import unit scale. Never swap Y/Z here:
            // `cadYUp` already means the source's +Y is up.
            let scaledMin = input.sourceBounds.minimum.values.map { $0 * importScale }
            let scaledMax = input.sourceBounds.maximum.values.map { $0 * importScale }
            let lower = [min(scaledMin[0], scaledMax[0]), min(scaledMin[1], scaledMax[1]),
                         min(scaledMin[2], scaledMax[2])]
            let upper = [max(scaledMin[0], scaledMax[0]), max(scaledMin[1], scaledMax[1]),
                         max(scaledMin[2], scaledMax[2])]
            guard FloeBuildingCADGeometry.approxEqual(importedBounds.minimum, lower, tolerance: 0.05),
                  FloeBuildingCADGeometry.approxEqual(importedBounds.maximum, upper, tolerance: 0.05) else {
                throw FloeBuildingCADError.invalidNativeState(
                    "The imported body bounds \(importedBounds.minimum)…\(importedBounds.maximum) "
                    + "do not match the pinned source bounds \(lower)…\(upper).")
            }

            let assembly = CADAssemblyService(document: document)
            var instanceIDs: [UUID] = []
            for (index, bodyID) in bodyIDs.enumerated() {
                let name = names[index]
                let transform: [String: Any] = [
                    "position": uniform.translation,
                    "rotation": uniform.rotation,
                    "scale": [uniform.scale, uniform.scale, uniform.scale],
                ]
                let placed = withOwnedWrite(lease) {
                    assembly.handle(action: "addInstance", args: [
                        "bodyID": bodyID.uuidString,
                        "name": "\(input.assetID) · \(name)",
                        "transform": transform,
                    ])
                }
                guard placed["ok"] as? Bool == true,
                      let instanceID = FloeBuildingCADGeometry.uuid(placed["id"]) else {
                    throw FloeBuildingCADError.invalidNativeState(
                        placed["message"] as? String ?? "The furniture instance could not be placed.")
                }
                instanceIDs.append(instanceID)
            }
            try testMutationCheckpoint("furniture.afterInstances")

            let state = try nativeState()
            for id in instanceIDs {
                guard let row = state.instances[id] else {
                    throw FloeBuildingCADError.invalidNativeState("The furniture instance \(id.uuidString) disappeared.")
                }
                guard FloeBuildingCADGeometry.approxEqual(row.position, uniform.translation, tolerance: 1e-6),
                      FloeBuildingCADGeometry.quaternionDot(row.rotation, uniform.rotation) > 1 - 1e-7,
                      FloeBuildingCADGeometry.approxEqual(row.scale,
                        [uniform.scale, uniform.scale, uniform.scale], tolerance: 1e-9) else {
                    throw FloeBuildingCADError.invalidNativeState(
                        "The placed furniture instance transform does not match the requested placement.")
                }
            }
            let placedCorners = sourceCorners.map { point -> [Double] in
                let rotated = FloeBuildingCADGeometry.rotate(
                    uniform.rotation, SIMD3(point[0], point[1], point[2]))
                return [rotated.x * uniform.scale + uniform.translation[0],
                        rotated.y * uniform.scale + uniform.translation[1],
                        rotated.z * uniform.scale + uniform.translation[2]]
            }
            guard let placedBounds = FloeBuildingCADGeometry.bounds(of: placedCorners) else {
                throw FloeBuildingCADError.invalidNativeState("The placed furniture has no finite bounds.")
            }
            let planBounds = resolvedPlan.envelopeInNativeMM
            let envelopeError = max(
                FloeBuildingCADGeometry.maxDifference(placedBounds.minimum, planBounds.minimum.values),
                FloeBuildingCADGeometry.maxDifference(placedBounds.maximum, planBounds.maximum.values))
            guard envelopeError <= max(0.05, maximumSizingErrorMM) else {
                throw FloeBuildingCADError.unsupportedFurnitureFit(
                    "The native placed envelope differs from the plan by \(envelopeError) mm "
                    + "(maximum \(maximumSizingErrorMM) mm).")
            }

            var orientedCorners: [[Double]] = []
            for point in sourceCorners {
                // Sizing is expressed in the SOURCE orientation frame; yaw
                // rotates the placed instance but must not change the
                // catalog dimensions. Only the declared source orientation is
                // applied here.
                orientedCorners.append(
                    FloeBuildingCADGeometry.orientedPoint(input.orientation, point))
            }
            guard let orientedBounds = FloeBuildingCADGeometry.bounds(of: orientedCorners) else {
                throw FloeBuildingCADError.invalidNativeState("The oriented furniture bounds are invalid.")
            }
            let actualDimensions = FurnitureDimensions(
                widthMM: (orientedBounds.maximum[0] - orientedBounds.minimum[0]) * uniform.scale,
                depthMM: (orientedBounds.maximum[2] - orientedBounds.minimum[2]) * uniform.scale,
                heightMM: (orientedBounds.maximum[1] - orientedBounds.minimum[1]) * uniform.scale)
            let sizingError = max(
                abs(actualDimensions.widthMM - resolvedPlan.dimensionsMM.widthMM),
                abs(actualDimensions.depthMM - resolvedPlan.dimensionsMM.depthMM),
                abs(actualDimensions.heightMM - resolvedPlan.dimensionsMM.heightMM))
            guard sizingError <= maximumSizingErrorMM else {
                throw FloeBuildingCADError.unsupportedFurnitureFit(
                    "The uniform native placement gives \(actualDimensions.widthMM) × \(actualDimensions.depthMM) × "
                    + "\(actualDimensions.heightMM) mm versus the plan; the error \(sizingError) mm exceeds "
                    + "\(maximumSizingErrorMM) mm. A strict per-axis fit needs an additive affine mesh hook.")
            }
            let planScales = resolvedPlan.scaleAlongOrientedAxes
            let scaleSpread = max(planScales.x, max(planScales.y, planScales.z))
                - min(planScales.x, min(planScales.y, planScales.z))
            let uniformApproximation = scaleSpread > 1e-9
                || uniform.nonUniformRelativeResidual > 1e-9

            try testMutationCheckpoint("furniture.beforeSave")
            try lease.verifyOwnership()
            let identity = try await saveUnlocked()
            try lease.verifyOwnership()
            let binding = FloeBuildingCADFurnitureBinding(
                instanceID: input.instanceID,
                assemblyInstanceIDs: instanceIDs, bodyIDs: bodyIDs,
                assetID: input.assetID, assetVersion: input.assetVersion,
                sourceSHA256: input.sourceSHA256,
                dependencySHA256: input.dependencySHA256,
                placementInput: input, placementPlan: resolvedPlan,
                importUnitScale: importScale,
                appliedUniformScale: uniform.scale,
                instanceTransform: FloeBuildingCADTransformBinding(
                    position: uniform.translation, rotation: uniform.rotation,
                    scale: [uniform.scale, uniform.scale, uniform.scale]),
                importedBodyBounds: bodyBounds,
                nativeEnvelopeMinimum: placedBounds.minimum,
                nativeEnvelopeMaximum: placedBounds.maximum,
                planResidualMM: max(envelopeError, sizingError),
                actualDimensionsMM: actualDimensions,
                sizingErrorMM: sizingError,
                maximumSizingErrorMM: maximumSizingErrorMM,
                uniformApproximationUsed: uniformApproximation,
                nativeImportVerified: true,
                physicalVerified: false, manufacturingVerified: false,
                nativeIdentity: identity)
            putFurniture(binding)
            return binding
        }
    }
}

public extension FloeBuildingCADSession {
    /// Re-read the live native bodies/instances and compare the actual placed
    /// envelope/transform with a stored furniture binding. Physical fit and
    /// manufacturing stay explicitly unverified.
    func validateFurnitureBinding(_ binding: FloeBuildingCADFurnitureBinding) throws {
        guard !document.isClosed else { throw FloeBuildingCADError.documentClosed }
        let state = try nativeState()
        guard Set(binding.assemblyInstanceIDs).count == binding.assemblyInstanceIDs.count,
              Set(binding.bodyIDs).count == binding.bodyIDs.count else {
            throw FloeBuildingCADError.invalidBinding("Duplicate furniture body/instance ids.")
        }
        let bodySet = Set(binding.bodyIDs)
        let instanceSet = Set(binding.assemblyInstanceIDs)
        guard binding.instanceTransform.rotation.count == 4,
              binding.instanceTransform.position.count == 3,
              binding.instanceTransform.scale.count == 3 else {
            throw FloeBuildingCADError.invalidBinding("The furniture instance transform is incomplete.")
        }
        for instanceID in binding.assemblyInstanceIDs {
            guard let row = state.instances[instanceID],
                  bodySet.contains(row.bodyID),
                  row.effectiveBodyID.map(bodySet.contains) == true,
                  !row.hidden, !row.isSubassembly else {
                throw FloeBuildingCADError.externalModification(
                    "Furniture instance \(instanceID.uuidString) is missing, hidden or replaced.")
            }
            guard FloeBuildingCADGeometry.approxEqual(row.position, binding.instanceTransform.position,
                                                      tolerance: 1e-6),
                  FloeBuildingCADGeometry.quaternionDot(row.rotation, binding.instanceTransform.rotation) > 1 - 1e-7,
                  FloeBuildingCADGeometry.approxEqual(row.scale, binding.instanceTransform.scale,
                                                      tolerance: 1e-9) else {
                throw FloeBuildingCADError.externalModification(
                    "Furniture instance \(instanceID.uuidString) was moved after the binding was written.")
            }
        }
        for row in state.instances.values {
            let usesFurnitureBody = bodySet.contains(row.bodyID)
                || row.effectiveBodyID.map(bodySet.contains) == true
            if usesFurnitureBody, !instanceSet.contains(row.id) {
                throw FloeBuildingCADError.externalModification(
                    "An extra assembly instance \(row.id.uuidString) references the furniture bodies.")
            }
        }
        var corners: [[Double]] = []
        for bodyID in binding.bodyIDs {
            let measured = try measureNativeBody(bodyID)
            corners.append(contentsOf: FloeBuildingCADGeometry.corners(
                minimum: measured.boundsMinimum, maximum: measured.boundsMaximum))
        }
        let placed = corners.map { point -> [Double] in
            let rotated = FloeBuildingCADGeometry.rotate(Array(binding.instanceTransform.rotation.prefix(4)),
                                                         SIMD3(point[0], point[1], point[2]))
            let scale = binding.instanceTransform.scale
            return [rotated.x * scale[0] + binding.instanceTransform.position[0],
                    rotated.y * scale[1] + binding.instanceTransform.position[1],
                    rotated.z * scale[2] + binding.instanceTransform.position[2]]
        }
        guard let bounds = FloeBuildingCADGeometry.bounds(of: placed) else {
            throw FloeBuildingCADError.invalidNativeState("The furniture binding has no finite native bounds.")
        }
        guard FloeBuildingCADGeometry.approxEqual(bounds.minimum, binding.nativeEnvelopeMinimum,
                                                  tolerance: max(0.05, binding.maximumSizingErrorMM)),
              FloeBuildingCADGeometry.approxEqual(bounds.maximum, binding.nativeEnvelopeMaximum,
                                                  tolerance: max(0.05, binding.maximumSizingErrorMM)) else {
            throw FloeBuildingCADError.externalModification(
                "The live furniture geometry no longer matches its bound native envelope.")
        }
    }
}

// MARK: - Off-main asset reads

private enum FloeBuildingCADFurnitureFiles {
    struct Contents: Sendable {
        var primary: Data
        var primaryHash: String
        /// Keys are normalized source-root-relative paths. The mesh parser
        /// rebases them against the primary's parent, matching MTL relative
        /// references; no basename fallback exists.
        var siblings: [String: Data]
        /// Root-relative primary path (or its last path component when no
        /// resource root was supplied).
        var parserFileName: String
    }

    private struct Resource {
        var relativePath: String
        var url: URL
    }

    static func read(primary: URL,
                     resources: FloeBuildingCADFurnitureResources?,
                     pinned: [String: String]) async throws -> Contents {
        try await Task.detached(priority: .userInitiated) {
            let root = resources?.rootURL.standardizedFileURL
            let primaryResolved = primary.resolvingSymlinksInPath().standardizedFileURL
            var normalized: [String: Resource] = [:]
            var primaryRelative = primaryResolved.lastPathComponent
            if let root, let resources {
                let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
                guard let rootPrefix = pathPrefix(resolvedRoot) else {
                    throw FloeBuildingCADError.invalidInput("The furniture resource root has no usable filesystem path.")
                }
                guard primaryResolved.path.hasPrefix(rootPrefix) else {
                    throw FloeBuildingCADError.invalidInput(
                        "The furniture primary file is outside the declared resource root.")
                }
                try rejectSymlink(primary.standardizedFileURL, description: "primary furniture asset")
                primaryRelative = String(primaryResolved.path.dropFirst(rootPrefix.count))
                for (rawKey, url) in resources.dependencyFiles {
                    let relative = try normalizeRelativePath(rawKey)
                    let key = relative.lowercased()
                    guard normalized[key] == nil else {
                        throw FloeBuildingCADError.invalidInput(
                            "Duplicate furniture resource relative path \(rawKey).")
                    }
                    let resolved = url.resolvingSymlinksInPath().standardizedFileURL
                    guard resolved.path.hasPrefix(rootPrefix) else {
                        throw FloeBuildingCADError.invalidInput(
                            "The furniture dependency \(rawKey) escapes the declared resource root.")
                    }
                    try rejectSymlink(url.standardizedFileURL, description: rawKey)
                    normalized[key] = Resource(relativePath: relative, url: resolved)
                }
                for (name, expected) in pinned {
                    let relative = try normalizeRelativePath(name)
                    guard let resource = normalized[relative.lowercased()] else {
                        throw FloeBuildingCADError.missingAssetDependency(name)
                    }
                    let data = try readFile(resource.url, limit: 32 * 1024 * 1024)
                    guard FloeBuildingCADGeometry.sha256(data) == expected.lowercased() else {
                        throw FloeBuildingCADError.assetHashMismatch(name)
                    }
                }
            } else if !pinned.isEmpty {
                throw FloeBuildingCADError.missingAssetDependency(
                    pinned.keys.sorted().first ?? "dependency")
            }
            let primaryData = try readFile(primaryResolved, limit: 64 * 1024 * 1024)
            var siblings: [String: Data] = [:]
            if let resources, !resources.dependencyFiles.isEmpty {
                for resource in normalized.values {
                    siblings[resource.relativePath.lowercased()] =
                        try readFile(resource.url, limit: 32 * 1024 * 1024)
                }
            }
            return Contents(primary: primaryData,
                            primaryHash: FloeBuildingCADGeometry.sha256(primaryData),
                            siblings: siblings,
                            parserFileName: primaryRelative)
        }.value
    }

    private static func pathPrefix(_ url: URL) -> String? {
        guard !url.path.isEmpty else { return nil }
        return url.path.hasSuffix("/") ? url.path : url.path + "/"
    }

    private static func readFile(_ url: URL, limit: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else {
            throw FloeBuildingCADError.invalidInput(
                "The asset file is not a regular file: \(url.lastPathComponent)")
        }
        guard let size = values.fileSize, size <= limit else {
            throw FloeBuildingCADError.invalidInput(
                "The asset file \(url.lastPathComponent) exceeds the bounded read size.")
        }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    private static func rejectSymlink(_ url: URL, description: String) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        if values.isSymbolicLink == true {
            throw FloeBuildingCADError.invalidInput(
                "The furniture resource \(description) is a symbolic link; pinned offline files must be regular files.")
        }
    }

    /// Normalizes a source-relative path and refuses absolute paths, drive
    /// prefixes, NUL and root escapes. The returned path preserves case for
    /// lookup; hashing/matching uses the lowercased form.
    static func normalizeRelativePath(_ raw: String) throws -> String {
        let decoded = raw.removingPercentEncoding ?? raw
        let replaced = decoded.replacingOccurrences(of: "\\", with: "/")
        guard !replaced.isEmpty,
              !replaced.hasPrefix("/"),
              !replaced.contains(":"),
              !replaced.contains("\0") else {
            throw FloeBuildingCADError.invalidInput(
                "The furniture resource path \(raw) is not a safe source-relative path.")
        }
        var parts: [String] = []
        for part in replaced.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                guard !parts.isEmpty else {
                    throw FloeBuildingCADError.invalidInput(
                        "The furniture resource path \(raw) escapes its source root.")
                }
                parts.removeLast()
            } else {
                parts.append(String(part))
            }
        }
        guard !parts.isEmpty else {
            throw FloeBuildingCADError.invalidInput(
                "The furniture resource path \(raw) resolves to the source root.")
        }
        return parts.joined(separator: "/")
    }
}
#endif
