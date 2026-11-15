import Foundation
import FloeMoleculePreviewBridge

public enum MoleculePreviewFormat: String, Codable, Sendable { case mol, smiles }
public struct MoleculePreviewOptions: Codable, Sendable, Equatable {
    public enum ForceField: String, Codable, Sendable { case mmff94 = "MMFF94", uff = "UFF", none }
    public var seed: Int = 42
    public var timeoutMilliseconds: Int = 3_000
    public var maxIterations: Int = 100
    public var forceField: ForceField = .mmff94
    public init() {}
}
public struct MoleculePreviewResult: Codable, Sendable, Equatable {
    public let cjson: String
    public let molblock: String
    public let canonicalSmiles: String
    public let inputAtomCount: Int
    public let atomCount: Int
    public let bondCount: Int
    public let inputAtomToOutput: [Int]
    public let specifiedStereoCenters: Int
    public let specifiedStereoPreserved: Bool
    public let engine: String
    public let method: String
    public let seed: Int
    public let forceField: String
    public let optimizationStatus: String
    public let optimizationIterationBudgetUsed: Int
    public let energy: Double?
    public let energyUnits: String
    public let embeddingMilliseconds: Double
    public let totalMilliseconds: Double
}
public struct MoleculePreviewError: Error, LocalizedError, Sendable {
    public let code: String
    public let message: String
    public var errorDescription: String? { message }
}

/// The call retains this token until the actual native worker has stopped.
/// Cancellation is cooperative at embedding attempts and optimization chunks.
public final class MoleculePreviewCancellation: @unchecked Sendable {
    fileprivate let pointer: UnsafeMutableRawPointer
    public init() throws {
        guard let value = fmp_cancel_create() else {
            throw MoleculePreviewError(code: "allocationFailed", message: "Could not allocate the preview cancellation token.")
        }
        pointer = value
    }
    deinit { fmp_cancel_destroy(pointer) }
    public func cancel() { fmp_cancel_request(pointer) }
    public var stage: Int { Int(fmp_stage(pointer)) }
}

public enum MoleculePreviewNative {
    public static let version = "RDKit 2026.09.1 / fece8caa / preview-1"
    private struct Request: Encodable {
        let input: String
        let format: MoleculePreviewFormat
        let options: MoleculePreviewOptions
    }
    private struct Envelope: Decodable {
        let ok: Bool
        let result: MoleculePreviewResult?
        let code: String?
        let error: String?
    }
    public static func generate(input: String, format: MoleculePreviewFormat,
                                options: MoleculePreviewOptions = .init(),
                                cancellation: MoleculePreviewCancellation? = nil) async throws -> MoleculePreviewResult {
        guard !input.isEmpty, input.utf8.count <= 256 * 1024, !input.utf8.contains(0) else {
            throw MoleculePreviewError(code: "invalidInput", message: "Empty or oversized molecule input.")
        }
        let token = try cancellation ?? MoleculePreviewCancellation()
        let bytes = try JSONEncoder().encode(Request(input: input, format: format, options: options))
        let request = String(decoding: bytes, as: UTF8.self)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let text: String = try await Task.detached(priority: .userInitiated) {
                try withExtendedLifetime(token) {
                    try request.withCString { raw in
                        guard let response = fmp_generate(raw, token.pointer) else {
                            throw MoleculePreviewError(code: "nativeFailure", message: "The native generator did not return a bounded response.")
                        }
                        defer { fmp_free(response) }
                        return String(cString: response)
                    }
                }
            }.value
            // Awaiting the detached worker above is intentional: no late result
            // may outlive a caller's claim that cancellation has completed.
            try Task.checkCancellation()
            let envelope = try JSONDecoder().decode(Envelope.self, from: Data(text.utf8))
            guard envelope.ok, let result = envelope.result else {
                throw MoleculePreviewError(code: envelope.code ?? "nativeFailure", message: envelope.error ?? "Unable to generate a preview.")
            }
            return result
        } onCancel: { token.cancel() }
    }
}
