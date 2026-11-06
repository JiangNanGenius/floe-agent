import Foundation
import FloeChemistryCore

/// An actual capabilities response from the configured worker, not a list of installed files.
public struct ChemistryWorkerCapabilities: Sendable, Equatable {
    public let protocolVersion: Int
    public let methods: Set<String>
    public let engines: [String: String]
    public let unavailable: [String: String]
    public var engineVersion: String {
        engines.keys.sorted().map { $0 + " " + engines[$0]! }.joined(separator: "; ")
    }

    public static func decode(_ response: Data) throws -> Self {
        guard response.count <= 1024 * 1024 else { throw ChemistryError.invalid("Capability response exceeds its size limit.") }
        let envelope = try JSONDecoder().decode(JSONValue.self, from: response)
        guard envelope["ok"] == .bool(true), let result = envelope["result"],
              result["protocolVersion"] == .number(1),
              let list = result["methods"]?.array, list.count <= 128,
              case .object(let versions) = result["engines"] else {
            throw ChemistryError.unavailable(envelope["error"]?.string ?? "The environment did not return supported chemistry capabilities.")
        }
        let names = try list.map { value -> String in
            guard let name = value.string, !name.isEmpty, name.utf8.count <= 128,
                  name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) else {
                throw ChemistryError.invalid("Invalid worker method.")
            }
            return name
        }
        guard Set(names).count == names.count, versions.count <= 32 else { throw ChemistryError.invalid("Invalid worker capabilities.") }
        var engines: [String: String] = [:], unavailable: [String: String] = [:]
        for (name, version) in versions {
            guard !name.isEmpty, name.utf8.count <= 128, let text = version.string,
                  !text.isEmpty, text.utf8.count <= 1024 else { throw ChemistryError.invalid("Invalid engine version.") }
            engines[name] = text
        }
        if let diagnostics = result["unavailable"] {
            guard case .object(let values) = diagnostics, values.count <= 32 else { throw ChemistryError.invalid("Invalid capability diagnostics.") }
            for (name, value) in values {
                guard name.utf8.count <= 128, let reason = value.string, reason.utf8.count <= 4096 else {
                    throw ChemistryError.invalid("Invalid capability diagnostics.")
                }
                unavailable[name] = reason
            }
        }
        guard names.isEmpty || !engines.isEmpty else { throw ChemistryError.invalid("Worker methods have no engine provenance.") }
        return Self(protocolVersion: 1, methods: Set(names), engines: engines, unavailable: unavailable)
    }
}

public struct ChemistryPreparedRun: Codable, Sendable, Equatable {
    public let identity: ChemistryExecutionIdentity
    public let requestJSON: String
    public let requestDigest: String
    public var projectID: UUID { identity.projectID }
    public var runID: UUID { identity.runID }

    init(_ execution: ChemistryExternalExecution) {
        identity = execution.identity; requestJSON = execution.requestJSON; requestDigest = execution.requestDigest
    }
    public func requestData() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let value = ChemistryWorkerEnvelope(protocolName: "floe.chemistry.worker", version: 1,
            identity: identity, requestJSON: requestJSON, requestDigest: requestDigest)
        let bytes = try encoder.encode(value)
        guard bytes.count <= 16 * 1024 * 1024,
              requestDigest == ChemistryProjectStore.digest(Data(requestJSON.utf8)) else {
            throw ChemistryError.invalid("Worker request is oversized or its checksum does not match.")
        }
        return bytes
    }
}

private struct ChemistryWorkerEnvelope: Encodable {
    let protocolName: String
    let version: Int
    let identity: ChemistryExecutionIdentity
    let requestJSON: String
    let requestDigest: String
    enum CodingKeys: String, CodingKey { case protocolName = "protocol", version, identity, requestJSON, requestDigest }
}

struct ChemistryWorkerResponse: Decodable {
    let protocolName: String
    let version: Int
    let identity: ChemistryExecutionIdentity
    let requestDigest: String
    let ok: Bool
    let result: JSONValue?
    let error: String?
    enum CodingKeys: String, CodingKey { case protocolName = "protocol", version, identity, requestDigest, ok, result, error }

    static func decode(_ response: Data, for prepared: ChemistryPreparedRun) throws -> Self {
        guard !response.isEmpty, response.count <= 64 * 1024 * 1024 else {
            throw ChemistryError.invalid("Worker returned no complete bounded result.")
        }
        let value = try JSONDecoder().decode(Self.self, from: response)
        guard value.protocolName == "floe.chemistry.worker", value.version == 1,
              value.identity == prepared.identity, value.requestDigest == prepared.requestDigest else {
            throw ChemistryError.invalid("Worker result belongs to a different calculation or input.")
        }
        if value.ok {
            guard let result = value.result, case .object = result else {
                throw ChemistryError.invalid("Worker returned no structure or calculation result.")
            }
        } else {
            guard let error = value.error, !error.isEmpty, error.utf8.count <= 16 * 1024 else {
                throw ChemistryError.invalid("Worker returned an invalid failure response.")
            }
        }
        return value
    }
}
