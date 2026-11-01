// SPDX-License-Identifier: MPL-2.0
//
// C03 image closure — shared semantics for real layer merge/copy/fill/cut.
//
// The Android UI and the model-facing `media.project` tool both use the SAME
// validated command engine (`MediaEditCommands.swift`) and the SAME renderer
// enrichment contract (`MediaCommandEnrichmentHost`). This file adds the
// operation planner and a strict raster verifier so a merge/copy result can
// never be a caller-fabricated path, a screen capture or a stale asset.
//
// It deliberately owns no second project store, edit engine, renderer or
// undo stack. Fill is a real `.fill` layer masked by the vector selection (not
// a guessed bucket fill); cut is one non-destructive region mask stroke;
// copy/merge are renderer-produced full-canvas transparent PNG assets that
// commit through `addAsset` + the existing command path.

import Foundation
import FloeCore
import FloeAndroidWorkbench
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum C03LayerOperation: Sendable, Equatable {
    /// A solid colour layer masked by the current complete selection.
    case fillSelection(colorHex: String, opacity: Double, name: String?)
    /// One region mask stroke erasing the current selection from the layer.
    case cutSelection(layerID: UUID)
    /// Renderer-produced selection ∩ source layer as a new full-canvas layer.
    case copySelection(sourceLayerID: UUID, name: String?)
    /// Renderer-produced composite of two or more contiguous layers.
    case mergeLayers(ids: [UUID], name: String?)
}

public struct C03PlannedLayerOperation: Sendable {
    /// Commands ready for the existing atomic transaction/CAS path.
    public var commands: [MediaEditCommand]
    /// Renderer-staged assets referenced by those commands; the caller deletes
    /// ONLY these when its proposal/commit is rejected before adoption.
    public var stagedAssets: [MediaAssetReference]

    public init(commands: [MediaEditCommand], stagedAssets: [MediaAssetReference] = []) {
        self.commands = commands
        self.stagedAssets = stagedAssets
    }
}

public enum C03LayerOperationError: Error, Sendable, Equatable {
    case invalidSelection(String)
    case invalidOperation(String)
    case rasterRejected(String)

    public var message: String {
        switch self {
        case .invalidSelection(let detail):
            return "a valid layer selection is required: \(detail)"
        case .invalidOperation(let detail):
            return "the layer operation is invalid: \(detail)"
        case .rasterRejected(let detail):
            return "the rendered layer asset was rejected: \(detail)"
        }
    }

    public var floError: FloeError {
        .validationFailed(message)
    }
}

/// Plans the four iOS-equivalent image operations against a validated draft.
public enum C03LayerOperationPlanner {
    public static func plan(
        _ operation: C03LayerOperation,
        project: MediaProject,
        host: MediaCommandEnrichmentHost
    ) async throws -> C03PlannedLayerOperation {
        switch operation {
        case .fillSelection(let colorHex, let opacity, let name):
            guard !colorHex.isEmpty,
                  colorHex.range(of: #"^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$"#,
                                 options: .regularExpression) != nil else {
                throw C03LayerOperationError.invalidOperation("fill colour must be #RRGGBB or #RRGGBBAA")
            }
            guard opacity.isFinite, (0...1).contains(opacity) else {
                throw C03LayerOperationError.invalidOperation("fill opacity must be 0...1")
            }
            if let name, name.isEmpty {
                throw C03LayerOperationError.invalidOperation("layer name must not be empty")
            }
            let command = MediaEditCommand.fillSelection(
                colorHex: colorHex, opacity: opacity, name: name)
            try validate(command, in: project)
            return C03PlannedLayerOperation(commands: [command])

        case .cutSelection(let layerID):
            let command = MediaEditCommand.cutSelection(layerID: layerID)
            try validate(command, in: project)
            return C03PlannedLayerOperation(commands: [command])

        case .copySelection(let sourceLayerID, let name):
            guard let selection = project.imageSelection, !selection.isEmpty else {
                throw C03LayerOperationError.invalidSelection("a non-empty selection is required")
            }
            let command = MediaEditCommand.copySelection(
                sourceLayerID: sourceLayerID,
                name: name,
                raster: MergedLayerRaster(assetID: UUID(), width: 0, height: 0))
            let enriched = try await MediaCommandEnrichment.enrich(
                [command], project: project, host: host)
            try validate(enriched, in: project)
            return C03PlannedLayerOperation(
                commands: enriched,
                stagedAssets: MediaCommandEnrichment.stagedAssets(in: enriched))

        case .mergeLayers(let ids, let name):
            guard ids.count >= 2, Set(ids).count == ids.count else {
                throw C03LayerOperationError.invalidOperation(
                    "merge needs at least two distinct layers")
            }
            let command = MediaEditCommand.mergeLayers(
                ids: ids,
                name: name,
                raster: MergedLayerRaster(assetID: UUID(), width: 0, height: 0))
            let enriched = try await MediaCommandEnrichment.enrich(
                [command], project: project, host: host)
            try validate(enriched, in: project)
            return C03PlannedLayerOperation(
                commands: enriched,
                stagedAssets: MediaCommandEnrichment.stagedAssets(in: enriched))
        }
    }

