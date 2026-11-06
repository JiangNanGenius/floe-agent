import Foundation
import FloeCanvasCore
import FloeCanvasFlow

public struct TemplateText: Codable, Hashable, Sendable {
    public var en: String
    public var zh: String
    public init(_ en: String, _ zh: String) { self.en = en; self.zh = zh }
    public func value(chinese: Bool) -> String { chinese ? zh : en }
}

public enum TemplateCategory: String, Codable, CaseIterable, Sendable {
    case ideas, image, video, music, film, audio, design
}

public enum TemplateError: Error, Equatable, Sendable {
    case invalid(String)
    case missingInput(String)
    case conflict(expected: Int?, actual: Int?)
    case notFound(UUID)
    case builtInImmutable
    case cancelled
    case staleContext
    case hostUnavailable(String)
}

public struct TemplateSlot: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: TemplateText
    public var nodeID: UUID
    public var required: Bool
    public init(id: String, title: TemplateText, nodeID: UUID, required: Bool = false) {
        self.id = id; self.title = title; self.nodeID = nodeID; self.required = required
    }
}

/// Purpose is node-local. It never changes the asset or introduces a new node kind.
public struct CreativePurpose: Codable, Hashable, Sendable {
    public enum Role: String, Codable, Sendable {
        case brief, reference, script, lyrics, characterReference, sceneReference
        case shotDescription, shotKeyframe, shotClip, finalOutput
    }
    public var role: Role
    public var recordID: UUID?
    public var referenceNodeIDs: [UUID]
    public init(_ role: Role, recordID: UUID? = nil, referenceNodeIDs: [UUID] = []) {
        self.role = role; self.recordID = recordID; self.referenceNodeIDs = referenceNodeIDs
    }
    public static let metadataKey = "floe.creative.purpose.v1"
    public func apply(to node: inout CanvasNodeSnapshot) throws {
        node.metadata[Self.metadataKey] = String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }
    public static func read(_ node: CanvasNodeSnapshot) throws -> Self? {
        guard let raw = node.metadata[metadataKey] else { return nil }
        return try JSONDecoder().decode(Self.self, from: Data(raw.utf8))
    }
}

public struct CreativeRecord: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case character, scene, shot }
    public var id: UUID
    public var kind: Kind
    public var name: String
    public var order: Int
    public var duration: Double?
    public var dialogue: String
    public var nodeIDs: [UUID]
    public var relatedRecordIDs: [UUID]
    public init(id: UUID = UUID(), kind: Kind, name: String, order: Int = 0,
                duration: Double? = nil, dialogue: String = "", nodeIDs: [UUID] = [],
                relatedRecordIDs: [UUID] = []) {
        self.id = id; self.kind = kind; self.name = name; self.order = order
        self.duration = duration; self.dialogue = dialogue; self.nodeIDs = nodeIDs
        self.relatedRecordIDs = relatedRecordIDs
    }
}

/// A reusable definition, never a live run or another document authority.
public struct CanvasTemplate: Codable, Hashable, Sendable, Identifiable {
    public var schemaVersion: Int = 1
    public var id: UUID
    public var version: Int
    public var title: TemplateText
    public var summary: TemplateText
    public var category: TemplateCategory
    public var isBuiltIn: Bool
    public var snapshot: CanvasSnapshot
    public var slots: [TemplateSlot]
    public var records: [CreativeRecord]
    public var extensions: [String: JSONValue]
    public init(id: UUID = UUID(), version: Int = 1, title: TemplateText,
                summary: TemplateText, category: TemplateCategory, isBuiltIn: Bool = false,
                snapshot: CanvasSnapshot, slots: [TemplateSlot] = [],
                records: [CreativeRecord] = [], extensions: [String: JSONValue] = [:]) {
        self.id = id; self.version = version; self.title = title; self.summary = summary
        self.category = category; self.isBuiltIn = isBuiltIn; self.snapshot = snapshot
        self.slots = slots; self.records = records; self.extensions = extensions
    }
}

public struct CanvasTemplateInstance: Codable, Hashable, Sendable {
    public var templateID: UUID
    public var templateVersion: Int
    public var instanceID: UUID
    public var snapshot: CanvasSnapshot
    public var slots: [TemplateSlot]
    public var records: [CreativeRecord]
    public var identityMap: [UUID: UUID]
    public var missingRequiredInputs: [String] {
        slots.filter { $0.required && !Self.hasContent(nodeID: $0.nodeID, in: snapshot) }.map(\.id)
    }
    static func hasContent(nodeID: UUID, in snapshot: CanvasSnapshot) -> Bool {
        guard let n = snapshot.pages.flatMap(\.nodes).first(where: { $0.id == nodeID }) else { return false }
        switch n.content {
        case .text(let text): return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .markdown(let text, _): return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default: return true
        }
    }
}

/// Intent passed to an EXISTING host executor. This enum does not call providers itself.
public enum TemplateOperation: String, Codable, CaseIterable, Sendable {
    case ideate, organize, analyzeReference, writeScript, writeLyrics, planShots, extractCharacters
    case generateImage, generateVideo, generateMusic, synthesizeVoice, designLayout
    case editImage, editVideo, editMusic, editCAD, renderCAD
    public static let parameterKey = "floe.template.operation"
}

public enum TemplateCapturePolicy: Sendable, Equatable {
    /// Referenced assets/editor projects become reusable input slots.
    case inputsOnly
    /// Immutable media and source revisions remain; editable projects still become slots.
    case retainReadOnlySources
}
