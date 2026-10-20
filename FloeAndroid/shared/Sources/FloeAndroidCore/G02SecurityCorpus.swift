// SPDX-License-Identifier: MPL-2.0
//
// Trusted catastrophic-corpus handoff for the ORDINARY production Root.
//
// The ORDINARY production composition builds a RunIngressContext per accepted
// generation. Its catastrophic gate needs the EXACT bundled FloeSecurity
// corpus bytes; the Swift module resource bundle is unavailable on Android
// (SWIFT_MODULE_RESOURCE_BUNDLE_UNAVAILABLE), so the trusted host (the App
// process, before it asks for the native Root start) reads the packaged
// `security/catastrophic-patterns.json` asset and freezes those bytes here.
//
// Guarantees:
//  * NOT a wire command: no BridgeV3 key, no mailbox job, no session/grant.
//    Only the trusted host bootstrap path calls [freeze] (JNI, pre-start).
//  * Validation is the ORIGINAL loader (`AndroidCatastrophicCorpus.makeGate`):
//    pinned SHA-256, <=1 MiB bound, same Codable shape, non-empty pattern
//    list and the SAME regex compile path. A missing, tampered, re-encoded,
//    empty or non-compiling corpus never freezes.
//  * Frozen ONCE per process and for the process lifetime: identical
//    re-freeze is idempotent, DIFFERENT bytes after a successful freeze are
//    refused (no silent swap under a live Root).
//  * A failed freeze leaves the corpus absent, so the run gate keeps its
//    honest `corpusAbsent` refusal BEFORE any model/store side effect; this
//    seam never substitutes an empty or match-nothing gate.

import Foundation

/// Additive status space for the trusted corpus handoff (the runtime-owner
/// space is -2xx, staging -3xx; this seam owns -4xx). Types only: no path,
/// byte, digest or corpus content ever leaves this seam.
public enum G02SecurityCorpusStatus {
    public static let ok: Int32 = 0
    public static let idempotentOk: Int32 = 1
    public static let invalidArguments: Int32 = -105
    public static let empty: Int32 = -421
    public static let oversized: Int32 = -422
    public static let invalid: Int32 = -423
    public static let conflict: Int32 = -426
}

public enum G02SecurityCorpus {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var frozen: Data?

    /// Validate through the ORIGINAL loader, then freeze for process use.
    /// Returns [G02SecurityCorpusStatus] values; only ok/idempotentOk mean
    /// the bytes are available to the production RunIngressContext.
    @discardableResult
    public static func freeze(_ data: Data) -> Int32 {
        guard !data.isEmpty else { return G02SecurityCorpusStatus.empty }
        guard data.count <= AndroidCatastrophicCorpus.maximumCorpusBytes else {
            return G02SecurityCorpusStatus.oversized
        }
        do {
            // Pinned hash + bounded size + SAME decode + non-empty patterns
            // + SAME regex compilation: any failure rejects the corpus.
            _ = try AndroidCatastrophicCorpus.makeGate(from: data)
        } catch {
            return G02SecurityCorpusStatus.invalid
        }
        lock.lock()
        defer { lock.unlock() }
        if let existing = frozen {
            return existing == data ? G02SecurityCorpusStatus.idempotentOk
                : G02SecurityCorpusStatus.conflict
        }
        frozen = data
        return G02SecurityCorpusStatus.ok
    }

    /// The frozen, validated corpus bytes for the production composition.
    /// nil means "not frozen" — the run gate then refuses with the truthful
    /// `corpusAbsent` and never a fabricated gate.
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

/// Freeze the trusted corpus bytes read by the host from the packaged
/// `security/catastrophic-patterns.json` asset. Called by the App bootstrap
/// BEFORE the native Root start; never reachable from the model/tool wire.
@_cdecl("floe_security_corpus_freeze")
public func floeSecurityCorpusFreeze(_ bytes: UnsafePointer<UInt8>?,
                                     _ length: Int32) -> Int32 {
    guard length >= 0 else { return G02SecurityCorpusStatus.invalidArguments }
    if length == 0 { return G02SecurityCorpusStatus.empty }
    guard Int(length) <= AndroidCatastrophicCorpus.maximumCorpusBytes else {
        return G02SecurityCorpusStatus.oversized
    }
    guard let bytes else { return G02SecurityCorpusStatus.invalidArguments }
    let data = Data(bytes: bytes, count: Int(length))
    return G02SecurityCorpus.freeze(data)
}
