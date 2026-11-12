// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum EDAError: Error, Equatable, Sendable {
    case invalid(String), missing(String), duplicate(String), unsupported(String)
    case staleRevision(expected: UInt64, actual: UInt64)
    case readOnly, cancelled
}

/// A concrete reason instead of the opaque `EDAError error 0` produced by
/// `localizedDescription` for an enum without LocalizedError.
extension EDAError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalid(let detail): "The electronics operation is invalid: " + detail
        case .missing(let detail): "The electronics item is missing: " + detail
        case .duplicate(let detail): "The electronics item already exists: " + detail
        case .unsupported(let detail): "This electronics capability is not supported: " + detail
        case .staleRevision(let expected, let actual): "The electronics original changed (expected revision \(expected), actual \(actual))."
        case .readOnly: "This electronics original is read-only."
        case .cancelled: "The electronics operation was cancelled."
        }
    }
}

/// All public geometry is measured in millimetres; angles are degrees.
public struct EDAPoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double = 0, _ y: Double = 0) { self.x = x; self.y = y }
    public static let zero = EDAPoint()
    public static func + (a: Self, b: Self) -> Self { .init(a.x + b.x, a.y + b.y) }
    public static func - (a: Self, b: Self) -> Self { .init(a.x - b.x, a.y - b.y) }
    public static func * (a: Self, b: Double) -> Self { .init(a.x * b, a.y * b) }
    public var length: Double { hypot(x, y) }
    public func distance(to p: Self) -> Double { (self - p).length }
    public func transformed(origin: Self, angle: Double, mirrored: Bool = false) -> Self {
        let r = angle * .pi / 180, a = mirrored ? -x : x
        return .init(origin.x + a * cos(r) - y * sin(r), origin.y + a * sin(r) + y * cos(r))
    }
    public func snapped(to grid: Double) -> Self {
        guard grid.isFinite, grid > 0 else { return self }
        return .init((x / grid).rounded() * grid, (y / grid).rounded() * grid)
    }
    public var isValid: Bool { x.isFinite && y.isFinite && abs(x) <= 100_000 && abs(y) <= 100_000 }
}

public enum EDAPinType: String, Codable, CaseIterable, Sendable {
    case input, output, bidirectional, triState, passive, powerInput, powerOutput
    case openCollector, openEmitter, noConnect, unspecified
}

public struct EDAPin: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var number: String
    public var name: String
    public var position: EDAPoint
    public var type: EDAPinType
    public var unit: Int
    public init(id: UUID = UUID(), number: String, name: String = "", position: EDAPoint,
                type: EDAPinType = .passive, unit: Int = 1) {
        self.id = id; self.number = number; self.name = name; self.position = position
        self.type = type; self.unit = unit
    }
}

public enum EDAGraphic: Codable, Hashable, Sendable {
    case line(EDAPoint, EDAPoint, width: Double)
    case rectangle(EDAPoint, EDAPoint, width: Double)
    case circle(center: EDAPoint, radius: Double, width: Double)
    case arc(center: EDAPoint, radius: Double, start: Double, sweep: Double, width: Double)
    case text(String, position: EDAPoint, height: Double, angle: Double)
    case dimension(EDAPoint, EDAPoint, offset: Double)
}

public struct EDASymbolDefinition: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var referencePrefix: String
    public var pins: [EDAPin]
    public var graphics: [EDAGraphic]
    public var fields: [String: String]
    /// Nil preserves older definitions. KiCad unit 0 artwork is shared; other
    /// artwork belongs only to its matching logical unit, never every gate.
    public var graphicUnits: [Int]?
    public init(id: UUID = UUID(), name: String, referencePrefix: String = "U",
                pins: [EDAPin] = [], graphics: [EDAGraphic] = [], fields: [String: String] = [:], graphicUnits: [Int]? = nil) {
        self.id = id; self.name = name; self.referencePrefix = referencePrefix
        self.pins = pins; self.graphics = graphics; self.fields = fields
        self.graphicUnits = graphicUnits
    }
    public func graphics(forUnit unit: Int) -> [EDAGraphic] {
        guard let graphicUnits, graphicUnits.count == graphics.count else { return graphics }
        return graphics.indices.filter { graphicUnits[$0] == 0 || graphicUnits[$0] == unit }.map { graphics[$0] }
    }
}

