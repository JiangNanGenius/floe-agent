// SPDX-License-Identifier: MPL-2.0
//
// Swift value-type adapter over the project-authored Clipper2 C ABI.
//
// The adapter owns no document, layer, selection or UI state. It quantizes
// editable Bezier paths with an explicit scale, flattens them with an explicit
// chord tolerance, and returns plain tessellated polygons plus query metadata.

import Foundation
import MediaExchangeCore
import Clipper2C

public struct GeometryQueryMetadata: Hashable, Sendable {
    public var operation: String
    public var fillRule: GeometryFillRule?
    public var flatteningTolerance: Double
    public var quantizationScale: Double
    public var inputPathCount: Int
    public var outputPathCount: Int
    public var clipperVersion: String

    public init(
        operation: String,
        fillRule: GeometryFillRule?,
        flatteningTolerance: Double,
        quantizationScale: Double,
        inputPathCount: Int,
        outputPathCount: Int,
        clipperVersion: String
    ) {
        self.operation = operation
        self.fillRule = fillRule
        self.flatteningTolerance = flatteningTolerance
        self.quantizationScale = quantizationScale
        self.inputPathCount = inputPathCount
        self.outputPathCount = outputPathCount
        self.clipperVersion = clipperVersion
    }
}

public struct GeometryOperationResult: Sendable {
    public var polygons: [TessellatedPolygon]
    public var metadata: GeometryQueryMetadata

    public init(polygons: [TessellatedPolygon], metadata: GeometryQueryMetadata) {
        self.polygons = polygons
        self.metadata = metadata
    }
}

public struct ClipperGeometryAdapter: Sendable {
    /// Integer units per canvas point. 1024 gives sub-pixel precision without
    /// overflowing for normal drawing canvases. The value is part of the
    /// result metadata so callers can reason about quantization error.
    public let quantizationScale: Int64
    public let flatteningTolerance: Double

    public init(quantizationScale: Int64 = 1024, flatteningTolerance: Double = 0.01) throws {
        guard quantizationScale > 0 else {
            throw GeometryError.quantizationOverflow
        }
        guard flatteningTolerance.isFinite, flatteningTolerance > 0 else {
            throw GeometryError.invalidTolerance(flatteningTolerance)
        }
        self.quantizationScale = quantizationScale
        self.flatteningTolerance = flatteningTolerance
    }

    public func boolean(
        _ operation: GeometryBooleanOperation,
        subject: [BezierPath],
        clip: [BezierPath],
        fillRule: GeometryFillRule = .nonZero
    ) throws -> GeometryOperationResult {
        let subjectEncoded = try encode(subject)
        let clipEncoded = try encode(clip)
        let result = subjectEncoded.coords.withUnsafeBufferPointer { subjectCoords in
            subjectEncoded.offsets.withUnsafeBufferPointer { subjectOffsets in
                clipEncoded.coords.withUnsafeBufferPointer { clipCoords in
                    clipEncoded.offsets.withUnsafeBufferPointer { clipOffsets in
                        floe_clipper_boolean(
                            operationCode(operation),
                            fillRuleCode(fillRule),
                            subjectCoords.baseAddress,
                            subjectCoords.count,
                            subjectOffsets.baseAddress,
                            subjectEncoded.offsets.count - 1,
                            clipCoords.baseAddress,
                            clipCoords.count,
                            clipOffsets.baseAddress,
                            clipEncoded.offsets.count - 1
                        )
                    }
                }
            }
        }
        let polygons = try decode(result, sourcePathIDs: subject.map(\.id) + clip.map(\.id))
        return GeometryOperationResult(
            polygons: polygons,
            metadata: GeometryQueryMetadata(
                operation: operation.rawValue,
                fillRule: fillRule,
                flatteningTolerance: flatteningTolerance,
                quantizationScale: Double(quantizationScale),
                inputPathCount: subject.count + clip.count,
                outputPathCount: polygons.count,
                clipperVersion: clipperVersion()
            )
        )
    }

