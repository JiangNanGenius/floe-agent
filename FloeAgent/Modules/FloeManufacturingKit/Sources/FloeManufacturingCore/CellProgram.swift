// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeManufacturingParameters

/// Identified turning tool record. A station may reference either a CAM
/// tool (`Station.toolID`) or one of these (`Station.turningToolID`), never
/// both. The record retains a setup snapshot; its insert geometry must match
/// the study. Operation selection, entry/exit and feeds belong to each study
/// and may differ while using the same physical insert. The nominal nose is 0.4 mm;
/// contract value: any other value is rejected, not adjusted.
public struct CellTurningTool: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var setup: TurningSetup
    public var nominalNoseRadiusMM: Double
    /// Vendor/rare settings preserved verbatim; never an active path input
    /// for the planner.
    public var parameters: ManufacturingParameterSet?
    public init(id: String, name: String, setup: TurningSetup = TurningSetup(),
                nominalNoseRadiusMM: Double = 0.4, parameters: ManufacturingParameterSet? = nil) {
        self.id = id; self.name = name; self.setup = setup
        self.nominalNoseRadiusMM = nominalNoseRadiusMM; self.parameters = parameters
    }
    public func validate() throws {
        try CellCheck.require(CellCheck.id(id) && !name.isEmpty && name.utf8.count <= 512, "turning tool identity \(id)")
        try setup.validate(requireOperations: false)
        try CellCheck.require(abs(nominalNoseRadiusMM - 0.4) < 1e-9, "turning tool \(id) requires the fixed 0.4 mm nominal nose radius")
        if let parameters { try ManufacturingStudy.checkParameterSet(parameters, catalog: .standard) }
    }
    /// Fail-closed match against a study that selects this tool.
    func validate(matching study: ManufacturingStudy) throws {
        try CellCheck.require(study.turning.enabled, "turning tool \(id) selected for a study without turning")
        let effective = study.turningSetup ?? TurningSetup()
        try CellCheck.require(effective.insertShape == setup.insertShape &&
                              effective.insertEdgeLengthMM == setup.insertEdgeLengthMM &&
                              effective.insertRotationDegrees == setup.insertRotationDegrees,
                              "turning tool \(id) insert geometry does not match the study")
        try CellCheck.require(abs(study.turning.toolNoseRadiusMM - nominalNoseRadiusMM) < 1e-9,
                              "turning tool \(id) nose radius does not match the study")
    }
}

/// Uniform resource namespace for cell scheduling. String form is
/// "<kind>:<id>", e.g. "spindle:main". Exclusion groups expand to their
/// member resources, so a step holding one member holds the whole group.
public struct CellResourceID: Codable, Equatable, Sendable, Hashable, Comparable, CustomStringConvertible {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case spindle, turret, workpiece, envelope
    }
    public var kind: Kind
    public var id: String
    public init(_ kind: Kind, _ id: String) { self.kind = kind; self.id = id }
    public var description: String { "\(kind.rawValue):\(id)" }
    public static func < (lhs: CellResourceID, rhs: CellResourceID) -> Bool {
        lhs.description < rhs.description
    }
}

enum CellCheck {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw ManufacturingError.invalid("cell: " + message) }
    }
    static func id(_ s: String) -> Bool {
        !s.isEmpty && s.utf8.count <= 96 && s.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
    }
    static func positive(_ value: Double, max: Double, name: String) throws {
        try require(value.isFinite && value > 0 && value <= max, "\(name) requires a finite value in (0, \(max)]")
    }
    static func nonnegative(_ value: Double, max: Double, name: String) throws {
        try require(value.isFinite && value >= 0 && value <= max, "\(name) requires a finite value in [0, \(max)]")
    }
}

/// Commanded rotation direction about the spindle +Z axis, viewed looking
/// along +Z from the chuck mouth toward the part. This is a commanded
/// direction for scheduling and synchronization, never a measured hardware
/// proof.
public enum CellRotationDirection: String, Codable, Sendable, CaseIterable {
    case cw
    case ccw
    /// Signed multiplier about +Z (cw = +1 by convention above).
    public var sign: Double { self == .cw ? 1 : -1 }
}

/// Dual-/multi-spindle, multi-turret manufacturing cell program: machines,
/// workpieces, channels and an explicit ordered action graph. This is a pure
/// value model; planning happens in `CellPlanner` and execution is owned by
/// Root's `CellEngine`.
///
/// Units: millimetres, degrees, RPM, seconds. A workpiece's material stock
/// stays in immutable workpiece-local coordinates; only `worldFromWorkpiece`
/// (a rigid transform) changes across spindle transfers.
public struct ManufacturingCell: Codable, Equatable, Sendable, Identifiable {
    public struct Spindle: Codable, Equatable, Sendable, Identifiable {
        public enum RotationMode: String, Codable, Sendable, CaseIterable {
            case stopped, rpm, cIndex
        }
        public struct Chuck: Codable, Equatable, Sendable {
            /// Current inner opening diameter of the chuck in mm.
            public var openingDiameterMM: Double
            /// Maximum achievable opening in mm.
            public var maxOpeningDiameterMM: Double
            /// Workpiece clamped right now, if any. Transfer never leaves a
            /// workpiece without an owner spindle.
            public var clampedWorkpieceID: String?
            /// Axial grip length of the clamped part inside the chuck in mm.
            public var gripLengthMM: Double?
            public init(openingDiameterMM: Double, maxOpeningDiameterMM: Double,
                        clampedWorkpieceID: String? = nil, gripLengthMM: Double? = nil) {
                self.openingDiameterMM = openingDiameterMM
                self.maxOpeningDiameterMM = maxOpeningDiameterMM
                self.clampedWorkpieceID = clampedWorkpieceID
                self.gripLengthMM = gripLengthMM
            }
        }
        public var id: String
        public var name: String
        /// Spindle axis frame; origin at the chuck mouth, +Z away from the
        /// chuck into the held part.
        public var frame: CellFrame
        public var maxRPM: Double
        /// Mode at program start. RPM and C-index are distinct states: C
        /// indexing is angular positioning, not continuous rotation.
        public var initialMode: RotationMode
        public var initialRPM: Double?
        public var initialCIndexDegrees: Double?
        /// Explicit physical C-position travel. Nil retains the original
        /// single-turn [0,360) contract; supplied limits retain unwrapped turns.
        public var cAxisTravelDegrees:[Double]?
        /// Commanded rotation direction; required in RPM mode.
        public var initialDirection: CellRotationDirection?
        /// Phase datum in degrees at program start ([0, 360)); required for
        /// phase-matched synchronization and transfers.
        public var initialPhaseDegrees: Double?
        public var chuck: Chuck
        /// Optional exclusion group (shared envelope, e.g. a headstock slide).
        public var exclusionGroupID: String?
        /// Vendor/rare settings preserved verbatim; typed fields own the
        /// active values, same contract as `ManufacturingCAM.Tool`.
        public var parameters: ManufacturingParameterSet?
        public init(id: String, name: String, frame: CellFrame, maxRPM: Double,
                    initialMode: RotationMode = .stopped, initialRPM: Double? = nil,
                    initialCIndexDegrees: Double? = nil,
                    initialDirection: CellRotationDirection? = nil,
                    initialPhaseDegrees: Double? = nil,
                    chuck: Chuck,
                    exclusionGroupID: String? = nil, parameters: ManufacturingParameterSet? = nil,
                    cAxisTravelDegrees:[Double]? = nil) {
            self.id = id; self.name = name; self.frame = frame; self.maxRPM = maxRPM
            self.initialMode = initialMode; self.initialRPM = initialRPM
            self.initialCIndexDegrees = initialCIndexDegrees
            self.initialDirection = initialDirection; self.initialPhaseDegrees = initialPhaseDegrees
            self.chuck = chuck
            self.exclusionGroupID = exclusionGroupID; self.parameters = parameters
            self.cAxisTravelDegrees = cAxisTravelDegrees
        }
        public func containsCPosition(_ value:Double)->Bool {
            guard value.isFinite else { return false }
            if let limits = cAxisTravelDegrees {
                return limits.count == 2 && value >= limits[0] && value <= limits[1]
            }
            return value >= 0 && value < 360
        }
    }