/// A logical component can have several symbol units on different sheets.
public struct EDAComponent: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var symbolID: UUID
    public var footprintID: UUID?
    public var reference: String
    public var value: String
    public var fields: [String: String]
    public var excludedVariants: Set<String>
    public init(id: UUID = UUID(), symbolID: UUID, footprintID: UUID? = nil,
                reference: String = "", value: String = "", fields: [String: String] = [:],
                excludedVariants: Set<String> = []) {
        self.id = id; self.symbolID = symbolID; self.footprintID = footprintID
        self.reference = reference; self.value = value; self.fields = fields
        self.excludedVariants = excludedVariants
    }
}

public struct EDASymbolPlacement: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var componentID: UUID
    public var unit: Int
    public var position: EDAPoint
    public var angle: Double
    public var mirrored: Bool
    public init(id: UUID = UUID(), componentID: UUID, unit: Int = 1,
                position: EDAPoint = .zero, angle: Double = 0, mirrored: Bool = false) {
        self.id = id; self.componentID = componentID; self.unit = unit
        self.position = position; self.angle = angle; self.mirrored = mirrored
    }
}

public struct EDAWire: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var points: [EDAPoint]
    public init(id: UUID = UUID(), points: [EDAPoint]) { self.id = id; self.points = points }
}

public struct EDAJunction: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var position: EDAPoint
    public init(id: UUID = UUID(), position: EDAPoint) { self.id = id; self.position = position }
}

public enum EDALabelScope: String, Codable, CaseIterable, Sendable { case local, global, hierarchical }
public struct EDANetLabel: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var position: EDAPoint
    public var scope: EDALabelScope
    public init(id: UUID = UUID(), name: String, position: EDAPoint, scope: EDALabelScope = .local) {
        self.id = id; self.name = name; self.position = position; self.scope = scope
    }
}

public struct EDASheetPort: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var position: EDAPoint
    public init(id: UUID = UUID(), name: String, position: EDAPoint) {
        self.id = id; self.name = name; self.position = position
    }
}

public struct EDASheetLink: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var childSheetID: UUID
    public var name: String
    public var ports: [EDASheetPort]
    public init(id: UUID = UUID(), childSheetID: UUID, name: String, ports: [EDASheetPort] = []) {
        self.id = id; self.childSheetID = childSheetID; self.name = name; self.ports = ports
    }
}

/// Graphical bus entry only. Electrical identity comes from real wire labels;
/// these endpoints never create scalar graph nodes or short the bus members.
public struct EDABusEntry: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var busPosition: EDAPoint
    public var wirePosition: EDAPoint
    public init(id: UUID = UUID(), busPosition: EDAPoint, wirePosition: EDAPoint) {
        self.id = id; self.busPosition = busPosition; self.wirePosition = wirePosition
    }
}

public struct EDABus: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var members: [String]
    public var points: [EDAPoint]
    /// Nil preserves old originals with no entry metadata.
    public var entries: [EDABusEntry]?
    public init(id: UUID = UUID(), name: String, members: [String], points: [EDAPoint], entries: [EDABusEntry]? = nil) {
        self.id = id; self.name = name; self.members = members; self.points = points; self.entries = entries
    }
}

public struct EDASheet: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var symbols: [EDASymbolPlacement]
    public var wires: [EDAWire]
    public var junctions: [EDAJunction]
    public var labels: [EDANetLabel]
    public var noConnects: [EDAJunction]
    public var buses: [EDABus]
    public var children: [EDASheetLink]
    public var graphics: [EDAGraphic]
    public init(id: UUID = UUID(), name: String = "Sheet 1", symbols: [EDASymbolPlacement] = [],
                wires: [EDAWire] = [], junctions: [EDAJunction] = [], labels: [EDANetLabel] = [],
                noConnects: [EDAJunction] = [], buses: [EDABus] = [], children: [EDASheetLink] = [],
                graphics: [EDAGraphic] = []) {
        self.id = id; self.name = name; self.symbols = symbols; self.wires = wires
        self.junctions = junctions; self.labels = labels; self.noConnects = noConnects
        self.buses = buses; self.children = children; self.graphics = graphics
    }
}

