// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit

public enum EditorJSON: Codable, Sendable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([EditorJSON]), object([String: EditorJSON])
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self), v.isFinite { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([EditorJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: EditorJSON].self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): guard v.isFinite else { throw HeavyEditorError.invalidDocument }; try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
    public subscript(_ key: String) -> EditorJSON { if case .object(let v) = self { return v[key] ?? .null }; return .null }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var number: Double? { if case .number(let v) = self { return v }; return nil }
    public var array: [EditorJSON] { if case .array(let v) = self { return v }; return [] }
    public static func decode(_ data: Data) throws -> EditorJSON { try JSONDecoder().decode(Self.self, from: data) }
    public func data() throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(self) }
    public func text() throws -> String { String(decoding: try data(), as: UTF8.self) }
}

public enum HeavyEditorKind: String, Codable, Sendable, CaseIterable { case gis, score, font }
public enum HeavyEditorOwner: Codable, Sendable, Equatable {
    case space(UUID), note(UUID), task(UUID)
    /// Parent music project and font-library identity, resolved only by the host.
    case music(UUID), fontLibrary(UUID)
    case qualification(UUID)
}
public enum HeavyEditorAccess: String, Codable, Sendable { case read, edit, importFile, exportFile }
public struct HeavyEditorDocument: Codable, Sendable, Equatable {
    public var schemaVersion = 1
    public let id: UUID
    public let kind: HeavyEditorKind
    public var title: String
    public var revision: UInt64
    public var modifiedAt: Date
    public var content: EditorJSON
    public init(id: UUID = UUID(), kind: HeavyEditorKind, title: String, content: EditorJSON) {
        self.id = id; self.kind = kind; self.title = title; self.content = content
        revision = 0; modifiedAt = Date()
    }
}
public struct HeavyEditorAccessRequest: Sendable {
    public let documentID: UUID
    public let owner: HeavyEditorOwner
    public let revision: UInt64
    public let access: HeavyEditorAccess
    public let command: String
}
public struct HeavyEditorHostHooks: Sendable {
    /// The real host resolves ownership and authorizes access. Imported data and
    /// model arguments cannot choose this owner, root or authorization callback.
    public let authorize: @Sendable (HeavyEditorAccessRequest) async throws -> Void
    public let didSave: @Sendable (HeavyEditorDocument) async -> Void
    public let export: @Sendable (UUID, HeavyEditorArtifact) async throws -> HeavyEditorExportReceipt
    public init(authorize: @escaping @Sendable (HeavyEditorAccessRequest) async throws -> Void,
                didSave: @escaping @Sendable (HeavyEditorDocument) async -> Void,
                export: @escaping @Sendable (UUID, HeavyEditorArtifact) async throws -> HeavyEditorExportReceipt) {
        self.authorize = authorize; self.didSave = didSave; self.export = export
    }
}
public struct HeavyEditorExportReceipt: Codable, Sendable {
    public let fileID: String
    public let name: String
    public let byteCount: Int
    public let sha256: String
    /// Construct only after the host's managed file service commits and reads
    /// back the output. fileID is its opaque result, never a model-chosen path.
    public init(fileID: String, artifact: HeavyEditorArtifact) throws {
        guard !fileID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw HeavyEditorError.invalidDocument }
        self.fileID = fileID; self.name = artifact.name; self.byteCount = artifact.data.count
        self.sha256 = SHA256.hash(data: artifact.data).map { String(format: "%02x", $0) }.joined()
    }
}
public struct HeavyEditorNativeExtension: Sendable {
    public let operations: Set<String>
    public let cancel: (@Sendable (String) async -> Void)?
    public let presentationClosed: (@Sendable () async -> Void)?
    public let run: @Sendable (String, EditorJSON) async throws -> EditorJSON
    public init(operations: Set<String>, cancel: (@Sendable (String) async -> Void)? = nil,
                presentationClosed: (@Sendable () async -> Void)? = nil,
                run: @escaping @Sendable (String, EditorJSON) async throws -> EditorJSON) {
        self.operations = operations; self.cancel = cancel; self.presentationClosed = presentationClosed; self.run = run
    }
}
public struct HeavyEditorArtifact: Sendable {
    public let name: String
    public let mediaType: String
    public let data: Data
    public init(name: String, mediaType: String, data: Data) throws {
        guard !name.isEmpty, name.count < 240, name != ".", name != "..",
              !name.contains("/"), !name.contains("\\"), !name.contains(":"),
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !mediaType.isEmpty else { throw HeavyEditorError.invalidDocument }
        self.name = name; self.mediaType = mediaType; self.data = data
    }
}
public enum HeavyEditorError: Error, LocalizedError, Sendable {
    case invalidDocument, revisionConflict, wrongDocument, unavailable, invalidCommand, engine(String)
    public var errorDescription: String? {
        switch self {
        case .invalidDocument: EditorText.t("工程或文件资料不完整。", "The project or file is incomplete.")
        case .revisionConflict: EditorText.t("作品已被修改，请重新打开后继续。", "This work has changed. Reopen it to continue.")
        case .wrongDocument: EditorText.t("这项操作不属于当前作品。", "This action does not belong to the current work.")
        case .unavailable: EditorText.t("编辑器尚未准备好。", "The editor is not ready.")
        case .invalidCommand: EditorText.t("这项操作不可用。", "This action is unavailable.")
        case .engine(let message): message
        }
    }
}
public enum EditorText {
    public static func t(_ zh: String, _ en: String) -> String {
        Locale.preferredLanguages.first?.hasPrefix("zh") == true ? zh : en
    }
}
public struct HeavyEditorDescriptor: Sendable {
    public let kind: HeavyEditorKind
    public let title: String
    public let symbol: String
    public let resourceRoot: URL
    public let projectExtension: String
    public let importExtensions: [String]
    public init(kind: HeavyEditorKind, title: String, symbol: String, resourceRoot: URL,
                projectExtension: String, importExtensions: [String]) {
        self.kind = kind; self.title = title; self.symbol = symbol; self.resourceRoot = resourceRoot
        self.projectExtension = projectExtension; self.importExtensions = importExtensions
    }
}
