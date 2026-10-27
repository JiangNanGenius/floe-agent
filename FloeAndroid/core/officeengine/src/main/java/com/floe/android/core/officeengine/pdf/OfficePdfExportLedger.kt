// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine.pdf

/**
 * Why the viewer asked the engine for one STAGED_EXPORT. The purpose is the
 * ONLY thing that decides what an OUTPUT_READY receipt may open (Main
 * contract 2026-10-27): a local PDF purpose can never fall through into the
 * SAF save-target handoff (which would open a picker, and could report a
 * user-file save or clear dirty state), and a SAF purpose keeps the existing
 * same-format Save Copy behaviour byte-for-byte.
 */
enum class OfficeExportPurpose {
    /** Existing flow: OUTPUT_READY hands the App the save-target picker channel (same format or PDF save-as). */
    SAF_COPY,

    /** Local only: OUTPUT_READY may open the isolated PDF preview. Never a picker, never "saved". */
    PDF_PREVIEW,

    /** Local only: OUTPUT_READY may open the system print dialog over the verified snapshot. Never "printed". */
    PDF_PRINT,
}

/**
 * Bounded, exact-once op→purpose ledger for one viewer mount.
 *
 * Rules (all fail-closed):
 *  - register binds one opId to exactly one purpose; re-registering an
 *    in-flight opId is refused (the engine serialises exports, a duplicate
 *    id here would be a module bug, never a silent overwrite);
 *  - consume removes AND returns the purpose in one step, so a late or
 *    duplicate terminal receipt for an already-consumed opId gets null and
 *    can open NOTHING (no renderer, no print, no picker, no notice flip);
 *  - unknown opIds always consume to null;
 *  - the map is bounded: the oldest entries are retired only for ops that
 *    already reached a terminal state elsewhere; an op registered but never
 *    terminalled stays visible until the mount ends (the engine's
 *    SESSION_ENDING/UNKNOWN receipts terminalise it honestly).
 */
class OfficePdfExportLedger(private val maxTracked: Int = MAX_TRACKED) {

    companion object {
        const val MAX_TRACKED = 16
    }

    private val purposes = LinkedHashMap<String, OfficeExportPurpose>()

    /** True when registered; false when the opId is already in flight. */
    fun register(opId: String, purpose: OfficeExportPurpose): Boolean = synchronized(purposes) {
        if (opId.isBlank() || purposes.containsKey(opId)) return false
        purposes[opId] = purpose
        // Defence-in-depth bound: retire the OLDEST entries when a mount
        // genuinely overflows tracking (never drop the newest in-flight op).
        while (purposes.size > maxTracked) {
            val oldest = purposes.keys.first()
            if (oldest == opId) break
            purposes.remove(oldest)
        }
        true
    }

    /** Exact-once consumption; null for unknown/consumed/stale/duplicate opIds. */
    fun consume(opId: String?): OfficeExportPurpose? = synchronized(purposes) {
        if (opId == null) null else purposes.remove(opId)
    }

    /** Peek without consuming (UI availability reporting only). */
    fun purposeOf(opId: String): OfficeExportPurpose? = synchronized(purposes) { purposes[opId] }

    fun inFlightCount(): Int = synchronized(purposes) { purposes.size }

    /** Mount end: nothing may be consumed afterwards. */
    fun clear() = synchronized(purposes) { purposes.clear() }
}