public enum EDAPadShape: String, Codable, CaseIterable, Sendable { case circle, rectangle, oval, roundRectangle, polygon }
public struct EDAPad: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var number: String
    public var position: EDAPoint
    public var size: EDAPoint
    public var angle: Double
    public var shape: EDAPadShape
    /// Polygon-only local mm vertices, implicitly closed; nil for older shapes.
    public var polygon: [EDAPoint]?
    /// Explicit mm radius for new round-rectangle pads. Nil preserves the
    /// historical unspecified-radius failure instead of inventing a shape.
    public var roundRectangleRadius: Double?
    public var drill: Double?
    /// Nil means plating has not been specified. Never infer it from copper layers.
    public var drillPlated: Bool?
    public var layers: [String]
    public init(id: UUID = UUID(), number: String, position: EDAPoint, size: EDAPoint = .init(1.5, 1.5),
                angle: Double = 0, shape: EDAPadShape = .circle, drill: Double? = nil,
                layers: [String] = ["F.Cu"], drillPlated: Bool? = nil, polygon: [EDAPoint]? = nil,
                roundRectangleRadius: Double? = nil) {
        self.id = id; self.number = number; self.position = position; self.size = size
        self.angle = angle; self.shape = shape; self.polygon = polygon; self.drill = drill; self.layers = layers; self.drillPlated = drillPlated
        self.roundRectangleRadius = roundRectangleRadius
    }
}

/// Explicit layer metadata aligned by index with a parent's unchanged graphics array.
/// Nil means unassigned. Layer IDs are relative to the front for footprint definitions.
public struct EDAGraphicLayerAssignment: Codable, Hashable, Sendable {
    public var layerID: String
    public var kind: EDALayerKind
    public init(layerID: String, kind: EDALayerKind) { self.layerID = layerID; self.kind = kind }
}

public struct EDAFootprintDefinition: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var pads: [EDAPad]
    public var graphics: [EDAGraphic]
    public var graphicLayers: [EDAGraphicLayerAssignment?]?
    public var fields: [String: String]
    public var modelReference: String?
    /// Nil is omitted from canonical encoding so unchanged bundled/library
    /// packages keep their exact hashes. New remote footprints carry only
    /// source-bound references; model bytes remain lazy.
    public var modelReferences: [EDAFootprintModelReference]?
    public init(id: UUID = UUID(), name: String, pads: [EDAPad] = [], graphics: [EDAGraphic] = [],
                graphicLayers: [EDAGraphicLayerAssignment?]? = nil,
                fields: [String: String] = [:], modelReference: String? = nil,
                modelReferences: [EDAFootprintModelReference]? = nil) {
        self.id = id; self.name = name; self.pads = pads; self.graphics = graphics
        self.graphicLayers = graphicLayers
        self.fields = fields; self.modelReference = modelReference
        self.modelReferences = modelReferences
    }
}

public struct EDAFootprint: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var definitionID: UUID
    public var componentID: UUID?
    public var reference: String
    public var value: String
    public var position: EDAPoint
    public var angle: Double
    public var side: String
    public var padNets: [String: String]
    public var locked: Bool
    public init(id: UUID = UUID(), definitionID: UUID, componentID: UUID? = nil,
                reference: String = "", value: String = "", position: EDAPoint = .zero,
                angle: Double = 0, side: String = "F.Cu", padNets: [String: String] = [:], locked: Bool = false) {
        self.id = id; self.definitionID = definitionID; self.componentID = componentID
        self.reference = reference; self.value = value; self.position = position
        self.angle = angle; self.side = side; self.padNets = padNets; self.locked = locked
    }
    public func point(_ local: EDAPoint) -> EDAPoint {
        local.transformed(origin: position, angle: angle, mirrored: side == "B.Cu")
    }
}

public struct EDATrack: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var netID: String
    public var layer: String
    public var width: Double
    public var points: [EDAPoint]
    public var locked: Bool
    public init(id: UUID = UUID(), netID: String, layer: String = "F.Cu", width: Double = 0.25,
                points: [EDAPoint], locked: Bool = false) {
        self.id = id; self.netID = netID; self.layer = layer; self.width = width
        self.points = points; self.locked = locked
    }
    public var length: Double { zip(points, points.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) } }
}

