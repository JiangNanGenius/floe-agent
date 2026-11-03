// SPDX-License-Identifier: MPL-2.0
//
// Bounded, content-free UI state for C07 App entry.
//
// This is NOT an authorization journal, share grant store, task/config database
// or second persistence authority. It keeps only:
//  * a digest of recently handled intents, so rotation/process-restart
//    redelivery cannot apply the same share twice (no URI, name, text, path,
//    size or grant is stored);
//  * the setup guide's current step and dismissal flag (no provider, model,
//    voice, account or credential choice).
// A missing/corrupt record can only re-offer an intake or restart the guide;
// it can never grant a destination or approve content.
package com.floe.android.host.entryflow

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

internal class C07EntryFlowStore(context: Context) {
    private val prefs = context.applicationContext
        .getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** True when this exact intent was already admitted (live) or settled
     * within the bounded duplicate window. A stale ADMITTED record whose
     * owning intake is gone (process death) is allowed to start again. */
    @Synchronized
    fun isDuplicate(
        fingerprint: String,
        liveIntakeID: String?,
        now: Long,
    ): Boolean {
        val records = load(now)
        val record = records.firstOrNull { it.fingerprint == fingerprint }
        return C07EntryDedup.blocks(record, fingerprint, liveIntakeID, now)
    }

    @Synchronized
    fun begin(fingerprint: String, intakeID: String, now: Long) {
        val records = load(now).filterNot {
            it.fingerprint == fingerprint || it.intakeID == intakeID
        }.toMutableList()
        records += C07JournalRecord(
            fingerprint = fingerprint,
            intakeID = intakeID,
            status = C07EntryJournalStatus.ADMITTED,
            updatedAt = now,
            expiresAt = now + ENTRY_DEDUP_WINDOW_MS,
        )
        write(records.takeLast(MAX_RECORDS))
    }

    @Synchronized
    fun settle(fingerprint: String, intakeID: String, status: C07EntryJournalStatus, now: Long) {
        val records = load(now).filterNot { it.intakeID == intakeID }.toMutableList()
        // A completed intake is protected for the full duplicate window; a
        // discard/failure only needs to absorb an immediate Activity
        // redelivery, so a deliberate fresh share is not blocked for minutes.
        val expiry = if (status == C07EntryJournalStatus.COMPLETED) {
            now + ENTRY_DEDUP_WINDOW_MS
        } else {
            now + ENTRY_DISCARD_WINDOW_MS
        }
        records += C07JournalRecord(
            fingerprint = fingerprint,
            intakeID = intakeID,
            status = status,
            updatedAt = now,
            expiresAt = expiry,
        )
        write(records.takeLast(MAX_RECORDS))
    }

    @Synchronized
    fun purge(now: Long) {
        write(load(now))
    }

    private fun load(now: Long): MutableList<C07JournalRecord> {
        val raw = prefs.getString(KEY_JOURNAL, null) ?: return mutableListOf()
        val array = runCatching { JSONArray(raw) }.getOrNull() ?: return mutableListOf()
        val output = ArrayList<C07JournalRecord>(array.length())
        for (index in 0 until array.length()) {
            val objectValue = array.optJSONObject(index) ?: continue
            val fingerprint = objectValue.optString("f")
            val intakeID = objectValue.optString("id")
            val status = runCatching {
                C07EntryJournalStatus.valueOf(objectValue.optString("s"))
            }.getOrNull() ?: continue
            val updatedAt = objectValue.optLong("t", 0L)
            val expiresAt = objectValue.optLong("e", 0L)
            if (fingerprint.length != 64 || intakeID.length != 36) continue
            if (expiresAt <= now) continue
            output += C07JournalRecord(fingerprint, intakeID, status, updatedAt, expiresAt)
        }
        return output
    }

    private fun write(records: List<C07JournalRecord>) {
        val array = JSONArray()
        for (record in records) {
            array.put(
                JSONObject()
                    .put("f", record.fingerprint)
                    .put("id", record.intakeID)
                    .put("s", record.status.name)
                    .put("t", record.updatedAt)
                    .put("e", record.expiresAt),
            )
        }
        prefs.edit().putString(KEY_JOURNAL, array.toString()).commit()
    }

    private companion object {
        const val PREFS = "floe.entryflow.v1"
        const val KEY_JOURNAL = "intake.journal.v1"
        const val MAX_RECORDS = 24
    }
}

/**
 * Setup-guide progress. It intentionally does not read or write any settings
 * owner: provider, model, credential, voice and notification choices remain
 * exactly where they already live.
 */
internal class C07SetupGuideStore(context: Context) {
    private val prefs = context.applicationContext
        .getSharedPreferences("floe.entryflow.v1", Context.MODE_PRIVATE)

    @Synchronized
    fun load(): C07SetupState {
        val raw = prefs.getString(KEY_SETUP, null) ?: return C07SetupState()
        val objectValue = runCatching { JSONObject(raw) }.getOrNull()
            ?: return C07SetupState()
        return C07SetupState(
            step = C07SetupStep.fromKey(objectValue.optString("step")),
            seen = objectValue.optBoolean("seen", false),
            finished = objectValue.optBoolean("finished", false),
            skipped = objectValue.optBoolean("skipped", false),
            updatedAt = objectValue.optLong("t", 0L),
        )
    }

    @Synchronized
    fun save(state: C07SetupState) {
        val objectValue = JSONObject()
            .put("v", 1)
            .put("step", state.step.key)
            .put("seen", state.seen)
            .put("finished", state.finished)
            .put("skipped", state.skipped)
            .put("t", state.updatedAt)
        prefs.edit().putString(KEY_SETUP, objectValue.toString()).apply()
    }

    @Synchronized
    fun clear() {
        prefs.edit().remove(KEY_SETUP).apply()
    }

    private companion object {
        const val KEY_SETUP = "setup.state.v1"
    }
}
