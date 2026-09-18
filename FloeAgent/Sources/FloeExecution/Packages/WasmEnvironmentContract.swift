// FloeExecution — bounded environment contract for the WASI command runtime.
//
// A real interactive shell exports the whole engine environment: the variables
// the host / ios_system initializes plus the dependency environment injected
// through `FloeShellSetEnvironment`. The previous 32-variable cap rejected
// those legitimate exports, so `floe-lua -e "print(2 + 40)"` failed with
// "WASM input exceeds limits" in build 184's full-app regression.
//
// The contract bounds the *shape and size* of the environment instead of
// dropping variables by name. A name-based filter cannot distinguish a
// host-internal variable from a legitimate user `export`, and silently
// truncating variables would change script behaviour without evidence. Each
// violation names the exact field and limit and never includes a key or value,
// so a cloud run can prove which boundary fired without leaking content.

import Foundation

/// Limits enforced before any environment dictionary reaches the WASI guest.
///
/// The limits are per-invocation. The byte limits count the encoded
/// `KEY=VALUE` payload (without the trailing NUL) that the WASI host builds.
public enum WasmEnvironmentContract {
    /// A real iOS host/shell export set is dozens of variables; this leaves
    /// generous headroom while still bounding a pathological environment.
    public static let maximumVariables = 256
    /// Total encoded `KEY=VALUE` bytes for the whole environment.
    public static let maximumTotalBytes = 64 * 1024
    /// Maximum bytes of one variable name.
    public static let maximumKeyBytes = 256
    /// Maximum bytes of one variable value.
    public static let maximumValueBytes = 16 * 1024

    /// A precise, content-free rejection reason. `description` is what reaches
    /// the command's stderr, so it must stay stable and value-free.
    public enum Violation: Error, Equatable, Sendable, CustomStringConvertible {
        case tooManyVariables(actual: Int, limit: Int)
        case totalBytesExceeded(actual: Int, limit: Int)
        case keyTooLong(limit: Int)
        case valueTooLong(limit: Int)
        case keyContainsNUL
        case valueContainsNUL
        case invalidKey(Reason)

        public enum Reason: String, Sendable {
            case empty
            case containsEquals
            case containsControlCharacter
        }

        public var description: String {
            switch self {
            case .tooManyVariables(let actual, let limit):
                return "WASM environment has too many variables: \(actual) > \(limit)"
            case .totalBytesExceeded(let actual, let limit):
                return "WASM environment exceeds \(limit) total bytes: \(actual)"
            case .keyTooLong(let limit):
                return "WASM environment key exceeds \(limit) bytes"
            case .valueTooLong(let limit):
                return "WASM environment value exceeds \(limit) bytes"
            case .keyContainsNUL:
                return "WASM environment key contains NUL"
            case .valueContainsNUL:
                return "WASM environment value contains NUL"
            case .invalidKey(let reason):
                return "WASM environment key is invalid: \(reason.rawValue)"
            }
        }
    }

    /// Validates one environment dictionary without mutating it. Throws the
    /// boundary violation without exposing the offending key or value.
    public static func validate(_ environment: [String: String]) throws {
        guard environment.count <= maximumVariables else {
            throw Violation.tooManyVariables(actual: environment.count, limit: maximumVariables)
        }
        var total = 0
        for (key, value) in environment {
            guard !key.isEmpty else { throw Violation.invalidKey(.empty) }
            guard !key.contains("=") else { throw Violation.invalidKey(.containsEquals) }
            guard !key.contains("\0") else { throw Violation.keyContainsNUL }
            guard !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Violation.invalidKey(.containsControlCharacter) }
            guard key.utf8.count <= maximumKeyBytes else { throw Violation.keyTooLong(limit: maximumKeyBytes) }
            guard !value.contains("\0") else { throw Violation.valueContainsNUL }
            guard value.utf8.count <= maximumValueBytes else { throw Violation.valueTooLong(limit: maximumValueBytes) }
            total += key.utf8.count + 1 + value.utf8.count
        }
        guard total <= maximumTotalBytes else {
            throw Violation.totalBytesExceeded(actual: total, limit: maximumTotalBytes)
        }
    }

    /// Encoded `KEY=VALUE` payload bytes for one entry.
    public static func encodedBytes(key: String, value: String) -> Int {
        key.utf8.count + 1 + value.utf8.count
    }

}