public struct EDAVia: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var netID: String
    public var position: EDAPoint
    public var diameter: Double
    public var drill: Double
    public var startLayer: String
    public var endLayer: String
    /// Explicit zero-expansion mask openings on reachable outer surfaces.
    /// Nil is unspecified; [] explicitly tents all reachable surfaces.
    public var maskLayers: [String]?
    public init(id: UUID = UUID(), netID: String, position: EDAPoint, diameter: Double = 0.6,
                drill: Double = 0.3, startLayer: String = "F.Cu", endLayer: String = "B.Cu", maskLayers: [String]? = nil) {
        self.id = id; self.netID = netID; self.position = position; self.diameter = diameter
        self.drill = drill; self.startLayer = startLayer; self.endLayer = endLayer; self.maskLayers = maskLayers
    }
}

public enum EDALayerKind: String, Codable, CaseIterable, Sendable { case copper, dielectric, mask, paste, silkscreen, courtyard, fabrication }
public struct EDALayer: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var kind: EDALayerKind
    public var thickness: Double
    public var material: String
    public init(_ id: String, kind: EDALayerKind, thickness: Double = 0, material: String = "") {
        self.id = id; self.kind = kind; self.thickness = thickness; self.material = material
    }
    public static var twoLayer: [Self] {
        [.init("F.Cu", kind: .copper, thickness: 0.035),
         .init("core", kind: .dielectric, thickness: 1.53, material: "FR4"),
         .init("B.Cu", kind: .copper, thickness: 0.035),
         .init("F.Mask", kind: .mask), .init("B.Mask", kind: .mask),
         .init("F.Paste", kind: .paste), .init("B.Paste", kind: .paste),
         .init("F.SilkS", kind: .silkscreen), .init("B.SilkS", kind: .silkscreen)]
    }
}

public struct EDANetClass: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var netNames: Set<String>
    public var clearance: Double
    /// Preferred routing sizes, not DRC minimum constraints.
    public var trackWidth: Double
    public var viaDiameter: Double
    public var viaDrill: Double
    public var differentialGap: Double
    public var targetLength: Double?
    public var maxSkew: Double?
    public init(id: UUID = UUID(), name: String = "Default", netNames: Set<String> = [],
                clearance: Double = 0.2, trackWidth: Double = 0.25, viaDiameter: Double = 0.6,
                viaDrill: Double = 0.3, differentialGap: Double = 0.2,
                targetLength: Double? = nil, maxSkew: Double? = nil) {
        self.id = id; self.name = name; self.netNames = netNames; self.clearance = clearance
        self.trackWidth = trackWidth; self.viaDiameter = viaDiameter; self.viaDrill = viaDrill
        self.differentialGap = differentialGap; self.targetLength = targetLength; self.maxSkew = maxSkew
    }
}

/// Explicit design values. Nil on a legacy thermal zone is unspecified;
/// refill never silently substitutes a thermal connection or a solid pad.
public struct EDAThermalRelief: Codable, Hashable, Sendable {
    public var gap: Double
    public var spokeWidth: Double
    /// Board XY degrees, independent of footprint rotation or board side.
    public var spokeAngleDegrees: Double
    public var spokeCount: Int
    public init(gap: Double, spokeWidth: Double, spokeAngleDegrees: Double, spokeCount: Int) {
        self.gap = gap; self.spokeWidth = spokeWidth
        self.spokeAngleDegrees = spokeAngleDegrees; self.spokeCount = spokeCount
    }
    /// An explicit creation/action choice, never a decoder or refill fallback.
    public static var creationDefault: Self {
        .init(gap: 0.25, spokeWidth: 0.3, spokeAngleDegrees: 45, spokeCount: 4)
    }
}

public enum EDAZoneFillState: String, Codable, Hashable, Sendable { case filled, empty }

public struct EDAZone: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var netID: String
    public var layer: String
    public var outline: [EDAPoint]
    public var priority: Int
    public var clearance: Double
    public var thermal: Bool
    public var thermalRelief: EDAThermalRelief?
    public var filledPolygons: [[EDAPoint]]
    public var fillRevision: UInt64?
    /// Derived by a successful refill commit. Nil preserves legacy semantics.
    public var fillState: EDAZoneFillState?
    public init(id: UUID = UUID(), netID: String, layer: String = "F.Cu", outline: [EDAPoint],
                priority: Int = 0, clearance: Double = 0.2, thermal: Bool = true,
                thermalRelief: EDAThermalRelief? = nil) {
        self.id = id; self.netID = netID; self.layer = layer; self.outline = outline
        self.priority = priority; self.clearance = clearance; self.thermal = thermal
        self.thermalRelief = thermalRelief
        filledPolygons = []; fillRevision = nil; fillState = nil
    }
}

