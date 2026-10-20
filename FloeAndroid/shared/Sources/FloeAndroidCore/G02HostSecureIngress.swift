// SPDX-License-Identifier: MPL-2.0
//
// G02 production composition — TRUSTED NATIVE HOST secure-ingress seam.
//
// The App editors (provider / MCP / web-search) never mint route authority.
// Each live editor sheet calls `floe_host_route_open` at editor open and
// passes the returned opaque handle back at close (`floe_host_route_clear`).
// At save-tap the App freezes the closed candidate/subject/baseRevision and
// submits it through `floe_host_save_intent_submit` together with its own
// route handle and the bounded secret bytes; the native seam injects the
// ROUTE PAIR from the live, accepted-Root-epoch binding and hands the frozen
// intent to the ORIGINAL one-shot vault. The public command then carries only
// the one-shot `int:v1:` handle (`secretIntent:"set"` + `ingressToken`), so a
// model-authored V3 command can never freeze, forge or widen authority.
//
// This seam is NOT a V3 command/tool: it is exported to the App host only
// (JNI), has no command name, no permission and no payload vocabulary.
//
// Status codes are the frozen vault/JNI numeric surface plus two route
// refusals; no path, token, candidate or secret is ever returned in an error.
import Foundation

public enum G02HostSecureIngressError: Error, Equatable {
    case invalidArgument
    case invalidIntent
    case secretTooLarge
    case intentTooLarge
    case emptySecret
    case saturated
    /// No accepted native Root epoch / no live bound route: fail closed.
    case routeUnavailable
    /// The caller's route handle is stale, foreign or for another subject
    /// kind: never consumes, never clears, never mints.
    case routeAssertionMismatch
    /// The editor incarnation is older than the newest admitted editor (or
    /// the same shared UI generation for a different editor): refused
    /// without mutating the live binding.
    case editorAdmissionStale
}

/// Frozen numeric statuses for the trusted host seam.
public enum G02HostSecureIngressStatus {
    public static let ok: Int32 = 0
    public static let invalidArgument: Int32 = -105
    public static let invalidIntent: Int32 = -110
    public static let secretTooLarge: Int32 = -111
    public static let saturated: Int32 = -112
    public static let emptySecret: Int32 = -115
    public static let intentTooLarge: Int32 = -116
    public static let routeUnavailable: Int32 = -117
    public static let routeAssertionMismatch: Int32 = -118
    public static let editorAdmissionStale: Int32 = -119
}

/// Typed Swift-facing facade used by the host tests and by the C exports.
public enum G02HostSecureIngress {
    public static var registry: G02HostRouteContextProvider {
        G02RuntimeComposition.shared.routeContext
    }

    public static func open(editorKind: String, editorID: String,
                            uiGeneration: UInt64,
                            expectedNativeRootEpoch: UInt64) -> RouteBinding? {
        registry.openEditorRoute(editorKind: editorKind, editorID: editorID,
                                 uiGeneration: uiGeneration,
                                 expectedNativeRootEpoch: expectedNativeRootEpoch)
    }

    public static func clear(token: String) {
        _ = registry.clearEditorRoute(token: token)
    }

    public static func submit(intentCoreJSON: Data, routeAssertion: String,
                              secret: Data) throws -> String {
        try registry.submitBoundIntent(intentCoreJSON: intentCoreJSON,
                                       routeAssertion: routeAssertion,
                                       secret: secret)
    }

    /// Worst-case route handle capacity including the NUL terminator.
    static let routeHandleCapacity: Int32 = 64

    /// The ACTUAL accepted native Root epoch right now (nil = none/fenced).
    /// Used only to classify the open refusal honestly; the admission itself
    /// re-reads it under the registry lock.
    static func liveAcceptedEpoch() -> UInt64? {
        registry.acceptedEpochSnapshot()
    }

