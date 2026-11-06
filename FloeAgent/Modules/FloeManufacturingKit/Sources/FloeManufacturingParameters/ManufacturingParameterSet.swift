// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Code classifying a parameter-set validation issue.
public enum ManufacturingParameterIssueCode: String, Codable, Sendable {
    /// The ID is not registered in the catalog; the value is preserved as-is.
    case unknownParameter
    case typeMismatch
    case nonFinite
    case outOfRange
    case invalidChoice
    /// The set/document declares a formatVersion newer than this build supports.
    case unsupportedVersion
}

/// A single validation finding for one parameter.
public struct ManufacturingParameterIssue: Codable, Equatable, Sendable {
    public var parameterID: String
    public var code: ManufacturingParameterIssueCode
    public var message: String
    public init(parameterID: String, code: ManufacturingParameterIssueCode, message: String) {
        self.parameterID = parameterID; self.code = code; self.message = message
    }
}

/// A persistable set of manufacturing parameter values.
///
/// Missing key means *unset*; `.null` means an explicit null; `.number(0)` /
/// `.integer(0)` are real zeros. The three states stay distinguishable after
/// any save/load round-trip.
public struct ManufacturingParameterSet: Codable, Equatable, Sendable {
    /// Current on-disk schema version. Higher versions are rejected on decode.
    public static let supportedFormatVersion = 1

    public var formatVersion: Int
    public var values: [String: ManufacturingParameterValue]

    public init(formatVersion: Int = ManufacturingParameterSet.supportedFormatVersion,
                values: [String: ManufacturingParameterValue] = [:]) {
        self.formatVersion = formatVersion
        self.values = values
    }

    /// Unset when the key is absent; otherwise the stored value (possibly `.null`).
    public func value(_ id: String) -> ManufacturingParameterValue? { values[id] }

    public mutating func set(_ id: String, _ value: ManufacturingParameterValue) {
        values[id] = value
    }

    /// Removes the key entirely, returning the parameter to the unset state.
    public mutating func remove(_ id: String) { values.removeValue(forKey: id) }

    private enum CodingKeys: String, CodingKey { case formatVersion, values }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .formatVersion)
        guard version <= ManufacturingParameterSet.supportedFormatVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .formatVersion, in: c,
                debugDescription: "unsupported manufacturing parameter set version \(version); original data must be preserved"
            )
        }
        formatVersion = version
        values = try c.decodeIfPresent([String: ManufacturingParameterValue].self, forKey: .values) ?? [:]
    }

    /// Validates stored values against the catalog.
    ///
    /// Unknown IDs produce informational `.unknownParameter` issues and their
    /// values are NOT deleted — future schema additions must round-trip.
    public func validate(catalog: ManufacturingParameterCatalog) -> [ManufacturingParameterIssue] {
        var issues: [ManufacturingParameterIssue] = []
        if formatVersion > ManufacturingParameterSet.supportedFormatVersion {
            issues.append(ManufacturingParameterIssue(
                parameterID: "formatVersion", code: .unsupportedVersion,
                message: "version \(formatVersion) is newer than supported \(ManufacturingParameterSet.supportedFormatVersion)"))
        }
        for (id, value) in values {
            guard let descriptor = catalog.lookup(id) else {
                issues.append(ManufacturingParameterIssue(
                    parameterID: id, code: .unknownParameter,
                    message: "parameter ID '\(id)' is not in the catalog; value preserved unchanged"))
                continue
            }
            validate(value, against: descriptor, into: &issues)
        }
        return issues.sorted { $0.parameterID < $1.parameterID }
    }

    private func validate(_ value: ManufacturingParameterValue,
                          against d: ManufacturingParameterDescriptor,
                          into issues: inout [ManufacturingParameterIssue]) {
        func issue(_ code: ManufacturingParameterIssueCode, _ message: String) {
            issues.append(ManufacturingParameterIssue(parameterID: d.id, code: code, message: message))
        }
        // `.null` is allowed for any parameter: it means explicitly cleared.
        if value.isNull { return }
        switch (d.kind, value) {
        case (.number, .number(let v)):
            guard v.isFinite else { issue(.nonFinite, "value must be finite"); return }
        case (.number, .integer(let v)):
            guard Double(v).isFinite else { issue(.nonFinite, "value must be finite"); return }
        case (.integer, .integer): break
        case (.integer, .number(let v)):
            guard v.isFinite else { issue(.nonFinite, "value must be finite"); return }
            guard v.rounded() == v else {
                issue(.typeMismatch, "kind is integer but value \(v) is not integral"); return
            }
        case (.boolean, .boolean): break
        case (.string, .string): break
        case (.choice, .string(let s)):
            if let choices = d.choices, !choices.isEmpty, !choices.contains(s) {
                issue(.invalidChoice, "value '\(s)' is not one of \(choices.joined(separator: ", "))")
                return
            }
        case (.array, .array): break
        case (.object, .object): break
        default:
            issue(.typeMismatch, "value \(value) does not match kind \(d.kind.rawValue)")
            return
        }
        if let numeric = value.numericMagnitude {
            if let lo = d.minimum, numeric < lo {
                issue(.outOfRange, "value \(numeric) is below minimum \(lo)")
            }
            if let hi = d.maximum, numeric > hi {
                issue(.outOfRange, "value \(numeric) is above maximum \(hi)")
            }
        }
    }

    /// Returns a copy with the preset's entries applied over current values.
    /// Preset keys that are absent leave the current value untouched.
    public func merged(with preset: ManufacturingParameterPreset) -> Self {
        var copy = self
        for (id, value) in preset.values { copy.values[id] = value }
        return copy
    }
}

/// A named, persistable delta of parameter overrides.
public struct ManufacturingParameterPreset: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var values: [String: ManufacturingParameterValue]

    public init(id: UUID = UUID(),
                name: String,
                values: [String: ManufacturingParameterValue] = [:]) {
        self.id = id; self.name = name; self.values = values
    }

    /// Convenience: build a preset from a full set, keeping only the listed IDs.
    public init(id: UUID = UUID(), name: String, from set: ManufacturingParameterSet, ids: [String]) {
        self.init(id: id, name: name, values: set.values.filter { ids.contains($0.key) })
    }
}