public struct EDAKeepout: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var outline: [EDAPoint]
    public var layers: Set<String>
    public var tracks: Bool
    public var vias: Bool
    /// Restricts filled copper zones; track and via restrictions are independent.
    /// Pad/footprint keepouts are not represented by this model.
    public var copper: Bool
    public init(id: UUID = UUID(), outline: [EDAPoint], layers: Set<String> = ["F.Cu", "B.Cu"],
                tracks: Bool = true, vias: Bool = true, copper: Bool = true) {
        self.id = id; self.outline = outline; self.layers = layers
        self.tracks = tracks; self.vias = vias; self.copper = copper
    }
}

public struct EDAHole: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var position: EDAPoint
    public var diameter: Double
    public var plated: Bool
    /// A nonnil endpoint explicitly defines a straight routed slot of this
    /// finished width. Nil retains the existing circular-hole geometry.
    public var endPosition: EDAPoint?
    public init(id: UUID = UUID(), position: EDAPoint, diameter: Double, plated: Bool = false, endPosition: EDAPoint? = nil) {
        self.id = id; self.position = position; self.diameter = diameter; self.plated = plated; self.endPosition = endPosition
    }
}

public struct EDABoard: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var layers: [EDALayer]
    public var outline: [EDAPoint]
    public var cutouts: [[EDAPoint]]
    public var holes: [EDAHole]
    public var footprints: [EDAFootprint]
    public var tracks: [EDATrack]
    public var vias: [EDAVia]
    public var zones: [EDAZone]
    public var keepouts: [EDAKeepout]
    public var graphics: [EDAGraphic]
    public var graphicLayers: [EDAGraphicLayerAssignment?]?
    public var netClasses: [EDANetClass]
    public var boardEdgeClearance: Double
    /// Nil is unspecified; it is not a non-plated-edge manufacturing instruction.
    public var edgePlated: Bool?
    /// Explicit DRC minima. Nil means not configured, not a manufacturing pass.
    /// Optional so schema-1 originals created before DRC remain readable.
    public var drcConstraints: EDADRCConstraints?
    public init(id: UUID = UUID(), name: String = "Board 1", layers: [EDALayer] = EDALayer.twoLayer,
                outline: [EDAPoint] = [.init(0, 0), .init(100, 0), .init(100, 80), .init(0, 80)]) {
        self.id = id; self.name = name; self.layers = layers; self.outline = outline
        cutouts = []; holes = []; footprints = []; tracks = []; vias = []; zones = []
        keepouts = []; graphics = []; graphicLayers = nil; netClasses = [.init()]; boardEdgeClearance = 0.25
        drcConstraints = nil
        edgePlated = nil
    }
}

public struct EDASimulationSetup: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var analysis: String
    public var parameters: [String: String]
    public var models: [UUID: String]
    public init(id: UUID = UUID(), name: String, analysis: String,
                parameters: [String: String] = [:], models: [UUID: String] = [:]) {
        self.id = id; self.name = name; self.analysis = analysis
        self.parameters = parameters; self.models = models
    }
}

public struct EDAProject: Codable, Hashable, Identifiable, Sendable {
    public var schemaVersion: Int = 1
    public var id: UUID
    public var title: String
    public var revision: UInt64
    public var createdAt: Date
    public var modifiedAt: Date
    public var sheets: [EDASheet]
    public var components: [EDAComponent]
    public var symbols: [EDASymbolDefinition]
    public var footprints: [EDAFootprintDefinition]
    public var boards: [EDABoard]
    public var simulations: [EDASimulationSetup]
    public var variants: [String]
    /// Exact source payloads retained by import adapters, never executable code.
    public var preservedSource: [String: String]
    public init(id: UUID = UUID(), title: String) {
        self.id = id; self.title = title; revision = 0; createdAt = Date(); modifiedAt = createdAt
        sheets = [.init()]; components = []; symbols = []; footprints = []; boards = [.init()]
        simulations = []; variants = ["Default"]; preservedSource = [:]
    }
}