    /// Applies the planned commands as ONE transaction. On any validation
    /// error nothing is committed; the original project value is unchanged.
    public static func apply(
        _ planned: C03PlannedLayerOperation,
        to project: inout MediaProject
    ) throws {
        try MediaTransactions.apply(planned.commands, to: &project)
    }

    private static func validate(_ commands: [MediaEditCommand], in project: MediaProject) throws {
        var draft = project
        for command in commands {
            try MediaEditCommandApplier.apply(command, to: &draft)
        }
    }
}

public struct C03VerifiedLayerRaster: Sendable, Equatable {
    public var assetID: UUID
    public var relativePath: String
    public var width: Int
    public var height: Int
    public var byteCount: Int64
    public var sha256: String
}

/// Strict verification of a renderer-staged merge/copy asset.
///
/// The asset must be a real regular file under the trusted project root and the
/// exact `Workbench/Assets/` namespace, with matching byte count, SHA-256 and
/// full-canvas PNG dimensions. A symlink, traversal, wrong dimension, stale
/// hash or caller-supplied path is refused. This does not create a second
/// asset store; it only proves the bytes before the existing command commits.
public enum C03LayerRasterVerifier {
    public static func verify(
        _ preparation: MergePreparation,
        project: MediaProject,
        root: URL
    ) throws -> C03VerifiedLayerRaster {
        guard let canvas = project.canvas else {
            throw C03LayerOperationError.rasterRejected("the project has no canvas")
        }
        let asset = preparation.asset
        let raster = preparation.raster
        guard asset.id == raster.assetID, asset.kind == .image else {
            throw C03LayerOperationError.rasterRejected("asset and raster identities differ")
        }
        guard raster.width == canvas.width, raster.height == canvas.height else {
            throw C03LayerOperationError.rasterRejected("the raster is not full-canvas")
        }
        guard safeRelative(asset.relativePath),
              asset.relativePath.hasPrefix("Workbench/Assets/"),
              !asset.relativePath.contains("..") else {
            throw C03LayerOperationError.rasterRejected(
                "the raster path is not an owned Workbench/Assets path")
        }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let target = base.appendingPathComponent(asset.relativePath)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard target.path.hasPrefix(base.path + "/") else {
            throw C03LayerOperationError.rasterRejected("the raster path escapes the project root")
        }
        guard isRealRegularFile(target.path),
              let size = fileSize(target.path),
              size > 0 else {
            throw C03LayerOperationError.rasterRejected("the raster file is missing or invalid")
        }
        if let declared = asset.byteCount, declared != size {
            throw C03LayerOperationError.rasterRejected("the raster size differs from the asset")
        }
        let data: Data
        do {
            guard size <= 512 * 1024 * 1024 else {
                throw C03LayerOperationError.rasterRejected(
                    "the raster exceeds the bounded 512 MiB asset limit")
            }
            data = try Data(contentsOf: target, options: [.mappedIfSafe])
        } catch {
            throw C03LayerOperationError.rasterRejected("the raster file could not be read")
        }
        guard data.count == Int(size) else {
            throw C03LayerOperationError.rasterRejected("the raster size changed while reading")
        }
        let digest = FloeDigest.sha256Hex(data)
        if let declared = asset.contentHash, declared.lowercased() != digest {
            throw C03LayerOperationError.rasterRejected("the raster hash differs from the asset")
        }
        if let declared = raster.contentHash, declared.lowercased() != digest {
            throw C03LayerOperationError.rasterRejected("the raster hash differs from the command")
        }
        guard let dimensions = pngDimensions(data),
              dimensions.0 == canvas.width, dimensions.1 == canvas.height else {
            throw C03LayerOperationError.rasterRejected(
                "the raster is not a PNG with the project canvas dimensions")
        }
        return C03VerifiedLayerRaster(
            assetID: asset.id,
            relativePath: asset.relativePath,
            width: dimensions.0,
            height: dimensions.1,
            byteCount: size,
            sha256: digest)
    }

    private static func safeRelative(_ path: String) -> Bool {
        guard !path.isEmpty, path.count <= 512, !path.hasPrefix("/"),
              !path.contains("\\"), !path.contains("\0") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func isRealRegularFile(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { return false }
        return true
    }

    private static func fileSize(_ path: String) -> Int64? {
        var info = stat()
        guard lstat(path, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { return nil }
        return Int64(info.st_size)
    }

    private static func pngDimensions(_ data: Data) -> (Int, Int)? {
        guard data.count >= 24 else { return nil }
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard Array(data.prefix(8)) == signature,
              String(data: data.subdata(in: 12..<16), encoding: .ascii) == "IHDR" else {
            return nil
        }
        func be32(_ offset: Int) -> Int {
            (Int(data[offset]) << 24) | (Int(data[offset + 1]) << 16) |
                (Int(data[offset + 2]) << 8) | Int(data[offset + 3])
        }
        let width = be32(16)
        let height = be32(20)
        guard width > 0, height > 0 else { return nil }
        return (width, height)
    }
}
