// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

/// Engine-neutral adapter contract. Engine owners (for example
/// FloeRPGProjectKit) implement this to expose engine-native files to the
/// auxiliary editors. This package ships no engine semantic schemas.
public protocol GameEditingAdapter: Sendable {
    var engine: GameEngineID { get }

    /// Classify a project file for the asset browser. Returning nil means
    /// "unknown"; the file stays visible and fully preserved.
    func assetKind(for path: GameRelativePath, in project: GameStoredProject) -> GameAssetKind?

    /// Parameter-form schemas for this engine, each binding form fields to
    /// concrete JSON paths inside a project document.
    func parameterSchemas(in project: GameStoredProject) -> [GameParameterSchema]

    /// Schemas for this file only. A database schema must never be applied to
    /// another file merely because both belong to the same project.
    func parameterSchemas(for path: GameRelativePath, in project: GameStoredProject) -> [GameParameterSchema]

    /// Optional record-aware schemas over the decoded parameter JSON. Each
    /// schema identifies an actual record, with paths into the full document.
    func parameterSchemas(for path: GameRelativePath, json: Data, in project: GameStoredProject) throws -> [GameParameterSchema]

    /// File <-> tile-map DTO codec for an engine-native map file, if supported.
    func tileMapBinding(for path: GameRelativePath, in project: GameStoredProject) -> GameTileMapBinding?

    /// File <-> narrative DTO codec for an engine-native event/script file, if supported.
    func narrativeBinding(for path: GameRelativePath, in project: GameStoredProject) -> GameNarrativeBinding?

    /// Engine-native parameter data codec for a project document (for example
    /// RPG Maker rxdata/rvdata binaries). When nil, the file is treated as
    /// plain JSON bytes; when present, the parameter form decodes/encodes
    /// through the owner's real codec and the session stores the engine-native
    /// bytes unchanged (undo/history keep both representations' bytes).
    func parameterBinding(for path: GameRelativePath, in project: GameStoredProject) -> GameParameterBinding?
}

public extension GameEditingAdapter {
    func parameterSchemas(for path: GameRelativePath, in project: GameStoredProject) -> [GameParameterSchema] { parameterSchemas(in: project) }
    func parameterSchemas(for path: GameRelativePath, json: Data, in project: GameStoredProject) throws -> [GameParameterSchema] { parameterSchemas(for: path, in: project) }
    /// Default: raw JSON bytes, no engine codec. Engine owners override.
    func parameterBinding(for path: GameRelativePath, in project: GameStoredProject) -> GameParameterBinding? { nil }
}

public enum GameAssetKind: String, CaseIterable, Codable, Sendable {
    case image, audio, video, tileset, map, script, data, manifest, save, unknown
}

/// Bidirectional codec between engine-native bytes and the editor DTO.
public struct GameTileMapBinding: Sendable {
    public var decode: @Sendable (Data) throws -> EditableTileMap
    public var encode: @Sendable (EditableTileMap) throws -> Data
    public init(decode: @escaping @Sendable (Data) throws -> EditableTileMap,
                encode: @escaping @Sendable (EditableTileMap) throws -> Data) {
        self.decode = decode; self.encode = encode
    }
}

/// Byte-level codec between an engine-native parameter document (binary or
/// otherwise) and the JSON bytes the parameter form edits. Implementations
/// must preserve every unknown field/record: only the edited JSON paths are
/// changed when data travels back through `encodeJSONToData`.
public struct GameParameterBinding: Sendable {
    public var decodeDataToJSON: @Sendable (Data) throws -> Data
    public var encodeJSONToData: @Sendable (Data) throws -> Data
    public init(decodeDataToJSON: @escaping @Sendable (Data) throws -> Data,
                encodeJSONToData: @escaping @Sendable (Data) throws -> Data) {
        self.decodeDataToJSON = decodeDataToJSON
        self.encodeJSONToData = encodeJSONToData
    }
}

public struct GameNarrativeBinding: Sendable {
    /// `known` lists command codes the adapter can edit structurally;
    /// anything else is surfaced read-only with its original bytes kept.
    public var knownCommands: [GameNarrativeCommandSpec]
    public var decode: @Sendable (Data) throws -> NarrativeDocument
    public var encode: @Sendable (NarrativeDocument) throws -> Data
    public init(knownCommands: [GameNarrativeCommandSpec],
                decode: @escaping @Sendable (Data) throws -> NarrativeDocument,
                encode: @escaping @Sendable (NarrativeDocument) throws -> Data) {
        self.knownCommands = knownCommands; self.decode = decode; self.encode = encode
    }
}

/// Declarative description of one editable event command parameter set.
public struct GameNarrativeCommandSpec: Sendable, Identifiable, Hashable {
    public var id: String { code }
    public let code: String
    public let title: GameEditCopy
    public let fields: [GameParameterField]
    public init(code: String, title: GameEditCopy, fields: [GameParameterField]) {
        self.code = code; self.title = title; self.fields = fields
    }
}

/// Registry mirroring GameAdapterRegistry semantics: one adapter per engine.
public struct GameEditingAdapterRegistry: Sendable {
    private var adapters: [GameEngineID: any GameEditingAdapter] = [:]
    public init() {}
    public init(adapters: [any GameEditingAdapter]) throws {
        for adapter in adapters { try register(adapter) }
    }
    public mutating func register(_ adapter: any GameEditingAdapter) throws {
        guard adapters[adapter.engine] == nil else { throw GameProjectError.duplicateAdapter(adapter.engine) }
        adapters[adapter.engine] = adapter
    }
    public func adapter(for engine: GameEngineID) -> (any GameEditingAdapter)? { adapters[engine] }
}

/// Fallback adapter: everything unknown, no schemas. Editors degrade to a
/// plain file browser instead of hiding files.
public struct GameUnknownEditingAdapter: GameEditingAdapter {
    public let engine: GameEngineID
    public init(engine: GameEngineID) { self.engine = engine }
    public func assetKind(for path: GameRelativePath, in project: GameStoredProject) -> GameAssetKind? { nil }
    public func parameterSchemas(in project: GameStoredProject) -> [GameParameterSchema] { [] }
    public func tileMapBinding(for path: GameRelativePath, in project: GameStoredProject) -> GameTileMapBinding? { nil }
    public func narrativeBinding(for path: GameRelativePath, in project: GameStoredProject) -> GameNarrativeBinding? { nil }
}
