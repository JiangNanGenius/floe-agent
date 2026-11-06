import Foundation
import FloeChemistryCore

public struct ChemistryToolDescriptor: Codable, Sendable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue
}

/// Created by the host from task/document grants. Imported files and model arguments cannot extend this scope.
public actor ChemistryToolSession {
    public let taskID: UUID
    private let service: ChemistryService
    private var projectIDs: Set<UUID>
    private let canCreate: Bool
    public init(taskID: UUID, service: ChemistryService, authorizedProjectIDs: Set<UUID>, canCreate: Bool = false) {
        self.taskID = taskID; self.service = service; projectIDs = authorizedProjectIDs; self.canCreate = canCreate
    }
    public func descriptors() async -> [ChemistryToolDescriptor] {
        let methods = await service.capabilities()
        let schema: JSONValue = .object([
            "type": .string("object"), "additionalProperties": .bool(false),
            "properties": .object([
                "projectID": .object(["type": .string("string")]),
                "objectID": .object(["type": .string("string")]),
                "runID": .object(["type": .string("string")]),
                "title": .object(["type": .string("string")]),
                "kind": .object(["type": .string("string"), "enum": .array(ChemicalKind.allCases.map { .string($0.rawValue) })]),
                "format": .object(["type": .string("string")]), "source": .object(["type": .string("string")]),
                "deferPreparation": .object(["type": .string("boolean"),
                    "description": .string("Preserve CIF/mmCIF, stereo SMILES or reaction inputs for explicit preparation by a configured worker. No calculated facts are claimed until the worker succeeds.")]),
                "method": .object(["type": .string("string"), "enum": .array(Set(methods.values.flatMap { $0 }).sorted().map(JSONValue.string))]),
                "environmentID": .object(["type": .string("string"), "enum": .array(methods.keys.sorted().map(JSONValue.string))]),
                "options": .object(["type": .string("object")]), "edits": .object(["type": .string("array")]),
                "expectedObjectRevision": .object(["type": .string("integer"), "minimum": .number(0)])
            ])
        ])
        let names = ["project.read", "object.import", "object.replace", "object.edit", "object.export", "run.start", "run.status", "run.cancel", "run.apply"] + (canCreate ? ["project.create"] : [])
        return names.map { ChemistryToolDescriptor(name: "chemistry." + $0,
            description: "Operate on authorized chemistry projects. Actual configured methods: " + methods.map { $0.key + ": " + $0.value.joined(separator: ", ") }.sorted().joined(separator: "; "),
            inputSchema: schema) }
    }
    private func string(_ args: JSONValue, _ key: String) throws -> String {
        guard let value = args[key]?.string, !value.isEmpty else { throw ChemistryError.invalid("Missing \(key).") }; return value
    }
    private func uuid(_ args: JSONValue, _ key: String) throws -> UUID {
        guard let value = UUID(uuidString: try string(args, key)) else { throw ChemistryError.invalid("Invalid \(key).") }; return value
    }
    private func revision(_ args: JSONValue) throws -> UInt64 {
        guard let value = args["expectedObjectRevision"]?.number, value.isFinite, value >= 0,
              value <= 9_007_199_254_740_991, value.rounded() == value else { throw ChemistryError.invalid("An exact object revision is required.") }
        return UInt64(value)
    }
    private func encoded<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
    public func invoke(name: String, arguments: JSONValue) async throws -> JSONValue {
        guard try JSONEncoder().encode(arguments).count <= 20 * 1024 * 1024 else { throw ChemistryError.invalid("Tool input exceeds its size limit.") }
        if name == "chemistry.project.create" {
            guard canCreate else { throw ChemistryError.unavailable("Project creation is outside this task's scope.") }
            let p = try await service.create(title: string(arguments, "title")); projectIDs.insert(p.id)
            return try encoded(p)
        }
        let id = try uuid(arguments, "projectID")
        guard projectIDs.contains(id) else { throw ChemistryError.unavailable("This project is outside the task's authorized scope.") }
        switch name {
        case "chemistry.project.read": return try encoded(await service.project(id))
        case "chemistry.object.import":
            let kind = ChemicalKind(rawValue: arguments["kind"]?.string ?? "molecule")
            guard let kind else { throw ChemistryError.invalid("Unknown chemistry object kind.") }
            return try encoded(await service.importObject(id, title: string(arguments,"title"), kind: kind,
                format: string(arguments,"format"), source: string(arguments,"source"), deferPreparation: arguments["deferPreparation"] == .bool(true)))
        case "chemistry.object.replace":
            return try encoded(await service.replaceObject(id, objectID: uuid(arguments,"objectID"), expectedObjectRevision: revision(arguments), format: string(arguments,"format"), source: string(arguments,"source")))
        case "chemistry.object.edit":
            guard let edits = arguments["edits"] else { throw ChemistryError.invalid("Edits are required.") }
            return try encoded(await service.editObject(id, objectID: uuid(arguments,"objectID"), expectedObjectRevision: revision(arguments), edits: edits))
        case "chemistry.object.export": return .string(try await service.export(id, objectID: uuid(arguments,"objectID"), format: string(arguments,"format")))
        case "chemistry.run.start":
            let run = try await service.start(id, objectID: uuid(arguments,"objectID"), method: string(arguments,"method"), options: arguments["options"] ?? .object([:]), environmentID: arguments["environmentID"]?.string)
            return .object(["runID": .string(run.uuidString), "projectID": .string(id.uuidString)])
        case "chemistry.run.status":
            let p = try await service.project(id); let runID = try uuid(arguments,"runID")
            guard let run = p.runs.first(where: { $0.id == runID }) else { throw ChemistryError.invalid("Run not found in this project.") }; return try encoded(run)
        case "chemistry.run.cancel": try await service.cancel(id, runID: uuid(arguments,"runID")); return .object(["cancelled": .bool(true)])
        case "chemistry.run.apply": return try encoded(await service.apply(id, runID: uuid(arguments,"runID"), expectedObjectRevision: revision(arguments)))
        default: throw ChemistryError.invalid("Unknown chemistry tool.")
        }
    }
}
