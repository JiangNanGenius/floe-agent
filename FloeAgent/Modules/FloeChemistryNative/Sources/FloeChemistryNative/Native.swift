import Foundation
import FloeChemistryBridge

public enum NativeChemistryError: Error, LocalizedError, Sendable {
    case oversized, allocationFailed
    public var errorDescription: String? {
        switch self {
        case .oversized: "Chemical input exceeds the native request limit."
        case .allocationFailed: "Native chemistry could not allocate its response."
        }
    }
}

/// A thread-safe native cancellation flag. The bridge observes it between optimizer chunks.
public final class ChemistryCancellation: @unchecked Sendable {
    private let token: UnsafeMutableRawPointer
    public init() throws {
        guard let value = fch_cancel_create() else { throw NativeChemistryError.allocationFailed }
        token = value
    }
    deinit { fch_cancel_destroy(token) }
    public func cancel() { fch_cancel_request(token) }
    fileprivate var pointer: UnsafeMutableRawPointer { token }
}

public enum ChemistryNative {
    public static let version = "Avogadro a5947518efb84132a44110dbdecab94fc87ce3b8"
    public static func execute(_ requestJSON: String, cancellation: ChemistryCancellation? = nil) throws -> String {
        guard requestJSON.utf8.count <= 16 * 1024 * 1024, !requestJSON.utf8.contains(0) else { throw NativeChemistryError.oversized }
        return try withExtendedLifetime(cancellation) {
            try requestJSON.withCString { request in
                guard let response = fch_execute(request, cancellation?.pointer) else { throw NativeChemistryError.allocationFailed }
                defer { fch_free(response) }
                return String(cString: response)
            }
        }
    }
}
