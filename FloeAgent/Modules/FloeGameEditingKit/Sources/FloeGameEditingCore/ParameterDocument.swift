// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

/// Schema-driven form field bound to a concrete JSON path. Schemas come from
/// engine adapters (or the host); this package ships no universal schema.
public struct GameParameterField: Sendable, Identifiable, Hashable {
    public enum FieldKind: Sendable, Hashable {
        case text
        case multiline
        case integer(Int?, Int?)
        case decimal(Double?, Double?)
        case toggle
        case choice([String])
    }
    public var id: String {
        path.components.map { component in
            switch component {
            case .key(let key): return key
            case .index(let index): return String(index)
            }
        }.joined(separator: ".")
    }
    public let label: GameEditCopy
    public let path: JSONFieldPath
    public let kind: FieldKind
    public let placeholder: String?
    public init(label: GameEditCopy, path: JSONFieldPath, kind: FieldKind, placeholder: String? = nil) {
        self.label = label; self.path = path; self.kind = kind; self.placeholder = placeholder
    }
}

public struct GameParameterSchema: Sendable, Identifiable, Hashable {
    public let id: String
    public let title: GameEditCopy
    public let fields: [GameParameterField]
    public init(id: String, title: GameEditCopy, fields: [GameParameterField]) {
        self.id = id; self.title = title; self.fields = fields
    }
}

/// Character/item parameter editing over a JSON document. Unknown fields and
/// entries outside the schema are retained because edits are structural.
public struct ParameterDocument: Hashable, Sendable {
    public private(set) var root: JSONValue
    public let schema: GameParameterSchema

    public init(bytes: Data, schema: GameParameterSchema) throws {
        self.root = try JSONValue.parse(bytes)
        self.schema = schema
    }
    public init(root: JSONValue, schema: GameParameterSchema) {
        self.root = root; self.schema = schema
    }

    public func value(for field: GameParameterField) -> JSONValue {
        field.path.lookup(in: root) ?? .null
    }

    /// Validates against the field kind and applies structurally.
    public mutating func set(_ value: JSONValue, for field: GameParameterField) throws {
        try validate(value, for: field)
        root = try field.path.replacing(in: root, with: normalized(value, for: field))
    }

    func validate(_ value: JSONValue, for field: GameParameterField) throws {
        switch field.kind {
        case .text, .multiline:
            guard value.isNull || value.stringValue != nil else { throw GameProjectError.invalidEdit }
        case .integer(let minimum, let maximum):
            guard value.isNull || value.intValue != nil else { throw GameProjectError.invalidEdit }
            if let number = value.intValue {
                if let minimum, number < minimum { throw GameProjectError.invalidEdit }
                if let maximum, number > maximum { throw GameProjectError.invalidEdit }
            }
        case .decimal(let minimum, let maximum):
            guard value.isNull || value.numberValue != nil else { throw GameProjectError.invalidEdit }
            if let number = value.numberValue {
                if let minimum, number < minimum { throw GameProjectError.invalidEdit }
                if let maximum, number > maximum { throw GameProjectError.invalidEdit }
            }
        case .toggle:
            guard value.isNull || value.boolValue != nil else { throw GameProjectError.invalidEdit }
        case .choice(let options):
            guard value.isNull || (value.stringValue.map(options.contains) ?? false) else {
                throw GameProjectError.invalidEdit
            }
        }
    }

    func normalized(_ value: JSONValue, for field: GameParameterField) -> JSONValue {
        // Nulls are stored as null; numbers keep integer form when possible.
        switch (field.kind, value) {
        case (.integer, .number(let number)) where number.rounded() == number:
            return .number(number)
        default: return value
        }
    }

    public func serialized() throws -> Data { try root.serialized() }
}
