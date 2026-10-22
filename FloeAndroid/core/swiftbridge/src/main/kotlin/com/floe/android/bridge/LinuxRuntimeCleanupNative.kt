// SPDX-License-Identifier: MPL-2.0
package com.floe.android.bridge

/**
 * G03-R3 trusted-host surface for the typed Core->runtime-UID workspace
 * cleanup request/receipt lane (job-3d39b56695c44bd2).
 *
 * Contract (implemented by Main's runtime-lane owner against these calls):
 *  - `bind` is called by the SAME trusted host that binds the shell mailbox,
 *    with the SAME accepted native Root epoch (strictly newer positive; the
 *    lane re-queues claimed records on rebind — a died pump never becomes
 *    "done"). Binding is NOT required to enqueue: Core queues obligations
 *    while unbound so cleanup cannot be stranded by admission fences.
 *  - Poll loop on a dedicated host worker (never the Main thread):
 *    next -> describe -> payload -> deliver over RuntimeWire to the runtime
 *    UID -> on the REAL execution result build the receipt JSON and call
 *    complete. The payload is the COMPLETE proven target-PROJECT scope
 *    (conversationID + projectID + targetEpoch + owned PrivateTasks shape);
 *    the runtime resolves its own copies by the same deterministic project
 *    mapping and MUST fail closed on anything it cannot prove.
 *  - Receipt JSON (<=4 KiB):
 *    {"requestID":"<32hex>","conversationID":"<uuid>","projectID":"<uuid>",
 *     "targetEpoch":N,"outcome":"cleared",
 *     "runtimeUID":<distinct int>,"certificateDigest":"<64hex>",
 *     "packageVersion":"...","binderIdentity":"...",
 *     "executorProofDigest":"<64hex>","pathsRemoved":N,"bytesFreed":N}
 *    or {"requestID":...,"conversationID":...,"projectID":...,"targetEpoch":N,
 *        "outcome":"refused","reason":"<bounded token>"} — a refusal RETAINS
 *    the obligation (retryable), never a success.
 *  - `status` is the lifecycle/host readback: only "settled" with a receipt
 *    digest proves the cross-UID wipe; the retained durable queue row
 *    finalizes through the existing owned retry sweep (the lane re-drives it
 *    on settlement, or the next launch sweep completes it).
 * Not a model-reachable surface: no V3 key, no tool registration.
 */
object LinuxRuntimeCleanupNative {
    init { System.loadLibrary("floe_jni") }

    /** 0 accepted; -105 refused (zero/stale/equal epoch). */
    external fun bind(epoch: Long): Int
    /** >0 claim token; 0 none/timeout; -1 unbound; -2 invalid bound. */
    external fun next(timeoutMillis: Int): Long
    external fun describe(claim: Long): ByteArray?
    /** The bounded scope payload for the claim, or null when stale/unknown. */
    external fun payload(claim: Long): ByteArray?
    external fun isLive(claim: Long): Boolean
    /** Settles the claim with the typed receipt JSON; reply body or null. */
    external fun complete(claim: Long, receipt: ByteArray): ByteArray?
    external fun status(requestID: String): ByteArray?
    external fun stats(): ByteArray?
}
