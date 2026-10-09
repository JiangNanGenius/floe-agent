//
//  EvalCache.swift
//  openshape3d
//
//  Memoised replay for `FeatureGraph.evaluate` — docs/INCREMENTAL_EVAL_DESIGN.md.
//
//  Every command used to replay every node from scratch: in a document holding
//  a 60M mm³ wheel, a trivial unrelated box extrude cost 18–21 s and +70 MB
//  (0.6 s in a light document). These types let a replay remember, per node,
//  the fingerprint of its inputs and the delta it applied to the state, so an
//  unchanged node is spliced back in instead of re-run.
//

import Foundation

/// One mutation a node made to the replay state, recorded while it ran so a
/// later replay can re-apply it without touching the kernel.
nonisolated enum EvalJournalOp: Sendable {
    /// A body the node inserted or replaced, its face table, and the
    /// kernel-face names the op wrote AFTER its put (nil = none). The names
    /// are back-filled at node end, because ops write them after `put`.
    case put(Body, FaceTable, kernelNames: [Int: ElementName]?)
    case remove(BodyID)
}

/// Everything a node did to the state: its ordered ops and its error.
/// `proposedUpgrades` are deliberately not here — see the design doc.
nonisolated struct EvalNodeDelta: Sendable {
    var ops: [EvalJournalOp] = []
    var error: FeatureError? = nil

    /// The bodies this delta puts, in order.
    var putBodyIDs: [BodyID] {
        ops.compactMap { if case let .put(body, _, _) = $0 { return body.id } else { return nil } }
    }
}

nonisolated struct EvalCacheEntry: Sendable {
    var fingerprint: UInt64
    var delta: EvalNodeDelta
}

/// The memo `FeatureGraph.evaluate(…, cache:)` reads and rewrites: per node,
/// the fingerprint of its inputs and the delta it produced. A value type —
/// the session owns one and threads it through each live rebuild; anything
/// that must not disturb the live memo evaluates against a copy and drops it.
/// Rebuilt on every replay, so nodes that left the graph are pruned for free.
nonisolated struct EvalCache: Sendable {
    var entries: [FeatureID: EvalCacheEntry] = [:]
    /// Diagnostics from the last replay: nodes spliced from the memo vs run.
    var lastSkipped = 0
    var lastRan = 0

    init() {}

    /// After the session applies a replay, cached bodies adopt the DOCUMENT's
    /// geometry and revision for every id given: the same content the replay
    /// produced, now with the re-minted `meshRevision` and SHARED copy-on-write
    /// storage — so a later splice compares equal to the document body (no
    /// needless replace, no GPU rebuild) and the memo does not double the
    /// geometry it remembers. Metadata and transform stay the replay's own:
    /// `performRebuild` re-applies the live name/hidden/material itself.
    ///
    /// Only the LAST node in `order` that puts a body id adopts it. An
    /// in-place op (boolean, blend, shell, push-pull) re-puts its target's
    /// id, so the document body is the LAST putter's output — the producer's
    /// own put must keep its snapshot. Adopting it too handed every later
    /// replay an already-cut plate as the plate node's "output": a boolean
    /// whose tool went stale left the old pocket in place, and re-picking
    /// the tool cut the pocketed body again (found live, 2026-09-02).
    mutating func adopt(_ live: [BodyID: Body], order: [FeatureID]) {
        var lastPutter: [BodyID: FeatureID] = [:]
        for id in order {
            guard let entry = entries[id] else { continue }
            for op in entry.delta.ops {
                if case let .put(body, _, _) = op { lastPutter[body.id] = id }
            }
        }
        for (id, entry) in entries {
            var delta = entry.delta
            delta.ops = delta.ops.map { op in
                guard case let .put(body, table, names) = op, lastPutter[body.id] == id,
                      let doc = live[body.id] else { return op }
                var adopted = body
                adopted.meshRevision = doc.meshRevision
                adopted.render = doc.render
                adopted.edges = doc.edges
                adopted.brep = doc.brep
                return .put(adopted, table, kernelNames: names)
            }
            entries[id] = EvalCacheEntry(fingerprint: entry.fingerprint, delta: delta)
        }
    }
}

/// Deterministic 64-bit FNV-1a over the bytes fed to it. Swift's `Hasher` is
/// seeded per process; this is stable across runs, dependency-free, and cheap
/// against the kernel work it saves.
nonisolated struct EvalFingerprint {
    private(set) var value: UInt64 = 0xcbf2_9ce4_8422_2325

    mutating func combine(_ data: Data) {
        for byte in data { value ^= UInt64(byte); value &*= 0x0000_0100_0000_01b3 }
    }

    mutating func combine(_ v: UInt64) {
        withUnsafeBytes(of: v) { for byte in $0 { value ^= UInt64(byte); value &*= 0x0000_0100_0000_01b3 } }
    }

    /// Sorted-keys JSON of a Codable value — byte-stable for equal content, so
    /// a `FeatureKind` (Codable, not Hashable) fingerprints without adding
    /// Hashable to a dozen payload types. Nil when encoding fails (a non-finite
    /// value); the caller must then salt so the node never falsely matches.
    static func json<T: Encodable>(_ value: T) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(value)
    }

    static func hash<T: Encodable>(_ value: T) -> UInt64 {
        var f = EvalFingerprint()
        if let data = json(value) { f.combine(data) } else { f.combine(UInt64.random(in: .min ... .max)) }
        return f.value
    }
}