    public struct Turret: Codable, Equatable, Sendable, Identifiable {
        /// A turret station identifies the actual tool it carries. Offsets
        /// are classified by effect: `toolOffsetMM` is a world-axis Cartesian
        /// tool-reference offset (worldToolReferencePaths = worldPaths +
        /// offset; geometry and material never shift); `wearOffsetMM` is
        /// saved wear metadata (not a planner path input; the executor may
        /// apply it to the real cut). `cuttingDiameterMM` remains descriptive
        /// metadata and never establishes tool ownership.
        public struct Station: Codable, Equatable, Sendable, Identifiable {
            public var id: String
            public var name: String
            /// Actual milling/live tool identity: reference into
            /// `ManufacturingCell.tools`.
            public var toolID: String?
            /// Actual turning insert identity: reference into
            /// `ManufacturingCell.turningTools`. Never set together with
            /// `toolID`.
            public var turningToolID: String?
            /// Tool/work offset, mm [x, y, z]. Supported frame: a world-axis
            /// Cartesian offset added to world material TCP paths to form the
            /// tool-reference paths; it never shifts geometry or material.
            public var toolOffsetMM: [Double]?
            /// Saved wear metadata, mm [x, y, z]; not a planner path input.
            public var wearOffsetMM: [Double]?
            public var cuttingDiameterMM: Double?
            public init(id: String, name: String, toolID: String? = nil, turningToolID: String? = nil,
                        toolOffsetMM: [Double]? = nil, wearOffsetMM: [Double]? = nil,
                        cuttingDiameterMM: Double? = nil) {
                self.id = id; self.name = name; self.toolID = toolID
                self.turningToolID = turningToolID
                self.toolOffsetMM = toolOffsetMM; self.wearOffsetMM = wearOffsetMM
                self.cuttingDiameterMM = cuttingDiameterMM
            }
        }
        public var id: String
        public var name: String
        public var stations: [Station]
        public var initialStationID: String
        /// Time for one neighbouring-station index move in seconds.
        public var indexDurationSeconds: Double
        /// Time to park/unpark the whole turret in seconds.
        public var parkDurationSeconds: Double
        public var parkedInitially: Bool
        public var exclusionGroupID: String?
        public var parameters: ManufacturingParameterSet?
        public init(id: String, name: String, stations: [Station], initialStationID: String,
                    indexDurationSeconds: Double, parkDurationSeconds: Double,
                    parkedInitially: Bool = false, exclusionGroupID: String? = nil,
                    parameters: ManufacturingParameterSet? = nil) {
            self.id = id; self.name = name; self.stations = stations
            self.initialStationID = initialStationID
            self.indexDurationSeconds = indexDurationSeconds
            self.parkDurationSeconds = parkDurationSeconds
            self.parkedInitially = parkedInitially
            self.exclusionGroupID = exclusionGroupID; self.parameters = parameters
        }
    }