    public func offset(
        _ paths: [BezierPath],
        delta: Double,
        joinType: GeometryJoinType = .miter,
        endType: GeometryEndType = .polygon,
        miterLimit: Double = 2,
        arcTolerance: Double? = nil
    ) throws -> GeometryOperationResult {
        guard delta.isFinite else { throw GeometryError.nonFinitePoint }
        guard miterLimit.isFinite, miterLimit >= 1 else {
            throw GeometryError.invalidTolerance(miterLimit)
        }
        let resolvedArcTolerance = arcTolerance ?? (flatteningTolerance * Double(quantizationScale))
        guard resolvedArcTolerance.isFinite, resolvedArcTolerance >= 0 else {
            throw GeometryError.invalidTolerance(resolvedArcTolerance)
        }
        let encoded = try encode(paths)
        let scaledDelta = delta * Double(quantizationScale)
        guard scaledDelta.isFinite,
              abs(scaledDelta) <= 9.0e18 else {
            throw GeometryError.quantizationOverflow
        }
        let result = encoded.coords.withUnsafeBufferPointer { coords in
            encoded.offsets.withUnsafeBufferPointer { offsets in
                floe_clipper_offset(
                    coords.baseAddress,
                    coords.count,
                    offsets.baseAddress,
                    encoded.offsets.count - 1,
                    scaledDelta,
                    joinCode(joinType),
                    endCode(endType),
                    miterLimit,
                    resolvedArcTolerance
                )
            }
        }
        let polygons = try decode(result, sourcePathIDs: paths.map(\.id))
        return GeometryOperationResult(
            polygons: polygons,
            metadata: GeometryQueryMetadata(
                operation: "offset",
                fillRule: nil,
                flatteningTolerance: flatteningTolerance,
                quantizationScale: Double(quantizationScale),
                inputPathCount: paths.count,
                outputPathCount: polygons.count,
                clipperVersion: clipperVersion()
            )
        )
    }

    // MARK: - Quantization

    private struct EncodedPaths {
        var coords: [Int64]
        var offsets: [Int]
    }

    private func encode(_ paths: [BezierPath]) throws -> EncodedPaths {
        var coords: [Int64] = []
        var offsets: [Int] = [0]
        for path in paths {
            let points = try path.flattened(tolerance: flatteningTolerance)
            for point in points {
                coords.append(try quantize(point.x))
                coords.append(try quantize(point.y))
            }
            offsets.append(coords.count / 2)
        }
        return EncodedPaths(coords: coords, offsets: offsets)
    }

    private func quantize(_ value: Double) throws -> Int64 {
        guard value.isFinite else { throw GeometryError.nonFinitePoint }
        let scaled = value * Double(quantizationScale)
        guard scaled.isFinite, scaled >= -9.0e18, scaled <= 9.0e18 else {
            throw GeometryError.quantizationOverflow
        }
        return Int64(scaled.rounded())
    }

    private func decode(_ result: FloeClipperResult, sourcePathIDs: [String]) throws -> [TessellatedPolygon] {
        var result = result
        defer { floe_clipper_result_free(&result) }
        if result.error_code != 0 {
            let message = result.error_message.map { String(cString: $0) } ?? "unknown Clipper2 error"
            throw GeometryError.clipperError(message)
        }
        guard let coords = result.coords, let offsets = result.offsets else {
            return []
        }
        var polygons: [TessellatedPolygon] = []
        let pathCount = Int(result.path_count)
        for index in 0..<pathCount {
            let start = Int(offsets[index])
            let end = Int(offsets[index + 1])
            guard end >= start, end * 2 <= Int(result.coord_count) else {
                throw GeometryError.clipperError("result offsets are invalid")
            }
            var points: [GeometryPoint] = []
            points.reserveCapacity(end - start)
            for pointIndex in start..<end {
                let x = Double(coords[pointIndex * 2]) / Double(quantizationScale)
                let y = Double(coords[pointIndex * 2 + 1]) / Double(quantizationScale)
                points.append(GeometryPoint(x: x, y: y))
            }
            polygons.append(TessellatedPolygon(
                points: points,
                sourcePathIDs: sourcePathIDs,
                flatteningTolerance: flatteningTolerance,
                quantizationScale: Double(quantizationScale)
            ))
        }
        return polygons
    }

    private func clipperVersion() -> String {
        guard let pointer = floe_clipper_version() else { return "unknown" }
        return String(cString: pointer)
    }

    // MARK: - C enum mapping (values are fixed by clipper2_c.h)

    private func operationCode(_ operation: GeometryBooleanOperation) -> Int32 {
        switch operation {
        case .intersection: return 0
        case .union: return 1
        case .difference: return 2
        case .xor: return 3
        }
    }

    private func fillRuleCode(_ rule: GeometryFillRule) -> Int32 {
        switch rule {
        case .evenOdd: return 0
        case .nonZero: return 1
        case .positive: return 2
        case .negative: return 3
        }
    }

    private func joinCode(_ join: GeometryJoinType) -> Int32 {
        switch join {
        case .square: return 0
        case .bevel: return 1
        case .round: return 2
        case .miter: return 3
        }
    }

    private func endCode(_ end: GeometryEndType) -> Int32 {
        switch end {
        case .polygon: return 0
        case .joined: return 1
        case .butt: return 2
        case .square: return 3
        case .round: return 4
        }
    }
}
