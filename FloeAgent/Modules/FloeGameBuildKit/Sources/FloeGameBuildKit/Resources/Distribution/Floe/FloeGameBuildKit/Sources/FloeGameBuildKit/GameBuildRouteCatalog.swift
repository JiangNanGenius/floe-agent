// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

public enum GameBuildProducerKind: String, Codable, Equatable, Sendable {
    case ci
    case hostExporter
    case hostStatic
    case userEditor
    case manualEditor
    case sourceArchive
}

public enum GameBuildProofLevel: String, Codable, Equatable, Sendable {
    case actualBuildAndRuntime
    case actualExporterAndRuntime
    case actualRuntime
    case actualExporter
    case actualBuild
    case sourceQualified
    case commandOnly
    case userPrerequisite
}

public struct GameBuildRoute: Codable, Equatable, Sendable {
    public let id: String
    public let kind: GameBuildOutputKind
    public let platform: GameBuildPlatform?
    public let stageID: String
    public let artifactName: String
    public let producer: GameBuildProducerKind
    public let proof: GameBuildProofLevel
    public let playable: Bool
    public let deliveryNote: String
    public let requires: [String]
    public let templateID: String?
    public let jobID: String?
    public let component: String?
    public let entryPoint: String?
    public let validation: GameArtifactValidationRule
    public let enabledByDefault: Bool

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        kind = try values.decode(GameBuildOutputKind.self, forKey: .kind)
        platform = try values.decodeIfPresent(GameBuildPlatform.self, forKey: .platform)
        stageID = try values.decode(String.self, forKey: .stageID)
        artifactName = try values.decode(String.self, forKey: .artifactName)
        producer = try values.decode(GameBuildProducerKind.self, forKey: .producer)
        proof = try values.decode(GameBuildProofLevel.self, forKey: .proof)
        playable = try values.decode(Bool.self, forKey: .playable)
        deliveryNote = try values.decode(String.self, forKey: .deliveryNote)
        requires = try values.decodeIfPresent([String].self, forKey: .requires) ?? []
        templateID = try values.decodeIfPresent(String.self, forKey: .templateID)
        jobID = try values.decodeIfPresent(String.self, forKey: .jobID)
        component = try values.decodeIfPresent(String.self, forKey: .component)
        entryPoint = try values.decodeIfPresent(String.self, forKey: .entryPoint)
        validation = try values.decodeIfPresent(GameArtifactValidationRule.self, forKey: .validation)
            ?? GameArtifactValidationRule()
        enabledByDefault = try values.decodeIfPresent(Bool.self, forKey: .enabledByDefault) ?? true
    }

    public init(id: String, kind: GameBuildOutputKind, platform: GameBuildPlatform?,
                stageID: String, artifactName: String, producer: GameBuildProducerKind,
                proof: GameBuildProofLevel, playable: Bool, deliveryNote: String,
                requires: [String] = [], templateID: String? = nil, jobID: String? = nil,
                component: String? = nil, entryPoint: String? = nil,
                validation: GameArtifactValidationRule = .init(), enabledByDefault: Bool = true) {
        self.id = id; self.kind = kind; self.platform = platform; self.stageID = stageID
        self.artifactName = artifactName; self.producer = producer; self.proof = proof
        self.playable = playable; self.deliveryNote = deliveryNote; self.requires = requires
        self.templateID = templateID; self.jobID = jobID; self.component = component
        self.entryPoint = entryPoint; self.validation = validation
        self.enabledByDefault = enabledByDefault
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, platform, stageID, artifactName, producer, proof, playable
        case deliveryNote, requires, templateID, jobID, component, entryPoint, validation, enabledByDefault
    }
}

public struct GameBuildAdapterBinding: Codable, Equatable, Sendable {
    public let kind: String
    public let component: String
    public let entryPoint: String
    public let sourceStatus: String
}

public struct GameEngineBuildRoutes: Decodable, Equatable, Sendable {
    public let engine: GameEngineID
    public let adapter: GameBuildAdapterBinding
    public let distributionProfileID: String
    public let stages: [GameBuildStage]
    public let routes: [GameBuildRoute]
    public let prerequisites: [GameBuildPrerequisite]
    public let workflowTemplateID: String?
    public let sourceTransports: [GameBuildSourceTransportKind]
    public let notes: [String]