    /// One CNC channel driving an actual set of spindles and turrets.
    /// Every spindle/turret belongs to exactly one channel; coordination
    /// across channels is expressed only through explicit edges, waits and
    /// barriers, never through shared ownership.
    public struct Channel: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var spindleIDs: [String]
        public var turretIDs: [String]
        public init(id: String, name: String, spindleIDs: [String] = [], turretIDs: [String] = []) {
            self.id = id; self.name = name; self.spindleIDs = spindleIDs; self.turretIDs = turretIDs
        }
    }

    public struct Workpiece: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        /// Immutable source identity; every operation on this part must carry
        /// a study with the same source.
        public var source: ManufacturingStudy.Source
        /// The study whose results define this part's current stock state.
        public var studyID: UUID
        /// Owning spindle at program start; nil only while a transfer holds
        /// the part between chucks (never persisted as a resting state).
        public var ownerSpindleID: String?
        /// Current placement of the immutable workpiece-local material
        /// coordinates in world. Transfer changes this transform only.
        public var worldFromWorkpiece: CellRigidTransform
        /// Axial grip currently inside the owner chuck in mm; 0 when unclamped.
        public var gripLengthMM: Double
        /// Overall axial length in mm; enables honest chuck-opening checks.
        public var lengthMM: Double?
        /// Envelope radius in mm for receiver-opening and clearance checks.
        public var envelopeRadiusMM: Double?
        public var parameters: ManufacturingParameterSet?
        public init(id: String, name: String, source: ManufacturingStudy.Source, studyID: UUID,
                    ownerSpindleID: String?, worldFromWorkpiece: CellRigidTransform,
                    gripLengthMM: Double, lengthMM: Double? = nil, envelopeRadiusMM: Double? = nil,
                    parameters: ManufacturingParameterSet? = nil) {
            self.id = id; self.name = name; self.source = source; self.studyID = studyID
            self.ownerSpindleID = ownerSpindleID
            self.worldFromWorkpiece = worldFromWorkpiece
            self.gripLengthMM = gripLengthMM; self.lengthMM = lengthMM
            self.envelopeRadiusMM = envelopeRadiusMM; self.parameters = parameters
        }
    }

    /// Shared-envelope exclusion set. While any member resource is held, no
    /// other step may hold any member (e.g. two turrets sharing one slide).
    public struct ExclusionGroup: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var resources: [CellResourceID]
        public init(id: String, resources: [CellResourceID]) { self.id = id; self.resources = resources }
    }

    public struct Budget: Codable, Equatable, Sendable {
        public var maxSteps = 4096
        public var maxSimulatedSeconds = 1e6
        public var maxEvents = 10_000_000
        public init(maxSteps: Int = 4096, maxSimulatedSeconds: Double = 1e6, maxEvents: Int = 10_000_000) {
            self.maxSteps = maxSteps; self.maxSimulatedSeconds = maxSimulatedSeconds; self.maxEvents = maxEvents
        }
    }

    /// Rare machine options kept explicitly instead of being dropped. All
    /// values are optional; absence selects the planner default, never a
    /// guessed machine constant.
    public struct UncommonOptions: Codable, Equatable, Sendable {
        /// Angular tolerance for "spindle axes parallel/antiparallel" during
        /// transfer frame checks. Default 1 degree.
        public var transferAxisToleranceDegrees: Double?
        /// Fallback clearance when an action leaves it unset.
        public var defaultApproachClearanceMM: Double?
        /// Explicitly permit finished parts to be released to a part catcher
        /// (unowned resting state). Default false: a release always requires
        /// another holder so the last grip is never dropped.
        public var allowsPartEject: Bool?
        /// Free-form vendor note, preserved for archive fidelity.
        public var notes: String?
        public init(transferAxisToleranceDegrees: Double? = nil, defaultApproachClearanceMM: Double? = nil,
                    allowsPartEject: Bool? = nil, notes: String? = nil) {
            self.transferAxisToleranceDegrees = transferAxisToleranceDegrees
            self.defaultApproachClearanceMM = defaultApproachClearanceMM
            self.allowsPartEject = allowsPartEject
            self.notes = notes
        }
    }

    public var formatVersion = 1
    public var id = UUID()
    public var name: String
    /// Actual tool inventory referenced by turret stations. Tool ownership
    /// is always through `Turret.Station.toolID` /
    /// `Turret.Station.turningToolID`, never through a diameter.
    public var tools: [ManufacturingCAM.Tool]
    /// Identified turning insert records referenced by stations.
    public var turningTools: [CellTurningTool]
    public var spindles: [Spindle]
    public var turrets: [Turret]
    public var channels: [Channel]
    public var workpieces: [Workpiece]
    public var exclusionGroups: [ExclusionGroup]
    public var uncommon: UncommonOptions?
    public var budget = Budget()
    public var steps: [CellStep]
    /// Named wait registry: `.wait(pointName:)` resolves against this list;
    /// an unresolved name fails closed at validation time.
    public var waitPoints: [CellNamedWaitPoint]
    /// Explicit cross-channel dependencies.
    public var edges: [CellEdge]
    public var parameters: ManufacturingParameterSet?

    public init(id: UUID = UUID(), name: String, tools: [ManufacturingCAM.Tool] = [],
                turningTools: [CellTurningTool] = [], spindles: [Spindle], turrets: [Turret],
                channels: [Channel], workpieces: [Workpiece],
                exclusionGroups: [ExclusionGroup] = [], uncommon: UncommonOptions? = nil,
                budget: Budget = Budget(), steps: [CellStep],
                waitPoints: [CellNamedWaitPoint] = [], edges: [CellEdge] = [],
                parameters: ManufacturingParameterSet? = nil) {
        self.id = id; self.name = name; self.tools = tools
        self.turningTools = turningTools
        self.spindles = spindles; self.turrets = turrets
        self.channels = channels; self.workpieces = workpieces
        self.exclusionGroups = exclusionGroups; self.uncommon = uncommon
        self.budget = budget; self.steps = steps; self.waitPoints = waitPoints
        self.edges = edges; self.parameters = parameters
    }

    // MARK: - Lookup helpers

    public func spindle(_ id: String) -> Spindle? { spindles.first { $0.id == id } }
    public func turret(_ id: String) -> Turret? { turrets.first { $0.id == id } }
    public func channel(_ id: String) -> Channel? { channels.first { $0.id == id } }
    public func workpiece(_ id: String) -> Workpiece? { workpieces.first { $0.id == id } }
    public func tool(_ id: String) -> ManufacturingCAM.Tool? { tools.first { $0.id == id } }
    public func turningTool(_ id: String) -> CellTurningTool? { turningTools.first { $0.id == id } }

    /// Resources expanded by exclusion groups: holding any member implies
    /// holding every member of each group that contains it.
    public func expandedResources(_ base: [CellResourceID]) -> [CellResourceID] {
        var result = Set(base)
        for group in exclusionGroups where group.resources.contains(where: { result.contains($0) }) {
            result.formUnion(group.resources)
        }
        return result.sorted()
    }

    // MARK: - Validation

    public func validate() throws {
        func require(_ condition: Bool, _ reason: String) throws { try CellCheck.require(condition, reason) }
        try require(formatVersion == 1, "unsupported version; keep original file")
        try require(!name.isEmpty && name.utf8.count <= 512, "name")
        try require((1...budget.maxSteps).contains(steps.count), "step count")
        try require(budget.maxSimulatedSeconds.isFinite && budget.maxSimulatedSeconds > 0 && budget.maxSimulatedSeconds <= 1e9, "simulated seconds budget")
        try require((1...10_000_000).contains(budget.maxEvents), "event budget")
        try require(!spindles.isEmpty, "at least one spindle")
        try require(Set(spindles.map(\.id)).count == spindles.count, "duplicate spindle id")
        try require(Set(turrets.map(\.id)).count == turrets.count, "duplicate turret id")
        try require(Set(channels.map(\.id)).count == channels.count, "duplicate channel id")
        try require(Set(workpieces.map(\.id)).count == workpieces.count, "duplicate workpiece id")
        try require(Set(exclusionGroups.map(\.id)).count == exclusionGroups.count, "duplicate exclusion group id")
        try require(Set(tools.map(\.id)).count == tools.count, "duplicate tool id")
        try require(Set(turningTools.map(\.id)).count == turningTools.count, "duplicate turning tool id")
        for tool in tools { try tool.validate() }
        for turningTool in turningTools { try turningTool.validate() }
        for spindle in spindles {
            try require(CellCheck.id(spindle.id) && !spindle.name.isEmpty && spindle.name.utf8.count <= 512, "spindle identity \(spindle.id)")
            try spindle.frame.validate()
            try CellCheck.positive(spindle.maxRPM, max: 100_000, name: "spindle \(spindle.id) max RPM")
            try CellCheck.positive(spindle.chuck.maxOpeningDiameterMM, max: 10_000, name: "spindle \(spindle.id) chuck opening")
            try CellCheck.positive(spindle.chuck.openingDiameterMM, max: 10_000, name: "spindle \(spindle.id) current opening")
            try require(spindle.chuck.openingDiameterMM <= spindle.chuck.maxOpeningDiameterMM, "spindle \(spindle.id) opening exceeds maximum")
            if let travel = spindle.cAxisTravelDegrees {
                try require(travel.count == 2 && travel.allSatisfy({ $0.isFinite && abs($0)<=1e6 }) && travel[0]<travel[1],
                            "spindle \(spindle.id) C travel requires finite ordered unwrapped limits")
            }
            switch spindle.initialMode {
            case .stopped:
                try require(spindle.initialRPM == nil && spindle.initialCIndexDegrees == nil,
                            "spindle \(spindle.id) stopped mode carries rpm/C values")
                try require(spindle.initialDirection == nil, "spindle \(spindle.id) stopped mode carries a direction")
            case .rpm:
                try require(spindle.initialRPM.map { $0.isFinite && $0 > 0 && $0 <= spindle.maxRPM } ?? false, "spindle \(spindle.id) initial RPM within limits")
                try require(spindle.initialCIndexDegrees == nil, "spindle \(spindle.id) rpm mode carries a C value")
                try require(spindle.initialDirection != nil, "spindle \(spindle.id) rpm mode requires a commanded direction")
            case .cIndex:
                try require(spindle.initialCIndexDegrees.map { spindle.containsCPosition($0) } ?? false, "spindle \(spindle.id) initial C index outside declared travel (default [0, 360))")
                try require(spindle.initialRPM == nil, "spindle \(spindle.id) C-index mode carries an RPM value")
                try require(spindle.initialDirection == nil, "spindle \(spindle.id) C-index mode carries a direction")
            }
            if let phase = spindle.initialPhaseDegrees {
                try CellCheck.require(phase.isFinite && phase >= 0 && phase < 360, "spindle \(spindle.id) initial phase in [0, 360)")
            }
            if let clamped = spindle.chuck.clampedWorkpieceID {
                let part = workpiece(clamped)
                try require(part != nil && part!.ownerSpindleID == spindle.id, "spindle \(spindle.id) clamps unknown or mismatched workpiece \(clamped)")
                try CellCheck.positive(spindle.chuck.gripLengthMM ?? 0, max: 10_000, name: "spindle \(spindle.id) grip length")
            } else {
                try require(spindle.chuck.gripLengthMM == nil, "spindle \(spindle.id) empty chuck carries a grip length")
            }
            try require(spindle.exclusionGroupID == nil || exclusionGroups.contains { $0.id == spindle.exclusionGroupID }, "spindle \(spindle.id) unknown exclusion group")
            if let parameters = spindle.parameters { try ManufacturingStudy.checkParameterSet(parameters, catalog: .standard) }
        }
        for turret in turrets {
            try require(CellCheck.id(turret.id) && !turret.name.isEmpty && turret.name.utf8.count <= 512, "turret identity \(turret.id)")
            try require((1...24).contains(turret.stations.count), "turret \(turret.id) station count")
            try require(Set(turret.stations.map(\.id)).count == turret.stations.count, "turret \(turret.id) duplicate station id")
            try require(turret.stations.contains { $0.id == turret.initialStationID }, "turret \(turret.id) initial station missing")
            try CellCheck.positive(turret.indexDurationSeconds, max: 60, name: "turret \(turret.id) index duration")
            try CellCheck.positive(turret.parkDurationSeconds, max: 600, name: "turret \(turret.id) park duration")
            for station in turret.stations {
                if let diameter = station.cuttingDiameterMM {
                    try CellCheck.positive(diameter, max: 1_000, name: "turret \(turret.id) station \(station.id) diameter")
                }
                try require(station.toolID == nil || station.turningToolID == nil,
                            "turret \(turret.id) station \(station.id) cannot hold both a CAM tool and a turning tool")
                if let toolID = station.toolID {
                    try require(self.tool(toolID) != nil, "turret \(turret.id) station \(station.id) references unknown tool \(toolID)")
                }
                if let turningToolID = station.turningToolID {
                    try require(self.turningTool(turningToolID) != nil, "turret \(turret.id) station \(station.id) references unknown turning tool \(turningToolID)")
                }
                for (label, offset) in [("tool offset", station.toolOffsetMM), ("wear offset", station.wearOffsetMM)] {
                    if let offset {
                        try require(offset.count == 3 && offset.allSatisfy { $0.isFinite && abs($0) <= 10_000 },
                                    "turret \(turret.id) station \(station.id) \(label) requires 3 finite values")
                    }
                }
            }
            try require(turret.exclusionGroupID == nil || exclusionGroups.contains { $0.id == turret.exclusionGroupID }, "turret \(turret.id) unknown exclusion group")
            if let parameters = turret.parameters { try ManufacturingStudy.checkParameterSet(parameters, catalog: .standard) }
        }
        var ownership = [String: String]()
        for channel in channels {
            try require(CellCheck.id(channel.id) && !channel.name.isEmpty && channel.name.utf8.count <= 512, "channel identity \(channel.id)")
            for spindleID in channel.spindleIDs {
                try require(spindle(spindleID) != nil, "channel \(channel.id) unknown spindle \(spindleID)")
                try require(ownership["spindle:" + spindleID] == nil, "spindle \(spindleID) owned by more than one channel")
                ownership["spindle:" + spindleID] = channel.id
            }
            for turretID in channel.turretIDs {
                try require(turret(turretID) != nil, "channel \(channel.id) unknown turret \(turretID)")
                try require(ownership["turret:" + turretID] == nil, "turret \(turretID) owned by more than one channel")
                ownership["turret:" + turretID] = channel.id
            }
        }
        for spindle in spindles { try require(ownership["spindle:" + spindle.id] != nil, "spindle \(spindle.id) not owned by any channel") }
        for turret in turrets { try require(ownership["turret:" + turret.id] != nil, "turret \(turret.id) not owned by any channel") }
        for part in workpieces {
            try require(CellCheck.id(part.id) && !part.name.isEmpty && part.name.utf8.count <= 512, "workpiece identity \(part.id)")
            try require(!part.source.documentID.isEmpty && part.source.revision >= 0 &&
                        part.source.contentSHA256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil, "workpiece \(part.id) source identity")
            try part.worldFromWorkpiece.validate()
            try CellCheck.nonnegative(part.gripLengthMM, max: 10_000, name: "workpiece \(part.id) grip length")
            if let length = part.lengthMM { try CellCheck.positive(length, max: 100_000, name: "workpiece \(part.id) length") }
            if let radius = part.envelopeRadiusMM { try CellCheck.positive(radius, max: 10_000, name: "workpiece \(part.id) envelope radius") }
            if let owner = part.ownerSpindleID {
                let host = spindle(owner)
                try require(host != nil, "workpiece \(part.id) unknown owner spindle \(owner)")
                try require(host!.chuck.clampedWorkpieceID == part.id, "workpiece \(part.id) owner chuck does not clamp it")
                try CellCheck.positive(part.gripLengthMM, max: 10_000, name: "workpiece \(part.id) grip while owned")
            } else {
                try require(part.gripLengthMM == 0, "unowned workpiece \(part.id) must not carry a grip")
            }
            if let parameters = part.parameters { try ManufacturingStudy.checkParameterSet(parameters, catalog: .standard) }
        }
        for group in exclusionGroups {
            try require(CellCheck.id(group.id), "exclusion group identity \(group.id)")
            try require(group.resources.count >= 2, "exclusion group \(group.id) needs at least two members")
            try require(Set(group.resources).count == group.resources.count, "exclusion group \(group.id) duplicate member")
            for resource in group.resources {
                switch resource.kind {
                case .spindle: try require(spindle(resource.id) != nil, "exclusion group \(group.id) unknown spindle \(resource.id)")
                case .turret: try require(turret(resource.id) != nil, "exclusion group \(group.id) unknown turret \(resource.id)")
                case .workpiece: try require(workpiece(resource.id) != nil, "exclusion group \(group.id) unknown workpiece \(resource.id)")
                case .envelope: break
                }
            }
        }
        if let uncommon {
            if let tolerance = uncommon.transferAxisToleranceDegrees {
                try CellCheck.positive(tolerance, max: 45, name: "transfer axis tolerance")
            }
            if let clearance = uncommon.defaultApproachClearanceMM {
                try CellCheck.positive(clearance, max: 10_000, name: "default approach clearance")
            }
            if let notes = uncommon.notes { try require(notes.utf8.count <= 4096, "uncommon notes length") }
        }
        // Steps: identity, channel order contiguity, payload references.
        try require(Set(steps.map(\.id)).count == steps.count, "duplicate step id")
        var orderByChannel = [String: [Int]]()
        for step in steps {
            try require(CellCheck.id(step.id), "step identity \(step.id)")
            try require(channel(step.channelID) != nil, "step \(step.id) unknown channel \(step.channelID)")
            try step.action.validate(stepID: step.id, cell: self)
            orderByChannel[step.channelID, default: []].append(step.order)
            if let parameters = step.parameters { try ManufacturingStudy.checkParameterSet(parameters, catalog: .standard) }
        }
        for (channelID, orders) in orderByChannel {
            try require(orders.sorted() == Array(0..<orders.count), "channel \(channelID) step order must be 0..<n without gaps or duplicates")
        }
        for point in waitPoints {
            try require(CellCheck.id(point.name), "wait point identity \(point.name)")
            try require(!point.stepIDs.isEmpty, "wait point \(point.name) has no steps")
            try require(Set(point.stepIDs).count == point.stepIDs.count, "wait point \(point.name) duplicate step")
            for target in point.stepIDs { try require(steps.contains { $0.id == target }, "wait point \(point.name) unknown step \(target)") }
        }
        try require(Set(waitPoints.map(\.name)).count == waitPoints.count, "duplicate wait point name")
        for step in steps {
            if case .wait(let wait) = step.action {
                try require(waitPoints.contains { $0.name == wait.pointName }, "step \(step.id) wait point \(wait.pointName) does not resolve")
            }
            if case .barrier(let barrier) = step.action {
                let participants = barrier.channelIDs.isEmpty ? channels.map(\.id) : barrier.channelIDs
                try require(participants.contains(step.channelID), "barrier \(step.id) must list its own channel \(step.channelID)")
                for channelID in participants { try require(channel(channelID) != nil, "barrier \(step.id) unknown channel \(channelID)") }
                try require(Set(participants).count == participants.count, "barrier \(step.id) duplicate channel")
            }
        }
        try require(Set(edges.map { $0.from + "\u{1f}" + $0.to }).count == edges.count, "duplicate edge")
        for edge in edges {
            try require(edge.from != edge.to, "self edge \(edge.from)")
            try require(steps.contains { $0.id == edge.from }, "edge from unknown step \(edge.from)")
            try require(steps.contains { $0.id == edge.to }, "edge to unknown step \(edge.to)")
        }
        if let parameters { try ManufacturingStudy.checkParameterSet(parameters, catalog: .standard) }
    }
}