    static func status(for error: Error) -> Int32 {
        if let ingress = error as? G02HostSecureIngressError {
            switch ingress {
            case .invalidArgument: return G02HostSecureIngressStatus.invalidArgument
            case .invalidIntent: return G02HostSecureIngressStatus.invalidIntent
            case .secretTooLarge: return G02HostSecureIngressStatus.secretTooLarge
            case .intentTooLarge: return G02HostSecureIngressStatus.intentTooLarge
            case .emptySecret: return G02HostSecureIngressStatus.emptySecret
            case .saturated: return G02HostSecureIngressStatus.saturated
            case .routeUnavailable: return G02HostSecureIngressStatus.routeUnavailable
            case .routeAssertionMismatch:
                return G02HostSecureIngressStatus.routeAssertionMismatch
            case .editorAdmissionStale:
                return G02HostSecureIngressStatus.editorAdmissionStale
            }
        }
        if let vault = error as? SaveIntentVaultError {
            switch vault {
            case .invalidArgument: return G02HostSecureIngressStatus.invalidArgument
            case .invalidSchema: return G02HostSecureIngressStatus.invalidIntent
            case .valueTooLarge: return G02HostSecureIngressStatus.secretTooLarge
            case .saturated: return G02HostSecureIngressStatus.saturated
            case .emptyValue: return G02HostSecureIngressStatus.emptySecret
            case .jsonTooLarge: return G02HostSecureIngressStatus.intentTooLarge
            }
        }
        return G02HostSecureIngressStatus.invalidArgument
    }
}

// MARK: - Trusted host C ABI (App process only; not a V3 command)

/// Admit ONE live editor incarnation and mint its canonical `rt:v1:` route
/// handle (copied into `outToken`, NUL included). The caller passes the
/// editor identity, the App-wide shared UI generation, and the native Root
/// epoch it captured AT EDITOR CREATION. Every argument (including the
/// output capacity) is validated BEFORE any live binding is mutated.
@_cdecl("floe_host_route_open")
public func floeHostRouteOpen(_ editorKind: UnsafePointer<CChar>?,
                              _ editorID: UnsafePointer<CChar>?,
                              _ uiGeneration: Int64,
                              _ expectedNativeRootEpoch: Int64,
                              _ outToken: UnsafeMutablePointer<CChar>?,
                              _ outCap: Int32) -> Int32 {
    // Capacity/shape first: a bad output buffer must never mint/replace a
    // live binding.
    guard let editorKind, let editorID, let outToken,
          outCap >= G02HostSecureIngress.routeHandleCapacity,
          uiGeneration > 0, expectedNativeRootEpoch > 0 else {
        return G02HostSecureIngressStatus.invalidArgument
    }
    guard let kindLength = hostCLength(editorKind, maximum: 32), kindLength > 0,
          let idLength = hostCLength(editorID, maximum: 128), idLength > 0 else {
        return G02HostSecureIngressStatus.invalidArgument
    }
    let kind = String(decoding: UnsafeBufferPointer(start: editorKind, count: kindLength)
        .map { UInt8(bitPattern: $0) }, as: UTF8.self)
    let identity = String(decoding: UnsafeBufferPointer(start: editorID, count: idLength)
        .map { UInt8(bitPattern: $0) }, as: UTF8.self)
    guard G02HostRouteContextProvider.isValidEditorID(identity),
          G02HostRouteContextProvider.editorKindSubject[kind] != nil else {
        return G02HostSecureIngressStatus.invalidArgument
    }
    // Distinguish "no live Root epoch" from a stale/foreign editor
    // incarnation so the host can report honestly.
    guard G02HostSecureIngress.liveAcceptedEpoch() != nil else {
        return G02HostSecureIngressStatus.routeUnavailable
    }
    guard let route = G02HostSecureIngress.open(
        editorKind: kind, editorID: identity,
        uiGeneration: UInt64(uiGeneration),
        expectedNativeRootEpoch: UInt64(expectedNativeRootEpoch)) else {
        return G02HostSecureIngressStatus.editorAdmissionStale
    }
    let bytes = Array(route.token.utf8)
    guard bytes.count + 1 <= Int(outCap) else {
        return G02HostSecureIngressStatus.invalidArgument
    }
    for (index, byte) in bytes.enumerated() { outToken[index] = CChar(bitPattern: byte) }
    outToken[bytes.count] = 0
    return G02HostSecureIngressStatus.ok
}

