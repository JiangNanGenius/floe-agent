import Foundation
import FloeChemistryCore
import FloeChemistryNative

public struct ChemistryRequest: Codable, Sendable {
    public var operation: String
    public var format: String
    public var data: String
    public var options: JSONValue
    public init(operation: String, format: String, data: String, options: JSONValue = .object([:])) {
        self.operation = operation; self.format = format; self.data = data; self.options = options
    }
}
public protocol ChemistryBackend: Sendable {
    var environmentID: String { get }
    var engineVersion: String { get }
    var methods: Set<String> { get }
    func evaluate(_ request: ChemistryRequest) async throws -> JSONValue
}

public struct NativeChemistryBackend: ChemistryBackend {
    public let environmentID: String
    public var engineVersion: String { ChemistryNative.version }
    public let methods: Set<String> = ["parse", "analyze", "export", "edit", "uff.energy", "uff.optimize", "crystal.supercell", "measure", "trajectory.frame", "reaction.balance", "spectrum.analyze"]
    public init(environmentID: String = "native.local") { self.environmentID = environmentID }
    public func evaluate(_ request: ChemistryRequest) async throws -> JSONValue {
        guard methods.contains(request.operation), request.data.utf8.count <= 16 * 1024 * 1024 else { throw ChemistryError.invalid("Unsupported native request.") }
        if request.operation == "spectrum.analyze" {
            return try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(SpectrumAnalysis.csv(request.data)))
        }
        if request.operation == "reaction.balance" {
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(request.data.utf8))
            guard let left = value["reactants"]?.array, let right = value["products"]?.array,
                  left.allSatisfy({ $0.string != nil }), right.allSatisfy({ $0.string != nil }) else { throw ChemistryError.invalid("Reaction inputs must be formula arrays.") }
            let coefficients = try ReactionBalancer.balance(reactants: left.compactMap(\.string), products: right.compactMap(\.string))
            return .object(["coefficients": .array(coefficients.map { .number(Double($0)) }), "method": .string("Exact atom and charge conservation")])
        }
        let token = try ChemistryCancellation()
        let bytes = try JSONEncoder().encode(request)
        let text = String(decoding: bytes, as: UTF8.self)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let raw = try await Task.detached(priority: .userInitiated) {
                try ChemistryNative.execute(text, cancellation: token)
            }.value
            try Task.checkCancellation()
            let envelope = try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
            guard envelope["ok"] == .bool(true), let result = envelope["result"] else {
                if envelope["cancelled"] == .bool(true) { throw ChemistryError.cancelled }
                throw ChemistryError.invalid(envelope["error"]?.string ?? "Native chemistry failed.")
            }
            return result
        } onCancel: { token.cancel() }
    }
}

/// The host supplies an already resolved environment/job adapter; this module never falls back to a host interpreter.
public struct ConfiguredChemistryBackend: ChemistryBackend {
    public let environmentID: String
    public let engineVersion: String
    public let methods: Set<String>
    private let execute: @Sendable (ChemistryRequest) async throws -> JSONValue
    public init(environmentID: String, engineVersion: String, methods: Set<String>,
                execute: @escaping @Sendable (ChemistryRequest) async throws -> JSONValue) {
        self.environmentID = environmentID; self.engineVersion = engineVersion; self.methods = methods; self.execute = execute
    }
    public func evaluate(_ request: ChemistryRequest) async throws -> JSONValue {
        guard methods.contains(request.operation) else { throw ChemistryError.unavailable("Method is unavailable in this environment.") }
        return try await execute(request)
    }
    public static func worker(environmentID: String, engineVersion: String, methods: Set<String>,
                              execute: @escaping @Sendable (Data) async throws -> Data) -> Self {
        Self(environmentID: environmentID, engineVersion: engineVersion, methods: methods) { request in
            let response = try await execute(JSONEncoder().encode(request))
            guard response.count <= 64 * 1024 * 1024 else { throw ChemistryError.invalid("Worker output exceeds its size limit.") }
            let value = try JSONDecoder().decode(JSONValue.self, from: response)
            guard value["ok"] == .bool(true), let result = value["result"] else { throw ChemistryError.invalid(value["error"]?.string ?? "Worker returned no result.") }
            return result
        }
    }
}

public enum ChemistryAccessAction: String, Sendable { case create, list, read, edit, compute, export, restore }
public struct ChemistryAccess: Sendable {
    public let projectID: UUID?
    public let action: ChemistryAccessAction
    public let environmentID: String?
}
public typealias ChemistryAuthorizer = @Sendable (ChemistryAccess) async throws -> Void