public struct CellEdge: Codable, Equatable, Sendable {
    /// Producer step: `to` cannot start until `from` has completed.
    public var from: String
    public var to: String
    public init(from: String, to: String) { self.from = from; self.to = to }
}

public struct CellNamedWaitPoint: Codable, Equatable, Sendable {
    public var name: String
    public var stepIDs: [String]
    public init(name: String, stepIDs: [String]) { self.name = name; self.stepIDs = stepIDs }
}

/// One ordered action inside a channel. Order within the channel plus the
/// explicit edges, wait points and barriers form the complete dependency
/// graph; nothing is implicit.
public struct CellStep: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var channelID: String
    /// Position inside the channel: each channel's orders are exactly 0..<n.
    public var order: Int
    public var action: CellAction
    public var parameters: ManufacturingParameterSet?
    public init(id: String, channelID: String, order: Int, action: CellAction,
                parameters: ManufacturingParameterSet? = nil) {
        self.id = id; self.channelID = channelID; self.order = order
        self.action = action; self.parameters = parameters
    }
}

/// Action payloads. Every duration is explicit machine time in seconds;
/// where a duration can be derived from machine constants (turret index/park)
/// it may be omitted and the derivation is stated on the payload.
public enum CellAction: Codable, Equatable, Sendable {
    case approach(CellApproach)
    case retract(CellRetract)
    case parkTurret(CellParkTurret)
    case indexTurret(CellIndexTurret)
    case dwell(CellDwell)
    case spindle(CellSpindleCommand)
    case chuck(CellChuckCommand)
    case synchronize(CellSynchronize)
    case transfer(CellTransfer)
    case wait(CellWait)
    case barrier(CellBarrier)
    case operate(CellOperation)
}

