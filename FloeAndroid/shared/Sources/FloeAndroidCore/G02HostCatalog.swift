// SPDX-License-Identifier: MPL-2.0
//
// Trusted provider-catalog handoff for the ORDINARY production Root.
//
// The ORDINARY production composition constructs the provider domain with the
// ONE original bundled catalog document (FloeAgent/FloeApp/Resources/
// ProviderCatalog.json — models.dev schemaVersion 1, MIT, license recorded in
// the document itself). Swift module resources are unavailable on Android, so
// the trusted host (the App process, BEFORE it asks for the native Root start)
// reads the packaged, reviewed `provider/ProviderCatalog.json` asset and
// freezes those bytes here; the ordinary bootstrap install then passes them
// into `G02RuntimeComposition.install(gen:catalogBytes:)` → `G02DomainServices`
// → `ModelConfigurationFacade`, whose catalog slot uses ONLY the ORIGINAL
// decoder (`ProviderCatalogIndex.validated` through `ConfigCatalogValidator`).
//
// Guarantees (mirrors the reviewed G02SecurityCorpus handoff):
//  * NOT a wire command: no BridgeV3 key, no mailbox job, no session/grant,
//    no permission. Only the trusted host bootstrap path calls freeze (JNI,
//    pre-start). This changes no frozen command/envelope input grammar.
//  * Validation is the ORIGINAL decoder + the original document byte bound
//    (`ProviderCatalogIndex.maximumDocumentBytes`); a missing, tampered,
//    re-encoded, empty or schema-invalid catalog never freezes.
//  * Frozen ONCE per process and for the process lifetime: identical
//    re-freeze is idempotent, DIFFERENT bytes after a successful freeze are
//    refused (no silent swap under a live Root).
//  * A failed freeze leaves the catalog slot at its honest typed
//    `needsConfiguration` refusal (`catalogNotInjected`): the App keeps the
//    documented Custom compatible-endpoint path and NEVER shows a fabricated
//    or fixture catalog as the official one.

import Foundation
import FloeProviders

/// Additive status space for the trusted catalog handoff. The runtime-owner
/// space is -2xx, staging -3xx, security corpus -4xx; this seam owns -43x.
/// Types only: no path, byte, digest or document content ever leaves here.
public enum G02HostCatalogStatus {
    public static let ok: Int32 = 0
    public static let idempotentOk: Int32 = 1
    public static let invalidArguments: Int32 = -105
    public static let empty: Int32 = -431
    public static let oversized: Int32 = -432
    public static let invalid: Int32 = -433
    public static let conflict: Int32 = -436
}

public enum G02HostCatalog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var frozen: Data?

    /// Validate through the ORIGINAL decoder/schema, then freeze for process
    /// use. Returns [G02HostCatalogStatus] values; only ok/idempotentOk mean
    /// the bytes are available to the production ordinary bootstrap.
    @discardableResult
    public static func freeze(_ data: Data) -> Int32 {
        guard !data.isEmpty else { return G02HostCatalogStatus.empty }
        guard data.count <= ProviderCatalogIndex.maximumDocumentBytes else {
            return G02HostCatalogStatus.oversized
        }
        // ORIGINAL decoder: size bound + schemaVersion/providers/source +
        // per-entry Codable validation. Any failure rejects the document.
        if case .failure = ConfigCatalogValidator.validate(data) {
            return G02HostCatalogStatus.invalid
        }
        lock.lock()
        defer { lock.unlock() }
        if let existing = frozen {
            return existing == data ? G02HostCatalogStatus.idempotentOk
                : G02HostCatalogStatus.conflict
        }
        frozen = data
        return G02HostCatalogStatus.ok
    }

    /// The frozen, validated catalog bytes for the production composition.
    /// nil means "not frozen" — the facade keeps its typed
    /// `needsConfiguration(catalogNotInjected)` refusal and never invents a
    /// catalog.
    public static func frozenBytes() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return frozen
    }

    /// Test-only reset: never called by a wire or production path.
    internal static func resetForTesting() {
        lock.lock()
        frozen = nil
        lock.unlock()
    }
}

// MARK: - C ABI (trusted host bootstrap seam)

/// Freeze the trusted catalog bytes read by the host from the packaged
/// `provider/ProviderCatalog.json` asset. Called by the App bootstrap BEFORE
/// the native Root start; never reachable from the model/tool wire.
@_cdecl("floe_host_catalog_freeze")
public func floeHostCatalogFreeze(_ bytes: UnsafePointer<UInt8>?,
                                  _ length: Int32) -> Int32 {
    guard length >= 0 else { return G02HostCatalogStatus.invalidArguments }
    if length == 0 { return G02HostCatalogStatus.empty }
    guard Int(length) <= ProviderCatalogIndex.maximumDocumentBytes else {
        return G02HostCatalogStatus.oversized
    }
    guard let bytes else { return G02HostCatalogStatus.invalidArguments }
    let data = Data(bytes: bytes, count: Int(length))
    return G02HostCatalog.freeze(data)
}
