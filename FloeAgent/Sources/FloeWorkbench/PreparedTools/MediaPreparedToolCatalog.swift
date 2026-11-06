// SPDX-License-Identifier: MPL-2.0
import Foundation

/// The complete editing surface and its execution routes are distinct facts.
/// Registration comes from an actual backend, never from a planned button.
public struct MediaPreparedToolDescriptor: Sendable, Codable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Codable { case image, video }
    public enum SourceState: String, Sendable, Codable { case planned, sourcePresent }
    public enum ModelBackend: String, Sendable, Codable { case imageModel, textModel }
    public var id: String
    public var kind: Kind
    public var category: String
    public var title: String
    public var titleEnglish: String
    public var icon: String
    public var sourceState: SourceState
    public var existingCommand: String?
    public var modelBackend: ModelBackend?
    public var scope: String
    public var transaction: String
    public var saveContract: String
    public var acceptance: [String]

    public func localizedTitle(languageCode: String) -> String {
        languageCode.lowercased().hasPrefix("zh") ? title : titleEnglish
    }
}

public enum MediaPreparedToolCatalogError: Error, Sendable, Equatable {
    case invalidSchema
    case invalidDescriptor(String)
    case duplicateID(String)
    case unknownTool(String)
    case unavailableBackend
    case unconfiguredModel(String)
}

public struct MediaPreparedToolCatalog: Sendable {
    public let entries: [MediaPreparedToolDescriptor]
    private let byID: [String: MediaPreparedToolDescriptor]

    private struct Envelope: Decodable {
        let schema: Int
        let entries: [MediaPreparedToolDescriptor]
    }

    public init(data: Data) throws {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.schema == 1 else { throw MediaPreparedToolCatalogError.invalidSchema }
        var index: [String: MediaPreparedToolDescriptor] = [:]
        for descriptor in envelope.entries {
            guard descriptor.id.hasPrefix(descriptor.kind.rawValue + "."),
                  !descriptor.category.isEmpty, !descriptor.title.isEmpty, !descriptor.titleEnglish.isEmpty,
                  descriptor.transaction == "instructionGroup",
                  descriptor.saveContract == "projectRevisionAndJournal" else {
                throw MediaPreparedToolCatalogError.invalidDescriptor(descriptor.id)
            }
            guard index[descriptor.id] == nil else {
                throw MediaPreparedToolCatalogError.duplicateID(descriptor.id)
            }
            index[descriptor.id] = descriptor
        }
        entries = envelope.entries
        byID = index
    }

    public func descriptor(id: String) throws -> MediaPreparedToolDescriptor {
        guard let descriptor = byID[id] else { throw MediaPreparedToolCatalogError.unknownTool(id) }
        return descriptor
    }

    /// The host supplies only backend registrations and actually configured
    /// models. Developer membership, balance or previous smoke-test status
    /// cannot disable a user-configured provider here.
    public struct Backends: Sendable {
        public var localToolIDs: Set<String>
        public var imageModelIDs: Set<String>
        public var textModelIDs: Set<String>

        public init(localToolIDs: Set<String> = [], imageModelIDs: Set<String> = [],
                    textModelIDs: Set<String> = []) {
            self.localToolIDs = localToolIDs
            self.imageModelIDs = imageModelIDs
            self.textModelIDs = textModelIDs
        }
    }

    public enum Route: Sendable, Equatable {
        case local
        case imageModel(id: String)
        case textModel(id: String)
    }

    public func routes(for id: String, backends: Backends) throws -> [Route] {
        let descriptor = try descriptor(id: id)
        var result: [Route] = []
        if backends.localToolIDs.contains(id) { result.append(.local) }
        switch descriptor.modelBackend {
        case .imageModel:
            result += backends.imageModelIDs.sorted().map { .imageModel(id: $0) }
        case .textModel:
            result += backends.textModelIDs.sorted().map { .textModel(id: $0) }
        case nil: break
        }
        return result
    }

    /// User/model chooses a route. A failed explicit choice never silently
    /// switches provider, uploads an asset, or substitutes an approximate edit.
    public func validate(route: Route, for id: String, backends: Backends) throws {
        guard try routes(for: id, backends: backends).contains(route) else {
            switch route {
            case .local: throw MediaPreparedToolCatalogError.unavailableBackend
            case .imageModel(let id), .textModel(let id):
                throw MediaPreparedToolCatalogError.unconfiguredModel(id)
            }
        }
    }

    public func discoverUsable(kind: MediaPreparedToolDescriptor.Kind,
                               backends: Backends) -> [MediaPreparedToolDescriptor] {
        entries.filter { $0.kind == kind && ((try? routes(for: $0.id, backends: backends).isEmpty) == false) }
    }
}