    private enum CodingKeys: String, CodingKey {
        case engine, adapter, distributionProfileID, stages, routes, prerequisites
        case workflowTemplateID, sourceTransports, notes
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        engine = try values.decode(GameEngineID.self, forKey: .engine)
        adapter = try values.decode(GameBuildAdapterBinding.self, forKey: .adapter)
        distributionProfileID = try values.decode(String.self, forKey: .distributionProfileID)
        stages = try values.decode([GameBuildStage].self, forKey: .stages)
        routes = try values.decode([GameBuildRoute].self, forKey: .routes)
        prerequisites = try values.decode([GameBuildPrerequisite].self, forKey: .prerequisites)
        workflowTemplateID = try values.decodeIfPresent(String.self, forKey: .workflowTemplateID)
        let kinds = try values.decodeIfPresent([String].self, forKey: .sourceTransports)
            ?? ["repositorySnapshot", "existingArtifact"]
        sourceTransports = try kinds.map {
            guard let value = GameBuildSourceTransportKind(rawValue: $0) else {
                throw DecodingError.dataCorruptedError(forKey: .sourceTransports, in: values,
                    debugDescription: "unknown source transport \($0)")
            }
            return value
        }
        notes = try values.decodeIfPresent([String].self, forKey: .notes) ?? []
    }
}

public struct GameBuildRouteCatalog: Decodable, Equatable, Sendable {
    public let schemaVersion: Int
    public let catalogID: String
    public let engineCount: Int
    public let engines: [GameEngineBuildRoutes]
    public let notes: [String]
}

/// Locates resources whether SwiftPM preserved the `.copy("Resources")`
/// directory or a host flattened it into the bundle root.
enum GameBuildResourceLocator {
    static func url(_ name: String, _ extensionName: String,
                    _ subdirectory: String, bundle: Bundle = .module) -> URL? {
        if let value = bundle.url(forResource: name, withExtension: extensionName,
                                  subdirectory: subdirectory) {
            return value
        }
        if subdirectory.hasPrefix("Resources/") {
            let stripped = String(subdirectory.dropFirst("Resources/".count))
            if let value = bundle.url(forResource: name, withExtension: extensionName,
                                      subdirectory: stripped) {
                return value
            }
        }
        return bundle.url(forResource: name, withExtension: extensionName)
    }
}

public enum GameBuildCatalogLoader {
    public static func load(bundle: Bundle? = nil) throws -> GameBuildRouteCatalog {
        let bundle = bundle ?? .module
        guard let url = GameBuildResourceLocator.url("build-routes.v1", "json",
                                                     "Resources/Catalog", bundle: bundle) else {
            throw GameBuildCapabilityError.invalidRouteCatalog("missing build-routes.v1.json")
        }
        do {
            let catalog = try JSONDecoder().decode(GameBuildRouteCatalog.self, from: Data(contentsOf: url))
            try validate(catalog)
            return catalog
        } catch let error as GameBuildCapabilityError {
            throw error
        } catch {
            throw GameBuildCapabilityError.invalidRouteCatalog(String(describing: error))
        }
    }

    public static func validate(_ catalog: GameBuildRouteCatalog) throws {
        guard catalog.schemaVersion == 1,
              catalog.engineCount == 20,
              catalog.engines.count == catalog.engineCount,
              Set(catalog.engines.map(\.engine)).count == catalog.engines.count,
              Set(catalog.engines.map(\.engine)) == Set(GameEngineID.allCases) else {
            throw GameBuildCapabilityError.invalidRouteCatalog("engine coverage is not the agreed 20")
        }
        for entry in catalog.engines {
            let stageIDs = Set(entry.stages.map(\.id))
            guard !entry.routes.isEmpty, !entry.stages.isEmpty,
                  !entry.distributionProfileID.isEmpty,
                  entry.routes.allSatisfy({ stageIDs.contains($0.stageID) }),
                  Set(entry.routes.map(\.id)).count == entry.routes.count else {
                throw GameBuildCapabilityError.invalidRouteCatalog("\(entry.engine.rawValue) route/stage mismatch")
            }
            for route in entry.routes {
                if route.kind == .sourceArchive {
                    guard !route.playable, route.stageID == "prepare" else {
                        throw GameBuildCapabilityError.invalidRouteCatalog("source archive must not claim playability")
                    }
                }
                if route.platform == .ios {
                    guard route.kind == .nativeProject, !route.artifactName.lowercased().hasSuffix(".ipa") else {
                        throw GameBuildCapabilityError.invalidRouteCatalog("iOS output must be an Xcode project, not an IPA")
                    }
                }
            }
        }
    }
}