/// Exact-ownership close of the caller's own route handle. A stale handle is
/// an accepted no-op (it can never clear a newer binding).
@_cdecl("floe_host_route_clear")
public func floeHostRouteClear(_ token: UnsafePointer<CChar>?) -> Int32 {
    guard let token, let length = hostCLength(token, maximum: 64), length > 0 else {
        return G02HostSecureIngressStatus.invalidArgument
    }
    let value = String(decoding: UnsafeBufferPointer(start: token, count: length)
        .map { UInt8(bitPattern: $0) }, as: UTF8.self)
    guard G02HostRouteContextProvider.isCanonicalRouteToken(value) else {
        return G02HostSecureIngressStatus.invalidArgument
    }
    _ = G02HostSecureIngress.registry.clearEditorRoute(token: value)
    return G02HostSecureIngressStatus.ok
}

/// Atomic bound submit: the closed intent core (subject/intent/candidate/
/// baseRevision, NO route) + the caller's route handle + bounded secret
/// bytes. Returns the canonical one-shot `int:v1:` handle.
@_cdecl("floe_host_save_intent_submit")
public func floeHostSaveIntentSubmit(_ intentCoreJSON: UnsafePointer<CChar>?,
                                     _ routeToken: UnsafePointer<CChar>?,
                                     _ value: UnsafePointer<UInt8>?,
                                     _ valueLen: Int32,
                                     _ outToken: UnsafeMutablePointer<CChar>?,
                                     _ outCap: Int32) -> Int32 {
    guard let intentCoreJSON, let routeToken, let value, let outToken,
          outCap >= Int32(SecretSaveIntentLimits.ingressTokenCapacity),
          valueLen > 0 else {
        return G02HostSecureIngressStatus.invalidArgument
    }
    guard valueLen <= Int32(SecretSaveIntentLimits.maximumSecretBytes) else {
        return G02HostSecureIngressStatus.secretTooLarge
    }
    guard let jsonLength = hostCLength(intentCoreJSON,
                                       maximum: SecretSaveIntentLimits.maximumIntentJSONBytes),
          jsonLength > 0 else {
        return G02HostSecureIngressStatus.invalidIntent
    }
    guard let tokenLength = hostCLength(routeToken, maximum: 64), tokenLength > 0 else {
        return G02HostSecureIngressStatus.invalidArgument
    }
    let routeValue = String(decoding: UnsafeBufferPointer(start: routeToken, count: tokenLength)
        .map { UInt8(bitPattern: $0) }, as: UTF8.self)
    var secret = Data(bytes: UnsafeRawPointer(value), count: Int(valueLen))
    defer {
        if secret.count > 0 { secret.resetBytes(in: 0..<secret.count) }
        secret = Data()
    }
    do {
        let token = try G02HostSecureIngress.submit(
            intentCoreJSON: Data(bytes: UnsafeRawPointer(intentCoreJSON), count: jsonLength),
            routeAssertion: routeValue,
            secret: secret)
        guard token.utf8.count + 1 <= Int(outCap) else {
            return G02HostSecureIngressStatus.invalidArgument
        }
        for (index, byte) in token.utf8.enumerated() {
            outToken[index] = CChar(bitPattern: byte)
        }
        outToken[token.utf8.count] = 0
        return G02HostSecureIngressStatus.ok
    } catch {
        return G02HostSecureIngress.status(for: error)
    }
}

private func hostCLength(_ pointer: UnsafePointer<CChar>, maximum: Int) -> Int? {
    var length = 0
    while length <= maximum {
        if pointer[length] == 0 { return length }
        length += 1
    }
    return nil
}
