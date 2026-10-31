// SPDX-License-Identifier: MPL-2.0
package com.floe.android.swiftbridge

import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction

/**
 * Trusted App transport for the G08 generic platform-tool lane.
 * DECLARATIONS ONLY — no business, permission, device or tool logic lives
 * here.
 *
 * Swift owns the bounded ticket table, strict trusted-descriptor validation,
 * dynamic registration in the ORIGINAL `ToolRunnerRegistry` and every
 * ownership check ([FloeAndroidCore] `PlatformToolHostMailbox` /
 * `PlatformToolHostBridge`). The Full App integrator supplies the actual
 * Full-only descriptor catalog and the App pump that claims tickets, performs
 * the typed phone/system operation in Kotlin, and settles exactly once.
 *
 * The common Play core never binds this lane: it registers no descriptor, so
 * a Play build exposes no phone/ADB/root tool name, schema or asset. This file
 * is source-only until Main wires `floe_platform_tools_jni.cpp` into the one
 * `floe_jni` target; the library below is the SAME `floe_jni` the existing
 * core bridge loaders pin (JVM `loadLibrary` is idempotent per class loader).
 *
 * Status space (mirrors the Swift exports exactly):
 *   0 ok; -101 stale claim; -102 generation fenced; -105 shape/shape refusal;
 *   -106 buffer too small; -107 oversize body; -108 descriptor or result
 *   invalid; -109 success refused because the owning call was cancelled;
 *   -110 claim not claimed (double-settle classification).
 *
 * Bodies (the authoritative wire contract is Swift-side):
 *   bind     -> catalog JSON `{"version":1,"tools":[...]}` (<= 128 KiB);
 *   setAvailability -> JSON name array `["namespace.action",...]`
 *     (<= 16 KiB, subset of the bound catalog) for the SAME live epoch;
 *   describe -> per-ticket descriptor JSON (<= 2048 B, closed key set);
 *   payload  -> model arguments JSON (<= 64 KiB, already schema-validated);
 *   complete status 0 -> result JSON (<= 64 KiB)
 *     `{"version":1,"summary":"...","exitStatus":0,
 *       "evidence":["..."],"artifact":{...}}`; a screenshot artifact MUST
 *     reference real bytes under the EXISTING `VNCArtifacts/` app-storage
 *     namespace (remote-screen evidence), with byteCount + SHA-256 of the
 *     actual PNG (`.png`, image/png) or JPEG (`.jpg`/`.jpeg`, image/jpeg);
 *     the Swift bridge re-reads and verifies it before it can become a
 *     model-visible `ToolArtifactReference`.
 *   complete status 1 -> typed failure `{"code":token,"detail":bounded}`
 *     (<= 512 B).
 *
 * The ticket descriptor carries the runtime-issued task/run/tool-call/
 * idempotency/scope/approval-grant identity; model JSON is NEVER an authority
 * source and can never replace those fields.
 */
object PlatformToolsNative {
    init { System.loadLibrary("floe_jni") }

    /** Bind ONE trusted Full-only catalog to the CURRENT live native root
     * epoch (strictly newer; Swift re-verifies the live epoch itself and
     * replaces every previously installed platform tool). 0 = accepted; any
     * negative = refused (no partial installation). */
    external fun bind(epoch: Long, catalog: ByteArray): Int

    /** Block up to [timeoutMillis] (clamped 0..1000 in JNI) for the next
     * queued ticket; 0 = none (re-arm). Positive = opaque claim id. */
    external fun next(timeoutMillis: Int): Long

    /** Publish the ACTUAL usable subset of the already-bound catalog for the
     * SAME live epoch (enable/disable without reopening the catalog or faking
     * a new generation). `namesJson` is a JSON string array of registered
     * names. Unknown/duplicate/oversized sets are refused atomically; queued
     * dispatch for names no longer available is fenced, in-flight claims keep
     * their original authority. Bind leaves every runner unavailable until
     * the Full host calls this. Returns 0 or a typed negative. */
    external fun setAvailability(epoch: Long, namesJson: ByteArray): Int

    /** Ticket descriptor JSON for a CLAIMED ticket, or null when stale/refused. */
    external fun describe(claim: Long): ByteArray?

    /** Full validated arguments JSON for a claimed ticket, or null on refusal. */
    external fun payload(claim: Long): ByteArray?

    /** 1 = the ticket still exists for the CURRENT bound generation. */
    external fun isLive(claim: Long): Int

    /** 1 = the owning tool call cancelled / generation fenced: stop the real
     * work and STILL settle exactly once via [complete]. */
    external fun shouldStop(claim: Long): Int

    /** Settle one claimed ticket exactly once. status 0 success (result JSON)
     * or status 1 typed failure. Returns 0 or a typed negative; a success
     * after cancellation is refused with -109 and never resumed as success. */
    external fun complete(claim: Long, status: Int, value: ByteArray): Int

    /** Exact-epoch teardown (fences waiters, removes owned runners). */
    external fun close(epoch: Long): Int

    /** Typed mailbox counters JSON (no arguments, results or host details). */
    external fun stats(): ByteArray?

    /** Actual readiness/capability JSON (bound epoch + installed tool names). */
    external fun readiness(): ByteArray?

    /** Trusted host readback of the ONE mailbox-bound actual artifact root
     * (`<live owned root>/FloeAgent`). null while unbound or after the root
     * epoch changed/retired. The Full image/screenshot writer commits its
     * real PNG or JPEG under this path's EXISTING `VNCArtifacts/` namespace;
     * the Swift bridge re-verifies bytes/MIME/size/SHA-256 before the image
     * can reach the model. Never a model-facing route or error string. */
    external fun artifactRoot(): ByteArray?

    /** Strict UTF-8 decode of [artifactRoot], or null when unbound/fenced. */
    fun artifactRootPath(): String? = strictText(artifactRoot())

    /** Strict UTF-8 JSON decode; a replacement-character guess is never
     * accepted for a descriptor, arguments or result body. */
    fun strictText(bytes: ByteArray?): String? = bytes?.let {
        runCatching {
            Charsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(it)).toString()
        }.getOrNull()
    }
}
