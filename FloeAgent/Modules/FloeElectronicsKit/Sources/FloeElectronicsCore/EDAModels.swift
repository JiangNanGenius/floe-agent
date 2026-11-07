// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum EDAError: Error, Equatable, Sendable {
    case invalid(String), missing(String), duplicate(String), unsupported(String)
    case staleRevision(expected: UInt64, actual: UInt64)
    case readOnly, cancelled
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
    public init(id: UUID = UUID(), name: String, referencePrefix: String = "U",
                pins: [EDAPin] = [], graphics: [EDAGraphic] = [], fields: [String: String] = [:]) {
        self.id = id; self.name = name; self.referencePrefix = referencePrefix
        self.pins = pins; self.graphics = graphics; self.fields = fields
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

public struct EDABus: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var members: [String]
    public var points: [EDAPoint]
    public init(id: UUID = UUID(), name: String, members: [String], points: [EDAPoint]) {
        self.id = id; self.name = name; self.members = members; self.points = points
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

public enum EDAPadShape: String, Codable, CaseIterable, Sendable { case circle, rectangle, oval, roundRectangle }
public struct EDAPad: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var number: String
    public var position: EDAPoint
    public var size: EDAPoint
    public var angle: Double
    public var shape: EDAPadShape
    public var drill: Double?
    public var layers: [String]
    public init(id: UUID = UUID(), number: String, position: EDAPoint, size: EDAPoint = .init(1.5, 1.5),
                angle: Double = 0, shape: EDAPadShape = .circle, drill: Double? = nil,
                layers: [String] = ["F.Cu"]) {
        self.id = id; self.number = number; self.position = position; self.size = size
        self.angle = angle; self.shape = shape; self.drill = drill; self.layers = layers
    }
}

public struct EDAFootprintDefinition: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var pads: [EDAPad]
    public var graphics: [EDAGraphic]
    public var fields: [String: String]
    public var modelReference: String?
    public init(id: UUID = UUID(), name: String, pads: [EDAPad] = [], graphics: [EDAGraphic] = [],
                fields: [String: String] = [:], modelReference: String? = nil) {
        self.id = id; self.name = name; self.pads = pads; self.graphics = graphics
        self.fields = fields; self.modelReference = modelReference
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
    public init(id: UUID = UUID(), netID: String, position: EDAPoint, diameter: Double = 0.6,
                drill: Double = 0.3, startLayer: String = "F.Cu", endLayer: String = "B.Cu") {
        self.id = id; self.netID = netID; self.position = position; self.diameter = diameter
        self.drill = drill; self.startLayer = startLayer; self.endLayer = endLayer
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

public struct EDAZone: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var netID: String
    public var layer: String
    public var outline: [EDAPoint]
    public var priority: Int
    public var clearance: Double
    public var thermal: Bool
    public var filledPolygons: [[EDAPoint]]
    public var fillRevision: UInt64?
    public init(id: UUID = UUID(), netID: String, layer: String = "F.Cu", outline: [EDAPoint],
                priority: Int = 0, clearance: Double = 0.2, thermal: Bool = true) {
        self.id = id; self.netID = netID; self.layer = layer; self.outline = outline
        self.priority = priority; self.clearance = clearance; self.thermal = thermal
        filledPolygons = []; fillRevision = nil
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
    public init(id: UUID = UUID(), position: EDAPoint, diameter: Double, plated: Bool = false) {
        self.id = id; self.position = position; self.diameter = diameter; self.plated = plated
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
    public var netClasses: [EDANetClass]
    public var boardEdgeClearance: Double
    /// Explicit DRC minima. Nil means not configured, not a manufacturing pass.
    /// Optional so schema-1 originals created before DRC remain readable.
    public var drcConstraints: EDADRCConstraints?
    public init(id: UUID = UUID(), name: String = "Board 1", layers: [EDALayer] = EDALayer.twoLayer,
                outline: [EDAPoint] = [.init(0, 0), .init(100, 0), .init(100, 80), .init(0, 80)]) {
        self.id = id; self.name = name; self.layers = layers; self.outline = outline
        cutouts = []; holes = []; footprints = []; tracks = []; vias = []; zones = []
        keepouts = []; graphics = []; netClasses = [.init()]; boardEdgeClearance = 0.25
        drcConstraints = nil
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
