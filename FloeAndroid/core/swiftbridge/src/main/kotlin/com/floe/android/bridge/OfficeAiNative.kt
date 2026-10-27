// SPDX-License-Identifier: MPL-2.0
package com.floe.android.bridge

/**
 * Trusted App transport for the G05-R2 Office AI host lane
 * (job-1db1a7a8d5da457a). Declarations only — NO business logic lives here.
 *
 * This mirrors the reviewed [WorkspaceSourceNative] pump family exactly:
 * Swift owns the bounded ticket table, the edit-context store and every
 * semantic authority ([FloeAndroidCore] `OfficeAIHostMailbox` /
 * `OfficeAIEditContextStore` / `OfficeAIHostBridge`); the Kotlin pump
 * (delivered by the bounded App-host package) claims tickets, executes the
 * REAL App-host work (owner-safe open through OfficePreviewController,
 * precision commands through OfficePrecisionClient, save/export through the
 * existing save-copy host seam, OOXML verification, and the journal ladder
 * on a headless lane), and settles each claim exactly once.
 *
 * There is no model-facing route here: no V3 handler key, no tool name and
 * no bridge payload can reach these exports — only a bound, epoch-exact pump
 * claims tickets.
 *
 * Status space (mirrors the mailbox Swift exports; additive and disjoint
 * from gateway -1xx, runtime-owner -2xx, attachment -3xx, skills-folder
 * -4xx, source-host -5xx, run-output -7xx):
 *   0 ok; -101 stale claim; -102 generation fenced; -105 shape;
 *   -106 buffer too small; -107 oversize body; -108 descriptor invalid;
 *   -110 claim not claimed (double-settle classification).
 *
 * Ticket bodies (the wire contract is defined Swift-side in
 * OfficeAIHostContract.swift — the App package MUST mirror it exactly):
 *   describe -> descriptor JSON (<= 2048 B, closed key set per operation);
 *   payload  -> staged parameter bytes (<= 96 KiB: the typed text or the
 *               expectation text; EMPTY for control-only tickets);
 *   complete status 0 -> success reply JSON (<= 1 MiB, {"ok":1,...});
 *   complete status 1 -> typed failure {"code":token,"detail":bounded} (<= 256 B).
 */
object OfficeAiNative {
    init { System.loadLibrary("floe_jni") }

    /** Bind the pump to the CURRENT live root epoch (strictly newer; the
     * Swift export verifies the live [RuntimeCoreNative.g02NativeRootEpoch]
     * equality itself and installs the document.office.edit tool runner on
     * success). 0 = accepted; any negative = refused. */
    external fun bindEpoch(epoch: Long): Int

    /** Block up to [timeoutMillis] (clamped 0..1000 in JNI) for the next
     * queued ticket; 0 = none (re-arm). Positive = opaque claim id. */
    external fun next(timeoutMillis: Int): Long

    /** Descriptor JSON for a CLAIMED ticket, or null when stale/refused. */
    external fun describe(claim: Long): ByteArray?

    /** Full staged parameter bytes for a claimed ticket (empty when none),
     * or null on any typed refusal. */
    external fun payload(claim: Long): ByteArray?

    /** 1 = the ticket still exists for the CURRENT bound generation. */
    external fun isLive(claim: Long): Int

    /** 1 = the owning operation cancelled / generation fenced: stop the
     * real work and STILL settle exactly once via [complete]. */
    external fun shouldStop(claim: Long): Int

    /** Settle one claimed ticket once. status 0 success (reply JSON) or
     * status 1 typed failure ({"code","detail"} <= 256 B). Returns 0 or a
     * typed negative (never throws). */
    external fun complete(claim: Long, status: Int, value: ByteArray): Int

    /** Exact-epoch teardown (generation retirement). */
    external fun close(epoch: Long): Int

    /** Typed mailbox counters JSON (no paths, bytes, identities or content). */
    external fun stats(): ByteArray?
}