public struct CellApproach: Codable, Equatable, Sendable {
    public var turretID: String
    public var spindleID: String
    public var workpieceID: String?
    public var durationSeconds: Double
    public var clearanceMM: Double
    public init(turretID: String, spindleID: String, workpieceID: String? = nil,
                durationSeconds: Double, clearanceMM: Double) {
        self.turretID = turretID; self.spindleID = spindleID; self.workpieceID = workpieceID
        self.durationSeconds = durationSeconds; self.clearanceMM = clearanceMM
    }
}

public struct CellRetract: Codable, Equatable, Sendable {
    public var turretID: String
    public var spindleID: String?
    public var durationSeconds: Double
    public init(turretID: String, spindleID: String? = nil, durationSeconds: Double) {
        self.turretID = turretID; self.spindleID = spindleID; self.durationSeconds = durationSeconds
    }
}

public struct CellParkTurret: Codable, Equatable, Sendable {
    public var turretID: String
    /// nil derives from `Turret.parkDurationSeconds`.
    public var durationSeconds: Double?
    public init(turretID: String, durationSeconds: Double? = nil) {
        self.turretID = turretID; self.durationSeconds = durationSeconds
    }
}

public struct CellIndexTurret: Codable, Equatable, Sendable {
    public var turretID: String
    public var stationID: String
    /// nil derives from `Turret.indexDurationSeconds` times the station
    /// distance along the shortest direction.
    public var durationSeconds: Double?
    public init(turretID: String, stationID: String, durationSeconds: Double? = nil) {
        self.turretID = turretID; self.stationID = stationID; self.durationSeconds = durationSeconds
    }
}

public struct CellDwell: Codable, Equatable, Sendable {
    public var seconds: Double
    /// Optional part held stationary during the dwell (adds it as a resource).
    public var workpieceID: String?
    public init(seconds: Double, workpieceID: String? = nil) {
        self.seconds = seconds; self.workpieceID = workpieceID
    }
}

public struct CellSpindleCommand: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable, CaseIterable {
        case stopped, rpm, cIndex
    }
    public var spindleID: String
    public var mode: Mode
    public var rpm: Double?
    public var cIndexDegrees: Double?
    /// Commanded direction about +Z; required in RPM mode, nil otherwise.
    public var direction: CellRotationDirection?
    /// Explicit ramp/settle time; no transient time is ever synthesized.
    public var durationSeconds: Double
    public init(spindleID: String, mode: Mode, rpm: Double? = nil, cIndexDegrees: Double? = nil,
                direction: CellRotationDirection? = nil, durationSeconds: Double) {
        self.spindleID = spindleID; self.mode = mode; self.rpm = rpm
        self.cIndexDegrees = cIndexDegrees; self.direction = direction
        self.durationSeconds = durationSeconds
    }
}

public struct CellChuckCommand: Codable, Equatable, Sendable {
    public enum Operation: String, Codable, Sendable, CaseIterable {
        /// Open the chuck to a diameter; part must already be unclamped.
        case open
        /// Clamp a specific workpiece with an explicit axial grip.
        case clamp
        /// Release whatever is clamped; the part must already be re-gripped.
        case release
    }
    public var spindleID: String
    public var operation: Operation
    public var openDiameterMM: Double?
    public var workpieceID: String?
    public var gripLengthMM: Double?
    public var durationSeconds: Double
    public init(spindleID: String, operation: Operation, openDiameterMM: Double? = nil,
                workpieceID: String? = nil, gripLengthMM: Double? = nil, durationSeconds: Double) {
        self.spindleID = spindleID; self.operation = operation
        self.openDiameterMM = openDiameterMM; self.workpieceID = workpieceID
        self.gripLengthMM = gripLengthMM; self.durationSeconds = durationSeconds
    }
}

public struct CellSynchronize: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable, CaseIterable {
        /// Continuous matched rotation: receiver RPM = donor RPM × speedRatio,
        /// with an explicit phase tolerance and a commanded target phase
        /// offset at acquisition.
        case matchedRPM
        /// Both spindles in the commanded stopped state.
        case bothStopped
    }
    /// Exactly two spindles.
    public var spindleIDs: [String]
    public var mode: Mode
    /// receiver/donor ratio for matchedRPM; default 1.
    public var speedRatio: Double?
    /// Required for matchedRPM, in degrees.
    public var phaseToleranceDegrees: Double?
    /// Commanded receiver-minus-donor phase at acquisition in degrees
    /// ([-360, 360)); default 0. This is a commanded datum, not a measured
    /// hardware proof. The reference phase is mapped through the axis
    /// relationship; acquisition changes the receiver chuck datum, not
    /// the material orientation.
    public var targetPhaseOffsetDegrees: Double?
    /// Explicit sync acquisition time in seconds.
    public var durationSeconds: Double
    public init(spindleIDs: [String], mode: Mode, speedRatio: Double? = nil,
                phaseToleranceDegrees: Double? = nil, targetPhaseOffsetDegrees: Double? = nil,
                durationSeconds: Double) {
        self.spindleIDs = spindleIDs; self.mode = mode; self.speedRatio = speedRatio
        self.phaseToleranceDegrees = phaseToleranceDegrees
        self.targetPhaseOffsetDegrees = targetPhaseOffsetDegrees
        self.durationSeconds = durationSeconds
    }
}

