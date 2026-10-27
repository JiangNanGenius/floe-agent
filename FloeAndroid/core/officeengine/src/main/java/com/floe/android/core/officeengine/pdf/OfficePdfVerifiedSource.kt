// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine.pdf

import java.io.File

/**
 * The concrete, consumer-stable source seam for the PDF renderer/print path
 * (Main integration guidance 2026-10-27). The renderer family consumes an
 * ALREADY-VERIFIED owned file through ONLY these three facts and never
 * asks who verified it:
 *
 * This interface is a HANDOFF OF FACTS, not an authority: it grants the
 * renderer family no model, path, storage or filesystem authority of its
 * own. The consumer that CONSTRUCTS a source carries the responsibility —
 * it must have verified these facts with its own eyes (Office: the receipt
 * policy; a durable run-output consumer: its own sealed-store verify()) and
 * must OWN the file behind it.
 *
 *  - [readableFile]: a plain regular file the CALLING app process can open
 *    read-only (same UID). Ownership/retention belongs to the verifier: the
 *    renderer never writes, deletes, moves or lists anything;
 *  - [expectedSha256]: 64 lowercase hex, computed by the owner BEFORE the
 *    snapshot was handed over (Office receipts via
 *    [OfficePdfReceiptPolicy.proveBytes]; a future RunOutputFile consumer
 *    via its own sealed store verify());
 *  - [expectedBytes]: the exact positive length the owner digested
 *    (bounded by the module cap, 256 MiB).
 *
 * Verification timing (honest for consumers, corrected 2026-10-27):
 *  - the render HOST re-opens a fresh read-only FD per request (no
 *    persistent FD, per-page render does NOT re-hash — the isolated
 *    renderer parses only what the host's descriptor carries);
 *  - the PRINT ADAPTER instead pins ONE read-only NO-FOLLOW descriptor for
 *    the whole job: it fstats + magic-checks that descriptor at open and
 *    for EVERY write pass re-proves, THROUGH THE SAME PINNED DESCRIPTOR
 *    (dup + lseek, never a path re-open), the exact copied length, the
 *    whole-copy SHA-256 against [expectedSha256] and a clean EOF — so a
 *    path entry replaced after verification can never print under the old
 *    identity, and an in-place same-length rewrite is refused before any
 *    success terminal fires;
 *  - binder transport to the isolated renderer is FD-only (no paths cross
 *    the process boundary either way).
 * Callers must therefore only construct a source from files they OWN and
 * keep immutable + RETAINED for the snapshot's lifetime (module staged
 * outputs and sealed run outputs both qualify: verified outputs are never
 * rewritten).
 */
interface OfficePdfVerifiedSource {
    val readableFile: File
    val expectedSha256: String
    val expectedBytes: Long
}

/**
 * Pure shape guard run before ANY descriptor is opened (never a digest —
 * the shape check is cheap and bounds-hostile; full byte proof happens at
 * snapshot CREATION by the owner, and freshness re-checks at print writes).
 */
object OfficePdfVerifiedSourceContract {

    private val SHA256_REGEX = Regex("^[0-9a-f]{64}$")

    /** 1..256 MiB, identical to the module's pinned staged-output cap. */
    const val MAX_SOURCE_BYTES: Long = 256L shl 20

    fun shapeOk(source: OfficePdfVerifiedSource?): Boolean =
        source != null &&
            SHA256_REGEX.matches(source.expectedSha256) &&
            source.expectedBytes in 1L..MAX_SOURCE_BYTES &&
            source.readableFile.isAbsolute
}
