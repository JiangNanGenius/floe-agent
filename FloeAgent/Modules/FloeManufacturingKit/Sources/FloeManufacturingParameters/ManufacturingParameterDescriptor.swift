// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Storage kind of a catalogued parameter.
public enum ManufacturingParameterKind: String, Codable, Sendable {
    case number, integer, boolean, string, choice, array, object
}

/// Physical / engineering unit attached to a descriptor.
public enum ManufacturingParameterUnit: String, Codable, Sendable {
    case none
    case mm          // millimetre
    case mm3         // cubic millimetre (volume)
    case mmPerMinute // feed rate
    case mmPerTooth  // chip load
    case mmPerRevolution
    case revPerMinute
    case mPerMinute  // surface / cutting speed
    case degrees
    case seconds
    case percent
    case ratio       // fraction of tool diameter, 0...1
    case litresPerMinute
    case celsius
}

/// Honest support classification for a parameter.
public enum ManufacturingParameterSupport: String, Codable, Sendable {
    /// Consumed by the current native engine preview (binding is non-nil).
    case previewUsed
    /// Editable / persisted / exported, but the geometric preview ignores it.
    case configurationOnly
    /// Fixed prototype value; not user-adjustable in the current runtime.
    case fixed
    /// Registered for completeness but currently unavailable in this parameter owner.
    case notAvailable
}

/// A single catalogued manufacturing parameter with bilingual metadata.
public struct ManufacturingParameterDescriptor: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var groupID: String
    public var nameZH: String
    public var nameEN: String
    public var helpZH: String
    public var helpEN: String
    public var unit: ManufacturingParameterUnit
    public var kind: ManufacturingParameterKind
    public var defaultValue: ManufacturingParameterValue?
    public var choices: [String]?
    public var minimum: Double?
    public var maximum: Double?
    public var binding: String?
    public var support: ManufacturingParameterSupport
    public var supportReasonZH: String
    public var supportReasonEN: String
    /// Rarely used fields are hidden from default search/UI listing.
    public var rare: Bool
    /// Field-level provenance, e.g. "OpenMill@0432a8c:tool.rs:ToolShape.BullNose.corner_radius".
    public var sourceRefs: [String]

    public init(
        id: String,
        groupID: String,
        nameZH: String,
        nameEN: String,
        helpZH: String,
        helpEN: String,
        unit: ManufacturingParameterUnit = .none,
        kind: ManufacturingParameterKind,
        defaultValue: ManufacturingParameterValue? = nil,
        choices: [String]? = nil,
        minimum: Double? = nil,
        maximum: Double? = nil,
        binding: String? = nil,
        support: ManufacturingParameterSupport,
        supportReasonZH: String = "",
        supportReasonEN: String = "",
        rare: Bool = false,
        sourceRefs: [String] = []
    ) {
        self.id = id
        self.groupID = groupID
        self.nameZH = nameZH
        self.nameEN = nameEN
        self.helpZH = helpZH
        self.helpEN = helpEN
        self.unit = unit
        self.kind = kind
        self.defaultValue = defaultValue
        self.choices = choices
        self.minimum = minimum
        self.maximum = maximum
        self.binding = binding
        self.support = support
        self.supportReasonZH = supportReasonZH
        self.supportReasonEN = supportReasonEN
        self.rare = rare
        self.sourceRefs = sourceRefs
    }

    /// True when this descriptor declares a runtime binding key.
    public var isRuntimeBound: Bool { binding != nil }
}

/// A catalog group (tool assemblies, stock/material, drilling, ...).
public struct ManufacturingParameterGroup: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var nameZH: String
    public var nameEN: String
    public init(id: String, nameZH: String, nameEN: String) {
        self.id = id; self.nameZH = nameZH; self.nameEN = nameEN
    }
}