/// Handoff of a workpiece between two spindle chucks. Preconditions are
/// enforced by the planner against the simulated machine state and fail
/// closed: both spindles stopped or synchronized, receiver chuck open wide
/// enough, explicit positive receiver grip (a part is never handed over with
/// zero grip — the last grip is never dropped), and an acquisition position
/// whose grip interval physically overlaps the held part. Ownership moves
/// only after the receiver acquires the part; the donor releases afterwards.
/// While both chucks grip, the part is never teleported or flipped; after
/// donor release the receiver retract translates the part rigidly by the
/// carriage displacement. The workpiece transform is updated rigidly;
/// material is never reinitialised or resampled.
public struct CellTransfer: Codable, Equatable, Sendable {
    public var donorSpindleID: String
    public var receiverSpindleID: String
    public var workpieceID: String
    /// Axial grip the receiver chuck takes, in mm; must be > 0 and within the
    /// clamped length.
    public var receiverGripLengthMM: Double
    /// Radial clearance between receiver chuck and part envelope in mm.
    public var clearanceMM: Double
    /// Rotation about the spindle axis applied by the receiver grip, in
    /// degrees. Default 0 keeps the angular datum.
    public var twistDegrees: Double
    /// World position of the receiver chuck mouth at acquisition in mm. The
    /// grip interval runs from here along the receiver axis into the part
    /// and must overlap the actual part extent; a remote chuck that cannot
    /// reach the part fails closed instead of silently passing.
    public var acquisitionOriginMM: [Double]
    /// Optional world position the receiver carriage retracts to after the
    /// donor releases, in mm. The part translates rigidly by this
    /// displacement; occupancy is unchanged.
    public var retractOriginMM: [Double]?
    /// Explicit transfer move time in seconds (approach + handover +
    /// retract), including its internal acquire/release ordering.
    public var durationSeconds: Double
    public init(donorSpindleID: String, receiverSpindleID: String, workpieceID: String,
                receiverGripLengthMM: Double, clearanceMM: Double, twistDegrees: Double = 0,
                acquisitionOriginMM: [Double], retractOriginMM: [Double]? = nil,
                durationSeconds: Double) {
        self.donorSpindleID = donorSpindleID
        self.receiverSpindleID = receiverSpindleID
        self.workpieceID = workpieceID
        self.receiverGripLengthMM = receiverGripLengthMM
        self.clearanceMM = clearanceMM
        self.twistDegrees = twistDegrees
        self.acquisitionOriginMM = acquisitionOriginMM
        self.retractOriginMM = retractOriginMM
        self.durationSeconds = durationSeconds
    }
}

public struct CellWait: Codable, Equatable, Sendable {
    /// Name in `ManufacturingCell.waitPoints`; must resolve.
    public var pointName: String
    public init(pointName: String) { self.pointName = pointName }
}

/// Collective barrier: no listed channel proceeds past it until every listed
/// channel has arrived. Arrival means all of that channel's steps that do not
/// transitively depend on this barrier have completed.
public struct CellBarrier: Codable, Equatable, Sendable {
    /// Participating channels; must include the barrier step's own channel.
    /// An empty list means every channel in the cell.
    public var channelIDs: [String]
    public init(channelIDs: [String] = []) { self.channelIDs = channelIDs }
}

/// A manufacturing job executed on one channel against one workpiece. The
/// embedded study is the exact native input (Root's executor calls
/// `compute(study, startingStock:)`); `stockDependencyIDs` name the prior
/// steps whose stock state must flow into this operation, in order.
public struct CellOperation: Codable, Equatable, Sendable {
    /// Provenance of `durationSeconds`: `.supplied` is a user-supplied
    /// nominal time; `.cuttingTimeline` was patched from a computed
    /// `CuttingTimeline.totalSeconds` after a real native run. Durations are
    /// nominal machine time, never solver wall time.
    public enum DurationProvenance: String, Codable, Sendable, CaseIterable {
        case supplied, cuttingTimeline
    }
    public var study: ManufacturingStudy
    public var workpieceID: String
    public var spindleID: String
    public var turretID: String?
    public var stationID: String?
    /// Actual milling/live tool expected at the selected station; when set,
    /// the station's `toolID` must match and the tool must be one of the
    /// study's active tools.
    public var toolID: String?
    /// Identified turning insert expected at the selected station; mutually
    /// exclusive with `toolID`. A study with more than one active tool
    /// refuses to run without an explicit station/tool selection and a
    /// preceding index schedule.
    public var turningToolID: String?
    /// Optional work offset in mm; uncommon, stored explicitly. Affects
    /// commanded paths (unlike station wear metadata).
    public var workOffsetMM: [Double]?
    /// Nominal operation time in seconds. The planner never invents cutting
    /// time: it is either supplied or patched from a computed timeline.
    public var durationSeconds: Double
    public var durationProvenance: DurationProvenance
    /// Ordered prior step ids whose stock state this operation continues.
    public var stockDependencyIDs: [String]
    public init(study: ManufacturingStudy, workpieceID: String, spindleID: String,
                turretID: String? = nil, stationID: String? = nil, toolID: String? = nil,
                turningToolID: String? = nil, workOffsetMM: [Double]? = nil,
                durationSeconds: Double, durationProvenance: DurationProvenance = .supplied,
                stockDependencyIDs: [String] = []) {
        self.study = study; self.workpieceID = workpieceID; self.spindleID = spindleID
        self.turretID = turretID; self.stationID = stationID; self.toolID = toolID
        self.turningToolID = turningToolID
        self.workOffsetMM = workOffsetMM
        self.durationSeconds = durationSeconds
        self.durationProvenance = durationProvenance
        self.stockDependencyIDs = stockDependencyIDs
    }
    /// Tools the study actually cuts with: enabled CAM operations' tool ids
    /// plus the explicit legacy identities (`turningToolID` while turning is
    /// enabled, `millingToolID` while the legacy slot is enabled). Studies
    /// lacking those identities fail closed: a station diameter never
    /// establishes tool ownership.
    public static func activeToolIDs(of study: ManufacturingStudy) -> Set<String> {
        var ids = Set<String>()
        if let cam = study.cam {
            for operation in cam.operations where operation.enabled { ids.insert(operation.toolID) }
        }
        if study.turning.enabled, let id = study.turningToolID, !id.isEmpty { ids.insert(id) }
        if study.milling.enabled, let id = study.millingToolID, !id.isEmpty { ids.insert(id) }
        return ids
    }
    /// Patch the nominal duration from a computed timeline without touching
    /// geometry. The executor calls this after a real native run whose
    /// result carries a `cuttingTimeline`; the schedule remains structurally
    /// identical apart from this step's occupancy, which Root re-plans.
    public func patchingDuration(from timeline: CuttingTimeline) throws -> Self {
        var copy = self
        copy.durationSeconds = timeline.totalSeconds
        copy.durationProvenance = .cuttingTimeline
        return copy
    }
    public func patchingDuration(seconds: Double) throws -> Self {
        guard seconds.isFinite && seconds > 0 && seconds <= 1e6 else {
            throw ManufacturingError.invalid("cell operation: patched duration requires a finite value in (0, 1e6]")
        }
        var copy = self
        copy.durationSeconds = seconds
        copy.durationProvenance = .cuttingTimeline
        return copy
    }
}

