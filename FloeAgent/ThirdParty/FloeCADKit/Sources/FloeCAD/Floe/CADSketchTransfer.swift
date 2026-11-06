// SPDX-License-Identifier: MPL-2.0
// Typed 2D drawing → native sketch handoff. Source bytes are evidence/data,
// never file access, execution or permission instructions.
import Foundation
import CryptoKit
import simd

public nonisolated struct CADSketchTransferPlane: Codable, Equatable, Sendable {
    public var origin: [Double]
    public var xAxis: [Double]
    public var yAxis: [Double]
}
public nonisolated struct CADSketchTransferOCS: Codable, Equatable, Sendable {
    public var normal: [Double]
    public var elevation: Double
}
public nonisolated struct CADSketchTransferCurve: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case line, circle, arc }
    public var kind: Kind
    public var handle: String
    public var layer: String
    public var sourceEntityType: String
    public var ocs: CADSketchTransferOCS
    public var start: [Double]?
    public var end: [Double]?
    public var center: [Double]?
    public var radius: Double?
    public var startAngle: Double?
    /// Signed radians: clockwise bulges are preserved, never made straight.
    public var sweepAngle: Double?
}
public nonisolated struct CADSketchTransferOmission: Codable, Equatable, Sendable {
    public var handle: String
    public var entityType: String
    public var layer: String
    public var reason: String
}
public nonisolated struct CADSketchTransferSnapshot: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var format: String
    public var drawingVersion: String
    public var draftRevision: UInt64
    public var insertionUnits: Int
    public var unitName: String
    public var unitScaleMM: Double?
    public var selectedHandles: [String]
    public var selectedLayers: [String]
    public var sourcePlane: CADSketchTransferPlane
    /// Exact plane-local drawing coordinates in the original drawing units.
    public var curves: [CADSketchTransferCurve]
    public var omissions: [CADSketchTransferOmission]

    public static func decodeValidated(_ data: Data) throws -> Self {
        guard data.count <= 12 * 1024 * 1024 else { throw CADSketchTransferError.invalid("Drawing selection is too large.") }
        let object = try JSONSerialization.jsonObject(with: data)
        try CADSketchTransferSchema.snapshot(object)
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate()
        return value
    }
    public func validate() throws {
        guard schemaVersion == 1, ["dxf", "dwg"].contains(format),
              !curves.isEmpty, curves.count <= 40_000,
              selectedHandles.count <= 20_000, selectedLayers.count <= 256,
              omissions.count <= 20_000, Set(selectedHandles).count == selectedHandles.count,
              selectedHandles.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 32 }),
              selectedLayers.allSatisfy({ $0.utf8.count <= 1024 }) else { throw CADSketchTransferError.invalid("Unsupported or invalid drawing selection.") }
        try sourcePlane.validate()
        if let unitScaleMM { guard unitScaleMM.isFinite, unitScaleMM > 0 else { throw CADSketchTransferError.invalid("Invalid drawing units.") } }
        let handles = Set(selectedHandles), layers = Set(selectedLayers)
        for curve in curves {
            guard handles.contains(curve.handle), layers.contains(curve.layer),
                  curve.ocs.normal.count == 3, curve.ocs.normal.allSatisfy({ $0.isFinite }),
                  curve.ocs.elevation.isFinite else { throw CADSketchTransferError.invalid("Invalid source curve reference.") }
            func point(_ p: [Double]?) -> Bool { p?.count == 2 && p!.allSatisfy({ $0.isFinite && abs($0) <= 1e12 }) }
            switch curve.kind {
            case .line:
                guard point(curve.start), point(curve.end), curve.start != curve.end else { throw CADSketchTransferError.invalid("Invalid drawing line.") }
            case .circle, .arc:
                guard point(curve.center), let radius = curve.radius, radius.isFinite, radius > 0, radius <= 1e12 else { throw CADSketchTransferError.invalid("Invalid drawing circle.") }
                if curve.kind == .arc {
                    guard let start = curve.startAngle, let sweep = curve.sweepAngle, start.isFinite, sweep.isFinite,
                          abs(sweep) > 1e-10, abs(sweep) < 2 * .pi - 1e-10 else { throw CADSketchTransferError.invalid("Invalid drawing arc.") }
                }
            }
        }
        for omission in omissions {
            guard handles.contains(omission.handle), omission.reason.utf8.count <= 4096 else { throw CADSketchTransferError.invalid("Invalid drawing omission.") }
        }
    }
}
public nonisolated struct CADSketchTransferPlacement: Codable, Equatable, Sendable {
    public enum Target: String, Codable, CaseIterable, Sendable { case selected, front, top, right, source }
    public var target: Target
    /// Subtract this point before rotating. Use matching reference points to
    /// align separately selected front/top/right view groups.
    public var sourceAnchor: [Double]
    public var offsetMM: [Double]
    public var rotationDegrees: Double
    /// Explicit override required for unitless/unknown drawings.
    public var unitScaleMM: Double?
    public var acceptOmissions: Bool
    public init(target: Target = .selected, sourceAnchor: [Double] = [0, 0],
                offsetMM: [Double] = [0, 0], rotationDegrees: Double = 0,
                unitScaleMM: Double? = nil, acceptOmissions: Bool = false) {
        self.target = target; self.sourceAnchor = sourceAnchor; self.offsetMM = offsetMM
        self.rotationDegrees = rotationDegrees; self.unitScaleMM = unitScaleMM
        self.acceptOmissions = acceptOmissions
    }
}
public nonisolated struct CADSketchTransferEnvelope: Codable, Equatable, Sendable {
    public enum Purpose: String, Codable, Sendable { case modelSketch, buildingFloorplan }
    public var schemaVersion: Int = 1
    public var purpose: Purpose
    public var sourceName: String
    public var sourceSHA256: String
    public var sourceIdentity: String?
    /// Exact bytes opened in the engine, retained with the imported sketch.
    public var sourceBytes: Data
    public var snapshot: CADSketchTransferSnapshot
    public var placement: CADSketchTransferPlacement?
    public init(purpose: Purpose, sourceName: String, sourceSHA256: String,
                sourceIdentity: String? = nil, sourceBytes: Data,
                snapshot: CADSketchTransferSnapshot, placement: CADSketchTransferPlacement? = nil) throws {
        self.purpose = purpose; self.sourceName = sourceName; self.sourceSHA256 = sourceSHA256
        self.sourceIdentity = sourceIdentity; self.sourceBytes = sourceBytes; self.snapshot = snapshot; self.placement = placement
        try validate()
    }
    public func validate() throws {
        guard schemaVersion == 1, !sourceName.isEmpty, sourceName.utf8.count <= 1024,
              (sourceIdentity?.utf8.count ?? 0) <= 4096,
              !sourceBytes.isEmpty, sourceBytes.count <= 10 * 1024 * 1024,
              sourceSHA256 == Self.digest(sourceBytes) else { throw CADSketchTransferError.invalid("Drawing source bytes or checksum do not match.") }
        try snapshot.validate()
        if let placement { try placement.validate(snapshot: snapshot) }
    }
    public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    /// Raw persisted-field gate for the package reader. Unknown nested fields
    /// and future versions must remain opaque/read-only, never decoded away.
    public static func validateStoredJSONObject(_ object: Any) throws {
        try CADSketchTransferSchema.envelope(object)
        let data = try JSONSerialization.data(withJSONObject: object)
        guard data.count <= 26 * 1024 * 1024 else { throw CADSketchTransferError.invalid("Drawing source exceeds the package budget.") }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate()
    }
}
public nonisolated enum CADSketchTransferError: Error, LocalizedError, Sendable {
    case invalid(String)
    public var errorDescription: String? { switch self { case let .invalid(message): return message } }
}
nonisolated extension CADSketchTransferPlane {
    func validate() throws {
        guard origin.count == 3, xAxis.count == 3, yAxis.count == 3,
              (origin + xAxis + yAxis).allSatisfy({ $0.isFinite && abs($0) <= 1e12 }) else { throw CADSketchTransferError.invalid("Invalid drawing plane.") }
        let x = SIMD3(xAxis[0], xAxis[1], xAxis[2]); let y = SIMD3(yAxis[0], yAxis[1], yAxis[2])
        guard abs(simd_length(x) - 1) < 1e-7, abs(simd_length(y) - 1) < 1e-7, abs(simd_dot(x, y)) < 1e-7 else { throw CADSketchTransferError.invalid("Drawing plane is not orthonormal.") }
    }
    var sketchPlane: SketchPlane { SketchPlane(origin: SIMD3(origin[0],origin[1],origin[2]), xAxis: SIMD3(xAxis[0],xAxis[1],xAxis[2]), yAxis: SIMD3(yAxis[0],yAxis[1],yAxis[2])) }
}
nonisolated extension CADSketchTransferPlacement {
    func validate(snapshot: CADSketchTransferSnapshot) throws {
        guard sourceAnchor.count == 2, offsetMM.count == 2,
              (sourceAnchor + offsetMM + [rotationDegrees]).allSatisfy({ $0.isFinite && abs($0) <= 1e12 }),
              let scale = unitScaleMM ?? snapshot.unitScaleMM, scale.isFinite, scale > 0,
              snapshot.omissions.isEmpty || acceptOmissions else { throw CADSketchTransferError.invalid("Choose drawing units and review omitted entities before importing.") }
    }
    func entities(snapshot: CADSketchTransferSnapshot) throws -> [SketchEntity] {
        try snapshot.validate()
        try validate(snapshot: snapshot)
        let scale = unitScaleMM ?? snapshot.unitScaleMM!, angle = rotationDegrees * .pi / 180
        func point(_ p: [Double]) throws -> SIMD2<Double> {
            let x = (p[0] - sourceAnchor[0]) * scale, y = (p[1] - sourceAnchor[1]) * scale
            let result = SIMD2(x*cos(angle)-y*sin(angle)+offsetMM[0], x*sin(angle)+y*cos(angle)+offsetMM[1])
            guard result.x.isFinite, result.y.isFinite, abs(result.x) <= 1e12, abs(result.y) <= 1e12 else { throw CADSketchTransferError.invalid("Scaled drawing coordinates exceed the model limit.") }
            return result
        }
        return try snapshot.curves.map { curve in
            if let radius = curve.radius, !(radius * scale).isFinite || radius * scale > 1e12 {
                throw CADSketchTransferError.invalid("Scaled drawing radius exceeds the model limit.")
            }
            switch curve.kind {
            case .line: return .line(id: UUID(), a: try point(curve.start!), b: try point(curve.end!))
            case .circle: return .circle(id: UUID(), center: try point(curve.center!), radius: curve.radius! * scale)
            case .arc:
                let start = curve.startAngle! + angle, sweep = curve.sweepAngle!
                return .arc(id: UUID(), center: try point(curve.center!), radius: curve.radius! * scale,
                            startAngle: sweep > 0 ? start : start + sweep,
                            endAngle: sweep > 0 ? start + sweep : start)
            }
        }
    }
}
/// The raw key whitelist is deliberately recursive. Package readers call this
/// before Codable so a newer source/curve/placement format cannot be lost.
private nonisolated enum CADSketchTransferSchema {
    static func object(_ value: Any, keys: Set<String>) throws -> [String: Any] {
        guard let value = value as? [String: Any], Set(value.keys).isSubset(of: keys) else { throw CADSketchTransferError.invalid("Unknown drawing-transfer fields; preserve the document read-only.") }; return value
    }
    static func snapshot(_ value: Any) throws {
        let v = try object(value, keys: ["schemaVersion","format","drawingVersion","draftRevision","insertionUnits","unitName","unitScaleMM","selectedHandles","selectedLayers","sourcePlane","curves","omissions"])
        guard v["schemaVersion"] as? Int == 1 else { throw CADSketchTransferError.invalid("Unsupported drawing-transfer version.") }
        _ = try object(v["sourcePlane"] as Any, keys: ["origin","xAxis","yAxis"])
        guard let curves = v["curves"] as? [Any], let omissions = v["omissions"] as? [Any] else { throw CADSketchTransferError.invalid("Invalid drawing-transfer arrays.") }
        for curve in curves { let c = try object(curve, keys: ["kind","handle","layer","sourceEntityType","ocs","start","end","center","radius","startAngle","sweepAngle"]); _ = try object(c["ocs"] as Any, keys: ["normal","elevation"]) }
        for omission in omissions { _ = try object(omission, keys: ["handle","entityType","layer","reason"]) }
    }
    static func envelope(_ value: Any) throws {
        let v = try object(value, keys: ["schemaVersion","purpose","sourceName","sourceSHA256","sourceIdentity","sourceBytes","snapshot","placement"])
        guard v["schemaVersion"] as? Int == 1 else { throw CADSketchTransferError.invalid("Unsupported drawing source version.") }
        try snapshot(v["snapshot"] as Any)
        if let placement = v["placement"], !(placement is NSNull) { _ = try object(placement, keys: ["target","sourceAnchor","offsetMM","rotationDegrees","unitScaleMM","acceptOmissions"]) }
    }
}

@MainActor public extension FloeCADDocument {
    /// Queue a read-only selection in the existing native workbench. The user
    /// chooses its plane/units/alignment before the single undoable commit.
    func queueDrawingTransfer(_ envelope: CADSketchTransferEnvelope) throws {
        guard !isClosed, !isReadOnly else { throw CADSketchTransferError.invalid("The target model is closed or read-only.") }
        try envelope.validate()
        viewModel().pendingDrawingTransfer = envelope
    }
}