extension CellAction {
    /// Reference and unit validation that does not need any simulation state.
    func validate(stepID: String, cell: ManufacturingCell) throws {
        func require(_ condition: Bool, _ reason: String) throws { try CellCheck.require(condition, reason) }
        switch self {
        case .approach(let approach):
            try require(cell.turret(approach.turretID) != nil, "step \(stepID) unknown turret \(approach.turretID)")
            try require(cell.spindle(approach.spindleID) != nil, "step \(stepID) unknown spindle \(approach.spindleID)")
            if let part = approach.workpieceID { try require(cell.workpiece(part) != nil, "step \(stepID) unknown workpiece \(part)") }
            try CellCheck.positive(approach.durationSeconds, max: 1e5, name: "step \(stepID) approach duration")
            try CellCheck.nonnegative(approach.clearanceMM, max: 10_000, name: "step \(stepID) approach clearance")
        case .retract(let retract):
            try require(cell.turret(retract.turretID) != nil, "step \(stepID) unknown turret \(retract.turretID)")
            if let spindleID = retract.spindleID { try require(cell.spindle(spindleID) != nil, "step \(stepID) unknown spindle \(spindleID)") }
            try CellCheck.positive(retract.durationSeconds, max: 1e5, name: "step \(stepID) retract duration")
        case .parkTurret(let park):
            try require(cell.turret(park.turretID) != nil, "step \(stepID) unknown turret \(park.turretID)")
            if let duration = park.durationSeconds { try CellCheck.positive(duration, max: 1e3, name: "step \(stepID) park duration") }
        case .indexTurret(let index):
            let turret = cell.turret(index.turretID)
            try require(turret != nil, "step \(stepID) unknown turret \(index.turretID)")
            try require(turret!.stations.contains { $0.id == index.stationID }, "step \(stepID) unknown station \(index.stationID) on turret \(index.turretID)")
            if let duration = index.durationSeconds { try CellCheck.positive(duration, max: 1e3, name: "step \(stepID) index duration") }
        case .dwell(let dwell):
            try CellCheck.positive(dwell.seconds, max: 1e5, name: "step \(stepID) dwell seconds")
            if let part = dwell.workpieceID { try require(cell.workpiece(part) != nil, "step \(stepID) unknown workpiece \(part)") }
        case .spindle(let command):
            let spindle = cell.spindle(command.spindleID)
            try require(spindle != nil, "step \(stepID) unknown spindle \(command.spindleID)")
            switch command.mode {
            case .stopped:
                try require(command.rpm == nil && command.cIndexDegrees == nil, "step \(stepID) stopped spindle carries rpm/C values")
                try require(command.direction == nil, "step \(stepID) stopped spindle carries a direction")
            case .rpm:
                try require(command.rpm.map { $0.isFinite && $0 > 0 && $0 <= spindle!.maxRPM } ?? false, "step \(stepID) RPM within spindle \(command.spindleID) limits")
                try require(command.cIndexDegrees == nil, "step \(stepID) rpm command carries a C value")
                try require(command.direction != nil, "step \(stepID) rpm command requires a commanded direction")
            case .cIndex:
                try require(command.cIndexDegrees.map { spindle!.containsCPosition($0) } ?? false, "step \(stepID) C index outside declared travel (default [0, 360))")
                try require(command.rpm == nil, "step \(stepID) C command carries an RPM value")
                try require(command.direction == nil, "step \(stepID) C command carries a direction")
            }
            try CellCheck.positive(command.durationSeconds, max: 1e3, name: "step \(stepID) spindle ramp duration")
        case .chuck(let command):
            try require(cell.spindle(command.spindleID) != nil, "step \(stepID) unknown spindle \(command.spindleID)")
            switch command.operation {
            case .open:
                try CellCheck.positive(command.openDiameterMM ?? 0, max: 10_000, name: "step \(stepID) open diameter")
                try require(command.workpieceID == nil && command.gripLengthMM == nil, "step \(stepID) open command carries part/grip values")
            case .clamp:
                try require(command.workpieceID != nil && cell.workpiece(command.workpieceID!) != nil, "step \(stepID) clamp requires a known workpiece")
                try CellCheck.positive(command.gripLengthMM ?? 0, max: 10_000, name: "step \(stepID) clamp grip length")
                try require(command.openDiameterMM == nil, "step \(stepID) clamp command carries an open diameter")
            case .release:
                try require(command.workpieceID == nil && command.gripLengthMM == nil && command.openDiameterMM == nil, "step \(stepID) release command carries extra values")
            }
            try CellCheck.positive(command.durationSeconds, max: 1e3, name: "step \(stepID) chuck duration")
        case .synchronize(let sync):
            try require(sync.spindleIDs.count == 2, "step \(stepID) synchronization requires exactly two spindles")
            try require(sync.spindleIDs[0] != sync.spindleIDs[1], "step \(stepID) synchronization needs two distinct spindles")
            for spindleID in sync.spindleIDs { try require(cell.spindle(spindleID) != nil, "step \(stepID) unknown spindle \(spindleID)") }
            switch sync.mode {
            case .matchedRPM:
                try require(sync.phaseToleranceDegrees.map { $0.isFinite && $0 > 0 && $0 <= 180 } ?? false, "step \(stepID) matched-RPM sync requires a phase tolerance in (0, 180]")
                let ratio = sync.speedRatio ?? 1
                try CellCheck.positive(ratio, max: 100, name: "step \(stepID) sync speed ratio")
                if let offset = sync.targetPhaseOffsetDegrees {
                    try require(offset.isFinite && abs(offset) < 360, "step \(stepID) target phase offset in (-360, 360)")
                }
            case .bothStopped:
                try require(sync.speedRatio == nil && sync.phaseToleranceDegrees == nil && sync.targetPhaseOffsetDegrees == nil,
                            "step \(stepID) stopped sync carries ratio/tolerance/offset values")
            }
            try CellCheck.positive(sync.durationSeconds, max: 1e3, name: "step \(stepID) sync duration")
        case .transfer(let transfer):
            try require(cell.spindle(transfer.donorSpindleID) != nil, "step \(stepID) unknown donor spindle \(transfer.donorSpindleID)")
            try require(cell.spindle(transfer.receiverSpindleID) != nil, "step \(stepID) unknown receiver spindle \(transfer.receiverSpindleID)")
            try require(transfer.donorSpindleID != transfer.receiverSpindleID, "step \(stepID) transfer needs two distinct spindles")
            let part = cell.workpiece(transfer.workpieceID)
            try require(part != nil, "step \(stepID) unknown workpiece \(transfer.workpieceID)")
            try CellCheck.positive(transfer.receiverGripLengthMM, max: 10_000, name: "step \(stepID) receiver grip length")
            if let length = part!.lengthMM {
                try require(transfer.receiverGripLengthMM <= length, "step \(stepID) receiver grip exceeds workpiece length")
            }
            try CellCheck.nonnegative(transfer.clearanceMM, max: 10_000, name: "step \(stepID) transfer clearance")
            try require(transfer.twistDegrees.isFinite && abs(transfer.twistDegrees) <= 360, "step \(stepID) twist within ±360")
            // Carriage targets must stay on the receiver axis line.
            let receiver = cell.spindle(transfer.receiverSpindleID)!
            var carriageTargets: [(String, [Double])] = [("acquisition origin", transfer.acquisitionOriginMM)]
            if let retract = transfer.retractOriginMM { carriageTargets.append(("retract origin", retract)) }
            for (label, origin) in carriageTargets {
                try require(origin.count == 3 && origin.allSatisfy { $0.isFinite && abs($0) <= 100_000 },
                            "step \(stepID) transfer \(label) requires 3 finite values")
                let delta = zip(origin, receiver.frame.originMM).map { $0 - $1 }
                let along = zip(delta, receiver.frame.axis).reduce(0.0) { $0 + $1.0*$1.1 }
                let radial = zip(delta, receiver.frame.axis).map { $0 - $1*along }
                let radialError = sqrt(radial.reduce(0) { $0 + $1*$1 })
                try require(radialError <= 1e-3, "step \(stepID) transfer \(label) is \(radialError) mm off the \(receiver.id) axis")
            }
            try CellCheck.positive(transfer.durationSeconds, max: 1e4, name: "step \(stepID) transfer duration")
        case .wait(let wait):
            try require(cell.waitPoints.contains { $0.name == wait.pointName }, "step \(stepID) wait point \(wait.pointName) does not resolve")
        case .barrier(let barrier):
            let participants = barrier.channelIDs.isEmpty ? cell.channels.map(\.id) : barrier.channelIDs
            try require(participants.count >= 2 || barrier.channelIDs.isEmpty, "step \(stepID) barrier needs at least two channels")
            for channelID in participants { try require(cell.channel(channelID) != nil, "step \(stepID) barrier unknown channel \(channelID)") }
        case .operate(let operation):
            let part = cell.workpiece(operation.workpieceID)
            try require(part != nil, "step \(stepID) unknown workpiece \(operation.workpieceID)")
            try require(cell.spindle(operation.spindleID) != nil, "step \(stepID) unknown spindle \(operation.spindleID)")
            try require(operation.toolID == nil || operation.turningToolID == nil,
                        "step \(stepID) cannot select both a CAM tool and a turning tool")
            if let turretID = operation.turretID {
                let host = cell.turret(turretID)
                try require(host != nil, "step \(stepID) unknown turret \(turretID)")
                if let stationID = operation.stationID {
                    try require(host!.stations.contains { $0.id == stationID }, "step \(stepID) unknown station \(stationID) on turret \(turretID)")
                    let station = host!.stations.first { $0.id == stationID }!
                    // A station identifies its tool; a diameter never does.
                    if let expectedTool = operation.toolID, let stationTool = station.toolID {
                        try require(expectedTool == stationTool, "step \(stepID) tool \(expectedTool) does not match station \(stationID) tool \(stationTool)")
                    }
                    if let expectedTool = operation.turningToolID, let stationTool = station.turningToolID {
                        try require(expectedTool == stationTool, "step \(stepID) turning tool \(expectedTool) does not match station \(stationID) turning tool \(stationTool)")
                    }
                }
            } else {
                try require(operation.stationID == nil, "step \(stepID) station without a turret")
            }
            // Legacy jobs need explicit tool identity; combined
            // turning+slot studies refuse to run as one cell operation.
            let study = operation.study
            if study.turning.enabled && study.milling.enabled {
                throw ManufacturingError.invalid("cell: step \(stepID): combined turning+slot studies are not schedulable as one cell operation; split them into identified turning and milling jobs")
            }
            if study.turning.enabled {
                try require(study.turningToolID?.isEmpty == false, "step \(stepID) turning study requires an explicit turningToolID identity")
                if let cutting = study.turningCutting, cutting.spindleMode == .constantSurfaceSpeed {
                    throw ManufacturingError.invalid("cell: step \(stepID): constant-surface-speed turning is unsupported in cell scheduling until a variable phase law exists; standalone studies keep CSS support")
                }
            }
            if study.milling.enabled {
                try require(study.millingToolID?.isEmpty == false, "step \(stepID) legacy slot study requires an explicit millingToolID identity")
            }
            // Tool/study consistency: the selected tool must be one the study
            // actually cuts with, and a multi-tool study refuses to run
            // without an explicit station/tool selection (turret state then
            // enforces the index schedule between operations).
            let activeTools = CellOperation.activeToolIDs(of: study)
            if !activeTools.isEmpty {
                let stationSelection: String? = {
                    guard let stationID = operation.stationID, let host = cell.turret(operation.turretID ?? "") else { return nil }
                    let station = host.stations.first { $0.id == stationID }
                    return station?.toolID ?? station?.turningToolID
                }()
                // A single active tool may resolve to the study's own
                // identity (turret-less legacy jobs); multiple tools require
                // an explicit selection so ownership is never ambiguous.
                let studyIdentity = activeTools.count == 1 ? activeTools.first : nil
                let selected = operation.toolID ?? operation.turningToolID ?? stationSelection ?? studyIdentity
                try require(selected != nil, "step \(stepID) study uses tools \(activeTools.sorted()) and requires an explicit station/tool selection")
                try require(activeTools.contains(selected!), "step \(stepID) selected tool \(selected!) is not an active tool of the study")
                if activeTools.count > 1 {
                    try require(operation.stationID != nil || operation.toolID != nil || operation.turningToolID != nil,
                                "step \(stepID) multi-tool study requires an explicit station selection with a preceding index schedule")
                }
            } else {
                try require(operation.toolID == nil && operation.turningToolID == nil, "step \(stepID) study has no explicit tool identity; tool selection must be nil")
            }
            // Turning insert match: effective setup and fixed nose contract.
            let selectedTurningID = operation.turningToolID ?? {
                guard let stationID = operation.stationID, let host = cell.turret(operation.turretID ?? "") else { return nil }
                return host.stations.first { $0.id == stationID }?.turningToolID
            }()
            if let turningID = selectedTurningID {
                let record = cell.turningTool(turningID)
                try require(record != nil, "step \(stepID) unknown turning tool \(turningID)")
                try record!.validate(matching: study)
            }
            // Legacy slot match: the selected CAM tool must be the flat end
            // mill the slot study actually specifies, including assembly.
            let selectedCAMID = operation.toolID ?? {
                guard let stationID = operation.stationID, let host = cell.turret(operation.turretID ?? "") else { return nil }
                return host.stations.first { $0.id == stationID }?.toolID
            }()
            if study.milling.enabled, let camID = selectedCAMID {
                let tool = cell.tool(camID)
                try require(tool != nil, "step \(stepID) unknown tool \(camID)")
                try require(tool!.kind == "flatEndMill", "step \(stepID) legacy slot requires a flat end mill, not \(tool!.kind)")
                try require(abs(tool!.diameterMM - 2*study.milling.toolRadiusMM) < 1e-9,
                            "step \(stepID) tool diameter does not match the slot width \(2*study.milling.toolRadiusMM) mm")
                try require(abs(tool!.cuttingLengthMM - study.milling.toolLengthMM) < 1e-9,
                            "step \(stepID) tool cutting length does not match the slot tool length")
                if let assembly = study.millingAssembly {
                    try require(tool!.assembly == assembly, "step \(stepID) tool assembly does not match the study assembly")
                }
            }
            if let offset = operation.workOffsetMM {
                // Stored explicitly, but a nonzero work offset would shift
                // cutting geometry, which the planner cannot apply to
                // material: fail closed until the executor contract defines
                // the study transform.
                try require(offset.count == 3 && offset.allSatisfy { $0.isFinite && abs($0) <= 100_000 }, "step \(stepID) work offset requires 3 finite values")
                try require(offset.allSatisfy { $0 == 0 }, "step \(stepID): nonzero work offsets are unsupported until the executor defines the study transform")
            }
            try CellCheck.positive(operation.durationSeconds, max: 1e6, name: "step \(stepID) operation duration")
            try require(operation.study.source == part!.source, "step \(stepID) study source does not match workpiece \(operation.workpieceID)")
            try require(operation.study.id == part!.studyID, "step \(stepID) study identity does not match workpiece \(operation.workpieceID)")
            try operation.study.validate(requireOperations: false)
            try require(Set(operation.stockDependencyIDs).count == operation.stockDependencyIDs.count, "step \(stepID) duplicate stock dependency")
            for dependency in operation.stockDependencyIDs {
                try require(cell.steps.contains { $0.id == dependency }, "step \(stepID) unknown stock dependency \(dependency)")
                try require(dependency != stepID, "step \(stepID) cannot depend on its own stock state")
            }
        }
    }
}
